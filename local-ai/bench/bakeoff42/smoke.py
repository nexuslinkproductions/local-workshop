#!/usr/bin/env python3
"""smoke.py — ONE direct llama-server smoke for bakeoff42 (run under the GPU lock).

Loads the model via bench/watchdog.sh -> ionice -c 3 -> jobcap -> llama-server,
measures load time + VRAM, runs "Say OK", a 128-token decode and a ~4K-token prefill,
parses the server log for the llama.cpp timing lines, kills the server, writes JSON.

Exit: 0 ok | 3 server never healthy | 4 gate/watchdog refused
"""
import argparse, json, os, re, signal, subprocess, sys, time, urllib.request

LAB = "/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB"
LOGD = f"{LAB}/bench/bakeoff42/logs"
G = f"{LAB}/engines/llama.cpp-sycl-tip/build/bin/llama-server"
WATCH = f"{LAB}/bench/watchdog.sh"
JOBCAP = "/home/nexuslink/.local/bin/jobcap"
ARCV = f"{LAB}/bench/arc-vram.py"
os.makedirs(LOGD, exist_ok=True)


def vram():
    try:
        out = subprocess.run(["python3", ARCV], capture_output=True, text=True, timeout=20).stdout
        m = re.search(r"free=(-?\d+).*used=(\d+)", out)
        return [int(m.group(1)), int(m.group(2))] if m else [None, None]
    except Exception:
        return [None, None]


