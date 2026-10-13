#!/usr/bin/env python3
"""Round trip through Hermes' own code paths: text_to_speech_tool -> WAV -> transcribe_audio.

Hermes ignores per-call TTS provider overrides (tts_tool.py: config is authoritative), so the
language is selected by setting tts.provider in config before each run. Run one language per
process so the config is re-read:
  voice/roundtrip.py de   |   voice/roundtrip.py en
Run with the Hermes runtime interpreter (has ruamel/yaml):
  CAP=4G CPUS=6-11,18-23 CPUW=20 ~/.local/bin/jobcap <hermes-venv-python> roundtrip.py de
Writes voice/roundtrip/<lang>-<provider>.wav and voice/roundtrip/results-<lang>.json.
"""
import json
import re
import subprocess
import sys
import time
import unicodedata
from pathlib import Path

sys.path.insert(0, str(Path.home() / ".hermes/hermes-agent"))
from tools.tts_tool import text_to_speech_tool  # noqa: E402
from tools.transcription_tools import transcribe_audio  # noqa: E402

OUT = Path(__file__).resolve().parent / "roundtrip"
OUT.mkdir(exist_ok=True)
CASES = {
    "de": ("piper_de", "Guten Morgen Marcel. Der Akku ist bei achtzig Prozent, und um neun Uhr beginnt die Besprechung."),
    "en": ("piper_en", "Good morning Marcel. The battery is at eighty percent, and the meeting starts at nine."),
}


def norm(s):
    s = unicodedata.normalize("NFC", s).lower()
    return re.sub(r"[^\w\s]", " ", s).split()


def wer(ref, hyp):
    r, h = norm(ref), norm(hyp)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev, d[j] = d[j], cur
    return d[len(h)] / max(1, len(r)), len(r)


def main():
    lang = sys.argv[1]
    provider, text = CASES[lang]
    active = subprocess.run(["hermes", "config", "get", "tts.provider"], capture_output=True, text=True).stdout.strip().splitlines()[-1]
    assert active == provider, f"config tts.provider is {active!r}, expected {provider!r}; set it first"
    wav = OUT / f"{lang}-{provider}.wav"
    t0 = time.perf_counter()
    env = json.loads(text_to_speech_tool(text, output_path=str(wav)))
    t_tts = time.perf_counter() - t0
    path = env.get("file_path") or str(wav)
    t1 = time.perf_counter()
    stt = transcribe_audio(path)
    t_stt = time.perf_counter() - t1
    hyp = stt.get("transcript", "")
    w, n = wer(text, hyp)
    res = {"lang": lang, "tts_provider": provider, "tts_success": env.get("success"), "wav": path,
           "tts_s": round(t_tts, 3), "stt_provider": stt.get("provider"), "stt_success": stt.get("success"),
           "stt_s": round(t_stt, 3), "reference": text, "transcript": hyp, "wer": round(w, 4), "ref_words": n,
           "word_acc_pct": round(100 * (1 - w), 1)}
    (OUT / f"results-{lang}.json").write_text(json.dumps(res, indent=2, ensure_ascii=False))
    print(f"[{lang}] tts {t_tts:.2f}s ({provider}) stt {t_stt:.2f}s ({stt.get('provider')}) "
          f"WER {w:.3f} word-acc {100 * (1 - w):.1f}% -> {hyp!r}", flush=True)


if __name__ == "__main__":
    main()
