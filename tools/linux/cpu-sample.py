#!/usr/bin/env python3
"""CPU sampler: percent of one core used by a process over a window.

    sample.py <pid> <seconds> [warmup]

Reads /proc/<pid>/stat utime+stime twice and reports the delta over the window,
100 percent meaning one core fully busy. Also prints thread count and RSS.
Exit 1 when the process is gone.
"""
import os
import sys
import time

CLK_TCK = os.sysconf("SC_CLK_TCK")
PAGE = os.sysconf("SC_PAGE_SIZE")


def read_stat(pid):
    with open("/proc/%d/stat" % pid, "r") as f:
        raw = f.read()
    # comm may contain spaces and parentheses; everything after the last ')' is
    # positional from field 3 on.
    fields = raw[raw.rfind(")") + 2:].split()
    utime = int(fields[11])
    stime = int(fields[12])
    threads = int(fields[17])
    return utime + stime, threads


def read_rss_mb(pid):
    with open("/proc/%d/statm" % pid, "r") as f:
        parts = f.read().split()
    return int(parts[1]) * PAGE / (1024.0 * 1024.0)


def main():
    if len(sys.argv) < 3:
        print("usage: sample.py <pid> <seconds> [warmup]", file=sys.stderr)
        return 64
    pid = int(sys.argv[1])
    window = float(sys.argv[2])
    warmup = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0

    if not os.path.isdir("/proc/%d" % pid):
        print("cpu-sample: no such process: %d" % pid, file=sys.stderr)
        return 1
    if warmup > 0:
        time.sleep(warmup)

    start_ticks, threads = read_stat(pid)
    t0 = time.monotonic()
    dt = 0.0
    while dt < window:
        time.sleep(min(0.1, window - dt))
        dt = time.monotonic() - t0
    end_ticks, threads = read_stat(pid)

    cpu = (end_ticks - start_ticks) / CLK_TCK / dt * 100.0
    print("pid=%d cpu=%.1f%% threads=%d rss=%.1fMB window=%.2fs"
          % (pid, cpu, threads, read_rss_mb(pid), dt))
    return 0


if __name__ == "__main__":
    sys.exit(main())
