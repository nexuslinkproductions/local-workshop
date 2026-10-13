# 22b — Jarvis voice stack (question 2 of BRIEF-22)

Scope: fully local wake word, streaming STT (German + English), characterful TTS, barge-in, echo cancel.
Constraints honoured: no GPU use, no model loads, Voxtype config untouched, nothing installed.
Sources are cited inline. Anything not checked is marked **unverified**. Measured-on-this-box numbers: **none yet** (all latency figures are published or community numbers from other hardware).

## Answer in brief

- **Wake word:** openWakeWord via the engine Hermes already ships (`pyopen-wakeword`, TFLite). Train a "Jarvis" model; the bundled `hey_hermes` is only the plumbing test. Porcupine's built-in "jarvis" works but is proprietary and needs a key. Not preferred.
- **STT (utterance, German + English):** `parakeet-tdt-0.6b-v3-int8` is already on disk (640 MB, 25 European languages incl. German, auto language detect). Fallback for quality: `cohere-transcribe-int8` (2.9 GB, 14 languages incl. German). Voxtype's current `parakeet-unified-en` is English-only and is not the German path.
- **Streaming partials:** not needed for the critical path (the LLM dominates latency). The only streaming model on disk is English-only. If live partials are wanted later, Vosk German (Apache-2.0, ~45 MB) is the CPU option. Unverified quality.
- **TTS (character):** Kyutai **Pocket TTS** (France; 100M params, CPU, ~200 ms to first audio, voice cloning from ~5 s, German supported since May 2026). Weights are CC-BY-4.0 and gated on Hugging Face. Fallback: **Piper** `de_DE-thorsten-high` (CC0, fastest, plain character). Piper is already wired into Hermes' local TTS providers.
- **Barge-in:** Silero VAD (already on disk) on the mic while TTS plays, with headphones (phase 1). Echo cancel via PipeWire `libspa-aec-webrtc` for speakers (phase 3). Hermes' existing energy-based barge-in detector works as a first stub.
- **Hermes config that must change** (not applied; see §7): TTS provider `mlx-local` (Apple-Silicon only) and STT path pointing at the Kingston volume.

## 0. What already exists on this box (checked, not assumed)

### Voxtype (1.1.0, `~/build/voxtype`, `~/.config/voxtype/config.toml`)
- Binary `~/.local/bin/voxtype` 1.1.0. `engine = "parakeet"`, `[parakeet] model = "parakeet-unified-en-0.6b"`, `streaming = true`, chunk 0.32 s, left ctx 5.6 s, right ctx 0.32 s. **English only.**
- Models on disk (`~/.local/share/voxtype/models/`):
  - `parakeet-unified-en-0.6b` (2.4 G, English, streaming): the one in use.
  - `parakeet-tdt-0.6b-v3` (2.4 G) and `parakeet-tdt-0.6b-v3-int8` (640 M): multilingual, German included. **Already downloaded, unused.**
  - `cohere-transcribe-int8` (2.9 G): 14 languages incl. German.
- Whisper engine is compiled in (`base.en`). `voxtype transcribe <wav> --engine <e> [--model …]` runs file-based transcription (CLI override, no config edit).
- Wake-word hook already exists: `voxtype record start|stop|toggle|cancel` (SIGUSR1/SIGUSR2), `record start --file=<path>` writes the transcript to a file, and `[audio] external_trigger_silence_timeout_secs` auto-stops external-trigger recordings after silence. `docs/CONFIGURATION.md` describes this as "the mechanism a wake-word integration uses". Voxtype has no wake word of its own.
- Voxtype's default output is *typing into the focused window* (`mode = "type"`). For an assistant, route the transcript with `--file` or `transcribe`, not typing. Whether `record start --file` still types is **unverified**.
- Voxtype's README claims Cohere Transcribe runs "9–11× realtime on a plain Zen 4 CPU" (`~/build/voxtype/README.md` line 9). The 7900X is Zen 4, so this is a relevant CPU number, but it is the project's own claim.

