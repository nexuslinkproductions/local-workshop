# 23 — Voice phase 0: local Piper TTS + parakeet STT wired into Hermes

Status: in progress (written incrementally). Scope: `research/22b-jarvis-voice.md` §7 items 1–2 and the V0/V1 steps. No GPU, no `bench/.gpu.lock`, Voxtype config untouched, no audio played on speakers.

## 1. What is installed where

| Piece | Location | Notes |
|---|---|---|
| Piper TTS 1.8.0 (`piper-tts`, OHF-Voice piper1-gpl, GPL-3.0) | `LOCAL-AI-LAB/voice/.venv-piper/` | venv from Hermes' Python 3.14.7, pip only, no sudo, no system install |
| Voice `de_DE-thorsten-high` (CC0, 114 MB) | `LOCAL-AI-LAB/voice/piper-voices/` | downloaded via `piper.download_voices` |
| Voice `en_US-lessac-high` (114 MB) | `LOCAL-AI-LAB/voice/piper-voices/` | en_US chosen over en_GB; both medium/high exist |
| TTS wrapper `piper-tts` | `LOCAL-AI-LAB/voice/piper-tts` | Python entry point on the venv; caps ONNX threads (`PIPER_THREADS`, default 4). Not named `piper`: `/usr/bin/piper` is the libratbag mouse app and is never called |
| STT venv `onnx-asr` 0.12.0 + onnxruntime + soundfile | `LOCAL-AI-LAB/voice/.venv-stt/` | pip only |
| STT wrapper `stt-parakeet` | `LOCAL-AI-LAB/voice/stt-parakeet` | ffmpeg → 16 kHz mono WAV → onnx-asr, model `parakeet-tdt-0.6b-v3` int8 read in place from `~/.local/share/voxtype/models/parakeet-tdt-0.6b-v3-int8/` (no copy) |
| Benches | `voice/bench_piper.py`, `voice/bench_piper_warm.py`; results `voice/bench-piper-*.json` | |

Why not Voxtype for STT: `voxtype transcribe --engine parakeet --model parakeet-tdt-0.6b-v3-int8` ignores the model override, prints "Unknown model … using default model 'base.en'" and loads `parakeet-unified-en-0.6b` (English only). Tested on a German WAV, it returned `Udmorgen Marken that local people function`. Voxtype's engine cannot reach v3 through the CLI, so STT goes through onnx-asr.

## 2. Piper latency

Measured on this box (Ryzen 7900X class, 12 logical CPUs pinned by `CAP=4G CPUS=6-11,18-23 CPUW=20 jobcap`; affinity verified = 12).

### 2a. Cold, one process per call (what Hermes' command provider does), 4 ONNX threads

Median of 3 runs. Wall includes process start and ~0.85 s voice-model load.

| Text | Voice | Audio s | Wall s | RTF | CPU s (whole process) |
|---|---|---|---|---|---|
| DE 1 sentence | thorsten-high | 3.83 | 1.41 | 0.377 | 3.31 |
| DE 3 sentences | thorsten-high | 6.07 | 1.67 | 0.275 | 4.23 |
| EN 1 sentence | lessac-high | 3.42 | 1.38 | 0.401 | 3.12 |
| EN 3 sentences | lessac-high | 5.31 | 1.64 | 0.308 | 4.01 |

The first pass (before the thread cap, ORT default) gave wall 1.54–1.92 s and CPU 11.7–21.7 s per call. Those numbers are superseded.

### 2b. Warm: voice loaded once, sentence by sentence (same process)

5 sentences per language, RTF = synth wall / audio. TTFA = wall time to the first sentence's audio when a paragraph is synthesized one sentence at a time, median of 3. Whole-process CPU is from the shell `time` builtin.

