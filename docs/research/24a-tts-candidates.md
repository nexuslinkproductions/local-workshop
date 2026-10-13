# 24a: small English TTS candidates (evidence as of 2026-10-13)

Scope: English TTS that could run locally (CPU or one modest GPU). Listening evidence first, leaderboards second.

The four CPU candidates in this shortlist were installed in isolated venvs and audition WAVs are indexed at `../voice/bakeoff/INDEX.md`.

## Caveat on the evidence

- **No independent blind listening test covering all candidates was found.** Ranking below uses three kinds of evidence, which are not the same thing:
  1. **Human preference (blind arena):** Artificial Analysis (AA) Provider Voice Arena Elo. Each model is scored on its provider's own voice, so it is not a same-voice comparison.
  2. **Predicted MOS:** UTMOS, a neural predictor of human MOS. One blog's 36 samples, one voice. The same blog says UTMOS over-rates small vocoder models.
  3. **Intelligibility/similarity:** HF Open TTS Leaderboard (WER and speaker similarity). It states it does *not* measure naturalness or listener preference.
- Speed numbers come from third-party runs on different hardware. They are not comparable across rows unless the rig matches.
- Vendor claims (Kyutai, Canopy, Qwen, Resemble, MOSS) are marked as such.

## Ranking for Marcel's use (English, local, streaming, CPU-first)

