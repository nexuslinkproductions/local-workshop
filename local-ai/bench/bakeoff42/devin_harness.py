#!/usr/bin/env python3
"""Devin E01 / E02 / E08 harness for Ornith on the Arc B580 (bench/bakeoff42).

Run only through devin_run.sh, which holds bench/.gpu.lock per experiment.
  python3 devin_harness.py E02|E01|E08
Exit codes: 0 ok, 3 abort (kernel hit or run budget), 4 error (experiment skipped).
Server: serve/bakeoff-launch.sh on port 18199, VRAM guard vram-sampler.py (floor 750 MiB).
"""
import glob, json, os, re, subprocess, sys, time, urllib.request

LAB = "/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB"
LOGS = f"{LAB}/bench/bakeoff42/logs"
PORT = 18199
BASE = f"http://127.0.0.1:{PORT}"
MAIN = f"{LAB}/models/llm/ornith-ai/Ornith-1.5-9B-GGUF/Ornith-1.5-9B-Q4_K_M.gguf"
MMPROJ = f"{LAB}/models/llm/ornith-ai/Ornith-1.5-9B-GGUF/mmproj-Ornith-1.5-9B-BF16.gguf"
TSV = f"{LOGS}/devin-e01-e02-e08.tsv"
KSTART = "2026-10-13 21:43:45"   # kernel-log window start for the reset check
BUDGET_S = 40 * 60               # per-experiment wall cap (lock wait excluded)
DIP_MIB = 900                    # E01 rule: stop a depth if free VRAM drops below this during fill

EXP = sys.argv[1] if len(sys.argv) > 1 else "?"
T0 = time.time()


class Abort(Exception):
    pass


def row(point, metric, value, unit, source, note=""):
    new = not os.path.exists(TSV)
    with open(TSV, "a") as f:
        if new:
            f.write("exp\tpoint\tmetric\tvalue\tunit\tsource\tnote\n")
        f.write("\t".join(str(x).replace("\t", " ").replace("\n", " ")
                          for x in (EXP, point, metric, value, unit, source, note)) + "\n")


def check(where):
    if time.time() - T0 > BUDGET_S:
        raise Abort(f"run budget exceeded at {where}")
    out = subprocess.run(["bash", "-c", f"journalctl -k --since '{KSTART}' 2>/dev/null | grep -iE 'reset|timedout|wedged'"],
                         capture_output=True, text=True).stdout.strip()
    if out:
        raise Abort(f"KERNEL HIT at {where}: {out[:600]}")


def free_mib():
    out = subprocess.run(["python3", f"{LAB}/bench/arc-vram.py"], capture_output=True, text=True).stdout
    m = re.search(r"free=(-?\d+)", out)
    return int(m.group(1)) if m else None


def min_free(csv, t0, t1):
    vals = []
    try:
        for ln in open(csv):
            p = ln.strip().split(",")
            if len(p) == 2 and p[0].isdigit() and t0 <= int(p[0]) <= t1:
                vals.append(int(p[1]))
    except FileNotFoundError:
        pass
    return min(vals) if vals else None


def nlines(p):
    try:
        with open(p, "rb") as f:
            return sum(1 for _ in f)
    except FileNotFoundError:
        return 0


def append_raw(path, rec):
    with open(path, "a") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    return nlines(path)           # line number of the record just written


def post(path, body, timeout=1800):
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def meminfo_mib(key):
    for ln in open("/proc/meminfo"):
        if ln.startswith(key + ":"):
            return int(ln.split()[1]) // 1024
    return None


def corpus():
    files = sorted(f for f in glob.glob(f"{LAB}/research/**/*.md", recursive=True) if "node_modules" not in f)
    return "\n\n".join(open(f, encoding="utf-8", errors="replace").read() for f in files)


