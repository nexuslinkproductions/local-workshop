#!/usr/bin/env python3
"""GPU engine busy percent of one process from two DRM fdinfo samples.

Reads /proc/<pid>/fdinfo/* only: no root, no intel_gpu_top, no perf. See
gpu-idle.sh for the command line and the output format.
"""
import os
import sys
import time


def read_fdinfo(pid):
    """Return {(pdev, client_id, engine): (busy, elapsed, unit, driver)}."""
    out = {}
    drivers = {}
    base = "/proc/%d/fdinfo" % pid
    try:
        names = os.listdir(base)
    except OSError:
        return out, drivers
    for name in names:
        path = os.path.join(base, name)
        try:
            with open(path, "r", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        drv = pdev = cid = None
        cyc = {}
        tot = {}
        ns = {}
        for line in lines:
            if ":" not in line:
                continue
            key, _, val = line.partition(":")
            val = val.strip()
            if key == "drm-driver":
                drv = val
            elif key == "drm-pdev":
                pdev = val
            elif key == "drm-client-id":
                cid = val
            elif key.startswith("drm-cycles-"):
                cyc[key[len("drm-cycles-"):]] = int(val)
            elif key.startswith("drm-total-cycles-"):
                tot[key[len("drm-total-cycles-"):]] = int(val)
            elif key.startswith("drm-engine-") and key.endswith("-ns"):
                ns[key[len("drm-engine-"):-3]] = int(val)
        if drv is None or pdev is None or cid is None:
            continue
        drivers[pdev] = drv
        for eng, busy in cyc.items():
            k = (pdev, cid, eng)
            prev = out.get(k)
            if prev is None or busy > prev[0]:
                out[k] = (busy, tot.get(eng, 0), "cycles", drv)
        for eng, busy in ns.items():
            k = (pdev, cid, eng)
            prev = out.get(k)
            if prev is None or busy > prev[0]:
                out[k] = (busy, 0, "ns", drv)
    return out, drivers


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: gpu-idle.py <pid> <seconds> [warmup]\n")
        return 64
    pid = int(sys.argv[1])
    secs = float(sys.argv[2])
    warm = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
    if not os.path.isdir("/proc/%d" % pid):
        sys.stderr.write("gpu-idle: pid %d is gone\n" % pid)
        return 1
    first, _ = read_fdinfo(pid)
    if not first:
        sys.stderr.write("gpu-idle: pid %d has no accounted DRM fd "
                         "(no drm-cycles/drm-engine keys in fdinfo)\n" % pid)
        return 2
    time.sleep(warm)
    a, drivers = read_fdinfo(pid)
    t0 = time.monotonic()
    time.sleep(secs)
    b, drivers_b = read_fdinfo(pid)
    wall = time.monotonic() - t0
    drivers.update(drivers_b)

    busy = {}
    total = {}
    clients = {}
    units = {}
    skipped = 0
    for k, (bval, btot, unit, _drv) in b.items():
        if k not in a:
            skipped += 1
            continue
        aval, atot, _u, _d = a[k]
        pdev, cid, eng = k
        d_busy = bval - aval
        d_tot = btot - atot
        if unit == "ns":
            d_tot = int(wall * 1e9)
        if d_busy < 0 or d_tot <= 0:
            skipped += 1
            continue
        g = (pdev, eng)
        busy[g] = busy.get(g, 0) + d_busy
        if d_tot > total.get(g, 0):
            total[g] = d_tot
        clients[g] = clients.get(g, 0) + 1
        units[g] = unit

    if not busy:
        sys.stderr.write("gpu-idle: no counter delta in the window "
                         "(pid %d idle on another GPU or counters not exposed)\n" % pid)
        return 3

    render = {}
    compute = {}
    for (pdev, eng) in sorted(busy):
        pct = 100.0 * busy[(pdev, eng)] / total[(pdev, eng)]
        print("%-14s %-8s %-4s %-6s busy=%.2f%% clients=%d"
              % (pdev, drivers.get(pdev, "?"), eng, units[(pdev, eng)],
                 pct, clients[(pdev, eng)]))
        if eng in ("rcs", "gfx"):
            render[pdev] = render.get(pdev, 0.0) + pct
        if eng == "ccs":
            compute[pdev] = compute.get(pdev, 0.0) + pct
    for pdev in sorted(render):
        print("RENDER %-14s %s busy=%.2f%% over %.1fs (pid %d)"
              % (pdev, drivers.get(pdev, "?"), render[pdev], wall, pid))
    for pdev in sorted(compute):
        print("COMPUTE %-13s %s busy=%.2f%% over %.1fs (pid %d)"
              % (pdev, drivers.get(pdev, "?"), compute[pdev], wall, pid))
    if skipped:
        print("NOTE skipped=%d counter entries (fd opened or closed inside "
              "the window)" % skipped)
    return 0


if __name__ == "__main__":
    sys.exit(main())
