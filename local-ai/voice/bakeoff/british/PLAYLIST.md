# British male shortlist: evening line

The evening line is "Good evening, Marcel. Everything is running smoothly. Shall I prepare the summary?"
One file, all six in this order, 0.6 s between: `voice/bakeoff/british/british-shortlist.wav` (32.7 s, 24 kHz mono, each clip loudness-matched to -18 LUFS so levels do not decide it).

| # | Voice | F0 Hz | First audio s | RTF | Why | File |
|---|---|---:|---:|---:|---|---|
| 1 | Kokoro bm_lewis | 91 | 0.67 | 0.11 | Lowest pitch of all candidates (F0 91 Hz) and first audio under 0.7 s. Kokoro card grade D+: check for roughness. | `voice/bakeoff/british/kokoro-bm_lewis-lineE-x1.00.wav` |
| 2 | Chatterbox VCTK p256 | 93 | 6.13 | 1.34 | Deepest clone (Birmingham, F0 93 Hz), zero-shot from a VCTK reference. About 6 s to first audio: not live-capable. | `voice/bakeoff/british/chatterbox-vctk-p256-lineE-x1.00.wav` |
| 3 | Kokoro bm_fable | 121 | 0.64 | 0.12 | Best-graded British male in Kokoro (C), 0.64 s first audio. Warmer pitch, but the fastest live option here. | `voice/bakeoff/british/kokoro-bm_fable-lineE-x1.00.wav` |
| 4 | Chatterbox VCTK p274 | 102 | 6.01 | 1.32 | Essex male, F0 102 Hz. Same speed penalty as p256. | `voice/bakeoff/british/chatterbox-vctk-p274-lineE-x1.00.wav` |
| 5 | Kyutai p232 | 102 | 29.92 | 10.55 | Southern England male, F0 102 Hz, streaming model. 30 s first audio and RTF 10.5 on this CPU: not live. | `voice/bakeoff/kyutai-tts/VCTK-p232-Southern-England-male-line7.wav` |
| 6 | Kyutai p226 | 111 | 37.33 | 12.11 | Surrey male (closest to RP), F0 111 Hz. Same CPU speed problem as p232. | `voice/bakeoff/kyutai-tts/VCTK-p226-Surrey-male-line7.wav` |

F0 is a crude pitch proxy on line 2 (lower = deeper), not a calmness score. Nothing here is verdicted by Marcel yet.
Not in the six: Kokoro bm_george (F0 139 Hz) and bm_daniel (126 Hz), Chatterbox p270 (113 Hz) and p287 (117 Hz), Kyutai p227 (Cumbria, 110 Hz), and Kani Rory (Glasgow) and Baddy (Liverpool), which are too slow (RTF about 4) and too high (F0 146-161 Hz).