def post(port, payload, timeout=900):
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/chat/completions",
        data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def timings(txt):
    """Pull prompt-eval / eval t/s from a llama.cpp server log slice."""
    # Last match of each: "prompt eval time" = prefill; "| eval time" (pipe-prefixed) = decode.
    # (2026-10-13 fix: the old \beval time regex also matched "prompt eval time" -> decode t/s was prefill t/s.)
    out = {}
    m = re.findall(r"prompt eval time =\s*[\d.]+ ms /\s*(\d+) tokens.*?([\d.]+) tokens per second", txt)
    if m:
        out["prefill_tokens"] = int(m[-1][0]); out["prefill_tps"] = float(m[-1][1])
    m = re.findall(r"\|\s+eval time =\s*[\d.]+ ms /\s*(\d+) tokens.*?([\d.]+) tokens per second", txt)
    if m:
        out["decode_tokens"] = int(m[-1][0]); out["decode_tps"] = float(m[-1][1])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--id", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--mmproj")
    ap.add_argument("--ctx", type=int, required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--kv", default="q8_0")
    ap.add_argument("--mmproj-cpu", action="store_true")
    ap.add_argument("--big-chars", type=int, default=0, help="extra ~29K-token prefill (Chief prompt size) for the VRAM check")
    a = ap.parse_args()

    logpath = f"{LOGD}/{a.id}-direct.server.log"
    cmd = ["nice", "-n", "10", "ionice", "-c", "3", "bash", WATCH, f"bakeoff-{a.id}", "--",
           "ionice", "-c", "3", JOBCAP, G, "-m", a.model]
    if a.mmproj:
        cmd += ["--mmproj", a.mmproj]
    if a.mmproj_cpu:
        cmd += ["--no-mmproj-offload"]
    cmd += ["--host", "127.0.0.1", "--port", str(a.port), "--device", "SYCL0", "-ngl", "99",
            "-c", str(a.ctx), "-np", "1", "-t", "16", "-fa", "on", "-ctk", a.kv, "-ctv", a.kv,
            "-b", "1024", "-ub", "1024", "-lm", "dio", "-fit", "off", "--jinja",
            "--temp", "0", "--repeat-penalty", "1.05"]
    cmd += os.environ.get("BAKEOFF_EXTRA", "").split()   # last, so these flags override (same as serve/bakeoff-launch.sh)

    lf = open(logpath, "w")
    t0 = time.time()
    p = subprocess.Popen(cmd, stdout=lf, stderr=subprocess.STDOUT, start_new_session=True)
    res = {"id": a.id, "model": a.model, "ctx": a.ctx, "log": logpath}

    ok = False
    for _ in range(300):
        if p.poll() is not None:
            break
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{a.port}/health", timeout=2) as r:
                st = json.loads(r.read()).get("status")
                if st in ("ok", "no slot available"):
                    ok = True
                    break
        except Exception:
            pass
        time.sleep(1)
    res["load_s"] = round(time.time() - t0, 2)
    res["health"] = ok
    if not ok:
        res["vram"] = vram()
        tail = open(logpath, errors="replace").read()
        res["error"] = "server never became healthy"
        res["log_tail"] = tail[-4000:]
        json.dump(res, open(f"{LOGD}/{a.id}-direct.json", "w"), indent=2)
        print(json.dumps({k: res[k] for k in ("id", "load_s", "health", "error")}))
        subprocess.run(f"pkill -TERM -f 'llama-server.*--port {a.port}'", shell=True)
        return 3

    res["vram_after_load"] = vram()

    def slice_after(mark):
        with open(logpath, errors="replace") as f:
            f.seek(mark)
            return f.read()

    # 1) Say OK
    try:
        r = post(a.port, {"messages": [{"role": "user", "content": "Say OK"}],
                          "max_tokens": 16, "temperature": 0})
        res["say_ok"] = r["choices"][0]["message"]["content"].strip()
    except Exception as e:
        res["say_ok_err"] = repr(e)

    # 2) decode t/s (128 tokens)
    mark = os.path.getsize(logpath)
    try:
        r = post(a.port, {"messages": [{"role": "user", "content":
                     "Count from 1 to 120, one number per line."}],
                     "max_tokens": 128, "temperature": 0})
        res["decode_reply_head"] = r["choices"][0]["message"]["content"][:60]
    except Exception as e:
        res["decode_err"] = repr(e)
    time.sleep(1)
    res.update(timings(slice_after(mark)))

    # 3) prefill t/s at ~4K tokens (max_tokens=1 so decode is negligible)
    filler = ("The quick brown fox jumps over the lazy dog near the riverbank at dawn. " * 240)[:17000]  # 4K step
    prompt4k = ("Read this text and reply with the single word DONE.\n\n" + filler)
    mark = os.path.getsize(logpath)
    try:
        r = post(a.port, {"messages": [{"role": "user", "content": prompt4k}],
                          "max_tokens": 1, "temperature": 0})
        res["prefill_reply"] = r["choices"][0]["message"]["content"].strip()
    except Exception as e:
        res["prefill_err"] = repr(e)
    time.sleep(1)
    tt = timings(slice_after(mark))
    if "prefill_tokens" in tt:
        res["prefill4k_tokens"] = tt["prefill_tokens"]
        res["prefill4k_tps"] = tt["prefill_tps"]
    if a.big_chars:
        big = ("The quick brown fox jumps over the lazy dog near the riverbank at dawn. " * (a.big_chars // 80 + 2))[:a.big_chars]
        mark = os.path.getsize(logpath)
        try:
            post(a.port, {"messages": [{"role": "user", "content": "Read this text and reply with the single word DONE.\n\n" + big}],
                          "max_tokens": 1, "temperature": 0})
            res["big_prefill_err"] = None
        except Exception as e:
            res["big_prefill_err"] = repr(e)[:300]
        time.sleep(1)
        tt = timings(slice_after(mark))
        res["big_prefill_tokens"] = tt.get("prefill_tokens")
        res["big_prefill_tps"] = tt.get("prefill_tps")
    res["vram_after_tests"] = vram()

    # stop the server
    subprocess.run(f"pkill -TERM -f 'llama-server.*--port {a.port}'", shell=True)
    try:
        os.killpg(os.getpgid(p.pid), signal.SIGTERM)
    except Exception:
        pass
    for _ in range(30):
        if vram()[0] and vram()[0] > 8000:
            break
        time.sleep(1)
    res["vram_after_stop"] = vram()

    json.dump(res, open(f"{LOGD}/{a.id}-direct.json", "w"), indent=2)
    print(json.dumps(res))
    return 0


if __name__ == "__main__":
    sys.exit(main())