class Server:
    def __init__(self, tag, ctx, extra):
        self.tag = tag
        self.log = f"{LOGS}/devin-{EXP}-{tag}.log"
        self.csv = f"{LOGS}/devin-{EXP}-{tag}-vram.csv"
        self.flag = f"{LOGS}/devin-{EXP}-{tag}.BREACH"
        for p in (self.csv, self.flag):
            if os.path.exists(p):
                os.remove(p)
        self.lf = open(self.log, "w")
        self.t_launch = time.time()
        self.ready_s = None
        self.left = ""
        self.p = subprocess.Popen(
            ["bash", f"{LAB}/serve/bakeoff-launch.sh", str(PORT), ctx, MAIN, MMPROJ, "q4_0", "--mmproj-cpu"],
            cwd=LAB, env=dict(os.environ, BAKEOFF_EXTRA=extra),
            stdout=self.lf, stderr=subprocess.STDOUT, start_new_session=True)
        self.samp = subprocess.Popen(
            ["python3", f"{LAB}/bench/bakeoff42/vram-sampler.py", self.csv, self.flag],
            cwd=LAB, env=dict(os.environ, VRAM_FLOOR_MIB="750"),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)

    def wait_ready(self, timeout=900):
        t = time.time()
        while time.time() - t < timeout:
            if self.p.poll() is not None:
                raise RuntimeError(f"server exited rc={self.p.returncode} before ready")
            try:
                if b'"ok"' in urllib.request.urlopen(BASE + "/health", timeout=5).read():
                    self.ready_s = round(time.time() - self.t_launch, 1)
                    return
            except Exception:
                pass
            time.sleep(2)
        raise RuntimeError("not ready within timeout")

    def stop(self):
        subprocess.run(["pkill", "-TERM", "-f", "[l]lama-server.*--port 18199"])
        subprocess.run(["pkill", "-TERM", "-f", "[b]akeoff-18199"])
        try:
            self.samp.terminate()
            self.samp.wait(timeout=10)
        except Exception:
            pass
        t = time.time()
        while time.time() - t < 90 and subprocess.run(
                ["pgrep", "-f", "[l]lama-server.*--port 18199"], capture_output=True).returncode == 0:
            time.sleep(1)
        try:
            self.p.wait(timeout=30)
        except Exception:
            pass
        self.lf.close()
        self.left = subprocess.run(["pgrep", "-af", "[s]ycl-tip/build/bin/llama-server.*--port 18199"],
                                   capture_output=True, text=True).stdout.strip()


# ---------------- E02: buffer census, load only ----------------
def run_e02():
    pts = [
        ("E02a", "131072", "-ub 256 -b 256 -lv 4", "c131072"),
        ("E02b", "262144", "-ub 256 -b 256 -lv 4", "c262144"),
        ("E02c", "65536", "-ub 256 -b 256 -lv 4 --spec-type draft-mtp --spec-draft-n-max 2 "
                          "--spec-draft-type-k q4_0 --spec-draft-type-v q4_0", "c65536-mtp-n2"),
    ]
    for pid, ctx, extra, tag in pts:
        check(pid)
        srv = Server(tag, ctx, extra)
        src = f"logs/devin-{EXP}-{tag}.log"
        try:
            srv.wait_ready()
            time.sleep(5)
            row(pid, "ready_s", srv.ready_s, "s", src, f"ctx {ctx}, load only, no prompt")
            row(pid, "idle_free_after_load", free_mib(), "MiB", f"logs/devin-{EXP}-{tag}-vram.csv", "arc-vram.py, no prompt sent")
        except Exception as e:
            row(pid, "ERROR", f"{type(e).__name__}: {str(e)[:200]}", "", src)
        finally:
            srv.stop()
        row(pid, "min_free_during_window", min_free(srv.csv, srv.t_launch, time.time()), "MiB",
            f"logs/devin-{EXP}-{tag}-vram.csv", "sampler min over launch..stop")
        if srv.left:
            row(pid, "LEFTOVER_PROCESS", srv.left[:200], "", "pgrep")
        for i, line in enumerate(open(srv.log, errors="replace"), 1):
            if "buffer size" in line or "MiB" in line:
                row(pid, "log_line", line.strip(), "", f"{src}:{i}")
        check(f"after {pid}")


# ---------------- E01: depth curve + needle ----------------
DEPTHS = [("0", 64), ("8K", 8192), ("32K", 32768), ("64K", 65536), ("128K", 131072), ("200K", 204800)]
NEEDLE_SENT = "Fact to remember: The vault code is 4-7-1-9-3.\n\n"
Q_TEXT = "\n\nQuestion: What is the vault code mentioned earlier in this text? Answer with the code only.\nAnswer: The vault code is"


