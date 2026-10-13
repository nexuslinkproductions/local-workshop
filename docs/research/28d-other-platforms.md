# 28d — Other local-first agent and voice platforms (2026-10-13)

Scope: every serious local-first agent / voice platform besides OpenCode-as-default, Hermes, the DeepSeek harness and pi-as-brand (those are other 28x lanes). pi and OpenCode are scored here only because they are the two most-cited local harnesses and the comparison needs them.

## Method and limits (read first)
- llama-swap endpoint at 127.0.0.1:18080 was **down** during this run (`curl` failed). I did not start it, did not load any model, did not touch bench/.gpu.lock, and installed nothing.
- So **no prompt was measured on the box**. Prompt-weight figures are (a) source-code reading of system prompts, (b) a third-party localhost benchmark on a different model/hardware (M4 Mac, Qwen 27B, llama-server, 32K cache), and (c) rough chars/4 estimates. They are not Gemma-tokenizer counts.
- Scores 1-5 are my judgment on the cited evidence. `[U]` = unverified (not checked against a primary source in this run).
- Official docs at opencode.ai and several Home Assistant/Open WebUI doc pages were not fetchable from my tool; I used the mirrors/secondary pages listed in Sources and flagged them.

## Scored table (BRIEF-28 criteria 1-8, each 1-5; higher = better for a 12B local brain)

Gate rule used for the verdict: criterion 1 (prompt weight) and criterion 3 (OpenAI-compatible endpoint) must be >= 3, or the platform is out for this box regardless of total.

| Platform (licence) | 1 Prompt wt | 2 Tool calls, small model | 3 OpenAI-compat / per-req | 4 Daemon / on-demand / Linux | 5 Voice / vision | 6 Control / ext / memory | 7 Stability / licence / privacy | 8 Cloud escalation | Total /40 | Gate |
|---|---|---|---|---|---|---|---|---|---|---|
| **Pi** (MIT [U]) | 5 | 3 | 5 | 3 | 1 | 4 | 4 | 4 | **29** | pass |
| **Goose** (Apache-2.0) | 3 | 2 | 4 | 5 | 1 | 5 | 4 | 5 | **29** | pass |
| **Pipecat** (BSD-2-Clause) | 4 | 3 | 5 | 3 | 5 | 3 | 5 | 4 | **32** | pass |
| **Home Assistant Assist** + llama.cpp integration (Apache-2.0 core [U]) | 3 | 3 | 5 | 5 | 5 | 2 | 4 | 4 | **31** | pass |
| Open WebUI (custom licence, branding clause) | 4 | 3 | 5 | 3 | 4 | 3 | 3 | 4 | 29 | pass |
| OpenVoiceOS + ovos-openai-plugin (open source [U]) | 4 | 2 | 4 | 4 | 5 | 3 | 4 | 3 | 29 | pass |
| AnythingLLM (MIT) | 3 | 3 | 4 | 3 | 2 | 4 | 5 | 4 | 28 | pass |
| OpenCode (MIT) | **1** | 3 | 5 | 4 | 1 | 4 | 5 | 5 | 28 | **FAIL (criterion 1)** |
| Letta (Apache-2.0) | 2 | 3 | 3 [U] | 4 | 1 | 5 | 4 | 4 | 26 | fail-soft (prompt bloat) |
| Leon (licence [U]) | 3 [U] | 2 [U] | 3 | 3 | 3 [U] | 4 | 3 [U] | 4 | 25 | unverified |
| smolagents (Apache-2.0) | 3 [U] | 2 [U] | 4 | 1 | 1 | 4 | 5 | 4 | 24 | library only |
| OpenClaw (MIT) | 2 [U] | 2 [U] | 3 [U] | 4 | 2 | 4 | 3 | 4 | 24 | fail-soft (prompt size unknown) |
| Open Interpreter / 01 | 2 [U] | 2 [U] | 3 [U] | 2 | 1 | 4 | 3 [U] | 3 | 20 | fail-soft |
| Kyutai Unmute | 4 | 3 | 4 | 2 | 4 | 1 | 4 | 2 | — | **HARDWARE FAIL** |

