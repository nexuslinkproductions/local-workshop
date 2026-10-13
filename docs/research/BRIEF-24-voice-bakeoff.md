# Brief: voice bake-off for Marcel's local JARVIS (2026-10-13)

## Why
Marcel listened to the Piper samples (Thorsten DE, Lessac EN) and called them "horrible, super bad".
He wants a voice and conversation feel like NVIDIA's new fluid voice models: natural, expressive,
fast turn-taking, interruptible. Piper stays only as an emergency fallback.

## Known (orchestrator checked, 2026-10-13)
- NVIDIA NemotronLabs VoiceChat 11B (released 2026-08-03): full-duplex speech-to-speech with tool
  calling, ~450 ms turn-taking. BUT: English only, single fixed voice, needs an 80 GB NVIDIA GPU
  (vLLM), research-only licence (OpenMDW 1.1), known gibberish/self-talk loops. Cannot run on this box.
  https://huggingface.co/nvidia/NVIDIA-NemotronLabs-VoiceChat-11B
- NVIDIA PersonaPlex-7B (2026-01-15): full-duplex, built on Kyutai's Moshi (France), voice prompt +
  persona prompt, ~170 ms first token, 240 ms interruption response, commercial-use licence, one GPU.
  Language support and Intel-GPU feasibility unknown.
- Box: Intel Arc B580 12 GB (shared with the LLM brain and Marcel's 3 monitors), Ryzen 9 7900X,
  61 GiB RAM, GT 1030 2 GB (NVIDIA 580 driver installed, active only after reboot; too small and
  too old for these models), torch 2.14+xpu and OpenVINO available, PipeWire.
- Already working: Parakeet v3 STT, Hermes voice wiring (research/23-voice-phase0.md), Piper.
- Marcel needs German AND English, a voice with character (JARVIS / Cortana feel), low latency,
  barge-in. Desktop must never lag (use ~/.local/bin/jobcap with CAP, CPUS=6-11,18-23 CPUW=20;
  any GPU use takes `flock -x /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/bench/.gpu.lock` and
  `ionice -c 3`; a tester agent also uses that lock, so keep GPU runs short and release the lock).

## Deliverable
Real audio Marcel can listen to, not a table of claims. For each candidate that runs here, render the
SAME five lines into WAV files under
/home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/voice/bakeoff/<engine>/ :
UPDATE (Marcel, 2026-10-13): ENGLISH ONLY. German voice is not needed. Lines 1-2 are replaced:
1. en: "Morning, Marcel. Quick heads-up: the deploy finished, two tests flaked, and I already reran them. All green now."
2. en (warm, conversational): "Honestly? I'd ship it. The edge case you're worried about only shows up on the old driver, and nobody runs that anymore."
3. en: "Good morning, Marcel. Your first meeting is at nine, and last night's build went through."
4. en: "Hold on, let me check that. Alright, I found three results, and the second one fits best."
5. en (character): "Sir, I would strongly advise against running that on the main branch. Shall I open a pull request instead?"
Measure per line: time to first audio (streaming if supported), total synthesis time, real-time factor,
device used, peak RAM/VRAM. Write voice/bakeoff/INDEX.md with one row per engine and file links.