| ONNX threads | Load (DE / EN) | Warm RTF (DE) | Warm wall per sentence (DE) | TTFA (DE / EN) | 3-sent paragraph wall (DE) | Whole-process CPU, 3-sent DE call |
|---|---|---|---|---|---|---|
| 2 | 0.87 / 0.84 s | 0.207 | 0.74 s | 0.79 / 0.73 s | 1.78 s (9.1 s audio) | 4.1 s |
| **4 (chosen)** | 0.88 / 0.85 s | **0.107** | **0.38 s** | **0.41 / 0.37 s** | **0.93 s** (8.7 s audio) | **4.2 s** |
| ORT default (12 cores) | 0.88 / 0.86 s | 0.129 | 0.42 s | 0.45 / 0.42 s | 1.09 s (9.1 s audio) | **21.0 s** |

Warm RTF for EN at 4 threads is 0.108; the English numbers track German within 1%.

Reading the table:
- 4 threads is the best trade: as fast as the default (faster in RTF), and about 5× less CPU. The default burns ~21 CPU-seconds, roughly 10 cores, for the same audio, which would collide with the LLM on the same CPU.
- 2 threads is cheapest but about 2× slower in RTF; keep as the fallback if the LLM needs more cores.
- The in-process `cpu/wall` ratio for the default row (20.9) is higher than 12 logical CPUs can deliver, so that one counter is unreliable. The whole-process `time` numbers are the trusted CPU figures.
- Cold per-call cost is ~0.9 s of model load on every utterance. Hermes' command provider spawns a process per call, so the assistant pays it each time. Fixing that needs the built-in provider or a keep-warm server; both are a later decision.

Sentence streaming implication: after the first sentence (~0.4 s warm, plus ~1 s cold), each later sentence synthesizes in ~0.4 s for ~1.5–2.5 s of audio, so synthesis stays ahead of playback. Good enough for a streamed reply.

## 3. STT: parakeet-tdt-0.6b-v3 int8

- Model read in place: `~/.local/share/voxtype/models/parakeet-tdt-0.6b-v3-int8/` (640 MB, sha256 in its manifest). No copy, Voxtype untouched.
- Runtime: `onnx-asr` 0.12.0 (MIT) on onnxruntime CPU, venv `voice/.venv-stt/`. Loads the int8 directory directly (`nemo-parakeet-tdt-0.6b-v3`, `quantization="int8"`).
- Wrapper `voice/stt-parakeet <audio>`: ffmpeg to 16 kHz mono WAV (accepts any container Hermes hands it), then recognize, transcript on stdout. Language is auto-detected by the model.
- ONNX intra-op threads capped at 4 (`STT_THREADS`). Uncapped it used ~12 CPU-s per call; capped ~3 CPU-s, same transcripts.

| Clip | Cap | Wall per call | Whole-process CPU | Output |
|---|---|---|---|---|
| smoke DE (3.4 s) | 4 | 1.59 s | 3.4 s | `Guten Morgen, Markel. Das lokale Piper funktioniert.` |
| smoke EN (2.6 s) | 4 | 1.59 s | 3.3 s | `Hello Marcel, the local voice works.` |
| smoke DE | uncapped | 1.94 s | 12.6 s | same |

Wall time is mostly the ~1.5–2 s model load per call (command provider = new process each time). Recognition alone is ~0.3 s for a 3 s clip.

Why not `voxtype transcribe`: its `--model` override is ignored by the parakeet engine. Each run logs "Unknown model 'parakeet-tdt-0.6b-v3-int8', using default model 'base.en'" and then loads `parakeet-unified-en-0.6b` (English-only). On a German WAV that gives `Udmorgen Marken that local people function`.

## 4. Hermes wiring (config changes)

Backup, taken before any change: `~/.hermes/config.yaml.bak-voice-20261013-090045` (mode 600). Applied with `hermes config set` (nested provider keys needed `--force`; Hermes treats user-defined provider names as unknown paths otherwise).