Notes on the scores that drive the verdict:
- **Pi, criterion 1 = 5**: its default system prompt is built from four tools (`read`, `write`, `edit`, `bash`) and a template of ~6.2 KB source (`system-prompt.ts`), i.e. roughly 1.3-1.6K tokens by chars/4 before project context and skills [estimate]. Third-party benchmark: lean harnesses (pi, mini-swe-agent, chad) kept system prompts under 2,600 tokens with 96-99% cache reuse; pi used 6% of a 32K unified cache for its preamble vs 56% for OpenCode [S2].
- **Goose, criterion 1 = 3**: its `system.md` is only ~1.2 KB, but tool schemas from extensions are added on top; benchmark tier "heavy but disciplined" (stable after turn one) [S2, S7].
- **OpenCode, criterion 1 = 1**: same benchmark measured an 18,046-token preamble = 225.7 s turn-one wait on M4 (vs 12.2 s for mini-swe-agent) and 125% GPU utilisation from side requests [S2]. That is larger than Marcel's 16K context before any user message. A 2026 Claude-Code comparison measured OpenCode at ~7K tokens for a one-line reply on a cloud model [S3]. A community slim-prompt fork reports ~5K tokens saved per request [S5b]. So OpenCode only fits after heavy trimming, which is a fork-level job.
- **Goose, criterion 2 = 2**: its own docs say it "relies heavily on tool calling capabilities and currently works best with Claude 4 models" [S7]. On a shared Snake task with qwen3-coder:30b (a different model, DGX Spark, 4 runs per harness): pi 4/4 correct, opencode 4/4, goose 2/4 [S8]. Small sample; treat as directional.
- **Pipecat criterion 3 = 5**: `OpenAILLMService` takes a `base_url` for any OpenAI-compatible server and supports function calling [S11]. Its own Nemotron sample runs a llama.cpp-served LLM through a Pipecat bot [S11b].
- **HA criterion 3 = 5**: the built-in llama.cpp integration takes "the base URL of your running OpenAI-compatible server", e.g. `http://localhost:8080/v1`, and lets you pick how much of Home Assistant the model can control (exposed entities only, etc.) [S10].

## Shortlist — top 4 by the criteria

Two roles are needed: a **brain** (agent that does work) and a **voice shell** (always-on audio loop). Ranking all platforms as one list would mix roles, so the top 4 are two brains and two voice shells.

### 1. Pipecat — best voice-loop framework (voice shell)
- Evidence: BSD-2-Clause [S11c]; OpenAI-compatible LLM via `base_url` [S11]; STT/TTS/VAD/turn-taking plus interruption handling per third-party write-up [S12c]; a published local llama.cpp + Magpie TTS sample for Blackwell GPUs [S11b].
- Fit: it is a framework, not a product. You write the daemon, hotkey and wake-word gate yourself. It can sit in front of the llama-swap endpoint and hand text to Hermes (or to pi/Goose) as the brain.
- Gap: no computer control, no memory of its own.

### 2. Home Assistant Assist (llama.cpp integration + Wyoming voice) — best always-on daemon and voice, weakest computer control
- Evidence: llama.cpp integration [S10]; Wyoming STT/TTS/wake-word pipeline and latency numbers from earlier internal research (blog-level; see research/22c-jarvis-architecture.md).
- Fit: 24/7 daemon, Linux-native, exposed-entity control. It does not drive a Hyprland desktop, screen or browser.
- Gap: home-control domain only. Not a general JARVIS brain.

### 3. Pi — best lean brain for a 12-16K local context
- Evidence: four default tools, lean prompt [S4]; native llama.cpp router support (`/login llama.cpp`, `llama-server --models-dir ... -c 32768`, `/llama` load/unload) [S4b]; print/JSON, RPC and SDK modes for process integration [S4]; `/thinking` levels [S4]; benchmark top tier [S2]; 4/4 correct on the Snake task [S8].
- Telemetry: install/update telemetry is on unless disabled; `PI_TELEMETRY=0` or `PI_OFFLINE=1` turns off startup network calls [S4].
- Gaps: no voice, no hotkey daemon (RPC mode would be the seam), vision and per-request thinking control on a Gemma endpoint not tested.

### 4. Goose — best extensible brain with a real daemon mode
- Evidence: `goose serve`, a long-lived WebSocket ACP server with one agent per connection [S7b]; 70+ MCP extensions, recipes, subagents, ACP bridge to Claude Code/Codex [S7, S14]; Apache-2.0 and Linux Foundation stewardship [S14].
- Gaps: tool-calling docs say it works best with Claude 4 [S7]; Snake result 2/4 [S8]; for unknown model ids it defaults to a 128K context, so the context must be pinned (`GOOSE_CONTEXT_LIMIT`) [S9, secondary].

Runners-up (tied at 29): Open WebUI (chat UI with OpenAI-compatible STT/TTS [S14b]; custom licence with a branding clause [S14c]) and OVOS (llama.cpp via ovos-openai-plugin [S13]; Linux installer [S13c]). Both are sound shells, neither is a computer-control brain.

## Voice-first platforms: can they host Gemma 4 through an OpenAI-compatible endpoint?

