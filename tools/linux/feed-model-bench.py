#!/usr/bin/env python3
"""feed-model-bench.py - idle cost of the two feed process models, same readers, same cadence.

  --model process       DeckMain's model: one fresh python3 per reader per tick.
  --model supervisor    feeds/supervisor.py runs the same readers on the same cadence.
  --optional            supervisor only: also enable the five optional jobs.
  --seconds N           window (default 60).
  --out DIR             scratch root (default $TMPDIR/feed-model-bench-<pid>).

Cadence, both models: sessions, link, metrics every 10 s; apps and df every 60 s.
Every job has its first run at the window start, so a 60 s window holds 6 runs of
each 10 s job and 1 run of each 60 s job. df runs in both models (DeckMain runs it
today); in model B it is a separate process series next to the supervisor.
link runs with --fixture (no ssh). The live link cost (58.9 ms CPU per run,
reports/fb.md) is added on its own line from the link runs counted.

CPU is process CPU time (utime + stime, children included), not top percent,
because the host is shared. The load average is printed at start and end.
Prints one JSON object. Stdlib only.
"""
import argparse
import json
import math
import os
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
V5 = os.path.join(REPO, "nexuslink.hud", "v5")
FEEDS = os.path.join(V5, "feeds")
FIX = os.path.join(V5, "fixtures")
SUP = os.path.join(FEEDS, "supervisor.py")
PY = sys.executable
LIVE_LINK_MS = 58.9  # reports/fb.md: live link.py CPU per run, ssh included
OPTIONAL = ["callcap", "chief", "level", "recent", "game_mode"]
CLK = os.sysconf("SC_CLK_TCK")

# name, argv, interval seconds (same readers and argv as supervisor.JOBS)
JOBS = [
    ("sessions", [PY, os.path.join(FEEDS, "sessions.py"), "--json"], 10),
    ("link", [PY, os.path.join(FEEDS, "link.py"), "--fixture",
              os.path.join(FIX, "link.json"), "--json"], 10),
    ("metrics", [PY, os.path.join(FEEDS, "metrics.py"), "--json"], 10),
    ("apps", [PY, os.path.join(FEEDS, "apps.py"), "--json"], 60),
    ("df", ["df", "-B1", "--output=source,used,size,target", "-x", "tmpfs",
            "-x", "devtmpfs", "-x", "squashfs", "-x", "overlay"], 60),
]


def _loadavg():
    with open("/proc/loadavg") as f:
        return [float(x) for x in f.read().split()[:3]]


def _cpu_stat(pid):
    """utime + stime + cutime + cstime of pid in seconds, or None if gone."""
    try:
        with open("/proc/%d/stat" % pid) as f:
            raw = f.read()
    except OSError:
        return None
    rest = raw[raw.rfind(")") + 2:].split()  # comm may hold spaces: cut after ')'
    return sum(int(rest[i]) for i in (11, 12, 13, 14)) / float(CLK)


def _status_kb(pid, key):
    try:
        with open("/proc/%d/status" % pid) as f:
            for line in f:
                if line.startswith(key + ":"):
                    return int(line.split()[1])
    except OSError:
        pass
    return 0


def _direct_children(pid):
    """Direct children from the kernel's children list (one small file read)."""
    try:
        with open("/proc/%d/task/%d/children" % (pid, pid)) as f:
            return len(f.read().split())
    except OSError:
        return 0


def _rusage_s(ru):
    return ru.ru_utime + ru.ru_stime


def bench_process(seconds):
    t0 = time.monotonic()
    load0 = _loadavg()
    events = []
    for name, argv, iv in JOBS:
        for k in range(int(math.ceil(seconds / float(iv)))):
            events.append((k * iv, name, argv))
    events.sort(key=lambda e: e[0])
    live = {}     # pid -> (name, started monotonic, Popen)
    per_job = {}  # name -> list of wall ms
    rss = []      # per child peak RSS in kB
    cpu = {"sum": 0.0}
    peak = [0]
    spawns = [0]

    def reap(block):
        for pid in list(live):
            done, status, ru = os.wait4(pid, 0 if block else os.WNOHANG)
            if done != pid:
                continue
            name, t_s, proc = live.pop(pid)
            proc.stdout.read()  # the reader's JSON, read and dropped
            proc.stdout.close()
            per_job.setdefault(name, []).append((time.monotonic() - t_s) * 1000.0)
            rss.append(ru.ru_maxrss)
            cpu["sum"] += _rusage_s(ru)

    for off, name, argv in events:
        target = t0 + off
        while time.monotonic() < target:
            reap(False)
            time.sleep(max(0.0, min(0.005, target - time.monotonic())))
        reap(False)
        t_s = time.monotonic()
        p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        live[p.pid] = (name, t_s, p)
        spawns[0] += 1
        peak[0] = max(peak[0], len(live))
    while live:
        reap(True)
    wall = max(seconds, time.monotonic() - t0)
    return dict(
        model="process", optional=False, seconds=seconds, wall_s=round(wall, 3),
        load_start=load0, load_end=_loadavg(),
        cpu_s=round(cpu["sum"], 4),
        percent_one_core=round(100.0 * cpu["sum"] / wall, 3),
        spawns=spawns[0], spawns_per_min=round(spawns[0] * 60.0 / seconds, 2),
        peak_processes=peak[0],
        rss_kb_child_peak_avg=round(sum(rss) / float(len(rss)), 0) if rss else 0,
        rss_kb_child_peak_max=max(rss) if rss else 0,
        runs={n: len(v) for n, v in per_job.items()},
        avg_wall_ms={n: round(sum(v) / len(v), 1) for n, v in per_job.items()},
        max_wall_ms={n: round(max(v), 1) for n, v in per_job.items()},
        link_runs=len(per_job.get("link", [])),
    )