| Key | Old | New |
|---|---|---|
| `tts.provider` | `mlx-local` (Apple-only, macOS path on Kingston volume) | `piper_de` |
| `tts.providers.piper_de` | (absent) | `type: command`, `command: /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/voice/piper-tts de_DE-thorsten-high {output_path} < {input_path}`, `format: wav`, `timeout: 120` |
| `tts.providers.piper_en` | (absent) | same, `command: … piper-tts en_US-lessac-high {output_path} < {input_path}` |
| `tts.providers.mlx-local` | present | left in place, unused (dead entry; delete in a later cleanup) |
| `stt.provider` | `parakeet` | `parakeet` (unchanged) |
| `stt.providers.parakeet.command` | `/run/media/…/Kingston…/.venv-stt/bin/python /home/nexuslink/.hermes/scripts/parakeet-stt-client.py {input_path} {output_path} --language {language}` | `/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/voice/stt-parakeet {input_path}` |
| `voice.auto_tts` | false | false (unchanged) |
| `wake_word.enabled` | false | false (unchanged) |

Full diff vs backup: 3 hunks, nothing else touched (`diff` checked).

Note: `hermes config get stt.provider` prints "not a recognized config key", but Hermes reads it: the STT round trip below dispatches to `parakeet` (`provider` field in the result).

**Hermes speaks one configured voice at a time.** `text_to_speech_tool` ignores per-call `provider` (log: "Ignoring per-call TTS provider override 'piper_en'; tts.provider is 'piper_de'"), by design (tts_tool.py). The English test therefore switches `tts.provider` to `piper_en` with `hermes config set`, runs, and switches back. Bilingual routing in normal use is an open decision (§8).

## 5. Round trip (Hermes paths: `text_to_speech_tool` → WAV → `transcribe_audio`)

Run from the Hermes runtime venv: `voice/roundtrip.py de|en`. WAVs in `voice/roundtrip/`. Reference sentences are fixed in the script. WER uses lower-case, punctuation stripped, word-level edit distance.

| Run | Lang | Reference | Transcript | TTS s | STT s | WER | Word acc |
|---|---|---|---|---|---|---|---|
| 1 | DE | Guten Morgen Marcel. Der Akku ist bei achtzig Prozent, und um neun Uhr beginnt die Besprechung. | Guten Morgen, Markel. Der Akku ist bei 80 Prozent und um 9 Uhr beginnt die Besprechung. | 1.61 | 2.23 | 0.188 | 81.2 % |
| 1 | EN | Good morning Marcel. The battery is at eighty percent, and the meeting starts at nine. | Good morning Marcel. The battery is at 80%, and the meeting starts at nine. | 1.53 | 2.09 | 0.133 | 86.7 % |
| 2 (final config, STT 4 threads) | DE | (same) | Guten Morgen Markel. Der Akku ist bei 80 Prozent und um 9 Uhr beginnt die Besprechung. | 1.64 | 1.81 | 0.188 | 81.2 % |
| 2 (final config) | EN | (same) | Good morning Marcel. The battery is at 80%, and the meeting starts at 9. | 1.58 | 1.79 | 0.200 | 80.0 % |

Reading the errors: the audio is clean, and the errors are mostly formatting. "achtzig"→"80", "neun"→"9", "eighty"→"80%", "nine"→"9" account for most of them. The real recognition error is the name: German "Marcel" came out as "Markel" or "Makel" depending on the run; English "Marcel" was correct in every run. A WER that counts digit-vs-word as an error will undercount accuracy for a spoken assistant; the transcript itself is usable.

Important: the first English attempt (run 0) was invalid. The config was still on `piper_de`, so the German voice read English text (WER 0.667). It is excluded from the results above.

## 6. Latency summary (per utterance, what Hermes pays)

| Step | Path | Wall s | Notes |
|---|---|---|---|
| TTS, one sentence | `piper-tts` command provider, cold | 1.4–1.6 | ~0.9 s of that is model load; warm sentence 0.37–0.41 s (§2b) |
| STT, one utterance (3 s) | `stt-parakeet` command provider, cold | 1.6–1.8 | ~1.5 s model load + ~0.3 s recognition |
| Round trip, one DE sentence | TTS + STT | ~3.4–3.9 | |

