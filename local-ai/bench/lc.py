#!/usr/bin/env python3
"""lc.py — ONE locked long-context llama-server session for Gemma 4 12B on the B580 (BRIEF-34).

Run ONLY under the GPU lock:  flock -x -w 7200 bench/.gpu.lock env LC_LOCKED=1 python3 bench/lc.py ...
Starts the server (watchdog.sh + ionice + jobcap, -lv 4 log), waits /health, samples VRAM/PSI 1 Hz,
runs needle.py steps (--steps 4096,8192 = prompt sizes), checks the kernel journal around every step.
Exit: 0 pass | 3 session stopped (load fail, VRAM free < floor, request error) -> next session ok
      4 GPU fault in the journal (reset/wedge/DEVICE_LOST/page fault) -> HALT the whole program.
Never retries, never touches bench/.gpu-reset-ack, never --force.
"""
import argparse, json, os, re, signal, subprocess, sys, threading, time, urllib.request

LAB = "/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB"
LOGD = f"{LAB}/bench/logs/chief256k"
BIN = f"{LAB}/engines/llama.cpp-sycl-tip/build/bin/llama-server"
M = f"{LAB}/models/llm/google/gemma-4-12B-it-qat-q4_0-gguf"
MTP = f"{LAB}/models/llm/unsloth/gemma-4-12B-it-qat-GGUF/mtp-gemma-4-12B-it.gguf"
FAULT = re.compile(r"GT0: (Engine )?reset|device wedged|Timedout job|DEVICE_LOST|devcoredump|"
                   r"Fault response|needs recovery|GPU HANG|job timed out|Faulted Address", re.I)
PROG = re.compile(r"prompt processing progress.*n_tokens = (\d+)")


def sh(cmd):
    return subprocess.run(["bash", "-c", cmd], capture_output=True, text=True).stdout


def faults():
    return [l for l in sh("journalctl -k -b --no-pager").splitlines() if FAULT.search(l)]


def vram():  # (free, used) MiB
    m = re.search(r"free=(-?\d+).*used=(\d+)", sh(f"{LAB}/bench/arc-vram.py"))
    return (int(m.group(1)), int(m.group(2))) if m else (None, None)


def psi_mem():
    m = re.search(r"full avg10=([\d.]+)", sh("cat /proc/pressure/memory"))
    return float(m.group(1)) if m else 0.0


