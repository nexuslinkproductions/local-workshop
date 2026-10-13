#!/usr/bin/env python3
"""lag-probe.py — desktop wakeup latency probe: measures how much a running job
steals from the CPUs the desktop lives on. Sleep 1 ms in a loop and record the
overshoot (how much later than 1 ms the process actually woke up).

    taskset -c 0-5 lag-probe.py [seconds]     # pin to CCD0 = the desktop's CPUs

Prints: samples p50 p99 max  (overshoot in ms). Run it idle to get the floor,
then during a bench run; p99 is the number that tracks visible stutter.
"""
import sys
import time

dur = float(sys.argv[1]) if len(sys.argv) > 1 else 60.0
t_end = time.perf_counter() + dur
ov = []
while time.perf_counter() < t_end:
    t0 = time.perf_counter()
    time.sleep(0.001)
    ov.append((time.perf_counter() - t0 - 0.001) * 1000.0)
ov.sort()


def pct(q):
    return ov[min(len(ov) - 1, int(q * len(ov)))]


print(f"samples={len(ov)} p50={pct(0.50):.2f} p99={pct(0.99):.2f} max={ov[-1]:.2f} ms")
