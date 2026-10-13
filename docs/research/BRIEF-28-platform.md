# Brief: which agent platform should run Marcel's local AI? (2026-10-13)

## Decision to support
Marcel wants his local JARVIS-style assistant to run through the agent platform (harness) that is best
equipped for LOCAL models, running in the background and answering when he calls on it. He thinks
"the DeepSeek harness" and "pi" may be better equipped for local models than Hermes. Research this
honestly: Hermes is not the default winner, and neither is anything else. Evidence decides.

## Fixed facts about the setup
- Box: Arch/Omarchy Linux, Hyprland (Wayland), PipeWire, Ryzen 9 7900X, 61 GiB RAM, Intel Arc B580 12 GB.
- Brain: Gemma 4 12B QAT Q4_0 on llama.cpp (SYCL), OpenAI-compatible endpoint, 16K ctx (32K possible
  with q8 KV), prompt 791 t/s, decode 27 t/s, thinking toggleable, tool calls pass, vision works.
  Served on demand via llama-swap at http://127.0.0.1:18080/v1 (harness-agnostic).
- Voice: Parakeet v3 STT (local), TTS being chosen (calm British voice), wake word later.
- Screen: 2-stage crop-zoom locate tool (16/16 on test page), grim screenshots, hyprctl window list.
- Hermes is already installed and is Marcel's main AI system (cloud models, tools, memory, skills,
  subagents, voice providers). Docs: https://hermes-agent.nousresearch.com/docs
- Marcel distrusts US-centric sources: lead with non-US sources where they exist; cite every claim.

## What "best equipped for local models" means (score each platform 1-5 with evidence)
1. Prompt weight: tokens of system prompt + tool schemas sent per turn (a 12B model with 16K context
   drowns in a 10K-token system prompt). Measure where possible (count tokens of the real prompt).
2. Tool-calling robustness with small local models (native OpenAI tools, or text-format fallback,
   retries, grammar/JSON constraints via llama.cpp).
3. Works with any OpenAI-compatible local endpoint; per-request params (thinking toggle, images).
4. Background/daemon mode, invoked on demand (hotkey, voice, CLI, socket/API), Linux/Wayland support.
5. Voice loop support (STT/TTS hooks, barge-in) and screen/vision input.
6. Computer control and extensibility (custom tools/plugins/MCP), memory.
7. Stability, maintenance activity, licence, telemetry/privacy (nothing leaves the box by default).
8. Escalation path to cloud models for hard tasks (Hermes has this).

## Output
Each researcher writes its own file research/28<letter>-<topic>.md incrementally with a scored table,
evidence links, and a 5-line verdict. No installs of system packages, no sudo; trying a platform in a
user-space venv/npm prefix is allowed if it helps measure prompt weight, but do NOT load models on the
GPU (another agent owns bench/.gpu.lock); measure against the endpoint only if it is already up.
Self-check (mandatory): every claim cited or marked unverified; list each criterion PASS/FAIL covered.