def mem_avail():
    return int(re.search(r"MemAvailable:\s+(\d+)", open("/proc/meminfo").read()).group(1)) // 1024


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--label", required=True)
    a.add_argument("--ctx", type=int, required=True)
    a.add_argument("--kv", default="q8_0", help="K=V type, or K:V")
    a.add_argument("--ub", type=int, default=512)
    a.add_argument("--b", type=int, default=1024)
    a.add_argument("--nkvo", action="store_true")
    a.add_argument("--mmproj", choices=["gpu", "cpu", "none"], default="gpu")
    a.add_argument("--mtp", action="store_true")
    a.add_argument("--mtp-kv", default="q8_0")
    a.add_argument("--nmax", type=int, default=3)
    a.add_argument("--steps", default="", help="comma list of needle prompt sizes in tokens")
    a.add_argument("--single", action="store_true", help="also run single-needle questions (prefix-cache reuse timings)")
    a.add_argument("--floor", type=int, default=900, help="stop session if VRAM free (MiB) falls below (Marcel 2026-10-13: 900)")
    a.add_argument("--port", type=int, default=18095)
    a.add_argument("--extra", default="", help="extra llama-server args")
    a.add_argument("--seed", type=int, default=1)
    a.add_argument("--load-timeout", type=int, default=600)
    a.add_argument("--keep-cache", action="store_true", help="steps may reuse the server prompt cache")
    a = a.parse_args()
    if os.environ.get("LC_LOCKED") != "1":
        sys.exit("refusing: run under flock -x bench/.gpu.lock env LC_LOCKED=1")
    os.makedirs(LOGD, exist_ok=True)
    out = f"{LOGD}/{a.label}"
    rec = {"label": a.label, "ctx": a.ctx, "kv": a.kv, "ub": a.ub, "nkvo": a.nkvo, "mmproj": a.mmproj,
           "mtp": a.mtp, "steps": [], "start": time.strftime("%F %T")}

    proc_ref = []

    def finish(code, why):
        if proc_ref and proc_ref[0].poll() == 9:
            code, why = 5, "ABORT-LAG by watchdog (not a GPU fault): " + why
        rec.update(result=code, why=why, end=time.strftime("%F %T"))
        json.dump(rec, open(out + ".json", "w"), indent=1)
        print(f"LC {a.label}: exit={code} {why}")
        sys.exit(code)

    # ---- gates (same rules as serve/gate-run.sh) + nothing else on the GPU
    g = sh(f"source {LAB}/bench/gate.sh; game_running && echo GAME; gpu_reset_unacked; pgrep -ax 'llama-server|llama-bench|llama-perplexit'")
    if g.strip():
        finish(3, f"gate refuses: {g.strip()[:200]}")
    base_faults = len(faults())
    rec["vram_free_before"], rec["vram_used_before"] = vram()
    if mem_avail() < 14000:
        finish(3, f"MemAvailable {mem_avail()} MiB < 14000")

    # other agents' disk IO trips the watchdog (psi_io_full > 1.0): start only on a quiet disk
    for _ in range(240):
        io = float(re.search(r"full avg10=([\d.]+)", sh("cat /proc/pressure/io")).group(1))
        if io < 0.3:
            break
        time.sleep(5)
    k, _, v = a.kv.partition(":")
    v = v or k
    args = ["--host", "127.0.0.1", "--port", str(a.port), "-m", f"{M}/gemma-4-12b-it-qat-q4_0.gguf",
            "--device", "SYCL0", "-ngl", "99", "-c", str(a.ctx), "-np", "1", "-t", "16", "-fa", "on",
            "-ctk", k, "-ctv", v, "-b", str(a.b), "-ub", str(a.ub), "-lm", "dio", "-fit", "off",
            "--jinja", "--temp", "0", "--repeat-penalty", "1.05", "-lv", "4", "-cram", "4096"]
    if a.mmproj == "gpu":
        args += ["--mmproj", f"{M}/mmproj-gemma-4-12b-it-qat-q4_0.gguf"]
    elif a.mmproj == "cpu":
        args += ["--mmproj", f"{M}/mmproj-gemma-4-12b-it-qat-q4_0.gguf", "--no-mmproj-offload"]
    else:
        args += ["--no-mmproj"]
    if a.nkvo:
        args += ["-nkvo"]
    if a.mtp:
        args += ["-md", MTP, "-ngld", "99", "--spec-draft-device", "SYCL0", "--spec-type", "draft-mtp",
                 "--spec-draft-n-max", str(a.nmax), "-ctkd", a.mtp_kv, "-ctvd", a.mtp_kv]
    args += a.extra.split()
    rec["argv"] = args
    q = " ".join(f"'{x}'" for x in args)
    cmd = (f"set +u; . {LAB}/bench/configs/sycl-env.sh; set -u; export CAP=14G CPUS=6-11,18-23 CPUW=20 "
           f"WATCH_IO_GRACE_S=60 WATCH_PSI_FULL_MAX={os.environ.get('LC_PSI_MAX', '1.0')} MATRIX_RESULTS={LOGD}/watchdog-rows.tsv; "
           f"exec bash {LAB}/bench/watchdog.sh lc-{a.label} -- ionice -c 3 /home/nexuslink/.local/bin/jobcap '{BIN}' {q}")
    logf = open(out + ".server.log", "w")
    t_launch = time.time()
    proc = subprocess.Popen(["bash", "-c", cmd], stdout=logf, stderr=subprocess.STDOUT, start_new_session=True)
    proc_ref.append(proc)

    def kill():
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(proc.pid, sig)
            except ProcessLookupError:
                break
            for _ in range(20):
                if proc.poll() is not None:
                    return
                time.sleep(0.5)
        subprocess.run(["pkill", "-KILL", "-f", f"llama-server.*--port {a.port}"])

    def halt_if_fault(where):
        f = faults()
        if len(f) > base_faults:
            kill()
            rec["fault_lines"] = f[base_faults:][:12]
            finish(4, f"GPU FAULT at {where}: {f[base_faults][:160]}")

    # ---- sampler: VRAM, PSI, MemAvailable, ubatch arrival times (tail of server log)
    st = {"vmin": None, "vmax_used": 0, "psi": 0.0, "mem_min": 10**9, "prog": [], "stop": False, "trip": None}
    ev = threading.Event()

    def sampler():
        pos = 0
        while not ev.is_set():
            f, u = vram()
            if f is not None:
                st["vmin"] = f if st["vmin"] is None else min(st["vmin"], f)
                st["vmax_used"] = max(st["vmax_used"], u)
            st["psi"] = max(st["psi"], psi_mem())
            try:  # attribution: is the IO pressure ours? server cgroup + server's own disk IO
                pid = sh("pgrep -ox llama-server").strip()
                if pid:
                    cg = "/sys/fs/cgroup" + open(f"/proc/{pid}/cgroup").read().strip().split("::")[-1]
                    st["cgmem"] = max(st.get("cgmem", 0), int(open(cg + "/memory.current").read()) >> 20)
                    m = re.search(r"full avg10=([\d.]+)", open(cg + "/io.pressure").read())
                    st["cgio"] = max(st.get("cgio", 0.0), float(m.group(1)))
                    io = dict(l.split(": ") for l in open(f"/proc/{pid}/io").read().splitlines())
                    st["srv_rd_mb"], st["srv_wr_mb"] = int(io["read_bytes"]) >> 20, int(io["write_bytes"]) >> 20
                m = re.search(r"full avg10=([\d.]+)", open("/proc/pressure/io").read())
                st["gio"] = max(st.get("gio", 0.0), float(m.group(1)))
            except Exception:
                pass
            st["mem_min"] = min(st["mem_min"], mem_avail())
            try:
                with open(out + ".server.log") as fh:
                    fh.seek(pos)
                    for line in fh.read().splitlines():
                        m = PROG.search(line)
                        if m:
                            st["prog"].append((time.time(), int(m.group(1))))
                    pos = fh.tell()
            except OSError:
                pass
            if f is not None and st["tripping"] and f < a.floor:
                st["trip"] = f"VRAM free {f} MiB < {a.floor}"
            ev.wait(1.0)

    st["tripping"] = False
    th = threading.Thread(target=sampler, daemon=True)
    th.start()
    # watch the journal while loading too
    base = f"http://127.0.0.1:{a.port}"
    up = False
    while time.time() - t_launch < a.load_timeout:
        if proc.poll() is not None:
            break
        try:
            urllib.request.urlopen(base + "/health", timeout=2).read()
            up = True
            break
        except Exception:
            time.sleep(2)
        if len(faults()) > base_faults:
            break
    ev.set(); th.join(2)
    halt_if_fault("load")
    log = open(out + ".server.log").read()
    bufs = [l.strip() for l in log.splitlines() if re.search(r"buffer size|KV buffer|compute buffer", l)]
    rec["buffers"] = bufs[:40]
    f0, u0 = vram()
    rec["load_s"] = round(time.time() - t_launch, 1)
    if not up:
        kill()
        why = "OOM-ish" if re.search(r"out of (device )?memory|OUT_OF|failed to allocate", log, re.I) else "died"
        rec["tail"] = log.splitlines()[-8:]
        finish(3, f"load failed ({why}) after {rec['load_s']} s")
    rec["vram_free_loaded"], rec["vram_used_loaded"] = f0, u0
    rec["vram_free_loaded_note"] = "free after load, before any prompt"
    ev.clear(); st.update(vmin=f0, tripping=True)
    th = threading.Thread(target=sampler, daemon=True); th.start()

    # tiny request: allocates the first graph at runtime
    try:
        body = json.dumps({"model": "x", "messages": [{"role": "user", "content": "Say OK."}], "max_tokens": 8,
                           "temperature": 0, "chat_template_kwargs": {"enable_thinking": False}}).encode()
        r = urllib.request.urlopen(urllib.request.Request(base + "/v1/chat/completions", body,
                                   {"Content-Type": "application/json"}), timeout=120)
        rec["warm_reply"] = json.loads(r.read())["choices"][0]["message"]["content"]
    except Exception as e:
        rec["warm_error"] = repr(e)
    halt_if_fault("warm request")

    why = "load-only ok"
    code = 0
    for step in [int(x) for x in a.steps.split(",") if x]:
        halt_if_fault(f"before step {step}")
        st.update(prog=[], trip=None)
        mem0 = st["vmin"]
        cmd = ["python3", f"{LAB}/bench/needle.py", "--base", base, "--tokens", str(step), "--seed", str(a.seed + step),
               "--out", f"{out}.step{step}.json", "--timeout", "3600"] + ([] if a.keep_cache else ["--no-cache"]) + (["--single"] if a.single else [])
        t0 = time.time()
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        while p.poll() is None:
            time.sleep(1)
            if proc.poll() is not None:
                p.kill(); break
            if st["trip"]:
                kill(); p.kill(); break
            if len(faults()) > base_faults:
                kill(); p.kill(); break
        txt = p.stdout.read() if p.stdout else ""
        dt = time.time() - t0
        pr = st["prog"]
        gaps = [round(pr[i][0] - pr[i - 1][0], 2) for i in range(1, len(pr))]
        s = {"step": step, "secs": round(dt, 1), "needle": txt.strip().splitlines()[-1:] or [""],
             "vram_free_min": st["vmin"], "psi_mem_full_max": st["psi"], "mem_avail_min": st["mem_min"],
             "ubatches_seen": len(pr), "attrib": {k: st.get(k) for k in ("cgmem", "cgio", "gio", "srv_rd_mb", "srv_wr_mb")},
             "max_ubatch_gap_s": max(gaps) if gaps else None,
             "p95_ubatch_gap_s": sorted(gaps)[int(len(gaps) * .95)] if gaps else None}
        try:
            j = json.load(open(f"{out}.step{step}.json"))
            s.update(prompt_tokens=j.get("prompt_tokens"), prefill_s=j.get("prefill_s"), tps=j.get("tokens_per_s"),
                     multi=(j.get("multi") or {}).get("recall"), single=(j.get("single") or {}).get("recall"),
                     timings=j.get("timings"), error=j.get("error"))
            if j.get("single"):
                s["single_timings"] = [x.get("timings") for x in j["single"]["per"]][:2]
        except Exception as e:
            s["json_error"] = repr(e)
        rec["steps"].append(s)
        print(json.dumps(s), flush=True)
        halt_if_fault(f"step {step}")
        if proc.poll() is not None:
            why, code = f"server died at step {step}", 3
            break
        if st["trip"]:
            why, code = f"step {step}: {st['trip']}", 3
            break
        if s.get("error") or s.get("json_error"):
            why, code = f"step {step} request error: {s.get('error') or s.get('json_error')}", 3
            break
        why = f"steps ok through {step}"
        st["vmin_step_done"] = st["vmin"]
    ev.set(); th.join(2)
    rec["vram_free_min_total"] = st["vmin"]
    rec["vram_used_max"] = st["vmax_used"]
    rec["psi_mem_full_max"] = st["psi"]
    rec["attrib"] = {k: st.get(k) for k in ("cgmem", "cgio", "gio", "srv_rd_mb", "srv_wr_mb")}
    kill()
    halt_if_fault("shutdown")
    finish(code, why)


if __name__ == "__main__":
    main()
