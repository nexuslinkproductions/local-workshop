#!/usr/bin/env python3
"""Needle-in-a-haystack harness for a local llama-server (OpenAI-compatible).

CPU-only: it only speaks HTTP to --base; it never starts a model.
`--selftest` spins an in-process mock server so the whole path is testable
without a GPU. stdlib only.

Usage:
  needle.py --base http://127.0.0.1:18090 --tokens 32768 [--needles 5] [--seed 1]
            [--out result.json] [--max-wait 3600] [--timeout 3600] [--single]
  needle.py --ppl-text-out ppl.txt     # helper: deterministic ~40K-char text file
  needle.py --selftest                 # mock-server self test
"""
import argparse
import glob
import json
import os
import random
import re
import string
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
LAB = os.path.dirname(HERE)
CHARS_PER_TOKEN = 3.6                     # fallback when /tokenize is unreachable
HEADROOM = 1500                           # prompt-token budget kept free for instructions/answer
SYS = "You are a precise assistant. Answer with ONLY the requested JSON object."
ADJ = ["crimson", "amber", "silent", "hollow", "gilded", "cobalt", "ivory", "rusted", "velvet", "arctic"]
NOUN = ["falcon", "harbor", "lantern", "cipher", "meadow", "anvil", "orchid", "compass", "beacon", "kestrel"]


# ---------------------------------------------------------------- text sources

def source_files():
    """research/*.md first, then LAB/*.md and the parent dir's *.md if more is needed. Deterministic order."""
    seen, out = set(), []
    for pat in (os.path.join(LAB, "research", "*.md"),
                os.path.join(LAB, "*.md"),
                os.path.join(os.path.dirname(LAB), "*.md")):
        for f in sorted(glob.glob(pat)):
            if f not in seen:
                seen.add(f)
                out.append(f)
    return out


def read_all(files):
    parts = []
    for f in files:
        try:
            parts.append(open(f, encoding="utf-8", errors="replace").read())
        except OSError:
            pass
    return "\n\n".join(parts)


def build_haystack(need_chars, files):
    """Concatenate real markdown, repeating with a per-copy marker, cut at a paragraph boundary."""
    texts = [open(f, encoding="utf-8", errors="replace").read() for f in files]
    if not texts:
        return ""
    chunks, n, copy = [], 0, 0
    while n < need_chars:
        for t in texts:
            head = ("\n\n<!-- copy %d -->\n\n" % copy) if copy else ""
            chunks.append(head + t)
            n += len(head) + len(t)
        copy += 1
    txt = "".join(chunks)
    if len(txt) > need_chars:
        cut = txt.rfind("\n\n", 0, need_chars)
        txt = txt[:cut] if cut > need_chars // 2 else txt[:need_chars]
    return txt


# ---------------------------------------------------------------- needles

def make_needles(n, seed):
    rng = random.Random(seed)
    seen, out = set(), []
    while len(out) < n:
        vault = "%s-%s-%02d" % (rng.choice(ADJ), rng.choice(NOUN), rng.randrange(100))
        if vault in seen:
            continue
        seen.add(vault)
        code = "".join(rng.choice(string.ascii_lowercase + string.digits) for _ in range(6))
        out.append({"vault": vault, "code": code,
                    "text": "The access code for vault %s is %s.\n\n" % (vault, code)})
    return out


def depths(n):
    """Evenly spread depths, 10%..90% (example in spec: 10/30/50/70/90)."""
    return [0.5] if n == 1 else [0.1 + 0.8 * i / (n - 1) for i in range(n)]


def insert_needles(hay, needles):
    """Insert each needle at its own paragraph boundary. Returns (text, placements)."""
    bnds, i = [0], hay.find("\n\n")
    while i != -1:
        bnds.append(i + 2)
        i = hay.find("\n\n", i + 2)
    used, placed = set(), []
    for nd, d in zip(needles, depths(len(needles))):
        tgt = int(d * len(hay))
        cands = [o for o in bnds if o not in used] or bnds
        off = min(cands, key=lambda o: abs(o - tgt))
        used.add(off)
        nd["depth"] = round(d, 3)
        placed.append((off, nd))
    placed.sort()
    out, prev = [], 0
    for off, nd in placed:
        out.append(hay[prev:off])
        out.append(nd["text"])
        prev = off
    out.append(hay[prev:])
    return "".join(out), placed


# ---------------------------------------------------------------- HTTP