| Platform | Gemma 4 via OpenAI-compat? | Evidence | Blocker for this box |
|---|---|---|---|
| Pipecat | Yes | `OpenAILLMService(base_url=...)` [S11] | None; you write the loop |
| Home Assistant Assist | Yes | llama.cpp integration takes a base URL [S10] | Home-control only |
| OVOS | Yes | ovos-openai-plugin, "local models via Ollama or llama.cpp" [S13] | Persona/skills model; wake word and STT setup [U] |
| Open WebUI (voice) | Yes | Chat base URL plus OpenAI-compatible STT/TTS [S14b] | Browser UI, no hotkey daemon |
| Kyutai Unmute | Yes in principle: "can be used with any OpenAI compatible LLM server" [S12] | README | **Fails hardware gate**: needs CUDA GPU with >=16 GB VRAM and x86_64; the B580 has 12 GB, Intel/SYCL, no CUDA. Unmute STT is EN/FR only [S12, 22c]. |
| Open Interpreter / 01 | [U] | 01 README mentions OpenAI Realtime and a LiveKit server [S20b] | Not checked |
| Leon | Partly: "supports both local and remote AI providers" [S21] | README | Voice details [U] |
| Hermes voice loop (existing) | Yes | Brief 27 | not in this lane |

## Long list (not scored in depth, one line each)
- **Jan** (Apache-2.0): desktop app on llama.cpp; OpenAI-compatible API on localhost:1337 [S15]; llama.cpp router mode and inline MCP approval in v0.8.0 [S15b]; Linux AppImage/deb. A chat app, not a background voice agent.
- **LM Studio**: not open source [U]. `llmster` headless daemon with systemd startup guide on Linux [S16]; MCP via its API (0.4+) [S16b]. Good serving layer; it is not a harness.
- **AnythingLLM** (MIT [S17]): RAG and agents, MCP compatibility; vendor claims up to 80% token reduction via skill selection (unverified). RAG-first, weak on voice.
- **Letta** (Apache-2.0 [S18]): stateful memory is best-in-class; core memory blocks are rendered into the system prompt [S18b], and release notes show a skills block inflating context [S18c]. Prompt-weight risk.
- **smolagents** (Apache-2.0 [S19]): library, not a platform. CodeAgent writes Python actions; any local model via ollama; MCP tools. Needs a strong code-writing model.
- **OpenClaw** (MIT [S22]): messaging-first assistant, Linux installer, models and harnesses are plugins. Very large community; prompt size and security not checked.
- **Open Interpreter**: now positioned as "a coding agent optimized for low-cost models" [S20]. 01 is a voice-device project [S20b].
- **OpenCode**: strong ecosystem (212K stars, MIT, `opencode serve` headless HTTP/OpenAPI server [S5, S6]). Ranked #1 by MarkTechPost's local-harness list [S23], but prompt weight fails here. Ranking != local fit.
- **Coding harnesses in the MarkTechPost list** (Cline, Aider, Codex CLI, Qwen Code, Kilo Code, OpenHands, Crush): coding-first, not voice. Crush sits in the heavy-to-start benchmark tier with OpenCode; Cline, Codex and Goose in the heavy-but-stable tier [S2].

## Verdict (5 lines)
1. Pi is the most local-friendly brain (lean prompt, native llama.cpp router); it has no voice or daemon, so it is a brain candidate, not the JARVIS shell.
2. OpenCode is ranked first by popularity but fails the prompt-weight gate on a 16K context unless heavily slimmed.
3. For the voice shell, Pipecat (framework, full control, BSD-2) and Home Assistant Assist (daemon, Wyoming voice, llama.cpp integration) are the strongest; Unmute is out on hardware.
4. Goose is the best extensible brain with a real serve daemon, but its tool-calling docs and small-sample result argue for a Gemma tool-call test before adoption.
5. Nothing here was measured on the box (endpoint down). Next step with the endpoint up: count the real system+tool prompt for pi and Goose against the Gemma 4 tokenizer, then run the same 5 tool tasks through pi, Goose and Hermes.

## Self-check
- Criteria covered: 1 prompt weight PASS (estimated, not measured); 2 tool calls PASS (partial, third-party); 3 OpenAI-compatible PASS (documented per platform); 4 daemon/Linux PASS (documented for Goose, HA, LM Studio, Pipecat-as-framework; pi RPC); 5 voice/vision PASS (voice platforms only); 6 control/ext/memory PASS; 7 stability/licence/telemetry PASS (licence verified for OpenCode, Goose, Letta, AnythingLLM, OpenClaw, Pipecat, Open WebUI; pi and OVOS and HA licences `[U]`); 8 cloud escalation PASS.
- Every number above is cited or tagged `[U]` or `[estimate]`.
- Not done: endpoint measurements, Gemma-tokenizer counts, GPU use, installs. Nothing was installed or changed in the workspace.

