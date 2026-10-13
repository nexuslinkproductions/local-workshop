#!/usr/bin/env python3
"""Piper WARM bench, in one process: load each voice once, then synthesize sentence by sentence.

Reports: model load time, cold first call, warm per-sentence wall/RTF/CPU, and time-to-first-audio
(TTFA) for a 3-sentence paragraph synthesized sentence by sentence (how an assistant streams).

Thread cap: piper builds its ONNX session with default SessionOptions, so when --threads N is given
we patch onnxruntime.SessionOptions to set intra_op_num_threads=N before loading. 0 = ORT default.

Run: CAP=4G CPUS=6-11,18-23 CPUW=20 ~/.local/bin/jobcap .venv-piper/bin/python bench_piper_warm.py --threads 4
"""
import argparse, io, json, os, statistics, time, wave
from pathlib import Path

import onnxruntime
from piper import PiperVoice

VOICE_DIR = Path(__file__).resolve().parent / "piper-voices"
ap = argparse.ArgumentParser()
ap.add_argument("--threads", type=int, default=0)
args = ap.parse_args()

if args.threads:
    _Orig = onnxruntime.SessionOptions

    class _Capped(_Orig):
        def __init__(self):
            super().__init__()
            self.intra_op_num_threads = args.threads
            self.inter_op_num_threads = 1
    onnxruntime.SessionOptions = _Capped

SENT = {
    "de_DE-thorsten-high": [
        "Guten Morgen Marcel, die Sprachausgabe läuft jetzt komplett lokal.",
        "Die Batterie des Laptops ist bei achtzig Prozent.",
        "Soll ich die Termine für heute vorlesen?",
        "Heute stehen drei Besprechungen an, die erste beginnt um neun Uhr.",
        "Das Wetter in Wien bleibt mild, mit einzelnen Schauern am Nachmittag.",
    ],
    "en_US-lessac-high": [
        "Good morning Marcel, speech output now runs fully local.",
        "The laptop battery is at eighty percent.",
        "Shall I read out today's calendar?",
        "You have three meetings today, the first one starts at nine.",
        "The weather in Vienna stays mild, with a few showers this afternoon.",
    ],
}
PARA = {  # 3-sentence paragraphs for TTFA
    "de_DE-thorsten-high": SENT["de_DE-thorsten-high"][:3],
    "en_US-lessac-high": SENT["en_US-lessac-high"][:3],
}


def synth(voice, text):
    """Return (wall_s, wav_bytes, audio_s, cpu_s)."""
    buf = io.BytesIO()
    c0, t0 = time.process_time(), time.perf_counter()
    with wave.open(buf, "wb") as w:
        voice.synthesize_wav(text, w)
    wall = time.perf_counter() - t0
    cpu = time.process_time() - c0
    buf.seek(0)
    with wave.open(buf) as w:
        audio = w.getnframes() / w.getframerate()
    return wall, audio, cpu


def bench_voice(name):
    path = VOICE_DIR / f"{name}.onnx"
    t0 = time.perf_counter()
    voice = PiperVoice.load(str(path))
    load = time.perf_counter() - t0
    cold_wall, _, _ = synth(voice, SENT[name][0])  # first call: allocator/graph warm-up
    rows = []
    for s in SENT[name]:
        w, a, c = synth(voice, s)
        rows.append({"wall": w, "audio": a, "rtf": w / a, "cpu_util": c / w})
    # TTFA: sentence 1 wall after start; later sentences show whether synth keeps ahead of playback
    ttfa_runs, para_runs = [], []
    for _ in range(3):
        p0 = time.perf_counter()
        first_w, first_a, _ = synth(voice, PARA[name][0])
        ttfa_runs.append(first_w)
        rest = [synth(voice, s) for s in PARA[name][1:]]
        para_runs.append(time.perf_counter() - p0)
    return {
        "load_s": load, "cold_first_call_s": cold_wall,
        "warm_sentences": rows,
        "warm_rtf_median": statistics.median(r["rtf"] for r in rows),
        "warm_wall_median": statistics.median(r["wall"] for r in rows),
        "warm_cpu_util_median": statistics.median(r["cpu_util"] for r in rows),
        "ttfa_s_median": statistics.median(ttfa_runs),
        "paragraph_total_s_median": statistics.median(para_runs),
        "paragraph_audio_s": sum(synth(voice, s)[1] for s in PARA[name]),
    }


if __name__ == "__main__":
    out = {"threads": args.threads or "ort-default", "affinity_cpus": len(os.sched_getaffinity(0))}
    for name in SENT:
        out[name] = bench_voice(name)
        r = out[name]
        print(f"[t={out['threads']}] {name}: load {r['load_s']:.2f}s cold1st {r['cold_first_call_s']:.2f}s "
              f"warm RTF {r['warm_rtf_median']:.3f} warm wall {r['warm_wall_median']:.2f}s "
              f"cpu/wall {r['warm_cpu_util_median']:.2f}x TTFA {r['ttfa_s_median']:.2f}s "
              f"para {r['paragraph_total_s_median']:.2f}s for {r['paragraph_audio_s']:.2f}s audio", flush=True)
    dest = VOICE_DIR.parent / f"bench-piper-warm-t{args.threads or 'default'}.json"
    dest.write_text(json.dumps(out, indent=2, ensure_ascii=False))
    print("wrote", dest)