### Hermes (`~/.hermes`) — the voice stack is already largely built
- **STT:** `stt.provider: parakeet`, but the command runs a Python venv under `/run/media/nexuslink/82CC5F65CC5F5311/Users/mikek/YURI-OS-MUSUBI/...` (Kingston volume, macOS-era path) with `~/.hermes/scripts/parakeet-stt-client.py`. Fragile: it depends on a mount and an old venv.
- **TTS:** `tts.provider: mlx-local` runs `mlx_audio.tts.generate … Kokoro-82M-bf16`. **MLX is Apple-Silicon only; this box cannot run that command.**
- **Wake word:** `wake_word.enabled: false`. Code in `tools/wake_word.py` and `tools/wake_word_engines.py` has three engines: openWakeWord (`pyopen-wakeword==1.1.0`, TFLite, ships `tools/wakewords/hey_hermes.tflite`), sherpa-onnx KWS (`sherpa-onnx==1.13.8`, open-vocabulary typed phrases), Porcupine (`pvporcupine==4.0.3`, needs `PORCUPINE_ACCESS_KEY`). Default `auto` order: openWakeWord → sherpa → Porcupine. Docs: `website/docs/user-guide/features/wake-word.md`.
- **Voice mode:** `tools/voice_mode.py` (1555 lines): recorder, energy VAD endpointing, interruptible playback (`stop_playback`), and an energy barge-in detector (`_BargeDetector`: 30 ms blocks, rolling noise floor, grace period after playback start). Local STT = `faster-whisper==1.2.1`. **No echo cancellation in-tree.**
- **Local TTS providers** (`tools/tts_tool_local.py`): Piper (`piper-tts==1.8.0`, auto-downloads voices by name), KittenTTS (opt-in extra, English), NeuTTS (cloning, subprocess). Also `type: command` providers under `tts.providers.<name>`, which is how Pocket TTS would plug in without code changes.
- **Gotcha:** the NeuTTS extra is pinned `python_version < '3.14'` (`pyproject.toml` line 244). The Hermes venv is Python 3.14.7, so **NeuTTS cannot be installed in that venv** as configured.
- **Not installed yet:** the Hermes venv has `onnxruntime` and `numpy` only. `pyopen_wakeword`, `sherpa_onnx`, `faster_whisper`, `piper`, `kittentts`, `neutts`, `sounddevice` are PM extras, installed on demand.
- `tools/stt_lease.py`: warm-up lease, so the local STT model loads while the user is still speaking (relevant to the desktop-freeze rule).
- `tools/voice_live.py`: GPT-Live full-duplex **cloud** mode (OpenAI, $0.05/min). Out of scope for a fully local stack; listed for completeness.

### Other local assets
- `~/.config/October/voice-models/silero_vad.onnx` (644 kB, Silero VAD ONNX). Usable for the wake → utterance gate and for barge-in. Licence check: MIT per the Silero repo (§4).
- `~/.config/October/voice-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8/`: English-only v2, not needed.
- `~/.local/bin/voiceio*`: `voiceio` is a broken symlink into a deleted scratch venv (`~/.hermes/cache/scratch/voiceio-venv`). Not a working stack.
- `/usr/bin/piper` is **not** Piper TTS. It is a GTK gaming-mouse configurator (Arch `piper 0.8-5`, libratbag). Its Python module `piper` is also that app. Do not confuse it with the TTS package.
- No espeak-ng, whisper-cli, sherpa-onnx or openwakeword CLI on PATH.
- PipeWire 1.6.8 ships `libpipewire-module-echo-cancel.so`; no echo-cancel module is configured in `~/.config/pipewire` or `/etc/pipewire`. EasyEffects is installed. `wtype` is installed; `ydotool`/`dotool` not checked.
- Audio: Focusrite Scarlett 2i2 4th Gen. Input 1 = MKE 600 (`voice-sample-record` targets it). Outputs: Scarlett headphones/line 1–2, Corsair Slipstream headset (its own mic is a separate source, pick the Scarlett explicitly), HDMI monitor, HDA.

