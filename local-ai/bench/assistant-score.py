#!/usr/bin/env python3
"""assistant-score.py — the 'assistant' half of a model test (Marcel's widened goal).

Runs against an already-started llama-server (called from matrix-server.sh inside its lock):
  (a) describe-my-screen: the live screenshot + the window titles from `hyprctl clients -j`
      captured at the same moment; score = how many open apps/windows the reply names.
  (b) two short English answers to work questions (text kept on disk).
  (c) latency for a ~200-token prompt with a cached system prefix: time to first token and to
      first sentence, without and with one screenshot (3 reps each, median).
  (d) PSI deltas over the whole block.
Raw replies go to MX_SCRATCH; one row per test goes to MX_RESULTS (bench/matrix-row.py schema).

    MX_PORT=.. MX_MODELNAME=.. MX_SHOT=<png> MX_TITLES=<json> MX_RESULTS=.. MX_SCRATCH=.. \
      (engine/model/ctx/... from MX_ENGINE, MX_SHA, MX_MODELNAME, MX_QUANT, MX_PLACEMENT, MX_CTX, MX_KV)
"""
import json
import os
import re
import statistics
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from importlib import import_module  # noqa: E402

row = import_module("matrix-row")
env = os.environ
PORT = int(env["MX_PORT"])
MODEL = env["MX_MODELNAME"]
SHOT = env.get("MX_SHOT", "")
RESULTS = env["MX_RESULTS"]
SCRATCH = env["MX_SCRATCH"]
BASE = dict(timestamp=time.strftime("%Y-%m-%dT%H:%M:%S%z"), engine=env.get("MX_ENGINE", ""),
            git_sha=env.get("MX_SHA", ""), model=env.get("MX_MODELNAME", ""), quant=env.get("MX_QUANT", ""),
            placement=env.get("MX_PLACEMENT", ""), ctx=env.get("MX_CTX", ""), kv_type=env.get("MX_KV", ""))
TAG = env.get("MX_TAG", MODEL)
URL = f"http://127.0.0.1:{PORT}/v1/chat/completions"

SYSTEM = ("You are a local desktop assistant running on the user's Linux PC. Answer briefly, "
          "accurately and in plain language. Never invent things you cannot see or know. " * 6)
WORK_EN = ("In two short sentences, write a polite reply to a client who asks when the ordered delivery "
           "arrives. Shipping is planned for Thursday.")
WORK_EN2 = ("In two short sentences, write a polite reply to a supplier who asks us to confirm the "
            "invoice number for the March order. Say we will send it by Friday.")
LAT_PROMPT = ("Summarise for me, in three sentences, what a local assistant should do when the user "
              "asks what is on screen: look at the screenshot, name the open applications, say what the "
              "user seems to be doing, and offer one useful next step. Keep it short and concrete.")


def psi():
    def get(path, key):
        for ln in open(path):
            if ln.startswith(key):
                return int(ln.split("total=")[1])
        return 0
    return (get("/proc/pressure/memory", "some"), get("/proc/pressure/memory", "full"),
            get("/proc/pressure/io", "some"), get("/proc/pressure/io", "full"))


def chat(messages, max_tokens=160, stream=False):
    body = {"model": MODEL, "messages": messages, "max_tokens": max_tokens, "temperature": 0,
            "stream": stream}
    req = urllib.request.Request(URL, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=900)


def ask(messages, max_tokens=160):
    with chat(messages, max_tokens) as r:
        d = json.loads(r.read().decode())
    return (d["choices"][0]["message"].get("content") or "").strip()


def img_part(path):
    import base64
    return {"type": "image_url",
            "image_url": {"url": "data:image/png;base64," + base64.b64encode(open(path, "rb").read()).decode()}}


def stream_latency(messages, max_tokens=120):
    """-> (ttft_s, first_sentence_s, text). Times from request send."""
    t0 = time.perf_counter()
    ttft = fs = None
    text = ""
    with chat(messages, max_tokens, stream=True) as r:
        for raw in r:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:") or line == "data: [DONE]":
                continue
            try:
                delta = json.loads(line[5:])["choices"][0]["delta"].get("content") or ""
            except (KeyError, IndexError, json.JSONDecodeError):
                continue
            if not delta:
                continue
            now = time.perf_counter() - t0
            if ttft is None:
                ttft = now
            text += delta
            if fs is None and re.search(r"[.!?](\s|$)", text.strip()) and len(text.strip()) > 20:
                fs = now
    return ttft, fs, text


