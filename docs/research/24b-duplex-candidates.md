# 24b: NVIDIA Magpie TTS (English) on this box, and the duplex candidates it replaced (2026-10-13)

## Magpie: status (2026-10-13)

- Works on the box. CPU (`cpu-tts` build) and Intel Arc B580 (`vulkan-tts` build, `--device vulkan:0`).
- Model files verified: F16 GGUF and `.nemo` sha256 match the Hugging Face LFS hashes. NanoCodec decoder size matches.
- Runtime: `voice/engines/magpie/src/NeMo-Speech.cpp` (ggml). Built `cpu-tts` and `vulkan-tts`. The Vulkan build is pristine llama.cpp (the `vulkan-*` presets set `NEMO_SPEECH_GGML_PATCHED=OFF`). CPU is patched.
- Outputs: `voice/bakeoff/magpie/{cpu,vulkan0}/` (20 WAVs, 5 lines × Aria and Jason). Index and numbers: `voice/bakeoff/INDEX.md`.
- Latency, English, after model load: time to first audio ~206 ms CPU, ~82 ms Vulkan0. RTF 0.35 CPU, 0.33 Vulkan0 (the local transformer and sampling still run on CPU on the Vulkan path).
- Quality: ASR round-trip with Parakeet v3 reproduces all 20 texts (mean WER 4.5%, spelling differences only). Not listened to by a human.
- Newer NVIDIA small English speech model than Magpie (2026-09-09): none found. HF search for nvidia `tts` and `speech` newest: Magpie, then ASR-only models (`nemotron-speech-streaming-en-0.6b` 2026-08-05, `nemotron-3.5-asr-streaming-0.6b`). Not a full survey.
- Gender of voices is by name only (Aria, Sofia female; Jason, John, Leo male). NVIDIA does not state gender in the model card.
- Reproduce: `NEMO_SPEECH_MODEL_DIR=voice/engines/magpie/models/cache build/<preset>/bin/nemo-speech synthesize ...` or `voice/engines/magpie/render_bakeoff.py <cpu|vulkan:0> <preset> Aria,Jason`.

## Earlier pass: full-duplex candidates (why the big models were dropped)

Research pass 1, written before the target changed. Marcel then narrowed the lane to the small NVIDIA
voice model above. Only the reasons the big duplex models were dropped are kept here. Not a full survey.

## Why each does not fit this box (12 GB Arc B580, shared with the LLM brain)

| Model | Facts (source) | Why it does not fit |
|---|---|---|
| NVIDIA PersonaPlex-7B-v1 | 7.7B params, safetensors ~15.4 GB bf16. Language tag `en` only. NVIDIA Open Model License (commercial OK). https://huggingface.co/nvidia/personaplex-7b-v1 | bf16 weights alone exceed 12 GB. Repo says "GPU with a significant amount of memory (24GB)" and no quantization for the PyTorch path (moshi README). Its `--cpu-offload` path moves layers per frame over PCIe, far from 80 ms real time. English only, so German is out. |
| Kyutai Moshi (moshiko/moshika) | 7B, same stack as PersonaPlex. https://github.com/kyutai-labs/moshi | Same 24 GB PyTorch requirement. Quantized builds exist only for MLX (Apple, int4/int8). English. |
| MiniCPM-o 4.5 | 9B (SigLip2 + Whisper-medium + CosyVoice2 + Qwen3-8B). EN and ZH speech only. Full-duplex. https://huggingface.co/openbmb/MiniCPM-o-4_5 | Model card: NVIDIA GPU with at least 28 GB for PyTorch. llama.cpp-omni path lists 12 GB NVIDIA GPU, and that one is half-duplex on NVIDIA/Metal. No German. |
| Qwen3-Omni-30B-A3B (Apache-2.0) | ~35B params total on HF. Speech output in 10 languages (German among them per Qwen tech report, unverified in this pass). Not full-duplex in the PersonaPlex sense. https://arxiv.org/abs/2509.17765 | Weights ~70 GB bf16, Q4 ~18–20 GB. Does not fit 12 GB VRAM. Transformers CPU bf16 needs ~70 GB RAM, we have 61 GiB. |
| Qwen3.5-Omni | Plus/Flash API only per secondary sources. Light is claimed open-weight, but `Qwen/Qwen3.5-Omni-Light` is not on the HF API (404 at check time). | Not verified as downloadable. |
| FLM-Audio (CofeAI) | 7B, native full-duplex, English and Chinese only. https://huggingface.co/CofeAI/FLM-Audio | No German. 7B bf16 ~14 GB. |
| Freeze-Omni (VITA-MLLM) | Built on a frozen Qwen2-7B-Instruct LLM plus speech codec. https://github.com/VITA-MLLM/Freeze-Omni | Two 7B-class models, NVIDIA-oriented, no German evidence. |
| Hibiki-Zero (Kyutai, 2026-02-12) | 3B. Simultaneous speech translation FR/ES/PT/DE -> EN with voice transfer. https://huggingface.co/kyutai/hibiki-zero-3b-pytorch-bf16 | Fits memory (~6 GB bf16), but it is a translator with English output only, not an assistant. Repo says "requires an NVIDIA GPU; 8 GB should work, 12 GB is safe". Not tried on XPU. Worth a look later for DE->EN live translation, not for the JARVIS voice. |
| NemotronLabs VoiceChat 11B | Ruled out in the brief (80 GB, English, research licence). | — |

## Kyutai notes (for later)

- Kyutai Pocket TTS (Jan 2026, ~100M params, CPU real-time, voice cloning, five more languages added April 2026): https://kyutai.org/tts/ . It is TTS only, not duplex. Language list not checked here.
- Kyutai TTS 1.6B (EN/FR, GPU-oriented) is in the Unmute stack: https://kyutai.org/next/tts

## Verdict

No full-duplex open model that speaks German and fits a 12 GB card with the LLM running. The
practical "fluid" path on this box is the cascade (STT -> LLM -> small streaming TTS), so the
voice quality work moves to TTS. See the Magpie section above.
