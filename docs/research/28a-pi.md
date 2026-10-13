# 28a — "pi" agent harness (earendil-works/pi) as Marcel's local-model platform

Date: 2026-10-13. Scope: BRIEF-28 criteria 1–8. Measured with the real pi 1.2.0 CLI against a
capture-only mock OpenAI endpoint (no model loaded, no GPU use, llama-swap not sent any request).
Scratch artifacts: `~/.hermes/cache/scratch/pi/` (system prompt, tool schemas, captured requests).

## Identity (verified)

- **Name / repo:** pi, a coding-agent harness by Mario Zechner. Repo moved from `badlogic/pi-mono`
  to `earendil-works/pi` after Earendil Inc. acquired the project (announced 2026-04-08).
  Earendil is a Vienna-based public benefit corp (co-founded by Armin Ronacher).
- **Version:** `@earendil-works/pi-coding-agent` **1.2.0**, published 2026-10-12 (npm `latest`).
  Recent cadence: 1.0 on 2026-10-01, 1.0.4 on 10-05, 1.1.0 on 10-07, 1.2.0 on 10-12.
- **Licence:** MIT (npm metadata, GitHub API `spdx_id: MIT`). Trademark held by Earendil.
- **Install used for measurement:** `npm install --prefix <scratch> --ignore-scripts @earendil-works/pi-coding-agent@1.2.0`
  (user-space, Node 26.7 / npm 11.19). Nothing installed system-wide.
- **Important:** the "<1,000-token, four-tool, no-MCP" pi of Nov 2025 is out of date. 1.0 added MCP
  (via codemode), a llama.cpp router integration, and non-LLM model calls. The default prompt is still small (below).

## Criterion 1 — Prompt weight (MEASURED)

Captured from the real request body (`captured.jsonl`, pi 1.2.0, reasoning:true model, `--thinking off`).
Token counts use **tiktoken cl100k_base as a proxy** — Gemma's tokenizer is not available here, expect ±15%.

| Piece | Chars | ~Tokens |
|---|---|---|
| Default instructions (preamble, tools list, rules, docs paths, cwd) | 2,810 | 638 |
| 4 tool schemas (read, bash, edit, write) as sent in `tools[]` | 2,956 | 714 |
| **Per-turn fixed overhead, default config** | | **~1,350** |
| `-t read` (one tool) | 1,919 + 713 | ~634 total |
| Run from workspace root (auto-loads `AGENTS.md` + `CONTEXT.md`) | 5,151 + 2,956 | **~2,070** |

- Share of a 16K context: ~8% per turn for default; ~13% if the workspace context files load.
- pi re-sends the whole system prompt and tool list every request (stateless API); prefix stays stable,
  so llama.cpp's KV prefix cache can reuse it (no per-turn timestamps observed in the prompt).
- Gotcha: pi auto-loads `AGENTS.md`/`CONTEXT.md` from the cwd. Launch it from a neutral directory or pass
  `--no-context-files` for the JARVIS assistant. Tool schemas for codemode/MCP were not measured (off by default).

**Score 5/5.** Smallest prompt of the platforms in this brief (per what is measured here).

## Criterion 2 — Tool-calling robustness with small local models

Measured (mock endpoint, scripted model output):
- **Truncated JSON args, finish_reason = `tool_calls`:** pi repairs partial JSON and **executes** it.
  A `write` call with content cut to `"hello wor"` wrote the 9-byte file and reported success.
- **Same truncation, finish_reason = `length`:** pi **refuses** to run it and returns
  "Tool call … was not executed: the response hit the output token limit … Re-issue the tool call". Good guard.
- **Wrong-type args (path is a directory):** error (`EISDIR`) returned as a tool result. The scripted mock then replied normally; no real model was exercised.
- **Unknown tool name:** returned as "Tool read not found" tool result (no crash).
- Defaults: no grammar-constrained decoding (`supportsOpenAIGrammarTools` = false), no strict-schema mode.
  Both are per-model compat options.

