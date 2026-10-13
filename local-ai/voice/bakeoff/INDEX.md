# Voice bake-off index (English only)

Rebuilt 2026-10-13 from files on disk (`voice/bakeoff/`), by `build_index.py`. Evening line = "Good evening, Marcel. Everything is running smoothly. Shall I prepare the summary?" (line E / line7). Line 2 and line 5 are the BRIEF-24 lines.

**Measures.** First audio = seconds to first audio; for streaming engines the time to the first generated frame, for the others the time until the full line is returned. RTF = synthesis wall time / audio duration (lower is better). F0 = median pitch on line 2 by crude autocorrelation (a pitch proxy, not a calmness score; lower is deeper). Nobody has listened to these except as noted in the verdict column.

## British male candidates (sorted by F0, lowest first)

| # | Engine | Voice | Accent | F0 Hz (line 2) | First audio s (evening line) | RTF (evening line) | Evening file | Line 2 | Line 5 | Status | Marcel verdict |
|---|---|---|---|---:|---:|---:|---|---|---|---|---|
| 1 | Kokoro-82M (full line) | bm_lewis | British, male (Kokoro card grade D+) | 90.6 | 0.67 | 0.11 | `voice/bakeoff/british/kokoro-bm_lewis-lineE-x1.00.wav` | `voice/bakeoff/british/kokoro-bm_lewis-line2-x1.00.wav` | `voice/bakeoff/british/kokoro-bm_lewis-line5-x1.00.wav` | rendered, speed 1.00 | not judged |
| 2 | Chatterbox Turbo, VCTK zero-shot clone (full line) | VCTK p256 | Birmingham, male | 93.4 | 6.13 | 1.34 | `voice/bakeoff/british/chatterbox-vctk-p256-lineE-x1.00.wav` | `voice/bakeoff/british/chatterbox-vctk-p256-line2-x1.00.wav` | `voice/bakeoff/british/chatterbox-vctk-p256-line5-x1.00.wav` | rendered, CPU, RTF > 1 | not judged |
| 3 | Chatterbox Turbo, VCTK zero-shot clone (full line) | VCTK p274 | Essex, male | 101.7 | 6.01 | 1.32 | `voice/bakeoff/british/chatterbox-vctk-p274-lineE-x1.00.wav` | `voice/bakeoff/british/chatterbox-vctk-p274-line2-x1.00.wav` | `voice/bakeoff/british/chatterbox-vctk-p274-line5-x1.00.wav` | rendered, CPU, RTF > 1 | not judged |
| 4 | Kyutai TTS 0.75B (streaming) | p232-Southern-England-male | Southern England, male | 101.9 | 29.92 | 10.55 | `voice/bakeoff/kyutai-tts/VCTK-p232-Southern-England-male-line7.wav` | `voice/bakeoff/kyutai-tts/VCTK-p232-Southern-England-male-line2.wav` | `voice/bakeoff/kyutai-tts/VCTK-p232-Southern-England-male-line5.wav` | rendered, CPU fp32, 3 lines | not judged |
| 5 | Kyutai TTS 0.75B (streaming) | p227-Cumbria-male | Cumbria, male | 110.1 | 38.57 | 10.91 | `voice/bakeoff/kyutai-tts/VCTK-p227-Cumbria-male-line7.wav` | `voice/bakeoff/kyutai-tts/VCTK-p227-Cumbria-male-line2.wav` | `voice/bakeoff/kyutai-tts/VCTK-p227-Cumbria-male-line5.wav` | rendered, CPU fp32, 3 lines | not judged |
| 6 | Kyutai TTS 0.75B (streaming) | p226-Surrey-male | Surrey, male | 111.1 | 37.33 | 12.11 | `voice/bakeoff/kyutai-tts/VCTK-p226-Surrey-male-line7.wav` | `voice/bakeoff/kyutai-tts/VCTK-p226-Surrey-male-line2.wav` | `voice/bakeoff/kyutai-tts/VCTK-p226-Surrey-male-line5.wav` | rendered, CPU fp32, 3 lines | not judged |
| 7 | Chatterbox Turbo, VCTK zero-shot clone (full line) | VCTK p270 | Yorkshire, male | 113.2 | 6.08 | 1.31 | `voice/bakeoff/british/chatterbox-vctk-p270-lineE-x1.00.wav` | `voice/bakeoff/british/chatterbox-vctk-p270-line2-x1.00.wav` | `voice/bakeoff/british/chatterbox-vctk-p270-line5-x1.00.wav` | rendered, CPU, RTF > 1 | not judged |
| 8 | Chatterbox Turbo, VCTK zero-shot clone (full line) | VCTK p287 | York, male | 117.1 | 5.39 | 1.35 | `voice/bakeoff/british/chatterbox-vctk-p287-lineE-x1.00.wav` | `voice/bakeoff/british/chatterbox-vctk-p287-line2-x1.00.wav` | `voice/bakeoff/british/chatterbox-vctk-p287-line5-x1.00.wav` | rendered, CPU, RTF > 1 | not judged |
| 9 | Kokoro-82M (full line) | bm_fable | British, male (Kokoro card grade C) | 120.6 | 0.64 | 0.12 | `voice/bakeoff/british/kokoro-bm_fable-lineE-x1.00.wav` | `voice/bakeoff/british/kokoro-bm_fable-line2-x1.00.wav` | `voice/bakeoff/british/kokoro-bm_fable-line5-x1.00.wav` | rendered, speed 1.00 | not judged |
| 10 | Kokoro-82M (full line) | bm_daniel | British, male (Kokoro card grade D) | 126.3 | 0.49 | 0.10 | `voice/bakeoff/british/kokoro-bm_daniel-lineE-x1.00.wav` | `voice/bakeoff/british/kokoro-bm_daniel-line2-x1.00.wav` | `voice/bakeoff/british/kokoro-bm_daniel-line5-x1.00.wav` | rendered, speed 1.00 | not judged |
| 11 | Kokoro-82M (full line) | bm_george | British, male (Kokoro card grade C) | 138.7 | 0.64 | 0.11 | `voice/bakeoff/british/kokoro-bm_george-lineE-x1.00.wav` | `voice/bakeoff/british/kokoro-bm_george-line2-x1.00.wav` | `voice/bakeoff/british/kokoro-bm_george-line5-x1.00.wav` | rendered, speed 1.00 | not judged |
| 12 | Kani TTS 2 (full line) | Baddy-Liverpool | Liverpool, male | 146.0 | 34.13 | 4.35 | `voice/bakeoff/kani-tts/Baddy-Liverpool-male-line7.wav` | `voice/bakeoff/kani-tts/Baddy-Liverpool-male-line2.wav` | `voice/bakeoff/kani-tts/Baddy-Liverpool-male-line5.wav` | rendered; too slow for live | not judged |
| 13 | Kani TTS 2 (full line) | Rory-Glasgow | Glasgow, male | 160.9 | 25.04 | 3.73 | `voice/bakeoff/kani-tts/Rory-Glasgow-male-line7.wav` | `voice/bakeoff/kani-tts/Rory-Glasgow-male-line2.wav` | `voice/bakeoff/kani-tts/Rory-Glasgow-male-line5.wav` | rendered; too slow for live | not judged |