def bench_supervisor(seconds, out, optional):
    root = os.path.join(out, "nexuslink-hud", "feeds")
    env = dict(os.environ)
    env["XDG_RUNTIME_DIR"] = out
    argv = [PY, SUP, "--out", out, "--link-fixture", os.path.join(FIX, "link.json")]
    for n in (OPTIONAL if optional else []):
        argv += ["--enable", n]
    load0 = _loadavg()
    proc = subprocess.Popen(argv, env=env, stdout=subprocess.DEVNULL,
                            stderr=subprocess.PIPE)
    hb = os.path.join(root, "supervisor.json")
    deadline = time.monotonic() + 10.0
    while not os.path.exists(hb) and time.monotonic() < deadline:
        time.sleep(0.02)
    t0 = time.monotonic()
    cpu_start = _cpu_stat(proc.pid) or 0.0
    rss_samples, peak_kids = [], 0
    df_cpu, df_walls, df_runs = 0.0, [], 0
    df_argv = [a for n, a, iv in JOBS if n == "df"][0]
    df_offs = [k * 60 for k in range(int(math.ceil(seconds / 60.0)))]
    df_live = None
    df_t = None
    k_next = 0
    while time.monotonic() - t0 < seconds:
        now = time.monotonic() - t0
        if df_live is None and k_next < len(df_offs) and now >= df_offs[k_next]:
            df_live = subprocess.Popen(df_argv, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL)
            df_t = time.monotonic()
            k_next += 1
        if df_live is not None:
            done, status, ru = os.wait4(df_live.pid, os.WNOHANG)
            if done == df_live.pid:
                df_cpu += _rusage_s(ru)
                df_walls.append((time.monotonic() - df_t) * 1000.0)
                df_runs += 1
                df_live = None
        peak_kids = max(peak_kids, _direct_children(proc.pid))
        rss_samples.append(_status_kb(proc.pid, "VmRSS"))
        time.sleep(0.1)
    while df_live is not None:
        done, status, ru = os.wait4(df_live.pid, 0)
        df_cpu += _rusage_s(ru)
        df_walls.append((time.monotonic() - df_t) * 1000.0)
        df_runs += 1
        df_live = None
    vmhwm = _status_kb(proc.pid, "VmHWM")
    threads = _status_kb(proc.pid, "Threads")
    proc.send_signal(signal.SIGTERM)
    # wait4 returns the supervisor's own rusage, its reaped children included
    _done, status, ru = os.wait4(proc.pid, 0)
    cpu_end = _rusage_s(ru)
    wall = time.monotonic() - t0
    try:
        with open(hb) as f:
            final = json.load(f)
    except (OSError, ValueError):
        final = {}
    sup_cpu = cpu_end - cpu_start
    spawns = int(final.get("spawns", 0))
    total_cpu = sup_cpu + df_cpu
    return dict(
        model="supervisor", optional=optional, seconds=seconds, wall_s=round(wall, 3),
        load_start=load0, load_end=_loadavg(),
        supervisor_cpu_s=round(sup_cpu, 4),
        supervisor_percent_one_core=round(100.0 * sup_cpu / wall, 3),
        df_cpu_s=round(df_cpu, 4), df_runs=df_runs,
        df_avg_wall_ms=round(sum(df_walls) / len(df_walls), 1) if df_walls else None,
        cpu_s=round(total_cpu, 4),
        percent_one_core=round(100.0 * total_cpu / wall, 3),
        spawns=spawns + df_runs,
        spawns_supervisor=spawns,
        spawns_per_min=round((spawns + df_runs) * 60.0 / seconds, 2),
        peak_processes=peak_kids + 1,
        rss_kb_supervisor_vmhwm=vmhwm,
        rss_kb_supervisor_idle_last=rss_samples[-1] if rss_samples else 0,
        threads=threads,
        exit=proc.returncode,
        runs={n: int(v) for n, v in (final.get("runs") or {}).items()},
        avg_wall_ms={n: round(final["run_ms"][n] / final["runs"][n], 1)
                     for n in (final.get("runs") or {})
                     if final["runs"][n] and n in (final.get("run_ms") or {})},
        kills=final.get("kills"), skipped=final.get("skipped"),
        link_runs=int((final.get("runs") or {}).get("link", 0)),
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, choices=["process", "supervisor"])
    ap.add_argument("--seconds", type=int, default=60)
    ap.add_argument("--optional", action="store_true")
    ap.add_argument("--out", default="")
    a = ap.parse_args()
    out = a.out or os.path.join(os.environ.get("TMPDIR", "/tmp"),
                                "feed-model-bench-%d" % os.getpid())
    os.makedirs(out, exist_ok=True)
    if a.model == "process":
        r = bench_process(a.seconds)
    else:
        r = bench_supervisor(a.seconds, out, a.optional)
    # the live link line: same method for both models, computed not run
    link_runs = r.get("link_runs", 0)
    added = link_runs * LIVE_LINK_MS / 1000.0
    r["live_link_cpu_s_added"] = round(added, 4)
    r["percent_with_live_link"] = round(100.0 * (r["cpu_s"] + added) / r["wall_s"], 3)
    print(json.dumps(r, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