Community / third-party evidence (dated, versions noted):
- **Polyglot benchmark** (Italian author, 30 runs per cell, Ollama OpenAI endpoint, pi **0.85.1**, 32k ctx, 6 coding tasks):
  pi made **zero tool calls in 18/18 runs** on qwen2.5-coder 7B and 14B (they emit tool calls as plain text);
  pi 89% (16/18) on qwen3-coder 30B-A3B; 28/30 on Qwen3.8-27B. Source: https://usepolyglot.dev/blog/tool-call-reliability ,
  https://github.com/giuseppe-sirigu/polyglot-benchmarks . The tool itself says pi is tested only against Ollama.
- **arXiv 2609.26693** "Measuring the Serving Stack Instead of the Model": same request gets different outcomes on
  Ollama / llama.cpp / vLLM / SGLang; grammar-constrained decoding removes parse errors but can cause non-termination
  (Qwen-0.5B: 869 turns). Not pi-specific. https://arxiv.org/html/2609.26693
- **Gemma 4 on llama.cpp (community, spring 2026):** repeated reports of broken tool-result handling, empty
  replies, and "announces a tool call then stops". One Reddit comment says llama.cpp's interleaved Gemma-4 template
  was written for agents "such as OpenCode or Pi" that send reasoning back. Reddit reports are unverified and may predate fixes.
  https://reddit.com/r/LocalLLaMA/comments/1sfj075 , https://reddit.com/r/LocalLLaMA/comments/1sfrubh
- **Gemma 4 12B QAT GGUF (local, read from metadata):** chat template handles a `developer` or `system`
  first message and gates thinking on `enable_thinking` (default false). Parsing rules for tool calls were not
  verified without a live run.
- **No pi + Gemma 4 12B result exists yet.** Not measured here (GPU lock; llama-swap `/running` was empty, no model loaded).

**Score 3/5.** Native-channel only: strong for 30B-class / Qwen 27B, unreliable for 7–14B models that emit text tool calls. Lenient
partial-JSON repair is a risk for write/edit unless finish_reason is trusted.

## Criterion 3 — Any OpenAI-compatible local endpoint; per-request params

Verified (captured request bodies):
- Endpoint via `~/.pi/agent/models.json` (`api: openai-completions`, `baseUrl`, `apiKey`, per-model `contextWindow`,
  `maxTokens`, `input: ["text","image"]`). Works against a generic OpenAI-compatible mock. llama-swap
  (`http://127.0.0.1:18080/v1`) was NOT driven live.
- **Thinking toggle:** with `compat.thinkingFormat: "chat-template"` and
  `chatTemplateKwargs: {"enable_thinking": {"$var": "thinking.enabled"}}`, `--thinking off` sends
  `chat_template_kwargs: {enable_thinking: false}` and `high` sends `true`. Without the compat block, pi sends
  `reasoning_effort` only, which llama.cpp ignores for Gemma. Matches the Gemma 4 template's `enable_thinking` variable.
- **Role:** reasoning models get the system prompt as `developer` role. The Gemma 4 template accepts
  `developer` at message 0 (verified in the GGUF template). Set `compat.supportsDeveloperRole: false` if a
  server drops it.
- **Images:** prompt with image → `content: [{type:"text"}, {type:"image_url", image_url:{url:"data:image/png;base64,..."}}]` (verified via RPC).
- `max_completion_tokens` is the default output field for local endpoints (taken from `maxTokens`). Community issue
  #5375 says llama.cpp wants `max_tokens`; set `compat.maxTokensField: "max_tokens"` if truncation shows up. Not verified here.
- Built-in llama.cpp **router** integration (`/login llama.cpp`, `/llama` load/unload) exists, but it targets
  llama-server router mode. Marcel's llama-swap uses the generic provider path.

**Score 4/5.** Covered in config and body shape; not yet proven against the live llama-swap stack.

## Criterion 4 — Background/daemon, invoked on demand

- **RPC mode is verified:** `pi --mode rpc --no-session` stays alive, reads JSONL commands on stdin
  (`get_state`, `prompt` with optional images, `steer`, `follow_up`, `abort`, `set_model`, `compact`, `new_session`, ...).
  Measured: `get_state` answered in 0.36 s from spawn; prompt + image ran to `agent_settled`; a second prompt in the same
  process ran in the same session; exit 0 on stdin close.
- **No built-in socket/HTTP/daemon listener.** A hotkey/voice front end needs a small wrapper (systemd user unit +
  Unix socket or FIFO → RPC stdin). Docs: https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md
