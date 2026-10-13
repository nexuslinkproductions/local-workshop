# VOICES-MORE: more English voice options for Marcel

Generated 2026-10-13 from the metrics files in `voice/bakeoff/`. Lines: **2** = "Honestly? I'd ship it...", **5** = "Sir, I would strongly advise...", **E** = "Good evening, Marcel. Everything is running smoothly. Shall I prepare the summary?" (new).

## 1. Calm British male (current target)

Speed: 1.0 = native; 1.15 = Kokoro native `speed=1.15`, or pitch-preserving `rubberband -3 -T 1.15` for Chatterbox. First audio = time to first audio chunk on CPU (non-streaming engines: time to full line).

| Voice | Engine | Source / accent | Speed | Line 2 | Line 5 | Line E | First audio (ms, line 2 / 5 / E) |
|---|---|---|---|---|---|---|---|
| `bm_george` | Kokoro-82M (CPU) | Kokoro card: British English, grade C | 1.00 | [2](british/kokoro-bm_george-line2-x1.00.wav) | [5](british/kokoro-bm_george-line5-x1.00.wav) | [E](british/kokoro-bm_george-lineE-x1.00.wav) | 1174 / 883 / 636 |
| `bm_george` | Kokoro-82M (CPU) | Kokoro card: British English, grade C | 1.15 | [2](british/kokoro-bm_george-line2-x1.15.wav) | [5](british/kokoro-bm_george-line5-x1.15.wav) | [E](british/kokoro-bm_george-lineE-x1.15.wav) | 889 / 804 / 570 |
| `bm_lewis` | Kokoro-82M (CPU) | Kokoro card: British English, grade D+ | 1.00 | [2](british/kokoro-bm_lewis-line2-x1.00.wav) | [5](british/kokoro-bm_lewis-line5-x1.00.wav) | [E](british/kokoro-bm_lewis-lineE-x1.00.wav) | 1241 / 896 / 667 |
| `bm_lewis` | Kokoro-82M (CPU) | Kokoro card: British English, grade D+ | 1.15 | [2](british/kokoro-bm_lewis-line2-x1.15.wav) | [5](british/kokoro-bm_lewis-line5-x1.15.wav) | [E](british/kokoro-bm_lewis-lineE-x1.15.wav) | 855 / 790 / 576 |
| `bm_daniel` | Kokoro-82M (CPU) | Kokoro card: British English, grade D | 1.00 | [2](british/kokoro-bm_daniel-line2-x1.00.wav) | [5](british/kokoro-bm_daniel-line5-x1.00.wav) | [E](british/kokoro-bm_daniel-lineE-x1.00.wav) | 890 / 727 / 486 |
| `bm_daniel` | Kokoro-82M (CPU) | Kokoro card: British English, grade D | 1.15 | [2](british/kokoro-bm_daniel-line2-x1.15.wav) | [5](british/kokoro-bm_daniel-line5-x1.15.wav) | [E](british/kokoro-bm_daniel-lineE-x1.15.wav) | 716 / 615 / 471 |
| `bm_fable` | Kokoro-82M (CPU) | Kokoro card: British English, grade C | 1.00 | [2](british/kokoro-bm_fable-line2-x1.00.wav) | [5](british/kokoro-bm_fable-line5-x1.00.wav) | [E](british/kokoro-bm_fable-lineE-x1.00.wav) | 1187 / 1176 / 641 |
| `bm_fable` | Kokoro-82M (CPU) | Kokoro card: British English, grade C | 1.15 | [2](british/kokoro-bm_fable-line2-x1.15.wav) | [5](british/kokoro-bm_fable-line5-x1.15.wav) | [E](british/kokoro-bm_fable-lineE-x1.15.wav) | 829 / 734 / 494 |
| clone `VCTK p256` | Chatterbox Turbo (zero-shot, CPU, non-streaming) | VCTK p256, Birmingham, 24 y, male (VCTK table) | 1.00 | [2](british/chatterbox-vctk-p256-line2-x1.00.wav) | [5](british/chatterbox-vctk-p256-line5-x1.00.wav) | [E](british/chatterbox-vctk-p256-lineE-x1.00.wav) | 9075 / 7474 / 6135 |
| clone `VCTK p256` | Chatterbox Turbo (zero-shot, CPU, non-streaming) | VCTK p256, Birmingham, 24 y, male (VCTK table) | 1.15 | [2](british/chatterbox-vctk-p256-line2-x1.15.wav) | [5](british/chatterbox-vctk-p256-line5-x1.15.wav) | [E](british/chatterbox-vctk-p256-lineE-x1.15.wav) | 9075 / 7474 / 6135 |
| clone `VCTK p274` | Chatterbox Turbo (zero-shot, CPU, non-streaming) | VCTK p274, Essex, 22 y, male (VCTK table) | 1.00 | [2](british/chatterbox-vctk-p274-line2-x1.00.wav) | [5](british/chatterbox-vctk-p274-line5-x1.00.wav) | [E](british/chatterbox-vctk-p274-lineE-x1.00.wav) | 8260 / 8501 / 6013 |
| clone `VCTK p274` | Chatterbox Turbo (zero-shot, CPU, non-streaming) | VCTK p274, Essex, 22 y, male (VCTK table) | 1.15 | [2](british/chatterbox-vctk-p274-line2-x1.15.wav) | [5](british/chatterbox-vctk-p274-line5-x1.15.wav) | [E](british/chatterbox-vctk-p274-lineE-x1.15.wav) | 8260 / 8501 / 6013 |
| clone `VCTK p287` | Chatterbox Turbo (zero-shot, CPU, non-streaming) | VCTK p287, York, 23 y, male (VCTK table) | 1.00 | [2](british/chatterbox-vctk-p287-line2-x1.00.wav) | [5](british/chatterbox-vctk-p287-line5-x1.00.wav) | [E](british/chatterbox-vctk-p287-lineE-x1.00.wav) | 9188 / 7497 / 5395 |
| clone `VCTK p287` | Chatterbox Turbo (zero-shot, CPU, non-streaming) | VCTK p287, York, 23 y, male (VCTK table) | 1.15 | [2](british/chatterbox-vctk-p287-line2-x1.15.wav) | [5](british/chatterbox-vctk-p287-line5-x1.15.wav) | [E](british/chatterbox-vctk-p287-lineE-x1.15.wav) | 9188 / 7497 / 5395 |
| clone `VCTK p270` | Chatterbox Turbo (zero-shot, CPU, non-streaming) | VCTK p270, Yorkshire, 21 y, male (VCTK table) | 1.00 | [2](british/chatterbox-vctk-p270-line2-x1.00.wav) | [5](british/chatterbox-vctk-p270-line5-x1.00.wav) | [E](british/chatterbox-vctk-p270-lineE-x1.00.wav) | 9291 / 8238 / 6084 |
| clone `VCTK p270` | Chatterbox Turbo (zero-shot, CPU, non-streaming) | VCTK p270, Yorkshire, 21 y, male (VCTK table) | 1.15 | [2](british/chatterbox-vctk-p270-line2-x1.15.wav) | [5](british/chatterbox-vctk-p270-line5-x1.15.wav) | [E](british/chatterbox-vctk-p270-lineE-x1.15.wav) | 9291 / 8238 / 6084 |