def run_e01():
    raw = f"{LOGS}/devin-E01-raw.jsonl"
    open(raw, "w").close()
    srv = Server("curve", "262144", "-ub 256 -b 256")
    try:
        srv.wait_ready()
        row("ctx262144", "ready_s", srv.ready_s, "s", "logs/devin-E01-curve.log")
        row("ctx262144", "idle_free_after_load", free_mib(), "MiB", "logs/devin-E01-curve-vram.csv")
        F = post("/tokenize", {"content": corpus(), "add_special": False})["tokens"]
        NT = post("/tokenize", {"content": NEEDLE_SENT, "add_special": False})["tokens"]
        QT = post("/tokenize", {"content": Q_TEXT, "add_special": False})["tokens"]
        S = F[:32] + NT + F[32:]           # needle sits at token ~32, before the filler
        row("corpus", "filler_tokens", len(F), "tok", "research/**/*.md sorted, excl node_modules")
        row("corpus", "needle_tokens", len(NT), "tok", "tokenize(NEEDLE_SENT)")
        assert len(S) >= 204800
        for label, D in DEPTHS:
            check(f"depth {label}")
            prompt = S[:D]
            t0 = time.time()
            stop_curve = False
            for step in ["warm1", "warm2", "rep1", "rep2", "rep3"]:
                rs = time.time()
                resp = post("/completion", {"prompt": prompt, "n_predict": 256, "temperature": 0,
                                            "cache_prompt": True, "ignore_eos": True, "stream": False})
                ln = append_raw(raw, {"exp": "E01", "depth": label, "ctx_tokens": D, "step": step,
                                      "wall_s": round(time.time() - rs, 2), "resp": resp})
                src = f"logs/devin-E01-raw.jsonl:{ln}"
                tm = resp.get("timings", {})
                if step == "warm1":
                    row(label, "fill_prompt_n", tm.get("prompt_n"), "tok", src)
                    row(label, "fill_cache_n", tm.get("cache_n"), "tok", src)
                    row(label, "prefill_tps", round(tm.get("prompt_per_second", 0), 1), "t/s", src)
                    fm = min_free(srv.csv, t0, time.time())
                    row(label, "min_free_during_fill", fm, "MiB", "logs/devin-E01-curve-vram.csv")
                    if fm is not None and fm < DIP_MIB:
                        row(label, "STOPPED_LOW_VRAM", fm, "MiB", "logs/devin-E01-curve-vram.csv",
                            "free fell below 900 MiB during fill; decode at this depth skipped, curve stops")
                        stop_curve = True
                        break
                elif step.startswith("rep") or step.startswith("warm"):
                    if step.startswith("rep"):
                        row(label, f"decode_tps_{step}", round(tm.get("predicted_per_second", 0), 2), "t/s", src)
                        row(label, f"decode_n_{step}", tm.get("predicted_n"), "tok", src)
                        row(label, f"decode_head_{step}", resp.get("content", "")[:40], "", src)
                check(f"{label} {step}")
            if stop_curve:
                break
            row(label, "min_free_whole_depth", min_free(srv.csv, t0, time.time()), "MiB", "logs/devin-E01-curve-vram.csv")
            row(label, "idle_free_after_depth", free_mib(), "MiB", "logs/devin-E01-curve-vram.csv")
            if label in ("128K", "200K"):
                rs = time.time()
                resp = post("/completion", {"prompt": S[:D] + QT, "n_predict": 24, "temperature": 0,
                                            "cache_prompt": True, "stream": False})
                ln = append_raw(raw, {"exp": "E01", "depth": label, "ctx_tokens": D, "step": "needle",
                                      "wall_s": round(time.time() - rs, 2), "resp": resp})
                src = f"logs/devin-E01-raw.jsonl:{ln}"
                content = resp.get("content", "")
                ok = bool(re.search(r"4\s*-\s*7\s*-\s*1\s*-\s*9\s*-\s*3", content))
                tm = resp.get("timings", {})
                row(label, "needle_pass", ok, "bool", src, repr(content[:60]))
                row(label, "needle_prompt_n", tm.get("prompt_n"), "tok", src)
                row(label, "needle_cache_n", tm.get("cache_n"), "tok", src)
                row(label, "needle_wall_s", round(time.time() - rs, 1), "s", src)
            check(f"after {label}")
    finally:
        srv.stop()
        if srv.left:
            row("cleanup", "LEFTOVER_PROCESS", srv.left[:200], "", "pgrep")


