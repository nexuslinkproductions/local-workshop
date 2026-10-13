# Expressive English TTS shortlist for a calm British JARVIS voice

Research checked 13 October 2026. The target is now **calm British male English**. American/female voices are omitted from the audition set. The existing Magpie/Kokoro speed bake-off is not repeated. Model/vendor claims are separated from blind-preference evidence; all local speed/memory numbers below are measured CPU results, not vendor claims.

## Recommendation

1. **Kyutai TTS 0.75B public-data model** — best fit for the British voice goal: it accepts reference audio prefixes, and Kyutai's voice repository includes VCTK speakers under CC BY 4.0. Its inference code works on CPU, but the local Ryzen 9 7900X run is far too slow for a live assistant (observed RTF ≈9–13; 5.5 GiB RSS). Do not confuse this with the 1.6B model's vendor 220 ms text-to-audio claim, which is not a local B580 measurement. Official card reports public English weights, CC BY 4.0 and 74.9% speaker similarity for 0.75B vs 80.9% for 1.6B.[[Kyutai 0.75B card](https://huggingface.co/kyutai/tts-0.75b-en-public)][[Kyutai voices and VCTK attribution](https://huggingface.co/kyutai/tts-voices)]
2. **KaniTTS 2 English (400M)** — the most direct British stock-voice candidate found: the official card exposes Rory (Glasgow) and Baddy (Liverpool), with tags `en_glasg` and `en_scou`. It installed with CPU-only PyTorch and is rendering on CPU. The vendor reports an RTX 5080 RTF around 0.2 and 3 GB VRAM; that is not evidence of B580 support or CPU speed. The model card does not declare a clear model-weights license, so treat the weights as terms-unclear until resolved.[[KaniTTS2 English card](https://huggingface.co/nineninesix/kani-tts-2-en)][[official examples/tag list](https://huggingface.co/spaces/nineninesix/kanitts-2-en/blob/main/examples.yaml)]
3. **Orpheus 3B** — expressive tags (`<laugh>`, `<sigh>`, etc.) and three male presets (`leo`, `dan`, `zac`), but the stock voices are generic English, not documented British voices; a B580 GGUF route exists only as a non-upstream/community conversion paired with a separate SNAC decoder. Its 3B parameter size and unsupported prompt-to-British workflow make it a poor immediate target. The model page is gated, so no checkpoint was downloaded.[[Orpheus card](https://huggingface.co/canopylabs/orpheus-3b-0.1-ft)][[GGUF + SNAC conversion](https://huggingface.co/cstr/orpheus-3b-0.1-ft-GGUF)]
4. **Dia 1.6B** — promising dialogue/emotion control and can condition on audio, so it could use a licensed VCTK male sample; however authors state CPU support is “to be added” and document only GPU testing. It is not a fast-on-CPU choice, and its reported 4.4 GB GPU use already exceeds the current ~2 GB B580 budget while Gemma is resident. No Dia venv/audio was produced.[[Nari Labs Dia card](https://huggingface.co/nari-labs/Dia-1.6B-0626)][[Dia upstream guidance](https://github.com/nari-labs/dia)]

This is a **hardware/voice-fit shortlist**, not a claim that these four are the four most natural in blind tests. The independent broad preference evidence favors models that do not fit the shared-VRAM constraint.

## Newer listening-test evidence

- Artificial Analysis' open-weights Speech Arena is blind user preference, not a vendor MOS claim. At retrieval, the top open-weight entries were Breeze TTS 2 (Elo 1223, 1,992 comparisons), Fish Audio S2 Pro (1116, 2,521), Step Audio EditX (1098, 2,166), and Voxtral TTS (1088, 2,253). Fish is the best ranked of these with emotion control; its 4B+400M dual-AR design and research/non-commercial license make it unsuitable as a quick CPU/B580 deployment.[[Artificial Analysis open-weights leaderboard](https://artificialanalysis.ai/text-to-speech/leaderboard/provider-voice/open-weights)][[Fish S2 Pro card/license](https://huggingface.co/fishaudio/s2-pro)]
- TTS Arena V2's live 39-row API contained none of Orpheus, Kani, Kyutai, Dia, CSM, VibeVoice, Higgs, Fish, or Voxtral at retrieval. Therefore it provides no preference ranking for this candidate set; its listed open entries were Kokoro v1.0 and Veena, not these models.[[TTS Arena V2 live leaderboard API](https://tts-agi-tts-arena-v2.hf.space/api/leaderboard)]
- Vendor-reported metrics remain separate: Kyutai's 220 ms and Kani's GPU RTF are vendor/hardware-specific; no independent pairwise naturalness result found for the British voices being auditioned.

## Candidate scan

| Candidate | Fit / British voice | Decision |
|---|---|---|
| Kyutai TTS 1.6B en/fr (France) | Main model supports voice-prefix cloning and Kyutai voice repo includes CC BY VCTK speakers; too large for ~2 GB spare VRAM. | Run 0.75B public variant instead; test its CPU speed empirically. |
| KaniTTS 2 English | 400M, English, stock Scottish Rory and Liverpool Baddy; vendor lists 3 GB GPU for RTX 5080 but not B580. | Install and audition those two British male voices on CPU. |
| Orpheus 3B (Canopy Labs) | Eight fixed English voices, three male; tags support emotion. No named British preset; Q4 GGUF still requires a supported talker+SNAC runtime and is an unverified integration here. | Shortlist only if later testing can verify a British reference-prompt path. |
| Dia 1.6B (Nari Labs, Korea) | English dialogue, audio prompting and nonverbal tags; CPU explicitly not yet supported upstream; GPU use exceeds shared budget. | Defer; do not spend a long CPU render until an efficient CPU/XPU path exists. |
| CSM-1B (Sesame, US) | General conversational model, no stock voice; reference audio conditioning possible. HF checkpoint requires agreeing to gated access and is listed as 2B params / F32. | Deferred: access gate, memory and no measured fast CPU path. Reference samples would need VCTK/LibriTTS-R, not bundled demo voices. |
| VibeVoice-Realtime-0.5B (Microsoft, US) | ~300 ms first audio is vendor claim; single speaker, no British stock/cloning path, BF16 card shows ~1B stored params. | Skip for British target. VibeVoice 1.5B has poor independent AA open-weights Elo 957 and is not a better fit. |
| Higgs Audio v2 (Boson AI, US) | 3.6B LLM + 2.2B audio DualFFN; Llama-community-derived terms; far beyond VRAM budget. | Skip. Higgs V3 TTS scored Elo 1038 on AA, still too large. |
| Fish Audio S2 Pro (China-origin vendor; company provenance not verified here) | Very expressive; 4B slow AR + 400M fast AR; research/non-commercial license and too large for shared GPU. | Strongest ranked expressive model, not a fast local candidate. |
| Voxtral TTS 4B (Mistral, France) | BF16 and documented single-GPU minimum ≥16 GB; CC BY-NC 4. AA Elo 1088. | No B580/shared-VRAM fit; no proven llama.cpp/ONNX/CPU alternative found. |
| Spark-TTS 0.5B (China-facing) | ~0.5B, cloning; current card says CC BY-NC-SA 4.0, not Apache. | Not in shortlist; license noncommercial and no independent preference result. |
| MOSS-TTS-Nano (OpenMOSS, China) | 100M, CPU-first and Apache-2.0; voice cloning/built-ins, but not the expressive LLM-TTS lane. | Dropped exactly as requested; partial venv/source removed. |
| Newer: Breeze TTS 2 | AA open-weights Elo 1223; reported 3B and 12 GB minimum, with research/noncommercial terms. | Naturalness-front-runner on board, but fails shared VRAM constraint. |
| Newer: Step Audio EditX | AA Elo 1098. | Not an obviously direct, compact TTS deployment for this hardware. |

## Local audition status

Four shared lines are used in local scripts: line 2 and 5 from `research/BRIEF-24-voice-bakeoff.md`, plus Marcel's requested “Ha, you actually got it working. Nice. Okay, what's next?” and “Good evening, Marcel. Everything is running smoothly. Shall I prepare the summary?”

| Engine / voice | Device | Status | Audio / metrics |
|---|---|---|---|
| Kyutai 0.75B / VCTK p226 (Surrey male) | CPU, 6 threads | Rendering; first 4/12 WAVs passed initial non-silence check pending full validation. Measured on first four: TTFA 36–44 s, RTF 8.73–13.15, peak RSS 5,480 MiB. | `voice/bakeoff/kyutai-tts/`; `voice/engines/kyutai-tts/render.py` |
| Kyutai 0.75B / VCTK p227 (Cumbria male) | CPU, 6 threads | Rendering | same folder; `metrics.json` |
| Kyutai 0.75B / VCTK p232 (Southern England male) | CPU, 6 threads | Rendering | same folder; `metrics.json` |
| KaniTTS2 / Rory (Glasgow male) | CPU, 6 threads | Rendering; 3/4 WAVs generated so far. Measured TTFA/complete-output 22.8–31.9 s, RTF 3.96–4.38, peak RSS 3,550 MiB. | `voice/bakeoff/kani-tts/`; `voice/engines/kani-tts/render.py` |
| KaniTTS2 / Baddy (Liverpool male) | CPU, 6 threads | Pending after Rory | same folder; `metrics.json` |

Reference audio for Kyutai is VCTK `p226_023`, `p227_023`, and `p232_023` from Kyutai's VCTK directory; the source repo identifies VCTK as CC BY 4.0. These identifiers map to male English accents Surrey, Cumbria, and Southern England respectively.[[Kyutai VCTK source/license](https://huggingface.co/kyutai/tts-voices)][[VCTK speaker list](https://huggingface.co/voices/VCTK_British_English_Males)]

**Audibility disclaimer:** no output was played on speakers by this run. The parent should listen to these files before assigning Marcel's subjective verdict. No claim of “natural” is made from RMS, ASR, or vendor prose.

## Repro/install notes

- Dedicated environments: `voice/engines/kyutai-tts/.venv` (CPU torch 2.9.1 + moshi 0.2.13) and `voice/engines/kani-tts/.venv` (CPU torch 2.14.1 + `kani-tts-2` 0.0.5). No CUDA wheel was installed. Both are CPU-only; no GPU lock was taken for these runs.
- Kani's vendor dependency pins conflicted: its model code imports `TransformersKwargs`, absent from the NeMo-pinned Transformers 4.52.0. It imported and loaded after using the model-card-published Transformers 4.56.0 over the resolved dependency set. This is a local compatibility workaround, not an upstream-tested installation recipe.
- MOSS's earlier partial venv and source checkout were removed at user direction; no MOSS model/audio remains.
- Full WAV/RMS/process/lock verification will be recorded in `voice/bakeoff/EXPRESSIVE.md` after the renders finish. Current rows above are interim, not final verification.