Blocked: **Pocket TTS cloning**. `kyutai/pocket-tts` refused voice cloning here (`VOICE_CLONING_UNSUPPORTED`: the cloning weights could not be downloaded; they appear gated). Its built-in catalogue includes a `george` voice, not rendered here (not verified as British/male).

**Magpie zero-shot: not available.** The v2607 card says zero-shot voice cloning was removed. NeMo-Speech.cpp only supports the 5 baked speakers (no reference-audio encoder in `src/tts`), so a cloning checkpoint would not run there. Not downloaded.

VCTK references (CC BY 4.0, from `kyutai/tts-voices/vctk/*_023.wav`, sentence 23) are in `british/refs/`. Gender and accent come from the VCTK speaker table mirrored at huggingface.co/voices/VCTK_British_English_Males (secondary source). Median F0 (crude autocorrelation estimate): p256 86 Hz, p274 96 Hz, p287 103 Hz, p270 105 Hz; the other British males were 110–152 Hz. Calmness was not measured; judge by ear.

## 2. Magpie (NVIDIA, 357M, CPU, NeMo-Speech.cpp)

Speakers are selected by **index** (`--speaker N`), which I verified changes the audio. Gender is **not documented** by NVIDIA for any index, so none is given. Two name sources disagree: the CLI `--voice` table and the GGUF `speaker_names` list give `John=0, Sofia=1, Aria=2, Jason=3, Leo=4`; the NeMo checkpoint `speakers.json` (also the HF demo app) gives `Aria=0, Jason=1, John=2, Leo=3, Sofia=4`. Which is correct is not resolved; index is the only reliable key.

