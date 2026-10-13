#!/usr/bin/env python3
"""swap-smoke.py — llama-swap smoke for bakeoff42: tool call + vision + VRAM for one model id.

Talks to the running llama-swap at 127.0.0.1:18080 (OpenAI /v1). Records whether a tool
call is emitted and whether an image is described, plus the wall time of each.
"""
import argparse, base64, json, os, re, subprocess, time, urllib.request

LAB = "/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB"
EP = "http://127.0.0.1:18080/v1/chat/completions"
ARCV = f"{LAB}/bench/arc-vram.py"


def vram():
    try:
        out = subprocess.run(["python3", ARCV], capture_output=True, text=True, timeout=20).stdout
        m = re.search(r"free=(-?\d+).*used=(\d+)", out)
        return {"free": int(m.group(1)), "used": int(m.group(2))} if m else {}
    except Exception:
        return {}


def post(payload, timeout=1200):
    req = urllib.request.Request(EP, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    t = time.monotonic()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read()), time.monotonic() - t


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--image")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    res = {"model": a.model}

    tools = [{"type": "function", "function": {
        "name": "get_weather", "description": "Get the current weather for a city",
        "parameters": {"type": "object", "properties": {"city": {"type": "string"}},
                       "required": ["city"]}}}]
    try:
        d, secs = post({"model": a.model, "messages": [
            {"role": "user", "content": "What is the weather in Vienna right now? Call the get_weather tool."}],
            "tools": tools, "tool_choice": "auto", "max_tokens": 256, "temperature": 0})
        msg = d["choices"][0]["message"]
        tc = msg.get("tool_calls")
        res["tool_call"] = {"ok": bool(tc), "secs": round(secs, 2),
                            "raw": json.dumps(tc)[:400] if tc else (msg.get("content") or "")[:400]}
    except Exception as e:
        res["tool_call"] = {"ok": False, "err": repr(e)}

    if a.image and os.path.exists(a.image):
        b64 = base64.b64encode(open(a.image, "rb").read()).decode()
        try:
            d, secs = post({"model": a.model, "messages": [{"role": "user", "content": [
                {"type": "text", "text": "Describe this screenshot in one sentence."},
                {"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}}]}],
                "max_tokens": 160, "temperature": 0})
            txt = d["choices"][0]["message"].get("content") or ""
            res["vision"] = {"ok": bool(txt.strip()), "secs": round(secs, 2), "text": txt[:400]}
        except Exception as e:
            res["vision"] = {"ok": False, "err": repr(e)}
    else:
        res["vision"] = {"ok": False, "err": f"no image at {a.image}"}

    res["vram"] = vram()
    json.dump(res, open(a.out, "w"), indent=2)
    print(json.dumps(res)[:900])


if __name__ == "__main__":
    main()
