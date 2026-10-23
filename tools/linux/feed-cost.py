#!/usr/bin/env python3
"""feed-cost.py - measure what one run of a feed reader costs on this machine.

    tools/linux/feed-cost.py [--runs N] [--timeout S] [--cadence SECONDS] -- <command ...>

Runs <command> N times (default 10), one after the other, and reports:

  cpu_ms_per_run      user+sys CPU of the command and all its children that were
                      waited for (getrusage RUSAGE_CHILDREN delta, divided by N)
  wall_ms_per_run     mean wall time
  procs_per_run       mean number of distinct processes seen in the command's tree
                      (the command itself plus every descendant, polled from /proc
                      every 2 ms, so a process that lives under 2 ms can be missed)
  exit_codes          sorted unique exit codes
  cpu_pct_at_cadence  cpu_ms_per_run / (cadence * 1000) * 100, when --cadence is given
                      (percent of ONE core if the command runs once per cadence seconds)

One JSON object on stdout. Stdout of the command is discarded. Nothing is written
to disk. Meant for the feed readers under nexuslink.hud/v5/feeds/, but works on any
command. Use nice for realistic numbers on a busy box; the CPU time itself does not
depend on niceness.
"""
import argparse
import json
import os
import resource
import subprocess
import sys
import threading
import time


def descendants(root_pid):
    """Return the set of pids under root_pid (including it), from /proc."""
    seen = {root_pid}
    frontier = [root_pid]
    while frontier:
        pid = frontier.pop()
        try:
            for tid in os.listdir("/proc/%d/task" % pid):
                try:
                    with open("/proc/%d/task/%s/children" % (pid, tid)) as fh:
                        for tok in fh.read().split():
                            child = int(tok)
                            if child not in seen:
                                seen.add(child)
                                frontier.append(child)
                except OSError:
                    continue
        except OSError:
            continue
    return seen


def run_once(cmd, timeout):
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            start_new_session=True)
    seen = {proc.pid}
    stop = threading.Event()

    def poll():
        while not stop.is_set():
            seen.update(descendants(proc.pid))
            time.sleep(0.002)

    thread = threading.Thread(target=poll, daemon=True)
    thread.start()
    started = time.monotonic()
    try:
        code = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, 9)
        except OSError:
            pass
        proc.wait()
        code = "timeout"
    wall = time.monotonic() - started
    stop.set()
    thread.join(timeout=1)
    return code, wall, len(seen)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runs", type=int, default=10)
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--cadence", type=float, default=0.0, help="seconds between runs in production")
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    args = ap.parse_args()
    cmd = args.cmd[1:] if args.cmd and args.cmd[0] == "--" else args.cmd
    if not cmd:
        ap.error("give a command after --")
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    codes, walls, procs = [], [], []
    for _ in range(max(1, args.runs)):
        code, wall, nproc = run_once(cmd, args.timeout)
        codes.append(code)
        walls.append(wall)
        procs.append(nproc)
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)
    n = float(len(codes))
    cpu_ms = cpu / n * 1000.0
    out = {
        "cmd": cmd,
        "runs": len(codes),
        "cpu_ms_per_run": round(cpu_ms, 2),
        "wall_ms_per_run": round(sum(walls) / n * 1000.0, 1),
        "procs_per_run": round(sum(procs) / n, 2),
        "procs_max": max(procs),
        "exit_codes": sorted({str(c) for c in codes}),
    }
    if args.cadence > 0:
        out["cadence_s"] = args.cadence
        out["cpu_pct_at_cadence"] = round(cpu_ms / (args.cadence * 1000.0) * 100.0, 4)
    json.dump(out, sys.stdout, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
