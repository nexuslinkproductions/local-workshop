#!/usr/bin/env python3
"""perf-prof.py <file.unitrace> [topN] : top kernels by device time from a unitrace -d summary (kernel names contain commas -> rsplit)."""
import re, sys
rows, tot = [], None
for line in open(sys.argv[1], errors="replace"):
    if "Total Device Time" in line: tot = int(re.search(r"(\d+)\s*$", line).group(1))
    if line.startswith("=== Kernel Properties"): break
    s = line.strip()
    parts = s.rsplit(",", 6)
    if len(parts) == 7 and parts[1].strip().isdigit() and not s.startswith("Kernel"):
        rows.append((parts[0].strip(), int(parts[1]), int(parts[2]), float(parts[3])))
rows.sort(key=lambda r: -r[2]); n = int(sys.argv[2]) if len(sys.argv) > 2 else 10
print(f"total device time ns: {tot}  kernels: {len(rows)}")
print("rank\tshare%\tcalls\ttotal_ms\tavg_us\tkernel")
for i, (k, c, t, p) in enumerate(rows[:n], 1):
    print(f"{i}\t{100*t/tot:.1f}\t{c}\t{t/1e6:.1f}\t{t/c/1e3:.1f}\t{re.sub(r'\\s+', ' ', k)[:150]}")