- Node.js SDK (`createAgentSession`, `RpcClient`) can embed it in-process instead of spawning. Docs: `docs/sdk.md`.
- Pi deliberately has no background bash ("use tmux"). This is about tool processes, not the agent daemon.

**Score 3/5.** Good long-lived RPC core; the daemon/hotkey wrapper is DIY.

## Criterion 5 — Voice loop and screen input

- No STT/TTS in pi. Wake word and barge-in must come from outside.
- Barge-in hooks exist: RPC `abort` and `steer` (`steer` is delivered after the current tool calls finish). `abort` was not exercised here.
- Screen input: image parts are accepted in prompts (verified). The screen-locate tool can run as a `bash` tool or
  a pi extension. Not tested.

**Score 2/5.** Image input is fine; the voice loop is entirely external.

## Criterion 6 — Computer control, extensibility, memory

- **Extensions:** TypeScript loaded via jiti, no build step. Events: `tool_call` (can block or mutate),
  `tool_result`, `context`, `before_agent_start`, `session_start/shutdown`, `agent_settled`, ... Can register tools,
  commands, shortcuts, providers, MCP servers. Docs: `docs/extensions.md`.
- **MCP:** built in since 1.0 (2026-10-01; the project had earlier refused it). `--no-mcp` to disable.
  Codemode and tool_search are built-in extensions (inactive until enabled).
- **Skills, prompt templates, themes, npm/git "pi packages".**
- **Computer control:** `bash` (no sandbox, no permission prompts, YOLO by default). Docs say run it in a container.
  Sub-agents are not built in; pi says spawn another pi via bash.
- **Memory:** none across sessions. Only AGENTS.md / CLAUDE.md context files, JSONL session tree (branch/fork),
  auto-compaction (`autoCompactionEnabled` true). Hermes has real memory; pi does not.

**Score 3/5.** Extensibility 5, memory 1, computer control is generic bash (no safety layer).

## Criterion 7 — Stability, maintenance, licence, telemetry/privacy

- **Maintenance:** GitHub API (2026-10-13): 114,756 stars, 14,616 forks, 321 open issues, last push 2026-10-12.
  Very fast release churn (four minor/major releases in 12 days). The maintainer's own 1.0 reversed the MCP policy.
- **Open bugs relevant to local use (reported, status not checked):**
  - #5266 TUI crash when a tool result lacks `content` (llama.cpp + extension, pi 0.78).
  - #8229 local endpoint overflows context between tool turns; compaction runs too late (llama.cpp 65,536-token case).
  - #8939 session header lost if the session file is deleted mid-run (silent corruption).
  - #5375 `maxTokens` fallback missing (partly visible in the 1.2.0 capture: `max_completion_tokens` came from models.json).
- **Licence:** MIT; core stays MIT per the Earendil RFC 0015 (2026-03-30). Some future components may be Fair Source.
- **Telemetry / privacy (docs):** `enableInstallTelemetry` defaults to **true** — anonymous install/update reporting plus
  "selected provider attribution headers". Disable with settings `enableInstallTelemetry: false` or `PI_TELEMETRY=0`.
  `PI_OFFLINE=1` (or `--offline`) disables catalog refreshes. Session sharing to Hugging Face is opt-in
  (`pi-share-hf`). With a local endpoint, inference stays on the box; the install ping goes to the internet unless disabled.

**Score 3/5.** MIT and active, but churn is high, the owner is a company that is still being formed, and install
telemetry is on by default (easy to turn off).

## Criterion 8 — Escalation to cloud models

- pi-ai supports 15+ providers (Anthropic, OpenAI, Google, OpenRouter, Groq, ...), `/model` and Ctrl+P switching,
  and cross-provider context handoff within a session (blog + docs). Not tested live (no cloud keys used).
- Hermes already does this and is Marcel's main system; pi would only be the local worker.

**Score 5/5** for pi alone (documented, not live-tested).

## Scored table

