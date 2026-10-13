#!/usr/bin/env python3
"""ramp-gemma-64k.py <target_tokens> — one prefill step of the 64K ramp (RESUME-after-reboot-2).

Sends one non-cached prompt of ~target_tokens to llama-swap gemma4-12b (thinking off), samples
Arc VRAM free (bench/arc-vram.py) every second during the request, and checks the kernel journal
for GPU resets before and after. Exit 0 = step passed. Exit 3 = STOP the ladder (reset/wedge/
page fault/VRAM free < 1024 MiB/request error). Never retries, never touches the ack file.
"""
import json, random, re, subprocess, sys, threading, time, urllib.request

LAB = "/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB"
ENDPOINT = "http://127.0.0.1:18080/v1/chat/completions"
RESET_RE = re.compile(r"GT0: (Engine )?reset|device wedged|Timedout job|DEVICE_LOST|devcoredump|"
                      r"Fault response|needs recovery|GPU HANG", re.I)
VRAM_FLOOR_MIB = 1024

def journal_hits():
    out = subprocess.run(["journalctl", "-k", "-b", "--no-pager"], capture_output=True, text=True).stdout
    return sum(1 for l in out.splitlines() if RESET_RE.search(l))

def free_mib():
    out = subprocess.run([f"{LAB}/bench/arc-vram.py"], capture_output=True, text=True).stdout
    m = re.search(r"free=(-?\d+)", out)
    return int(m.group(1)) if m else None

def gate_ok():
    # Not gate_check(): it refuses on the llama-server we are deliberately driving. Only the
    # game and the unacked-reset rules apply to this run (same rules gate-run.sh enforces).
    r = subprocess.run(["bash", "-c", f"source {LAB}/bench/gate.sh; game_running && echo GAME; gpu_reset_unacked; true"],
                       capture_output=True, text=True)
    out = r.stdout.strip()
    return out == "", out

def main():
    target = int(sys.argv[1])
    rng = random.Random(target)  # distinct text per step so the prompt cache cannot shortcut prefill
    vocab = ["river", "lantern", "quartz", "harbor", "signal", "meadow", "copper", "orbit", "velvet",
             "granite", "pioneer", "compass", "ledger", "thunder", "fjord", "saffron", "atlas", "beacon"]
    words = [rng.choice(vocab) for _ in range(target)]  # measured: ~1.0 tokens/word for this list
    prompt = ("Below is a long word list. Ignore it and answer with the single word OK.\n"
              + " ".join(words))

    ok, why = gate_ok()
    if not ok:
        print(json.dumps({"step": target, "stop": "gate", "why": why})); sys.exit(3)
    before = journal_hits()
    f0 = free_mib()
    samples = []
    stop = threading.Event()

    def sampler():
        while not stop.is_set():
            f = free_mib()
            if f is not None:
                samples.append(f)
            stop.wait(1.0)

    th = threading.Thread(target=sampler, daemon=True)
    th.start()
    body = {"model": "gemma4-12b", "temperature": 0, "max_tokens": 16,
            "messages": [{"role": "user", "content": prompt}]}
    req = urllib.request.Request(ENDPOINT, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    err, usage, reply = None, {}, ""
    try:
        with urllib.request.urlopen(req, timeout=900) as r:
            d = json.loads(r.read())
            usage = d.get("usage", {})
            reply = (d["choices"][0]["message"].get("content") or "")[:80]
    except Exception as e:  # HTTP/timeout/crash: report, stop the ladder
        err = repr(e)
    dt = time.time() - t0
    stop.set(); th.join(timeout=5)
    after = journal_hits()
    fmin = min(samples) if samples else None
    res = {"step": target, "prompt_tokens": usage.get("prompt_tokens"), "secs": round(dt, 1),
           "prompt_tps": round(usage.get("prompt_tokens", 0) / dt, 1) if usage and dt else None,
           "reply": reply, "vram_free_before": f0, "vram_free_min": fmin, "samples": len(samples),
           "journal_new_hits": after - before, "error": err}
    print(json.dumps(res))
    if err or after != before or (fmin is not None and fmin < VRAM_FLOOR_MIB):
        sys.exit(3)
    sys.exit(0)

if __name__ == "__main__":
    main()