A warm keep-alive (built-in Hermes provider or a small daemon) would cut each step to roughly its warm number. Not done here; see §8.

## 7. Checks (self-check)

Each task, with the evidence:

| # | Task | Result | Evidence |
|---|---|---|---|
| 1 | Piper installed in venv, no system install, no sudo | PASS | `voice/.venv-piper/`, piper-tts 1.8.0; `/usr/bin/piper` never called |
| 1 | Voices de_DE-thorsten-high and en_US-lessac-high in `voice/piper-voices/` | PASS | `.onnx` + `.onnx.json` both present, 114 MB each |
| 1 | Wrapper `voice/piper-tts`, no `piper` name | PASS | smoke synth DE and EN; `PIPER_THREADS` cap verified (CPU 2.0x/4.0x) |
| 2 | Latency, RTF, CPU for 1- and 3-sentence DE/EN, under jobcap | PASS | §2a cold, §2b warm; jobcap affinity 12 CPUs verified |
| 2 | Warm latency + TTFA + thread caps 2/4/default | PASS | §2b |
| 3 | parakeet v3 int8 found and usable from Hermes | PASS (path fixed) | read in place from voxtype models dir; via onnx-asr, not voxtype (§3) |
| 4 | Backup of config before edit | PASS | `~/.hermes/config.yaml.bak-voice-20261013-090045` |
| 4 | `tts.provider` / `stt.provider` set via `hermes config set` | PASS | `hermes config get tts.provider` → `piper_de`; `stt.provider` → `parakeet` |
| 4 | auto_tts false, wake_word disabled | PASS | `voice.auto_tts` → false; `wake_word.enabled` → false |
| 4 | No sed edit of config.yaml | PASS | all changes via `hermes config set`; diff = 3 hunks |
| 5 | Round trip DE: Hermes TTS → WAV → Hermes STT | PASS (word acc 81.2 %, Marcel→Markel) | §5 runs 1 and 2 |
| 5 | Round trip EN: same | PASS (word acc 86.7 % / 80.0 %) | §5 runs 1 and 2 |
| 5 | Re-run of round trip after final config | PASS | §5 run 2 |
| — | No audio played on speakers | PASS | `text_to_speech_tool` only writes files; no `aplay`/`pw-play` in path |
| — | GPU / `bench/.gpu.lock` / Voxtype config untouched | PASS | not read or written (lock file still present) |

## 8. Open decisions and risks

1. **Bilingual routing.** Hermes uses one configured TTS provider and ignores per-call overrides. Right now the assistant speaks German only (`piper_de`). Options: (a) a language heuristic inside `piper-tts` that picks the voice from the text; (b) let the model emit a language tag the wrapper reads; (c) two Hermes profiles. Needs a decision before Phase 1.
2. **Cold model load per call** (~0.9 s Piper, ~1.5 s parakeet). Fix: keep-warm server or Hermes' built-in provider path. Not built in phase 0.
3. **Thread caps.** Piper 4 threads (RTF 0.107 warm), STT 4 threads. Reasonable default while the LLM runs. Not measured with the LLM active; test once the LLM is serving.
4. **Name recognition.** Marcel is heard as "Markel"/"Makel" in German. A hotword or post-STT name fix is a Phase 1 item.
5. **Digits.** STT writes digits where the speaker said words. Fine for display, bad for WER.
6. **Dead `mlx-local` entry** left in config (unused).
7. **Piper is GPL-3.0.** Fine for personal use with Hermes calling it as a separate package (22b §9).

## 9. Rollback

```sh
cp ~/.hermes/config.yaml.bak-voice-20261013-090045 ~/.hermes/config.yaml
```

Restores the old `tts.provider: mlx-local` and the Kingston STT command. Nothing else needs undoing. The voice venvs and models in `LOCAL-AI-LAB/voice/` are inert with the config reverted; delete them only if you want the disk back.