def _post(base, path, obj, timeout):
    req = urllib.request.Request(base.rstrip("/") + path, data=json.dumps(obj).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def tokenize(base, text, timeout):
    return _post(base, "/tokenize", {"content": text}, timeout).get("tokens") or []


def chat(base, prompt, timeout, max_tokens=400, cache=True):
    body = {"model": "local",
            "messages": [{"role": "system", "content": SYS},
                         {"role": "user", "content": prompt}],
            "temperature": 0, "max_tokens": max_tokens,
            "chat_template_kwargs": {"enable_thinking": False}}
    if not cache:
        body["cache_prompt"] = False
    t0 = time.time()
    d = _post(base, "/v1/chat/completions", body, timeout)
    return d, time.time() - t0


def extract_json(text):
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        return {}
    try:
        obj = json.loads(m.group(0))
    except ValueError:
        return {}
    return obj if isinstance(obj, dict) else {}


def score(reply, needles):
    got = {str(k).lower(): v for k, v in extract_json(reply).items()}
    hits, per = 0, []
    for nd in needles:
        v = got.get(nd["vault"].lower())
        ok = isinstance(v, str) and v.strip().strip('"') == nd["code"]
        hits += bool(ok)
        per.append({"vault": nd["vault"], "code": nd["code"], "got": v, "hit": bool(ok)})
    return hits, per


# ---------------------------------------------------------------- run

def run(base, tokens, n_needles, seed, out, max_wait, timeout, single):
    result = {"base": base, "tokens": tokens, "needles": n_needles, "seed": seed, "ok": False}
    deadline = time.time() + max_wait
    try:
        files = source_files()
        text = read_all(files)
        if not text.strip():
            raise RuntimeError("no markdown text found under research/ or its parents")
        needles = make_needles(n_needles, seed)
        names = ", ".join(n["vault"] for n in needles)
        question = ("Question: The text above contains access codes for several vaults. "
                    "Return ONLY a JSON object mapping every vault name to its code, "
                    'e.g. {"example-00": "abc123"}. Vaults: %s.' % names)

        cpt, tok_fn = CHARS_PER_TOKEN, None
        try:
            sample = text[:8000]
            toks = tokenize(base, sample, timeout)
            if toks:
                cpt = len(sample) / len(toks)
                tok_fn = lambda s: tokenize(base, s, timeout)   # noqa: E731
        except Exception:
            pass

        target = max(1, tokens - HEADROOM)
        overhead = (len(SYS) + len(question)) / cpt
        hay_chars = max(2000, int((target - overhead) * cpt))
        for _ in range(4):                                       # land within +-3% of target
            hay = build_haystack(hay_chars, files)
            prompt_hay, placed = insert_needles(hay, needles)
            prompt = prompt_hay + "\n\n" + question
            if not tok_fn:
                break
            actual = len(tok_fn(prompt))
            if not actual or abs(actual - target) <= 0.03 * target:
                break
            hay_chars = max(2000, int(hay_chars * target / actual))

        positions = [{"vault": nd["vault"], "depth": nd["depth"], "offset": off,
                      "boundary": bool(off == 0 or hay[off - 2:off] == "\n\n")}
                     for off, nd in placed]

        if time.time() > deadline:
            raise RuntimeError("max-wait exceeded before request")
        resp, prefill = chat(base, prompt, timeout, cache=not NOCACHE)
        reply = ((resp.get("choices") or [{}])[0].get("message") or {}).get("content") or ""
        pt = (resp.get("usage") or {}).get("prompt_tokens") or (len(tok_fn(prompt)) if tok_fn else int(len(prompt) / cpt))

        hits, per = score(reply, needles)
        result.update({
            "chars_per_token": round(cpt, 4), "target_tokens": target,
            "prompt_tokens": pt, "prefill_s": round(prefill, 3),
            "tokens_per_s": round(pt / prefill, 1) if prefill else 0,
            "needle_positions": positions,
            "multi": {"recall": "%d/%d" % (hits, n_needles), "hits": hits, "per": per},
            "reply": reply, "timings": resp.get("timings"), "ok": True,
        })

        if single:
            s_per = []
            for nd in needles:
                if time.time() > deadline:
                    break
                q = ('Question: What is the access code for vault %s? Return ONLY a JSON '
                     'object like {"%s": "code"}.' % (nd["vault"], nd["vault"]))
                sp = prompt_hay + "\n\n" + q
                r2, _ = chat(base, sp, timeout)
                rep2 = ((r2.get("choices") or [{}])[0].get("message") or {}).get("content") or ""
                h2, p2 = score(rep2, [nd])
                s_per.append({"vault": nd["vault"], "depth": nd["depth"], "hit": bool(h2),
                              "prompt_tokens": (r2.get("usage") or {}).get("prompt_tokens"), "timings": r2.get("timings")})
            sh = sum(x["hit"] for x in s_per)
            result["single"] = {"recall": "%d/%d" % (sh, len(s_per)), "per": s_per}
    except Exception as e:
        result["error"] = "%s: %s" % (type(e).__name__, e)

    if out:
        try:
            with open(out, "w", encoding="utf-8") as f:
                json.dump(result, f, indent=1)
        except OSError as e:
            print("needle: cannot write %s: %s" % (out, e), file=sys.stderr)
    if result.get("ok"):
        line = ("needle: target=%d prompt_tokens=%d prefill=%.2fs %s tok/s multi=%s"
                % (result["target_tokens"], result["prompt_tokens"], result["prefill_s"],
                   result["tokens_per_s"], result["multi"]["recall"]))
        if "single" in result:
            line += " single=%s" % result["single"]["recall"]
        print(line)
    else:
        print("needle: FAILED %s" % result.get("error", "?"))
    return result


# ---------------------------------------------------------------- helper: ppl text

def write_ppl_text(path, total=40000):
    txt = read_all(sorted(glob.glob(os.path.join(LAB, "research", "*.md"))))[:total]
    with open(path, "w", encoding="utf-8") as f:
        f.write(txt)
    return len(txt)


# ---------------------------------------------------------------- selftest

class Mock(BaseHTTPRequestHandler):
    drop = None       # vault name to omit (degraded mode)

    def log_message(self, *a):
        pass

    def _send(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(n) or b"{}")
        if self.path.endswith("/tokenize"):
            self._send({"tokens": [0] * max(1, int(len(body.get("content", "")) / CHARS_PER_TOKEN))})
            return
        if "/v1/chat/completions" in self.path:
            prompt = body["messages"][-1]["content"]
            found = dict(re.findall(r"vault ([\w\-]+) is ([a-z0-9]{6})", prompt))
            if self.drop:
                found.pop(self.drop, None)
            content = json.dumps(found)
            self._send({"choices": [{"message": {"role": "assistant", "content": content}}],
                        "usage": {"prompt_tokens": max(1, int(len(prompt) / CHARS_PER_TOKEN)),
                                  "completion_tokens": len(content)}})
            return
        self._send({"error": "not found"}, 404)


def selftest():
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Mock)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = "http://127.0.0.1:%d" % port
    try:
        r = run(base, tokens=3000, n_needles=5, seed=1, out=None,
                max_wait=60, timeout=30, single=True)
        assert r["ok"], r.get("error")
        assert r["multi"]["hits"] == 5, r["multi"]
        assert r["single"]["recall"] == "5/5", r["single"]
        pos = [p["offset"] for p in r["needle_positions"]]
        assert pos == sorted(pos), pos
        assert all(p["boundary"] for p in r["needle_positions"]), r["needle_positions"]
        assert abs(r["prompt_tokens"] - r["target_tokens"]) <= 0.03 * r["target_tokens"], \
            (r["prompt_tokens"], r["target_tokens"])

        Mock.drop = make_needles(5, 1)[0]["vault"]      # degraded: server drops one needle
        d = run(base, tokens=3000, n_needles=5, seed=1, out=None,
                max_wait=60, timeout=30, single=False)
        assert d["ok"], d.get("error")
        assert d["multi"]["hits"] == 4, d["multi"]
        Mock.drop = None

        print("selftest OK: multi 5/5, degraded 4/5, positions ordered & at paragraph boundaries, "
              "prompt_tokens within 3%% of target (%d vs %d)"
              % (d["prompt_tokens"], d["target_tokens"]))
        return 0
    finally:
        srv.shutdown()