## Sources
- [S2] Localhost benchmark of 9 coding harnesses, secondary summary (HN post): https://bedrocknews.com/article/hackernews/49651221
- [S3] Claude Code vs OpenCode token analysis (cloud, reference only): https://pan.parallax.kr/article/claude-code-uses-more-tokens-than-opencode-analysis
- [S4] pi README and system prompt: https://raw.githubusercontent.com/badlogic/pi-mono/main/packages/coding-agent/README.md ; https://raw.githubusercontent.com/badlogic/pi-mono/main/packages/coding-agent/src/core/system-prompt.ts
- [S4b] pi llama.cpp router doc: https://raw.githubusercontent.com/badlogic/pi-mono/main/packages/coding-agent/docs/llama-cpp.md
- [S5] OpenCode local provider config (secondary): https://mywiredhouse.net/blog/opencode-setup-with-local-models ; [S5b] slim-prompt fork: https://github.com/SK-DEV-AI/opencode-slim-system
- [S5c] OpenCode server mode (mirror; official page not fetched): https://open-code.ai/en/docs/server
- [S6] OpenCode repo: https://github.com/anomalyco/opencode
- [S7] Goose providers doc: https://block.github.io/goose/docs/getting-started/providers ; [S7b] goose serve source: https://github.com/aaif-goose/goose/blob/e68c8026f346311b2a707db3d79d4c1d8d9b868a/ui/goose2/src-tauri/src/services/acp/goose_serve.rs ; Goose system prompt: https://raw.githubusercontent.com/aaif-goose/goose/main/crates/goose/src/prompts/system.md
- [S8] Snake experiment, pi / opencode / goose on qwen3-coder:30b: https://benjaminschott.com/blog/2026/pi-opencode-goose-snake
- [S9] Goose context-window pitfall (secondary): https://sovgrid.org/blog/goose-vs-vibe-vs-opencode-local-coding-cli
- [S10] Home Assistant llama.cpp integration: https://home-assistant.io/integrations/llama_cpp
- [S11] Pipecat OpenAI LLM service: https://docs.pipecat.ai/server/services/llm/openai ; [S11b] Nemotron voice sample: https://github.com/pipecat-ai/nemotron-january-2026 ; [S11c] Pipecat LICENSE (BSD-2-Clause): https://github.com/pipecat-ai/pipecat/blob/main/LICENSE
- [S12] Kyutai Unmute README (CUDA, 16 GB VRAM, x86_64, any OpenAI-compatible LLM): https://github.com/kyutai-labs/unmute ; [S12c] Pipecat voice-agent write-up (secondary): https://callsphere.ai/blog/vw4h-build-voice-agent-pipecat-self-hosted
- [S13] OVOS OpenAI-compatible plugin: https://github.com/OpenVoiceOS/ovos-openai-plugin ; https://openvoiceos.github.io/beta-technical-manual/openai-plugin ; [S13b] OVOS repo: https://github.com/OpenVoiceOS/OpenVoiceOS ; [S13c] ovos-installer (in repo README)
- [S14] Open WebUI repo: https://github.com/open-webui/open-webui ; [S14b] Open WebUI voice and audio: https://docs.openwebui.com/ecosystem/computer/ai/voice-and-audio ; [S14c] Open WebUI licence: https://docs.openwebui.com/license
- [S15] Jan repo: https://github.com/janhq/jan ; https://jan.ai/docs/desktop/api-server ; [S15b] Jan v0.8.0: https://jan.ai/changelog/2026-05-22-jan-v0.8.0
- [S16] LM Studio llmster on Linux: https://lmstudio.ai/docs/developer/core/headless_llmster ; [S16b] LM Studio MCP via API: https://lmstudio.ai/docs/developer/core/mcp
- [S17] AnythingLLM repo (MIT): https://github.com/Mintplex-Labs/anything-llm
- [S18] Letta repo (Apache-2.0, 25,108 stars): https://github.com/letta-ai/letta ; [S18b] Letta memory profile (secondary): https://github.com/lossless-group/study-memory-layers-for-agents/blob/main/context-v/profiles/Profile__Letta.md ; [S18c] Letta releases: https://github.com/letta-ai/letta/releases
- [S19] smolagents repo: https://github.com/huggingface/smolagents
- [S20] Open Interpreter README: https://raw.githubusercontent.com/openinterpreter/open-interpreter/main/README.md ; [S20b] 01 repo: https://github.com/openinterpreter/01
- [S21] Leon repo: https://github.com/leon-ai/leon
- [S22] OpenClaw repo (MIT): https://github.com/openclaw/openclaw
- [S23] MarkTechPost local-harness ranking (secondary, via yowox): https://yowox.com/posts/open-source-agent-harnesses-local-llms
- Internal: research/22b-jarvis-voice.md, research/22c-jarvis-architecture.md (Wyoming/Piper, Kyutai STT EN/FR, Pipecat/OVOS/HA earlier notes), research/BRIEF-28-platform.md.