## 1. Wake word

| Option | Licence (code / models) | Cost on CPU | Custom "Jarvis" | Verdict |
|---|---|---|---|---|
| **openWakeWord** (dscripka; Hermes uses the rhasspy fork `pyopen-wakeword`) | Apache-2.0 code; **pre-trained models CC BY-NC-SA 4.0** (training data licences) — [github.com/dscripka/openWakeWord](https://github.com/dscripka/openWakeWord) | Small; ONNX or TFLite | Yes: openWakeWord training notebook, synthetic clips generated with **Piper TTS** — [tele-ai doc](https://github.com/CarbonRaven/tele-ai/blob/main/documentation/raspberry-pi-5-openwakeword.md) (third-party summary). Colab T4 ~30–60 min per model (same source). Local training is Linux-only. | **Pick.** Already in Hermes. Pretrained `hey_jarvis` exists (list in linux-voice-assistant). |
| **microWakeWord** (OHF-Voice, Apache-2.0 per the repo, unverified) | repo: [github.com/OHF-Voice/micro-wake-word](https://github.com/OHF-Voice/micro-wake-word) | Models 50–300 KB; example 82.5 KB int8 streaming, recall 94 %, FP 1/140 hard negatives (community trainer README) — [interkelstar/microwakeword-trainer](https://github.com/interkelstar/microwakeword-trainer) | Yes, same synthetic pipeline | Good second engine. Not in Hermes; runs via `pymicro-wakeword` in linux-voice-assistant. |
| **sherpa-onnx KWS** (k2-fsa, Apache-2.0) | Apache-2.0 | Streaming zipformer, RTF 0.036 on a 3.3M model (sherpa demo) — [k2-fsa KWS docs](https://k2-fsa.github.io/sherpa/onnx/kws) | **Yes without training**: keywords typed as tokens, per-keyword boost/threshold. English KWS model only verified. | Good for a "type any phrase" mode. Already a Hermes engine. |
| **Porcupine** (Picovoice, commercial vendor) | proprietary; free tier with key | low | built-in "jarvis" keyword | Works, but needs an access key and a proprietary engine. Last resort. |

Decision: **openWakeWord**. Use the bundled `hey_hermes` as the plumbing test, then train "Jarvis" with the openWakeWord notebook, adding Piper German voices for negatives. **Licence note:** pretrained weights are CC BY-NC-SA. Fine for personal use, not for a commercial product. A custom model trained from your own synthetic data carries whatever licence you choose for your data. This is a legal point, not verified here.

Sensitivity starting point: `wake_words_sensitivity ≈ 0.35` for custom OWW models (RealtimeSTT docs, [docs/wake-words.md](https://github.com/KoljaB/RealtimeSTT/blob/master/docs/wake-words.md)). Tune on real room audio.

## 2. Speech-to-text (streaming, German + English)

Requirement split: the **utterance** path (after wake word, transcribe a full sentence) and the **streaming** path (partial text while speaking). Streaming matters for barge-in and captions, not for answer latency.

| Model | Languages | Streaming | Licence | Size on disk / RAM | Speed evidence | On this box |
|---|---|---|---|---|---|---|
| **parakeet-tdt-0.6b-v3** (NVIDIA) | 25 European incl. **de**, en; auto-detect | **No** (offline TDT; "not a streaming model", [GGUF card](https://huggingface.co/memoravox/parakeet-tdt-0.6b-v3-gguf)) | NVIDIA card; licence **unverified** here | 640 MB int8 / 2.4 GB fp32, on disk | Voxtype runs it via ONNX on CPU. No speed number measured here | **Pick for utterances.** Already on disk, no download. Model card: [build.nvidia.com](https://build.nvidia.com/nvidia/parakeet-tdt-0_6b/modelcard) |
| **parakeet-unified-en-0.6b** | English only | **Yes** (streaming chunks) | NVIDIA | 2.4 GB | Current Voxtype config | English-only. Keep for English dictation. |
| **cohere-transcribe-03-2026** (Cohere, Canada) | 14 incl. **de**, en, fr, it, es… | No (encoder-decoder, offline) | **Apache-2.0** — [HF blog](https://huggingface.co/blog/CohereLabs/cohere-transcribe-03-2026-release) | 2B params; 2.9 GB int8 on disk, already present | #1 English on Open ASR leaderboard, avg WER 5.42 %. Voxtype claims 9–11× realtime on Zen 4 CPU (project README, not independent) | **Fallback for accuracy.** Heavier RAM load; load once and keep warm. |
| whisper large-v3-turbo (OpenAI, MIT) + German fine-tune (`cstr/whisper-large-v3-turbo-german-ggml`) | many; German fine-tune | No (chunk-based) | MIT / check fine-tune | ~1.5 GB (turbo) | Iris Xe Vulkan: medium 6.4 s vs 21.7 s CPU for an 11 s clip — [giobatt/whisper-gpu-benchmarks](https://github.com/giobatt/whisper-gpu-benchmarks). Arc B580 **not measured**. | Not on disk. Only worth it if Vulkan on the B580 is free; it is not (LLM owns it). |
| Vosk (Alpha Cephei, Russian; Apache-2.0) `vosk-model-small-de-0.15` | German, 20+ | **Yes**, zero-latency streaming | Apache-2.0 — [github.com/alphacep/vosk-api](https://github.com/alphacep/vosk-api) | ~45 MB | WER 13.75 on German small per a third-party listing — [whipscribe](https://whipscribe.com/tools/vosk) (**unverified**) | Only if live German partials are needed. Lower accuracy than parakeet. |
| faster-whisper (Hermes local STT today) | Whisper languages | No | MIT | CPU-only ctranslate2 | Hermes' current `stt.local` engine | Not GPU-capable on Arc. Keep only as a fallback. |

**Recommendation**
1. Utterance STT: `parakeet-tdt-0.6b-v3-int8`. Test first with `voxtype transcribe --engine parakeet --model parakeet-tdt-0.6b-v3-int8 <de-sample.wav>` on a recorded German and English sample (CLI override, Voxtype config untouched). Record wall time and WER by eye.
2. If accuracy on Marcel's mic is not good enough: `cohere-transcribe-int8`.
3. Streaming partials: skip in phase 1. Add Vosk German only if live captions are wanted.
4. Voxtype reuse question: **yes, the engine can be reused**, through `voxtype record start --file=…` on wake and `external_trigger_silence_timeout_secs` for auto-stop. The catch: the running daemon loads one model (`parakeet-unified-en`, English). For German, the daemon model must change (a Voxtype config decision). Do not run two STT models in parallel by default.

## 3. Text-to-speech (characterful, local, German)

| Engine | Licence | Params | German | Cloning | CPU speed evidence | GPU need | Verdict |
|---|---|---|---|---|---|---|---|
| **Pocket TTS** (Kyutai, France) | **code MIT**, **weights CC-BY-4.0, gated on HF** ([HF card](https://huggingface.co/kyutai/pocket-tts)) | 100M | **Yes**: six languages incl. German since 3 May 2026 ([Kyutai blog](https://kyutai.org/blog/2026-05-04-pocket-tts-multilingual/)); German `german` (6-layer) and `german_24l` configs in v2.0.0 ([releases](https://github.com/kyutai-labs/pocket-tts/releases)) | **Yes** (~5 s reference clip) | ~200 ms to first audio chunk; ~6× realtime on M4 with 2 cores (Kyutai). Kyutai's comparison says Pocket TTS and Kokoro were the only ones realtime on Intel Core Ultra 7 165H (vendor report) — [tech report](https://kyutai.org/pocket-tts-technical-report) | No (CPU; GPU not worth it per Kyutai) | **Pick for character.** German quality **unverified** — test. |
| **Piper** (OHF-Voice `piper1-gpl`, the maintained successor to archived rhasspy/piper) | **GPL-3.0-or-later** (rhasspy/piper was MIT until archived 6 Oct 2025) — [piper1-gpl releases](https://github.com/OHF-Voice/piper1-gpl/releases) | 15–80M per voice | Yes: **de_DE thorsten** (CC0), thorsten-high/medium/emotional (CC0), **kerstin** (CC0), eva_k / karlsson / ramona (M-AILABS, BSD-style), mls (CC-BY 4.0) — [per-voice licence table](https://huggingface.co/cstr/piper-voices-GGUF) | Not supported (no cloning). Plain character. | Community: TTFA 39–90 ms warm on CPU; "Piper is the leader… drop-in for an always-on agent" — [tts-bench](https://github.com/5uck1ess/tts-bench/blob/master/docs/results.md) (community, different CPU). 2 ARM cores: `siwis-medium` RTF ≈ 0.12 at 2 threads, ×8.2 realtime — [obole-ia benchmark](https://github.com/obole-ia/tts-cpu-benchmark) | No | **Fallback and reliability pick.** Already a Hermes provider (`tools/tts_tool_local.py`). |
| **Chatterbox Multilingual** (Resemble AI, US) | MIT ([HF card](https://huggingface.co/ResembleAI/chatterbox)) | 0.5B Llama | Yes (23 languages incl. de) | Yes, zero-shot + emotion exaggeration control | Vendor claims sub-200 ms (their hosted service). Community L40S RTF ≈ 0.19 ([chatterbox-turbo-streaming](https://github.com/piyushgit011/chatterbox-turbo-streaming)). **No CPU number found.** | Reference code uses `device="cuda"`. Guides list 6 GB min, 10 GB+ recommended ([Clore](https://docs.clore.ai/guides/audio-and-voice/chatterbox-tts)). A measured 3.06 GB allocation on a P40 ([Chatterbox-Pro](https://github.com/x90skysn3k/Chatterbox-Pro)). | **Best character among open models, but GPU-bound.** Would share the B580 with the LLM. Not on GT 1030 (2 GB). Revisit for a "voice hour" if the LLM is idle. |
| **NeuTTS** (Neuphonic, UK) | Air: Apache-2.0. Nano/2E: NeuTTS Open License 1.0 (terms unverified). | Air ~360M active, Nano ~120M | "Supported: English, Spanish, German, French (model-dependent)" — [neutts README](https://github.com/neuphonic/neutts). `neutts-nano-german` exists (GGUF). | Yes, 3–15 s reference | Claimed real-time on CPU with GGUF Q4 (400–600 MB RAM) — [third-party blog](https://www.spheron.network/blog/neutts-air-spheron-voice-ai/) (unverified) | No | Viable German-clone option. **Blocked in the Hermes venv (py 3.14 marker).** |
| **Kokoro-82M** (hexgrad, Apache-2.0) | Apache-2.0 | 82M | **No**: card lists American and British English ([HF](https://huggingface.co/hexgrad/Kokoro-82M)) | No ("lacks voice cloning") | ×0.87–0.93 realtime on 2 ARM cores; slower than speech (obole-ia benchmark). Community 8-core ≈ 5× (unverified). | No | Reject for German. Current Hermes config uses it via MLX (Mac). |
| **KittenTTS** (KittenML, Apache-2.0) | Apache-2.0 | 15M (25 MB int8) | **English only** ([KittenTTS](https://github.com/KittenML/KittenTTS)) | No | RTF 0.187 on Raspberry Pi 5 (LiteRT port card) | No | English-only fallback. Already a Hermes extra. |

**Recommendation**
- Character voice: **Pocket TTS**, German model. Clone a **licensed or original** reference clip: Marcel's own voice (`voice-sample-record` exists) or a CC0 voice. Do **not** clone a film actor. Kyutai's prohibited-use clause requires explicit consent for cloning.
- Fallback / reliability: **Piper `de_DE-thorsten-high`** (CC0; 113.9 MB per the Piper index). Use `thorsten-medium` (63 MB) if RAM is tight.
- Upgrade path (GPU, later): Chatterbox Multilingual, once the B580 has room.
- Install gotcha for Pocket TTS on Linux: `pip install pocket-tts` pulls the CUDA PyTorch wheel set (~3 GB). Use `--extra-index-url https://download.pytorch.org/whl/cpu` ([Kyutai README](https://github.com/kyutai-labs/pocket-tts)).
- Runtime alternative without torch: CrispASR (C/GGUF), which ships Pocket-TTS German as a 124 MB Q8 GGUF — [v0.8.31 release notes](https://github.com/CrispStrobe/CrispASR/releases/tag/v0.8.31). Unverified project; keep as an option.
- Hermes wiring: a `type: command` provider in `tts.providers` is enough for Pocket TTS (`{input_path}`, `{output_path}` placeholders, as the existing mlx-local entry shows).

## 4. Barge-in and echo cancel

- **Silero VAD** (MIT, ~1–2 MB ONNX): < 1 ms per 30 ms chunk on one CPU thread ([repo](https://github.com/snakers4/silero-vad); perf page via [mirror](https://mintlify.wiki/snakers4/silero-vad/model/performance)). Already on disk (`silero_vad.onnx`). Use it instead of Hermes' energy VAD for the barge-in trigger.
- **Phase 1 (headphones):** with the Scarlett headphones output, the MKE 600 hears almost no playback. Barge-in = Silero on the mic while TTS plays; on trigger, call the existing `stop_playback()` and open the capture. Hermes' `_BargeDetector` (energy, rolling floor, grace period) is a working stub.
- **Phase 3 (speakers):** **PipeWire echo cancel** with the WebRTC AEC3 backend (`library.name = aec/libspa-aec-webrtc`, default) — [PipeWire docs](https://docs.pipewire.org/page_module_echo_cancel.html). Load it from `~/.config/pipewire/pipewire.conf.d/`, send TTS to the echo-cancel playback sink, and point wake/VAD at the echo-cancelled source. Pattern confirmed by linux-voice-assistant's AEC doc ([enabling_aec.md](https://github.com/OHF-Voice/linux-voice-assistant/blob/main/docs/enabling_aec.md)). **Unverified here:** how the module interacts with the EasyEffects mic chain on Input 1; test order before adopting.
- Speex AEC is an older option (linux-voice-assistant's noise suppression uses speexdsp); not evaluated further.

## 5. Latency budget (targets, not measured)

Only the cited numbers are measured-elsewhere. Everything else is an estimate to replace after §7 tests.

| Stage | Target | Basis |
|---|---|---|
| Wake word fire → capture start | < 100 ms | openWakeWord frame size 80 ms (Hermes engine `frame_length`); estimate |
| End-of-utterance detection | 400–700 ms | VAD hangover; config value, **to set** |
| STT (utterance, parakeet v3 int8, CPU) | 0.5–1.5 s for a 5 s utterance | **estimate, unmeasured**; Voxtype/Cohere claim 9–11× realtime for cohere on Zen 4 |
| LLM first sentence | depends on model | separate research (Q1) |
| TTS first audio | 40–200 ms | Piper 39–90 ms warm (community); Pocket ~200 ms first chunk (Kyutai) |
| **Total to first spoken word** | **~1.5–2.5 s** | sum of estimates; the LLM is the variable |

## 6. Desktop-never-freezes constraints (apply to every stage)

- Keep wake word and VAD always-on: both tiny (openWakeWord models are KB-scale, Silero ~1–2 MB).
- Load STT/TTS models **once at idle** and keep them warm. Hermes' `stt_lease` already does this for STT. Never load the 2.9 GB Cohere model on demand: the 20–37 GB model load froze the desktop earlier (brief, measured).
- Limit voice workers to 1–2 threads (Piper and Pocket both use 2 cores). Pin them away from the LLM's cores if the quiet-mode pinning from `00-plan.md` (10-13) is in use.
- Do not give the voice stack GPU VRAM: the B580 is the LLM's, and the GT 1030 (2 GB) is too small for Chatterbox.

## 7. Proposed changes (NOT applied; decisions for Marcel)

1. Hermes `tts.provider`: `mlx-local` → `piper` (fallback) or a `type: command` Pocket TTS provider (character). The mlx entry cannot run on this box.
2. Hermes `stt.provider` path: replace the Kingston-volume `parakeet` venv path with a local command, or with Voxtype's `transcribe --engine parakeet --model parakeet-tdt-0.6b-v3-int8`.
3. Voxtype: if German dictation through Voxtype is wanted, change `[parakeet] model` to `parakeet-tdt-0.6b-v3-int8`. **Not done** (Voxtype is out of scope for this task).
4. Hermes `wake_word`: `enabled: true` with the openWakeWord engine selected (exact `provider` value to confirm in `tools/wake_word.py`; default `auto` already picks openWakeWord on Linux). Currently `enabled: false`.
5. PipeWire echo cancel: optional drop-in file in `~/.config/pipewire/pipewire.conf.d/` (phase 3).

## 8. Phased plan (voice part only; full plan is in the BRIEF)

- **V0 — tests, no installs (fastest):** `voxtype transcribe` with parakeet-v3-int8 on a German and an English WAV from `~/Music/voice-samples`. Record time and transcript. Decide utterance STT.
- **V1 — speak back:** Piper `de_DE-thorsten-high` via Hermes' existing local provider (PM install of `piper`). One German reply spoken. Verify the desktop stays responsive.
- **V2 — wake word:** install the openWakeWord extra; run `hey_hermes` as a plumbing test; then train "Jarvis" with Piper German negatives. Wire to `voxtype record start --file` or Hermes' own capture.
- **V3 — character voice:** Pocket TTS German, cloned from a licensed reference. A/B against Piper on German text, including names and numbers.
- **V4 — barge-in:** Silero VAD on the mic during playback; headphones first. Then PipeWire AEC for speakers.
- **V5 — optional:** Vosk German partials, or Chatterbox when the GPU is free.

## 9. Open risks and unverified items

- **German quality** of Pocket TTS: only Kyutai's own demo and a release note. Not heard on this box. **Unverified.**
- **Pocket TTS access:** weights are gated on Hugging Face (accept the terms with a HF account, token needed on the box). CC-BY-4.0 requires attribution.
- **Parakeet v3 accuracy and language auto-detect** on short German utterances: unverified. Auto-detect can flip language on 1–2 word commands.
- **Voxtype `record start --file`** behaviour (does it still type?): unverified. Needs a test.
- **Piper is GPL-3.0-or-later.** Fine for personal use with Hermes calling it as a separate package. Caution if shipped.
- **openWakeWord pretrained weights** are CC BY-NC-SA 4.0. Personal use OK; custom-trained models carry your own licence.
- **Chatterbox and NeuTTS-Nano-German:** GPU need and licence terms unverified on this box (NeuTTS Nano's "NeuTTS Open License 1.0" text not read).
- **Hermes NeuTTS extra** is blocked on Python 3.14 (pyproject marker). Pocket TTS and Piper avoid this.
- **PipeWire AEC + EasyEffects** ordering on Input 1: unverified.
- **No latency measured on this box.** All numbers in §5 are estimates or other hardware. A 5-minute test in V0 replaces the STT one.
- **Piper naming collision:** `/usr/bin/piper` is a mouse configurator. Check `which piper` before assuming Piper TTS.
- **GPT-Live** (cloud, OpenAI) exists in Hermes. Not local. Excluded.

## 10. Sources (all fetched 2026-10-13 unless noted)

- openWakeWord repo and licence: https://github.com/dscripka/openWakeWord
- openWakeWord training summary (third-party): https://github.com/CarbonRaven/tele-ai/blob/main/documentation/raspberry-pi-5-openwakeword.md
- microWakeWord: https://github.com/OHF-Voice/micro-wake-word ; community trainer: https://github.com/interkelstar/microwakeword-trainer
- linux-voice-assistant (OWW/MWW, hey_jarvis, AEC doc): https://github.com/OHF-Voice/linux-voice-assistant , https://github.com/OHF-Voice/linux-voice-assistant/blob/main/docs/enabling_aec.md , https://github.com/OHF-Voice/linux-voice-assistant/blob/main/docs/install_application.md
- sherpa-onnx open-vocabulary KWS: https://k2-fsa.github.io/sherpa/onnx/kws
- RealtimeSTT wake-word docs: https://github.com/KoljaB/RealtimeSTT/blob/master/docs/wake-words.md
- Silero VAD: https://github.com/snakers4/silero-vad
- NVIDIA Parakeet TDT 0.6B v3 model card: https://build.nvidia.com/nvidia/parakeet-tdt-0_6b/modelcard ; GGUF card (non-streaming note): https://huggingface.co/memoravox/parakeet-tdt-0.6b-v3-gguf
- Cohere Transcribe 03-2026: https://huggingface.co/blog/CohereLabs/cohere-transcribe-03-2026-release ; https://cohere.com/blog/transcribe
- whisper.cpp Vulkan on Iris Xe: https://github.com/giobatt/whisper-gpu-benchmarks ; German turbo GGML: https://huggingface.co/cstr/whisper-large-v3-turbo-german-ggml (cited via the Wyoming Intel project https://github.com/querdenker2k/wyoming-whisper-intel-gpu)
- Vosk: https://github.com/alphacep/vosk-api ; https://alphacephei.com/vosk/models ; third-party WER: https://whipscribe.com/tools/vosk
- Pocket TTS: https://github.com/kyutai-labs/pocket-tts ; https://huggingface.co/kyutai/pocket-tts ; https://kyutai.org/blog/2026-05-04-pocket-tts-multilingual/ ; https://kyutai.org/pocket-tts-technical-report ; https://github.com/kyutai-labs/pocket-tts/releases
- CrispASR Pocket-TTS GGUF: https://github.com/CrispStrobe/CrispASR/releases/tag/v0.8.31
- Piper: archive/licence context https://github.com/OHF-Voice/piper1-gpl/releases ; German voice licences https://huggingface.co/cstr/piper-voices-GGUF ; voice list https://huggingface.co/ruslanmv/hp-piper-voices (its "MIT" note conflicts with the per-voice table; per-voice terms used here)
- Piper / Kokoro CPU benchmark (2 ARM cores): https://github.com/obole-ia/tts-cpu-benchmark
- TTS latency table (community): https://github.com/5uck1ess/tts-bench/blob/master/docs/results.md
- Kokoro-82M card: https://huggingface.co/hexgrad/Kokoro-82M
- Chatterbox Multilingual: https://huggingface.co/ResembleAI/chatterbox ; VRAM guide https://docs.clore.ai/guides/audio-and-voice/chatterbox-tts ; measured VRAM https://github.com/x90skysn3k/Chatterbox-Pro ; L40S RTF https://github.com/piyushgit011/chatterbox-turbo-streaming
- NeuTTS: https://github.com/neuphonic/neutts ; third-party CPU claim https://www.spheron.network/blog/neutts-air-spheron-voice-ai/
- KittenTTS: https://github.com/KittenML/KittenTTS ; Pi5 RTF https://huggingface.co/litert-community/kitten-tts-nano-0.8
- PipeWire echo cancel: https://docs.pipewire.org/page_module_echo_cancel.html
- Local (checked on disk): `~/.config/voxtype/config.toml`, `~/build/voxtype/docs/CONFIGURATION.md`, `~/.hermes/config.yaml` (tts/stt/wake_word), `~/.hermes/hermes-agent/tools/{wake_word,wake_word_engines,voice_mode,voice_live,stt_lease,tts_tool_local}.py`, `~/.hermes/hermes-agent/pyproject.toml`, `~/.hermes/hermes-agent/website/docs/user-guide/features/wake-word.md`, `~/.config/October/voice-models/`.