# ---------------------------------------------------------------- main

NOCACHE = False

def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--base", default=None)
    p.add_argument("--tokens", type=int, default=32768)
    p.add_argument("--needles", type=int, default=5)
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--out", default=None)
    p.add_argument("--max-wait", type=float, default=3600)
    p.add_argument("--timeout", type=float, default=3600)
    p.add_argument("--single", action="store_true")
    p.add_argument("--no-cache", action="store_true", help="first request bypasses the server prompt cache")
    p.add_argument("--ppl-text-out", default=None)
    p.add_argument("--selftest", action="store_true")
    a = p.parse_args()
    global NOCACHE
    NOCACHE = a.no_cache

    if a.selftest:
        return selftest()
    if a.ppl_text_out and not a.base:
        n = write_ppl_text(a.ppl_text_out)
        print("needle: wrote %s (%d chars)" % (a.ppl_text_out, n))
        return 0
    if a.ppl_text_out:
        write_ppl_text(a.ppl_text_out)
    if not a.base:
        p.error("--base required (or use --selftest / --ppl-text-out)")
    r = run(a.base, a.tokens, a.needles, a.seed, a.out, a.max_wait, a.timeout, a.single)
    return 0 if r.get("ok") else 2


if __name__ == "__main__":
    sys.exit(main())
