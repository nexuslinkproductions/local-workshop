#!/usr/bin/env python3
"""feed-model-bench.py - measure the idle cost of the two feed process models.

  --model process     replay DeckMain's cadence, one fresh python3 per reader
  --model supervisor  run feeds/supervisor.py for real and sample its /proc

Both models get the same readers and cadences: sessions, link, metrics every
10 s, apps every 60 s. `df` is measured too in the process model (DeckMain runs
it); the supervisor does not own it.

link.py in the process model runs --fixture (no ssh, no tailscale). The live
cost reported by reports/fb.md (58.9 ms CPU per run) is added on top of the
measured sum and printed as a separate line, so the decision sees both.

Prints one JSON summary plus a short human table. Stdlib only.
"""
import argparse
import json
import os
import resource
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
V5 = os.path.join(REPO, "nexuslink.hud", "v5")
FEEDS = os.path.join(V5, "feeds")
FIX = os.path.join(V5, "fixtures")
SUP = os.path.join(FEEDS, "supervisor.py")
LIVE_LINK_MS = 58.9  # reports/fb.md: live link.py CPU per run, ssh included

# name, argv, interval seconds
JOBS = [
    ("sessions", ["python3", os.path.join(FEEDS, "sessions.py"), "--json"], 10),
    ("link", ["python3", os.path.join(FEEDS, "link.py"),
              "--fixture", os.path.join(FIX, "link.json"), "--json"], 10),
    ("metrics", ["python3", os.path.join(FEEDS, "metrics.py"), "--json"], 10),
    ("apps", ["python3", os.path.join(FEEDS, "apps.py"), "--json"], 60),
    ("df", ["df", "-B1", "--output=source,used,size,target", "-x", "tmpfs",
            "-x", "devtmpfs", "-x", "squashfs", "-x", "overlay"], 60),
]


def _cpu_of(pid):
    try:
        with open("/proc/%d/stat" % pid) as f:
            raw = f.read()
    except OSError:
        return None
    # comm may contain spaces/parens: cut after the last ')'
    rest = raw[raw.rfind(")") + 2:].split()
    ticks = os.sysconf("SC_CLK_TCK")
    utime, stime, cutime, cstime = (int(rest[11]), int(rest[12]),
                                    int(rest[13]), int(rest[14]))
    return (utime + stime + cutime + cstime) / float(ticks)


def _rss_kb(pid):
    try:
        with open("/proc/%d/status" % pid) as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1])
    except OSError:
        pass
    return 0


def _threads(pid):
    try:
        return len(os.listdir("/proc/%d/task" % pid))
    except OSError:
        return 0


def _child_count(pid):
    """Processes alive in the supervisor's process group, minus itself."""
    n = 0
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % entry) as f:
                raw = f.read()
            rest = raw[raw.rfind(")") + 2:].split()
            pgrp = int(rest[2])
        except (OSError, IndexError, ValueError):
            continue
        if pgrp == pid and int(entry) != pid:
            n += 1
    return n


def bench_process(seconds):
    t0 = time.monotonic()
    base = resource.getrusage(resource.RUSAGE_CHILDREN)
    spawns = 0
    peak = 0
    next_due = {}
    for name, _argv, iv in JOBS:
        next_due[name] = t0 + 0.05 * len(next_due)
    live = []
    while True:
        now = time.monotonic()
        if now - t0 >= seconds:
            break
        due = min(next_due.values())
        if due > now:
            time.sleep(min(due - now, 0.05))
            continue
        for name, argv, iv in JOBS:
            if next_due[name] > now:
                continue
            p = subprocess.Popen(argv, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
            live.append(p)
            spawns += 1
            peak = max(peak, len(live))
            next_due[name] = next_due[name] + iv
            # reap what has finished without blocking the schedule
            live = [q for q in live if q.poll() is None]
    for p in live:
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
    end = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = ((end.ru_utime + end.ru_stime) - (base.ru_utime + base.ru_stime))
    wall = time.monotonic() - t0
    link_runs = int(round(seconds / 10.0))
    return {
        "model": "process",
        "seconds": round(wall, 3),
        "cpu_s": round(cpu, 4),
        "percent_one_core": round(100.0 * cpu / wall, 3),
        "spawns": spawns,
        "peak_processes": peak,
        "link_runs": link_runs,
        "live_link_cpu_s_added": round(link_runs * LIVE_LINK_MS / 1000.0, 4),
        "percent_with_live_link": round(
            100.0 * (cpu + link_runs * LIVE_LINK_MS / 1000.0) / wall, 3),
        "note": "link measured with --fixture; live link +58.9 ms/run added above",
    }


def bench_supervisor(seconds, outdir):
    env = dict(os.environ)
    env["XDG_RUNTIME_DIR"] = outdir
    argv = ["nice", "-n", "19", "python3", SUP, "--out", outdir]
    proc = subprocess.Popen(argv, env=env, stdout=subprocess.DEVNULL,
                            stderr=subprocess.PIPE)
    t0 = time.monotonic()
    child_peak = 0
    samples = []
    try:
        while time.monotonic() - t0 < seconds:
            child_peak = max(child_peak, _child_count(proc.pid))
            time.sleep(0.1)
        cpu_end = _cpu_of(proc.pid)
        rss = _rss_kb(proc.pid)
        threads = _threads(proc.pid)
        wall = time.monotonic() - t0
        # between ticks: sample the child count for two seconds after the last
        # 10 s tick has had time to finish
        between = []
        tb = time.monotonic()
        while time.monotonic() - tb < 2.0:
            between.append(_child_count(proc.pid))
            time.sleep(0.05)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
    snaps = 0
    for name in ("sessions", "link", "metrics", "apps"):
        p = os.path.join(outdir, "nexuslink-hud", "feeds", name + ".json")
        if os.path.exists(p):
            snaps += 1
    return {
        "model": "supervisor",
        "seconds": round(wall, 3),
        "cpu_s": round(cpu_end or 0.0, 4),
        "percent_one_core": round(100.0 * (cpu_end or 0.0) / wall, 3),
        "peak_processes": child_peak + 1,
        "processes_alive_between_ticks": max(between) if between else None,
        "rss_kb_idle": rss,
        "threads": threads,
        "snapshots_written": snaps,
        "exit": proc.returncode,
        "stdout_head": "",
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, choices=["process", "supervisor"])
    ap.add_argument("--seconds", type=int, default=60)
    ap.add_argument("--out", default="")
    a = ap.parse_args()
    out = a.out or os.path.join(os.environ.get("TMPDIR", "/tmp"),
                                "feed-model-bench-%d" % os.getpid())
    os.makedirs(out, exist_ok=True)
    if a.model == "process":
        r = bench_process(a.seconds)
    else:
        r = bench_supervisor(a.seconds, out)
    print(json.dumps(r, indent=2, sort_keys=True))
    return 0 if r.get("percent_one_core", 1) >= 0 else 1


if __name__ == "__main__":
    sys.exit(main())