# ---------------- E08: prompt cache, 3-turn Chief-like session + edit ----------------
def chat(msgs, turn, log, raw):
    body = {"messages": msgs, "max_tokens": 160, "temperature": 0, "stream": True,
            "chat_template_kwargs": {"enable_thinking": False}}
    req = urllib.request.Request(BASE + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    l0 = nlines(log)
    t0 = time.time()
    ttft, parts, timings = None, [], None
    with urllib.request.urlopen(req, timeout=1800) as r:
        for raw_b in r:
            s = raw_b.decode("utf-8", "replace").strip()
            if not s.startswith("data:"):
                continue
            d = s[5:].strip()
            if d == "[DONE]":
                break
            try:
                ch = json.loads(d)
            except ValueError:
                continue
            if ch.get("timings"):
                timings = ch["timings"]
            for c in ch.get("choices", []):
                piece = (c.get("delta") or {}).get("content") or ""
                if piece:
                    if ttft is None:
                        ttft = time.time() - t0
                    parts.append(piece)
    l1 = nlines(log)
    text = "".join(parts)
    ln = append_raw(raw, {"exp": "E08", "turn": turn, "ttft_s": round(ttft if ttft is not None else -1, 3),
                          "wall_s": round(time.time() - t0, 2), "timings": timings,
                          "log_lines": [l0 + 1, l1], "content": text[:400]})
    return text, ln, timings, round(ttft if ttft is not None else -1, 3), (l0 + 1, l1)


def chunk_tokens(text, start, target):
    n = int(target * 4)
    for _ in range(4):
        c = text[start:start + n]
        t = len(post("/tokenize", {"content": c, "add_special": False})["tokens"])
        if abs(t - target) <= 0.03 * target:
            break
        n = max(1000, int(n * target / t))
    return c, t


def run_e08():
    raw = f"{LOGS}/devin-E08-raw.jsonl"
    open(raw, "w").close()
    log = f"{LOGS}/devin-E08-chief.log"
    srv = Server("chief", "262144", "-ub 256 -b 256 --checkpoint-min-step 2048 --cache-ram 16384 -lv 4")
    try:
        srv.wait_ready()
        row("E08", "ready_s", srv.ready_s, "s", "logs/devin-E08-chief.log")
        row("E08", "MemAvailable_before", meminfo_mib("MemAvailable"), "MiB", "/proc/meminfo")
        text = corpus()
        c1, n1 = chunk_tokens(text, 0, 8000)
        c2, n2 = chunk_tokens(text, 300000, 1500)
        c3, n3 = chunk_tokens(text, 600000, 1000)
        row("E08", "chunk_tokens_u1_u2_u3", f"{n1}/{n2}/{n3}", "tok", "tokenize of corpus slices")
        u1 = f"Project material:\n\n{c1}\n\nSummarize the key decisions in this material in five bullets."
        u2 = f"Tool result (read_file): {c2}\n\nList the three most important numbers in it, one per line."
        u3 = f"Tool result (grep): {c3}\n\nWrite the next step in one sentence."
        u4 = "Give a one-line status."
        u5 = "Name the file that matters most."
        check("E08 start")

        def turn(name, msgs):
            check(name)
            txt, ln, tm, ttft, lr = chat(msgs, name, log, raw)
            src = f"logs/devin-E08-raw.jsonl:{ln}"
            tm = tm or {}
            row(name, "ttft_s", ttft, "s", src)
            row(name, "prompt_n", tm.get("prompt_n"), "tok", src)
            row(name, "cache_n", tm.get("cache_n"), "tok", src)
            row(name, "prompt_ms", tm.get("prompt_ms"), "ms", src)
            row(name, "predicted_n", tm.get("predicted_n"), "tok", src)
            for i, l in enumerate(open(log, errors="replace"), 1):
                if lr[0] <= i <= lr[1] and re.search(r"checkpoint|restor", l, re.I):
                    row(name, "log_line", l.strip()[:300], "", f"logs/devin-E08-chief.log:{i}")
            return txt

        a1 = turn("T1_first_8K", [{"role": "user", "content": u1}])
        a2 = turn("T2_tool_result", [{"role": "user", "content": u1}, {"role": "assistant", "content": a1},
                                     {"role": "user", "content": u2}])
        a3 = turn("T3_followup", [{"role": "user", "content": u1}, {"role": "assistant", "content": a1},
                                  {"role": "user", "content": u2}, {"role": "assistant", "content": a2},
                                  {"role": "user", "content": u3}])
        h = [{"role": "user", "content": u1}, {"role": "assistant", "content": a1},
             {"role": "user", "content": "[edited] " + u2}, {"role": "assistant", "content": a2},
             {"role": "user", "content": u3}, {"role": "assistant", "content": a3},
             {"role": "user", "content": u4}]
        a4 = turn("T4_edit_earlier_u2", h)
        h5 = [{"role": "user", "content": "[edited] " + u1}] + h[1:] + [{"role": "assistant", "content": a4},
                                                                        {"role": "user", "content": u5}]
        turn("T5_extra_edit_u1_full_reprefill", h5)
        row("E08", "MemAvailable_after", meminfo_mib("MemAvailable"), "MiB", "/proc/meminfo")
    finally:
        srv.stop()
        if srv.left:
            row("cleanup", "LEFTOVER_PROCESS", srv.left[:200], "", "pgrep")


if __name__ == "__main__":
    os.makedirs(LOGS, exist_ok=True)
    fn = {"E01": run_e01, "E02": run_e02, "E08": run_e08}.get(EXP)
    if fn is None:
        print("usage: devin_harness.py E01|E02|E08")
        sys.exit(4)
    try:
        check("start")
        fn()
        print(f"DONE {EXP} in {(time.time() - T0) / 60:.1f} min")
    except Abort as e:
        print(f"ABORT {EXP}: {e}")
        row("harness", "ABORT", str(e)[:300], "", "harness")
        sys.exit(3)
    except Exception as e:
        print(f"ERROR {EXP}: {type(e).__name__}: {e}")
        row("harness", "ERROR", f"{type(e).__name__}: {str(e)[:250]}", "", "harness")
        sys.exit(4)
