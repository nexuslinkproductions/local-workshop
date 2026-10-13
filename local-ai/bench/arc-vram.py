#!/usr/bin/env python3
"""arc-vram.py — user-space VRAM usage for the Arc B580 (xe driver) via DRM fdinfo.

The xe driver writes `drm-total-vram0` / `drm-total-gtt` into each DRM client's
/proc/<pid>/fdinfo/<fd>. Forked children share the file descriptor, so the same
`drm-client-id` shows up in many pids — we de-duplicate by client-id before
summing, otherwise usage is counted once per thread.

    ./arc-vram.py           # "free=<MiB> total=<MiB> used=<MiB>"
    ./arc-vram.py --json    # per-client breakdown too

ponytail: reads the whole /proc on each call; fine for a bench tag, not a daemon.
"""
import glob, json, os, re, sys

PDEV = "0000:03:00.0"                       # Arc B580 PCI address
TOTAL = 12168933376                          # clinfo: Global memory size (11.33 GiB)

def _kib(v: str) -> int:
    v = v.strip()
    m = re.match(r"(\d+)\s*(KiB|MiB|GiB|B)?", v)
    if not m:
        return 0
    n = int(m.group(1))
    return n * {"KiB": 1, "MiB": 1024, "GiB": 1024 * 1024, "B": 1 / 1024, None: 1}[m.group(2)]

def clients():
    """{client_id: (vram_kib, gtt_kib, pids)} for every live Arc DRM client."""
    out = {}
    for path in glob.glob("/proc/[0-9]*/fdinfo/*"):
        try:
            txt = open(path).read()
        except OSError:
            continue
        if f"drm-pdev:\t{PDEV}" not in txt:
            continue
        d = dict(re.findall(r"^(drm-[a-z0-9-]+):\t(.*)$", txt, re.M))
        cid = d.get("drm-client-id")
        if cid is None:
            continue
        vr = _kib(d.get("drm-total-vram0", "0"))
        gt = _kib(d.get("drm-total-gtt", "0"))
        prev = out.get(cid, (0, 0, 0))
        out[cid] = (max(prev[0], vr), max(prev[1], gt), prev[2] + 1)
    return out

def main():
    c = clients()
    used_kib = sum(v for v, _, _ in c.values())
    gtt_kib = sum(g for _, g, _ in c.values())
    total_mib = TOTAL / 1048576
    used_mib = used_kib / 1024
    free_mib = total_mib - used_mib
    if "--json" in sys.argv:
        print(json.dumps({
            "free_mib": round(free_mib, 1), "total_mib": round(total_mib, 1),
            "used_mib": round(used_mib, 1), "gtt_used_mib": round(gtt_kib / 1024, 1),
            "clients": {k: {"vram_mib": round(v / 1024, 1), "pids": p} for k, (v, _, p) in c.items()},
        }))
    else:
        print(f"free={free_mib:.0f} total={total_mib:.0f} used={used_mib:.0f} gtt={gtt_kib/1024:.0f}")

if __name__ == "__main__":
    main()