def median(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def write(test, tcp="", notes=""):
    row.append(RESULTS, **{**BASE, "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z")}, test=test,
               tool_call_pass=tcp, notes=notes[:900])


def main():
    p0 = psi()
    titles = json.load(open(env["MX_TITLES"])) if env.get("MX_TITLES") else []
    names = sorted(({(t.get("class") or "").strip() for t in titles} |
                    {(t.get("title") or "").strip() for t in titles}) - {""})
    shot_part = [img_part(SHOT)] if SHOT and os.path.exists(SHOT) else []

    # (a) describe the screen; score = windows/apps named in the reply
    if shot_part:
        q = ("Describe what is on this screen: name each open application or window you can see, "
             "and say in one or two sentences what the user is doing right now. English, max 90 words.")
        reply = ask([{"role": "user", "content": shot_part + [{"type": "text", "text": q}]}], 200)
        open(f"{SCRATCH}/assist-describe-{TAG}.txt", "w").write(reply)
        low = reply.lower()
        # a window counts as named if its app class or a distinctive title word appears in the reply
        hits = []
        for t in titles:
            cls = (t.get("class") or "").lower()
            ttl = (t.get("title") or "").lower()
            key_words = [w for w in re.findall(r"[a-z0-9]{4,}", ttl)][:3]
            if (cls and cls in low) or any(w in low for w in key_words):
                hits.append(t.get("class") or t.get("title"))
        n_win = len({(t.get("class") or "") for t in titles if t.get("class")}) or 1
        write("assist-describe", f"{len(set(hits))}/{n_win}",
              f"describe apps named {len(set(hits))}/{n_win} classes; titles={names[:12]} | reply={reply[:400]!r}")
    else:
        write("assist-describe", "", "SKIPPED: no screenshot")

    # (b) two short English answers
    for lang, q in (("en1", WORK_EN), ("en2", WORK_EN2)):
        reply = ask([{"role": "system", "content": SYSTEM}, {"role": "user", "content": q}], 120)
        open(f"{SCRATCH}/assist-{lang}-{TAG}.txt", "w").write(reply)
        write(f"assist-{lang}", "", f"reply={reply[:500]!r}")

    # (c) latency: warm the cached system prefix, then 3 reps without and with the screenshot
    ask([{"role": "system", "content": SYSTEM}, {"role": "user", "content": "ok"}], 1)
    for mode in ("noimg", "img"):
        if mode == "img" and not shot_part:
            continue
        ttfts, fss = [], []
        for _ in range(3):
            user = ([*shot_part] if mode == "img" else []) + [{"type": "text", "text": LAT_PROMPT}]
            ttft, fs, text = stream_latency([{"role": "system", "content": SYSTEM},
                                             {"role": "user", "content": user}])
            ttfts.append(ttft); fss.append(fs)
        mt, mf = median(ttfts), median(fss)
        row.append(RESULTS, **{**BASE, "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z")}, test=f"assist-latency-{mode}",
                   ttft_ms=f"{mt*1000:.0f}" if mt else "", tool_call_pass="",
                   notes=f"200-tok prompt, cached system prefix, median of 3: ttft={mt and round(mt*1000)}ms "
                         f"first_sentence={mf and round(mf*1000)}ms reps_ttft={[round(x*1000) for x in ttfts if x]} "
                         f"img={'yes' if mode == 'img' else 'no'}")

    p1 = psi()
    d = [b - a for a, b in zip(p0, p1)]
    write("assist-psi", "", f"PSI deltas over assistant block (us): mem_some=+{d[0]} mem_full=+{d[1]} "
                            f"io_some=+{d[2]} io_full=+{d[3]}")
    print("assistant-score done", flush=True)


if __name__ == "__main__":
    main()
