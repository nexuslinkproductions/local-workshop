# 22 — Local JARVIS / Cortana: research synthesis (2026-10-13)

Goal (Marcel): an all-round local assistant with voice both ways and a character of its own. It sees his
screen, helps with work (writing in DE/EN, prompts, research and search, planning), can act on the computer,
remembers context, and never makes the desktop lag. Detail files:
[22a models](22a-jarvis-models.md) · [22b voice](22b-jarvis-voice.md) · [22c architecture](22c-jarvis-architecture.md).

## Decisions so far

| Part | Pick | Status |
|---|---|---|
| Brain (always on) | Gemma 4 12B (dense 11.95B, text+image+audio+video, Apache-2.0), Google QAT Q4_0 6.5 GiB + mmproj 0.16 GiB: fits entirely in B580 VRAM | download queued; **vision path unverified**: projector bug class (`<unused49>`, F16 overflow) not fixed upstream, fix PR #26488 closed unmerged |
| Brain fallback | Gemma 4 E4B (4.6 GiB + 0.9 GiB mmproj, vision+audio) | to test if 12B vision fails |
| Heavy lane (on demand) | Qwen3.6-35B-A3B (measured: 481 t/s prompt, 40 t/s decode) | needs the RAM guards; not always-on |
| Orchestrator | Hermes (tools, memory, search, subagents, computer_use); local model as a provider, cloud escalation for hard tasks | serving layer ready (serve/), not enabled |
| Speech-to-text | parakeet-tdt-0.6b-v3 int8 (on disk, 25 languages incl. German) | not wired |
| Wake word | openWakeWord (Hermes ships it), train "Jarvis"-style word | phase 3 |
| Voice (TTS) | Pocket TTS (Kyutai, FR, German, voice cloning; gated HF weights) for character; Piper `de_DE-thorsten-high` as the safe fallback | not installed |
| Barge-in | Silero VAD (on disk), headphones first, then PipeWire WebRTC echo-cancel | phase 3+ |
| Screen | window titles via `hyprctl clients -j` + accessibility text always; pixels (`grim`) only on demand | phase 2 |

## Found broken on this box (orchestrator verified)
- Hermes `tts` = `mlx-local` pointing at a macOS path on the Kingston volume: Apple-only, path gone. Voice output cannot work today.
- `/usr/bin/piper` is the libratbag **gaming-mouse configurator** (pacman: "GTK application to configure gaming mice"), not Piper TTS. 22c's "Piper installed" is wrong.
- Privacy: `auxiliary.vision` (screenshots) and hindsight extraction go to cloud providers by default. Must become local before always-on screen capture.

## Speed risk to measure first
Gemma 4 12B prompt reading on the B580 is unmeasured (estimate 100-150 t/s in 22a, likely higher on SYCL). Voice needs a
cached system-prompt prefix so each turn only reads the new words.

## Phase plan (from 22c, condensed)
0. Voice repair: local TTS + STT wired into Hermes, round-trip test.  1. Gemma 4 12B on the bench: speed, vision sanity, assistant score.
2. Push-to-talk loop: key -> STT -> local model + screen context -> spoken answer.  3. Wake word + barge-in.
4. Local vision/memory instead of cloud.  5+. Computer control (approval-gated), proactive help, character.