| # | Criterion (BRIEF-28) | Score /5 | Main evidence |
|---|---|---|---|
| 1 | Prompt weight | **5** | ~1,350 tok/turn default (measured); ~2,070 with workspace AGENTS/CONTEXT |
| 2 | Tool-call robustness (small models) | **3** | Native-only; 0/18 on qwen2.5-coder 7–14B text calls (Polyglot, pi 0.85.1); repairs truncated args; `length` guard works |
| 3 | OpenAI-compatible endpoint, per-request params | **4** | models.json endpoint; thinking via chat-template kwargs (measured); image_url (measured); llama-swap not live-tested |
| 4 | Background / on-demand | **3** | RPC JSONL long-lived (measured, 0.36 s to first reply); no built-in socket daemon |
| 5 | Voice / screen | **2** | No STT/TTS; abort/steer exist; image input works |
| 6 | Control, extensibility, memory | **3** | TS extensions, MCP since 1.0; no memory; bash with no sandbox |
| 7 | Stability / licence / privacy | **3** | MIT; very fast churn; install telemetry on by default (switchable) |
| 8 | Cloud escalation | **5** | 15+ providers, mid-session switch (documented) |
| | **Total** | **28/40** | |

## Sources (non-US first, per brief)

- Earendil (Vienna) acquisition announcement: https://earendil.com/posts/announcing-pi-and-lefos
- Mario Zechner (Austria), original design post, Nov 2025: https://mariozechner.at/posts/2025-11-30-pi-coding-agent/
- Pi v1.0 / MCP reversal coverage: https://yuphora.com/news/technology/6088eeeaf25a4f1824bb
- Earendil / Pi joins Earendil (Vienna framing): https://piagent.fyi/news/pi-joins-earendil
- Flavio Copes (author, origin not verified) deep dive, LM Studio + Gemma 4 config, developer-role compat tip: https://flaviocopes.pages.dev/pi
- Polyglot tool-call benchmark (Italian-named author; origin not confirmed): https://usepolyglot.dev/blog/tool-call-reliability
- Repo/docs (primary, US-hosted): https://github.com/earendil-works/pi (rpc.md, extensions.md, custom-provider.md, models.md, security.md, llama-cpp.md)
- npm registry: @earendil-works/pi-coding-agent@1.2.0 (MIT)
- arXiv 2609.26693 (authors not extracted): https://arxiv.org/html/2609.26693

## Verdict

1. Pi has the smallest per-turn prompt I measured (~1.35K tokens with four tools, 8% of 16K) and exposes every request body, which fits the "know what the model sees" requirement.
2. It has no voice loop, no cross-session memory, and no built-in daemon. Hermes already provides all three plus cloud escalation, so pi does not beat Hermes as the JARVIS front end.
3. Its weak point for local models is tool-call handling: native-channel only, lenient repair of truncated args, and the 7–14B text-call failure mode (0/18). No pi + Gemma 4 12B data exists.
4. Recommendation: keep Hermes as the front end. Pilot pi as a local worker (`pi --mode rpc` behind llama-swap, models.json compat set as above) and measure tool-call success on about 20 read/edit tasks with the Gemma 4 12B before any real use. Keep the worker out of the voice path until that pilot is done.
5. Confidence: medium. Prompt numbers are measured (proxy tokenizer). Tool-call numbers come from a third-party benchmark on other models and pi 0.85.1. The llama-swap live path is untested.

## Self-check (BRIEF-28 mandatory)

- Criterion 1 Prompt weight: **PASS** — measured from the captured request body.
- Criterion 2 Tool-call robustness: **PASS** — mock-measured behaviour + cited third-party benchmark; Gemma 4 pi-specific data **unverified** (not measured).
- Criterion 3 Endpoint / per-request params: **PASS** — mock-measured; llama-swap live path **unverified**.
- Criterion 4 Background / on-demand: **PASS** — RPC measured; Linux/Wayland daemon wrapper **unverified** (not built).
- Criterion 5 Voice / screen: **PASS** — docs + image input measured; abort/steer **unverified** at runtime.
- Criterion 6 Control / extensibility / memory: **PASS** — docs + source; extension and MCP runtime **unverified**.
- Criterion 7 Stability / licence / telemetry: **PASS** — npm + GitHub API + docs; telemetry default read from docs, not captured on the wire.
- Criterion 8 Cloud escalation: **PASS** — documented, not live-tested.
- Not done: no GPU use, no model loaded, no sudo or system packages. Mock servers stopped.
