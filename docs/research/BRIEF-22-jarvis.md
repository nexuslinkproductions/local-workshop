# Brief: Marcel's local Jarvis / Cortana (architecture research)

## What Marcel wants (his words, decoded; do not narrow it)
A personal AI presence in the style of JARVIS (Iron Man) or Cortana (Halo) that works beside him
all day on his Linux desktop. Not a prompt helper, not only a screen clicker. Capabilities he named
or implied, all in scope:
- talk to it by voice and it answers by voice, with a character of its own; natural conversation
- it sees his screen (what he sees), understands context, can be asked "what am I looking at",
  "how should I phrase this", "find X for me"
- helps him work: writing and formulating (German and English), prompt crafting, research and web
  search, summarising, explaining, planning
- "and much more": acting on the computer (open things, click, type), remembering context across
  days, proactive help, running tasks in the background
Treat this as the requirement set. Where a capability is hard, say how to get it, do not drop it.

## The box (measured)
Ryzen 9 7900X 12c/24t, 61 GiB RAM DDR5-6000 (~63 GB/s), Intel Arc B580 12 GB (also drives his 3
monitors), GT 1030 2 GB (NVIDIA 580 driver installed, active after reboot), Hyprland (Omarchy),
PipeWire, Scarlett audio interface + MKE 600 mic. Engines on the box: llama.cpp SYCL and Vulkan
(tip 358a420ec), oneAPI 2026.0/2026.1, OpenVINO, llama-swap (serve/). Measured: Qwen3.6-35B-A3B
(MoE, experts in RAM) 481 t/s prompt, 40 t/s decode, screenshot read ~10-17 s; loading 20-37 GB
models through RAM froze his desktop (memory/IO stalls) -> a model that fits entirely in the 12 GB
VRAM is very attractive. Already present: Voxtype (local push-to-talk dictation, parakeet/moonshine
STT), Hermes agent framework (tools, memory, browser, skills, TTS tool, subagents) which is his main
AI system, and the Omarchy HUD (Quickshell).

Read for context: /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/research/10-test-matrix.md (sections
2.4-2.6), research/12-best-moe-models.md, research/21-small-quants.md (if present).

## Questions to answer (with sources)
1. Model candidates for the always-on assistant brain on THIS box, including the Gemma 4 family
   (Marcel saw good results with Gemma 4 12B; verify sizes, vision, audio input, tool calling,
   context, licence, llama.cpp support and GGUF availability), Qwen3.6-35B-A3B, MiniCPM-V-4.7, and
   any newer all-rounder that fits (dense <= ~14B fully in VRAM at Q4, or small-active MoE).
   Criteria: conversation quality, German, vision understanding of real screens, tool calling,
   latency for voice (time to first sentence), memory footprint. Use independent benchmarks where
   they exist, mark vendor-only numbers.
2. Voice stack, fully local: speech-to-text (streaming, German+English; is Voxtype's engine reusable
   for always-listening with wake word?), wake word options, text-to-speech with a voice that has
   character (quality, latency, German support, runs on CPU or GT 1030 or B580 without hurting the
   LLM), barge-in/interrupt, echo cancel. Give measured latency numbers from sources.
3. Screen awareness: how to give it "what I see" cheaply: periodic low-res capture vs on-demand
   screenshot, window titles/accessibility tree from Hyprland (`hyprctl clients -j`), OCR, active
   app context; privacy controls.
4. Architecture: how the pieces connect. Strongly consider: Hermes as the brain/orchestrator (it
   already has tools, memory, search, subagents) with the local model as a provider plus cloud
   escalation for hard tasks; a small fast local model for the voice loop and a bigger one on
   demand; existing open projects that already do local voice+vision assistants on Linux (evaluate
   honestly, name what to reuse). Keep the desktop-never-freezes rule central.
5. A phased build plan: smallest end-to-end loop first (push-to-talk -> local model with a
   screenshot -> spoken answer), then wake word, memory, proactive help, computer control.

## Source rule
Marcel distrusts US-centric sources: lead with non-US citations (European, Chinese, Japanese labs,
papers, community benchmarks, GitHub repos) where they exist; cite every claim with a URL; mark
anything unverified.

## Output
Write /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB/research/22-jarvis-assistant.md incrementally
(write each section to disk as soon as it is done). Sections: requirements, model shortlist table,
voice stack table, screen awareness, architecture (with a diagram in text), phased plan, open risks.
Do not load models or touch the GPU (another agent owns it and the bench/.gpu.lock).

Self-check (mandatory): re-read the file, confirm every section exists and every claim has a source
or is marked unverified; list each section PASS/FAIL.
