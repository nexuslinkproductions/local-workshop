#!/usr/bin/env python3
# vram-sampler.py <csv> <breach_flag>: free B580 VRAM every 2 s (bench/arc-vram.py).
# free < FLOOR MiB (env VRAM_FLOOR_MIB, default 750, Marcel 2026-10-13 21:00 (was 900)) -> write breach flag once and stop run_suite / llama-swap / llama-server (model is stopped, not restarted).
import os, re, subprocess, sys, time
FLOOR = int(os.environ.get("VRAM_FLOOR_MIB", "750"))
csv, flag = sys.argv[1], sys.argv[2]
LAB = "/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB"
STOP = [["pkill", "-TERM", "-f", "[r]un_suite.py"],
        ["pkill", "-TERM", "-f", "[l]lama-swap -config serve/config.yaml"],
        ["pkill", "-TERM", "-f", "[l]lama-server.*--port 18"]]
def free():
    out = subprocess.run(["python3", f"{LAB}/bench/arc-vram.py"], capture_output=True, text=True).stdout
    m = re.search(r"free=(-?\d+)", out)   # 21:20 bug: negative free (VRAM overcommitted into GTT) failed \d+ -> -1 -> never breached
    return int(m.group(1)) if m else -99999   # unreadable counts as breach too
f = open(csv, "a", buffering=1)
f.write("epoch,free_mib\n")
while True:
    t0 = time.time()
    fr = free()
    f.write(f"{int(t0)},{fr}\n")
    if fr < FLOOR and not os.path.exists(flag):
        open(flag, "w").write(f"BREACH free={fr} MiB at {time.strftime('%T')}\n")
        for c in STOP:
            subprocess.run(c, cwd=LAB)
    time.sleep(max(0.0, 2.0 - (time.time() - t0)))