No British male voice has a verdict from Marcel yet. The shortlist is in `british/PLAYLIST.md`.

## Other engines (reference, not British male, or rejected)

| Engine / voice | First audio s | RTF | File | Status | Marcel verdict |
|---|---:|---:|---|---|---|
| Kokoro-82M US af_heart | 1.483 | 0.200 | `voice/bakeoff/kokoro/af_heart-line2.wav` | rendered | Marcel: dislikes all heard so far (00-plan 10-13) |
| Kokoro-82M US am_michael | 0.998 | 0.119 | `voice/bakeoff/kokoro/am_michael-line2.wav` | rendered | Marcel: dislikes all heard so far (00-plan 10-13) |
| Pocket TTS alba (streaming) | 0.069 | 0.187 | `voice/bakeoff/pocket-tts/alba-line2.wav` | rendered | Marcel: dislikes all heard so far (00-plan 10-13) |
| Pocket TTS michael (streaming) | 0.069 | 0.239 | `voice/bakeoff/pocket-tts/michael-line2.wav` | rendered | Marcel: dislikes all heard so far (00-plan 10-13) |
| Supertonic-3 M1 | 1.006 | 0.125 | `voice/bakeoff/supertonic/M1-line2.wav` | rendered | Marcel: dislikes all heard so far (00-plan 10-13) |
| Chatterbox Turbo stock VCTK p254 (male ref) | 7.600 | 1.214 | `voice/bakeoff/chatterbox-turbo/VCTK-p254-male-line2.wav` | rendered; RTF > 1 | Marcel: dislikes all heard so far (00-plan 10-13) |
| Magpie idx 2 (name 'Aria' in CLI) | 0.206 | 0.353 | `voice/bakeoff/magpie/voices/magpie-idx2-line2-x1.00.wav` | rendered, CPU | rejected by ear (Marcel) |
| Magpie idx 3 (name 'Jason' in CLI) | 0.205 | 0.353 | `voice/bakeoff/magpie/voices/magpie-idx3-line2-x1.00.wav` | rendered, CPU | rejected by ear (Marcel) |
| Piper en_US-lessac-high (bench, no WAV kept) | - | 0.401 | `-` | bench only | Marcel: 'horrible' (00-plan 10-13) |

## Notes

- Kokoro US (af_*, am_*) and the other Kokoro voices: `kokoro/voices/` (24 voices at 1.15, see `VOICES-MORE.md` §3).
- Magpie: speakers are by index; the CLI names and speakers.json names disagree (see `VOICES-MORE.md` §2). Index 4 is not male per Marcel.
- Pocket TTS, Supertonic-3, Chatterbox Turbo stock: Marcel's 10-13 note says he dislikes all voices heard so far. No per-voice verdict was recorded.
- Kyutai first-audio on CPU includes processing the voice prompt, so it is far above the 0.5 s target.
- Metrics sources: `kyutai-tts/metrics-british.json`, `british/kokoro-metrics.json`, `british/chatterbox-metrics.json`, `kani-tts/metrics.json`, `kokoro/metrics.json`, `pocket-tts/metrics.json`, `supertonic/metrics.json`, `chatterbox-turbo/metrics.json`, `magpie/summary.json`, `../bench-piper-results.json`.