Native speed has no control in the CLI (no rate or duration option; the synth struct has only temperature/cfg/steps/top-k). Speeds 1.15 and 1.30 are offline `rubberband -3 -T` (pitch-preserving, R3).

| Index | CLI `--voice` name | speakers.json name | Line | 1.00 | 1.15 | 1.30 | First audio ms (1.00) |
|---|---|---|---|---|---|---|---|
| 0 | John | Aria | 2 | [1.00](magpie/voices/magpie-idx0-line2-x1.00.wav) | [1.15](magpie/voices/magpie-idx0-line2-x1.15.wav) | [1.30](magpie/voices/magpie-idx0-line2-x1.30.wav) | 208 |
| 0 | John | Aria | 5 | [1.00](magpie/voices/magpie-idx0-line5-x1.00.wav) | [1.15](magpie/voices/magpie-idx0-line5-x1.15.wav) | [1.30](magpie/voices/magpie-idx0-line5-x1.30.wav) | 206 |
| 1 | Sofia | Jason | 2 | [1.00](magpie/voices/magpie-idx1-line2-x1.00.wav) | [1.15](magpie/voices/magpie-idx1-line2-x1.15.wav) | [1.30](magpie/voices/magpie-idx1-line2-x1.30.wav) | 209 |
| 1 | Sofia | Jason | 5 | [1.00](magpie/voices/magpie-idx1-line5-x1.00.wav) | [1.15](magpie/voices/magpie-idx1-line5-x1.15.wav) | [1.30](magpie/voices/magpie-idx1-line5-x1.30.wav) | 208 |
| 2 | Aria | John | 2 | [1.00](magpie/voices/magpie-idx2-line2-x1.00.wav) | [1.15](magpie/voices/magpie-idx2-line2-x1.15.wav) | [1.30](magpie/voices/magpie-idx2-line2-x1.30.wav) | 329 |
| 2 | Aria | John | 5 | [1.00](magpie/voices/magpie-idx2-line5-x1.00.wav) | [1.15](magpie/voices/magpie-idx2-line5-x1.15.wav) | [1.30](magpie/voices/magpie-idx2-line5-x1.30.wav) | 288 |
| 3 | Jason | Leo | 2 | [1.00](magpie/voices/magpie-idx3-line2-x1.00.wav) | [1.15](magpie/voices/magpie-idx3-line2-x1.15.wav) | [1.30](magpie/voices/magpie-idx3-line2-x1.30.wav) | 210 |
| 3 | Jason | Leo | 5 | [1.00](magpie/voices/magpie-idx3-line5-x1.00.wav) | [1.15](magpie/voices/magpie-idx3-line5-x1.15.wav) | [1.30](magpie/voices/magpie-idx3-line5-x1.30.wav) | 206 |
| 4 | Leo | Sofia | 2 | [1.00](magpie/voices/magpie-idx4-line2-x1.00.wav) | [1.15](magpie/voices/magpie-idx4-line2-x1.15.wav) | [1.30](magpie/voices/magpie-idx4-line2-x1.30.wav) | 347 |
| 4 | Leo | Sofia | 5 | [1.00](magpie/voices/magpie-idx4-line5-x1.00.wav) | [1.15](magpie/voices/magpie-idx4-line5-x1.15.wav) | [1.30](magpie/voices/magpie-idx4-line5-x1.30.wav) | 349 |