1. **Kokoro-82M**: best-supported quality per size. Apache-2.0, widely deployed. Not streaming within a sentence (chunked). CPU TTFA about 250–300 ms.
2. **Kyutai Pocket TTS**: fastest CPU TTFA measured (tens of ms to ~150 ms, depending on rig), native streaming, voice cloning from ~5 s. Objective quality a notch below Kokoro. Weights are gated.
3. **Chatterbox Turbo**: MIT, Turbo variant, paralinguistic tags, cloning. Needs a GPU in practice (CPU 2.6–9.9 s on the bench). Non-streaming.
4. **Supertonic-3**: only candidate here with German in the 31-language set (not needed now). CPU-fast, but weights are OpenRAIL-M.
5. **Voxtral TTS 4B**: strong AA arena score, but NC weights and 16 GB+ GPU. Not a CPU option.
6. **Qwen3-TTS 0.6B**: Apache-2.0, streaming claimed (vendor 97 ms). No independent measurement of the 0.6B found.
7. **Orpheus 3B**: Apache-2.0, English, streaming (vendor ~200 ms GPU). 3B, no independent CPU numbers, no listening test found.
8. **Kitten TTS (15–80M)**: Apache-2.0, tiny, English only, non-streaming, CPU TTFA ~0.3–0.5 s. Quality below Kokoro; no blind test found.
9. **MOSS-TTS-Nano (0.1B)**: Apache-2.0, 20 languages incl. German, streaming claimed. Third-party CPU TTFA is poor (3.7–6.4 s), contradicting vendor "single CPU core" claim. Needs a re-measure.
10. **CSM-1B**: Apache-2.0 (gated), English. Sub-realtime on the bench (0.2–0.5x). Community reports of instability (HF discussion #14). Not a CPU candidate.

Dropped/not fit: Breeze TTS 2 (AA top open-weight, Elo 1216, but research/non-commercial licence and 12 GB GPU minimum; EN and ZH only). Fish S2 Pro (AA Elo 1117, Fish Audio Research License: non-commercial free, commercial needs a separate licence).

## Comparison table

| Model | Size | Licence (weights / code) | Origin (see notes) | Streaming | CPU TTFA / speed (measured) | Listening / quality evidence |
|---|---|---|---|---|---|---|
| Kokoro-82M v1.0 | 82M | Apache-2.0 | hexgrad (not verified) | No (chunked) | 245–299 ms warm (Ryzen 9950X3D / Mac CPU); 0.64–0.67 RTF on 4-vCPU Xeon (heyneo) | AA Elo 1064 (5,283 votes, rank ~53); UTMOS 4.44–4.46 (heyneo). Languages: 8 (no German). |
| Kyutai Pocket TTS | ~100M | Code MIT; model weights CC-BY-4.0, gated | Kyutai, France (general knowledge, not re-fetched) | Yes (native, LM over Mimi codec) | 33 ms warm (Mac M4 CPU); 95–150 ms (Ryzen); 147 ms (speed page rig); RTF 0.69–0.76 on Xeon (heyneo) | UTMOS 4.10 (heyneo). Not on AA. Languages: EN, FR, DE, PT, IT, ES. Clones from ~5 s. |
| Chatterbox Turbo | 350M per HF card; ~744M per tts-bench count | MIT (code + weights per HF card) | Resemble AI, Toronto, Canada (wiki source, weak) | No (non-streaming per bench) | CPU 2.6–9.9 s warm (not real-time); CUDA 1.62 s warm; MPS 2.0 s. Vendor "sub-200 ms" applies to Resemble's hosted service, not local Turbo. | AA lists "Chatterbox HD" (hosted, Elo 1102) not Turbo. No independent listening test found. |
| Supertonic-3 | ~99M (ONNX) | Code MIT; weights OpenRAIL-M | Supertone Inc., Korea (semopl, LinkedIn) | Not verified | 509 ms TTFA (Ryzen CPU), 681 ms (Mac CPU), 6.1x RTFx | UTMOS 4.32 at 5-step; 1.53 at 2-step (heyneo). 31 languages incl. DE, FR, ES. |
| Voxtral TTS 4B (2603) | 4B, BF16 | CC BY-NC 4.0 (main card); PR branch claims Apache-2 (conflict) | Mistral AI, France | Yes (vendor) | Needs ≥16 GB GPU. Vendor H200 TTFA 70 ms @ concurrency 1. | AA Elo 1083 (2,138 votes), open-weight #4 on AA. 9 languages incl. EN, DE. |
| Sesame CSM-1B | 1B | Apache-2.0 (HF card), gated | Sesame, US (not re-verified) | Not verified | 0.2x (Mac), 0.5x RTFx (CUDA), default; sub-realtime | Community reports of instability (HF discussion #14). English only. |
| Orpheus 3B 0.1-ft | 3B (Llama-3B backbone) | Apache-2.0 | Canopy Labs, San Francisco, US (aitechsuite) | Yes (vendor ~200 ms, ~100 ms input streaming) | Vendor GPU claim; no CPU measurement found | No independent listening test found. English. |
| MOSS-TTS-Nano | 0.1B | Apache-2.0 | MOSI.AI / OpenMOSS, China | Yes (vendor) | 3.7 s TTFA Mac CPU (RTFx 1.9); 6.4 s CPU on speed page (conflicts with "one CPU core" vendor claim) | No listening test found. 20 languages incl. DE. 48 kHz stereo. |
| Kitten TTS nano/micro/mini | 15M / 40M / 80M (25–80 MB) | Apache-2.0 | KittenML; co-founder based in San Francisco (LinkedIn) | No (non-streaming) | 316–516 ms TTFA CPU; 6.4–8.2x RTFx | No blind test found. English only, 8 voices. |
| Qwen3-TTS 0.6B Base | 0.6B | Apache-2.0 | Alibaba Qwen, China | Yes (tech report, vendor 97 ms) | No independent measure of 0.6B (1.7B: 0.6x RTFx on Mac) | No listening test found. 10 languages incl. DE. |
| Fish S2 Pro | not verified | Fish Audio Research License (non-commercial) | Fish Audio (HQ not verified) | Not verified | No CPU measure | AA Elo 1117 (2,377 votes), open-weight #2. |
| Breeze TTS 2 | not verified | Research/non-commercial (weights); Apache-2.0 (code) | BreezeBlue / RESONIA Inc (Taiwan per brand, not verified) | Yes (vendor, <40 ms TTFA H100) | 12 GB GPU minimum | AA Elo 1216, top open-weight on AA. EN and ZH only. |

## Leaderboard notes

- **Artificial Analysis Provider Voice Arena** (https://artificialanalysis.ai/text-to-speech/leaderboard, checked 2026-10-13): Elo from blind votes on each provider's native voice. Kokoro 82M v1.0: 1064 (5,283 votes, cheapest at ~$0.7/1M chars). Voxtral TTS: 1083 (2,138). Fish S2 Pro: 1117. Breeze TTS 2: 1216. Top open-weight list on the page: Breeze 2 > Fish S2 Pro > Step Audio EditX > Voxtral > Magpie (excluded from this pass). Kokoro's Elo drifts (offlinetts July snapshot: 1055, rank 48).
- **HF Open TTS Leaderboard** (https://huggingface.co/blog/open-tts-leaderboard, launched 2026-09-30): ranks by macro WER on Seed-TTS and CV3 Eval plus speaker similarity. Kokoro-82M, Supertonic-3 and Fish S2 Pro lead English WER. The blog itself says it does not measure naturalness or listener preference. Do not read it as a listening ranking.
- **tts-bench** (https://github.com/5uck1ess/tts-bench, results May 2026, speed page https://5uck1ess.github.io/tts-bench/speed.html): third-party CPU/CUDA/MPS TTFA and RTFx on several rigs. Rig is named per table. Notes that Piper is fastest on predefined-voice CPU (not in scope here), Pocket TTS is the fastest cloning-capable option on CPU.
- **heyneo CPU benchmark** (https://heyneo.com/blog/kokoro-supertonic-inflect-nano-pocket-tts-cpu-benchmark): 6 configs, 4-core Xeon, UTMOS. Includes the only head-to-head Kokoro vs Pocket vs Supertonic on one rig in this pass. Author is a vendor-adjacent blog; the code repo is public (gauravvij/kokoro-tts-vs-supertonic-3-tts).
- **Anecdotal, not used for ranking**: Reddit r/LocalLLaMA Pocket TTS post (same heyneo data), HF Kitten/CSM discussions.

## Origins (non-US where verified)

- Non-US, verified in-page or by a source above: Mistral (France), Kyutai (France, general knowledge), MOSI.AI/OpenMOSS (China), Alibaba Qwen (China), Supertone (Korea), Resemble AI (Toronto, Canada, from a wiki page; weak source).
- US, verified: Canopy Labs (SF, aitechsuite), KittenML (SF co-founder, LinkedIn).
- Not verified: hexgrad (Kokoro), Fish Audio, BreezeBlue/RESONIA (Taiwan, brand only), Sesame (US, general knowledge).

## Gaps

- No independent blind listening test covering Pocket, Chatterbox Turbo, Supertonic-3, Kitten, CSM, Orpheus, MOSS-Nano, Qwen3-TTS 0.6B.
- No CPU TTFA for Orpheus, Voxtral, Qwen3-TTS 0.6B, or Fish S2 Pro.
- Kyutai's technical report page fetched but its evaluation section was not extracted in this pass.
- Kitten's and tts-bench "Kokoro vs Kitten" blog pages returned empty in extraction.

## Sources (new in this pass unless marked "ledger")

- **Kyutai, France — Pocket TTS:** https://huggingface.co/kyutai/pocket-tts (ledger #3), https://github.com/kyutai-labs/pocket-tts, https://kyutai.org/pocket-tts-technical-report
- **OpenMOSS / MOSI.AI, China — MOSS-TTS-Nano:** https://github.com/OpenMOSS/MOSS-TTS-Nano (ledger #1), https://huggingface.co/OpenMOSS-Team/MOSS-TTS-Nano-100M-ONNX (ledger #2)
- **Supertone, Korea — Supertonic-3:** https://github.com/supertone-oss-archive/supertonic, https://huggingface.co/supertone-oss-archive/supertonic-3
- **Mistral, France — Voxtral TTS:** https://huggingface.co/mistralai/Voxtral-4B-TTS-2603 (ledger #9)
- **Alibaba Qwen, China — Qwen3-TTS:** https://github.com/QwenLM/Qwen3-TTS (ledger #8), https://arxiv.org/html/2601.15621v1
- **Kokoro:** https://huggingface.co/hexgrad/Kokoro-82M (release table, licence, languages), https://github.com/hexgrad/kokoro (ledger #4)
- **Chatterbox Turbo:** https://huggingface.co/ResembleAI/chatterbox-turbo (ledger #5 domain), https://github.com/resemble-ai/chatterbox (MIT LICENSE)
- **Sesame CSM:** https://huggingface.co/sesame/csm-1b (ledger #11 domain), https://github.com/SesameAILabs/csm
- **Orpheus:** https://huggingface.co/canopylabs/orpheus-3b-0.1-ft, https://github.com/canopyai/Orpheus-TTS
- **Kitten TTS:** https://github.com/KittenML/KittenTTS
- **Fish S2 Pro:** https://huggingface.co/fishaudio/s2-pro (ledger #10), https://huggingface.co/fishaudio/s2-pro/blob/main/LICENSE.md
- **Breeze TTS 2:** https://huggingface.co/BreezeBlue/Breeze-TTS-2
- **Artificial Analysis Provider Voice Arena:** https://artificialanalysis.ai/text-to-speech/leaderboard (ledger #7)
- **HF Open TTS Leaderboard:** https://huggingface.co/blog/open-tts-leaderboard (ledger #6)
- **CPU measurements:** https://heyneo.com/blog/kokoro-supertonic-inflect-nano-pocket-tts-cpu-benchmark; tts-bench https://github.com/5uck1ess/tts-bench/blob/master/docs/results.md and https://5uck1ess.github.io/tts-bench/speed.html

## Ledger issues (not fixed; ledger not modified)

- `~/.hermes/cache/citations/ledger.json` id 12 URL `https://hug.com/hf-audio/open_tts_leaderboard` looks like a typo. The likely intended URL is `https://huggingface.co/spaces/hf-audio/open_tts_leaderboard`. Not fetched; treat as unverified.
- Ledger has no title fields (all empty). Ledger does not list Supertonic, Kitten, Orpheus, Qwen3-TTS, Fish S2 Pro, Breeze, tts-bench, heyneo or AA sub-pages.
- The target file `24a-tts-candidates.md` did not exist before this pass; it was created here.
