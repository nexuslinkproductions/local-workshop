#!/usr/bin/env python3
"""Piper latency bench: wall time, real-time factor, CPU use per text.

Runs the real wrapper (voice/piper-tts) once per text, as Hermes' command provider does,
so model load is included. 3 repeats per text; median reported.
Run: CAP=4G CPUS=6-11,18-23 CPUW=20 ~/.local/bin/jobcap python3 voice/bench_piper.py
"""
import json, os, resource, statistics, subprocess, time, wave
from pathlib import Path

VOICE = Path(__file__).resolve().parent
OUT = Path(os.environ.get("TMPDIR", "/tmp")) / "piper-bench"
OUT.mkdir(parents=True, exist_ok=True)
TEXTS = {
    ("de", 1): ("de_DE-thorsten-high", "Guten Morgen Marcel, die Sprachausgabe läuft jetzt komplett lokal."),
    ("de", 3): ("de_DE-thorsten-high",
                "Guten Morgen Marcel. Die Batterie des Laptops ist bei achtzig Prozent. "
                "Soll ich die Termine für heute vorlesen?"),
    ("en", 1): ("en_US-lessac-high", "Good morning Marcel, speech output now runs fully local."),
    ("en", 3): ("en_US-lessac-high",
                "Good morning Marcel. The laptop battery is at eighty percent. "
                "Shall I read out today's calendar?"),
}
REPEATS = 3


def audio_seconds(path):
    with wave.open(str(path)) as w:
        return w.getnframes() / float(w.getframerate())


def run_once(voice, text, idx):
    wav = OUT / f"bench-{voice}-{idx}.wav"
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    t0 = time.perf_counter()
    p = subprocess.run([str(VOICE / "piper-tts"), voice, str(wav)], input=text.encode(),
                       capture_output=True, timeout=300)
    wall = time.perf_counter() - t0
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode()[-500:])
    cpu = (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)
    dur = audio_seconds(wav)
    return {"wall_s": wall, "cpu_s": cpu, "audio_s": dur, "rtf": wall / dur, "cpu_util": cpu / wall}


def main():
    print("affinity cpus:", len(os.sched_getaffinity(0)), sorted(os.sched_getaffinity(0))[:3], "...")
    results = {}
    for (lang, n), (voice, text) in TEXTS.items():
        runs = [run_once(voice, text, i) for i in range(REPEATS)]
        med = {k: statistics.median(r[k] for r in runs) for k in ("wall_s", "cpu_s", "audio_s", "rtf", "cpu_util")}
        med["chars"] = len(text)
        results[f"{lang}-{n}sent"] = {"voice": voice, "median": med, "runs_wall_s": [round(r["wall_s"], 2) for r in runs]}
        print(f"{lang}-{n}sent {voice}: wall {med['wall_s']:.2f}s audio {med['audio_s']:.2f}s "
              f"RTF {med['rtf']:.3f} cpu {med['cpu_s']:.2f}s util {med['cpu_util']:.2f}x", flush=True)
    (VOICE / "bench-piper-results.json").write_text(json.dumps(results, indent=2, ensure_ascii=False))
    print("wrote", VOICE / "bench-piper-results.json")


if __name__ == "__main__":
    main()