Logs for `--speaker` runs print `speaker=0` in every case; that field is the runtime default, not the request, so it is not evidence of a fallback.

## 3. Kokoro 24-voice set at 1.15 (reference; American and female not prioritised)

Sex is from the Kokoro card icons (🚹 male / 🚺 female). Grade is the card's overall grade. British voices use lang `b`; the rest use lang `a`.

| Voice | Sex | Grade | Line 2 | Line 5 | First audio ms (2 / 5) |
|---|---|---|---|---|---|
| `af_heart` | F | A | [2](kokoro/voices/af_heart-line2-x1.15.wav) | [5](kokoro/voices/af_heart-line5-x1.15.wav) | 1119 / 773 |
| `af_bella` | F | A- | [2](kokoro/voices/af_bella-line2-x1.15.wav) | [5](kokoro/voices/af_bella-line5-x1.15.wav) | 1095 / 751 |
| `af_alloy` | F | C | [2](kokoro/voices/af_alloy-line2-x1.15.wav) | [5](kokoro/voices/af_alloy-line5-x1.15.wav) | 934 / 799 |
| `af_aoede` | F | C+ | [2](kokoro/voices/af_aoede-line2-x1.15.wav) | [5](kokoro/voices/af_aoede-line5-x1.15.wav) | 1167 / 693 |
| `af_kore` | F | C+ | [2](kokoro/voices/af_kore-line2-x1.15.wav) | [5](kokoro/voices/af_kore-line5-x1.15.wav) | 1021 / 810 |
| `af_nicole` | F | B- | [2](kokoro/voices/af_nicole-line2-x1.15.wav) | [5](kokoro/voices/af_nicole-line5-x1.15.wav) | 1445 / 1160 |
| `af_nova` | F | C | [2](kokoro/voices/af_nova-line2-x1.15.wav) | [5](kokoro/voices/af_nova-line5-x1.15.wav) | 936 / 688 |
| `af_sarah` | F | C+ | [2](kokoro/voices/af_sarah-line2-x1.15.wav) | [5](kokoro/voices/af_sarah-line5-x1.15.wav) | 1063 / 1017 |
| `af_sky` | F | C- | [2](kokoro/voices/af_sky-line2-x1.15.wav) | [5](kokoro/voices/af_sky-line5-x1.15.wav) | 1125 / 652 |
| `bf_emma` | F | B- | [2](kokoro/voices/bf_emma-line2-x1.15.wav) | [5](kokoro/voices/bf_emma-line5-x1.15.wav) | 890 / 747 |
| `bf_isabella` | F | C | [2](kokoro/voices/bf_isabella-line2-x1.15.wav) | [5](kokoro/voices/bf_isabella-line5-x1.15.wav) | 921 / 683 |
| `am_adam` | M | F+ | [2](kokoro/voices/am_adam-line2-x1.15.wav) | [5](kokoro/voices/am_adam-line5-x1.15.wav) | 2544 / 680 |
| `am_echo` | M | D | [2](kokoro/voices/am_echo-line2-x1.15.wav) | [5](kokoro/voices/am_echo-line5-x1.15.wav) | 2271 / 677 |
| `am_eric` | M | D | [2](kokoro/voices/am_eric-line2-x1.15.wav) | [5](kokoro/voices/am_eric-line5-x1.15.wav) | 2421 / 625 |
| `am_fenrir` | M | C+ | [2](kokoro/voices/am_fenrir-line2-x1.15.wav) | [5](kokoro/voices/am_fenrir-line5-x1.15.wav) | 939 / 723 |
| `am_liam` | M | D | [2](kokoro/voices/am_liam-line2-x1.15.wav) | [5](kokoro/voices/am_liam-line5-x1.15.wav) | 2414 / 631 |
| `am_michael` | M | C+ | [2](kokoro/voices/am_michael-line2-x1.15.wav) | [5](kokoro/voices/am_michael-line5-x1.15.wav) | 1119 / 713 |
| `am_onyx` | M | D | [2](kokoro/voices/am_onyx-line2-x1.15.wav) | [5](kokoro/voices/am_onyx-line5-x1.15.wav) | 2470 / 1067 |
| `am_puck` | M | C+ | [2](kokoro/voices/am_puck-line2-x1.15.wav) | [5](kokoro/voices/am_puck-line5-x1.15.wav) | 902 / 697 |
| `am_santa` | M | D- | [2](kokoro/voices/am_santa-line2-x1.15.wav) | [5](kokoro/voices/am_santa-line5-x1.15.wav) | 2326 / 731 |
| `bm_daniel` | M | D | [2](kokoro/voices/bm_daniel-line2-x1.15.wav) | [5](kokoro/voices/bm_daniel-line5-x1.15.wav) | 2278 / 660 |
| `bm_fable` | M | C | [2](kokoro/voices/bm_fable-line2-x1.15.wav) | [5](kokoro/voices/bm_fable-line5-x1.15.wav) | 898 / 637 |
| `bm_george` | M | C | [2](kokoro/voices/bm_george-line2-x1.15.wav) | [5](kokoro/voices/bm_george-line5-x1.15.wav) | 1005 / 792 |
| `bm_lewis` | M | D+ | [2](kokoro/voices/bm_lewis-line2-x1.15.wav) | [5](kokoro/voices/bm_lewis-line5-x1.15.wav) | 2325 / 867 |

## 4. Speed without losing quality (method and measured cost)

- **Magpie: no native rate control.** Chosen method: pitch-preserving time-stretch. Offline R3 on the full line: about 50 ms of CPU per ~8 s clip (earlier run).
- **Streaming probe** (librubberband realtime API via ctypes, R3, 186 ms chunks = Magpie's 4096-sample codec chunk, 22050 Hz, 1.30x): engine start delay **46 ms**, compute **~1 ms median / 2.5 ms max per chunk**, so the added latency is about 46 ms once per stream. Source: first 8.4 s of a 1.00 Magpie line.
- Quality was not measured with ASR or a listening test in this pass. Magpie's index files at 1.30 are a pitch-preserving stretch of the 1.00 render, not a new synthesis.
- Kokoro and Chatterbox are not streamed in these scripts; their speed is handled by Kokoro's `speed` parameter, or rubberband for Chatterbox.

## 5. Flags for Marcel

- **Existing bake-off folder `voice/bakeoff/magpie/{cpu,vulkan0,speed}/` is named by `--voice` names** (`Aria`, `Jason`). Those CLI names map to indices 2 and 3 (CLI table) or 0 and 1 (speakers.json). Not renamed here. Decide which name source to trust.
- The earlier `voices/` Magpie files labelled with names (incl. `john` and `leo`) were deleted and re-rendered by index.
- The GPU was not used; no `bench/.gpu.lock` was taken.

## 6. Self-check

- WAVs listed and checked: 126; exist and non-silent (RMS > 1e-3, duration > 0.5 s): **126/126** PASS.
- Leftover render processes: NONE (no nemo-speech, Kokoro, Pocket, Chatterbox, or rubberband process running; the only pgrep hit was a tool wrapper shell).
