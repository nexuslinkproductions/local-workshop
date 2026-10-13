# 28b — "The DeepSeek harness": identification and BRIEF-28 scoring

Date: 2026-10-13. Scope: identify what Marcel means by "the DeepSeek harness", then score it against BRIEF-28. Verdict is for the local-assistant platform question only.

## 1. Identification

Three projects match "DeepSeek harness". Only one is DeepSeek's own.

| # | Project | Who | What | Evidence |
|---|---|---|---|---|
| **A** | **`deepseek-ai/deepseek-harness`** (CLI `dsh`, npm `@deepseek-ai/dsh`) | DeepSeek AI org | Open-source agent harness, MIT, Node/TypeScript, "Everything is a Plugin" on the Cordis kernel. Web UI on `127.0.0.1:3080`, headless mode, SDKs, ACP server. Developer preview. | GitHub API: owner `deepseek-ai` (Organization), created 2026-08-13, MIT, ~248k stars [1][2]. npm registry: latest `0.2.0-rc.2`, maintainers include `tianyicui-deepseek` [3]. Official page [4]. |
| B | `Hmbown/DeepSeek-TUI` → now **Codewhale** (`codewhale`, legacy `deepseek` binary) | Independent (Hunter Bown) | Rust terminal coding agent. Provider-neutral since rename. Native `ollama`, `vllm`, `sglang` routes with localhost defaults. | Repo says it "began as `deepseek-tui`… is now provider-neutral and independently maintained; it is not affiliated with any model provider" [5][6]. |
| C | `HenryZ838978/deepseek-harness` | Third party | Python protocol-adapter / "witness" library for DeepSeek V4 API quirks (reasoning_content round-trip, prefix-cache alignment). Not an agent. | Repo README [7]. **Excluded** from scoring: it is a library, not a platform. |

Also seen, docs only (not platforms): `sandbaseai/deepseek-harness-handbook` (states it is not an official DeepSeek project) and `libukai/awesome-deepseek-harness` (Chinese curated list) [8][9].

**Most likely referent: A.** It is the one with "DeepSeek harness" as its literal name and DeepSeek org ownership. B is a plausible alternative if Marcel saw "DeepSeek TUI" under its old name, so it gets a short note in §4. C is not a candidate.

Source-quality caveats:
- Secondary sites (deepseekagent.io, deepseekharness.io, flowtivity, deepseekv4guide) disagree on version numbers and star counts (they cite rc.1, rc.5, 0.1.5-rc.x). **I used the npm registry and GitHub API**, which are primary. Some of their "desktop app for Windows/Mac" and "Linux no build" claims are secondary-only; I did not verify them against the official download page.
- Chinese sources: the official repo ships a Chinese README (`README.zh.md`) [1]. A Chinese-language search surfaced libukai's curated list [8], which cites the stale baseline 0.1.2-rc.1. **No Zhihu or Juejin article surfaced in search**, so I have no non-US editorial source beyond the official Chinese docs. Stated, not hidden.

## 2. What I ran (verification, no GPU load)

- Installed `@deepseek-ai/dsh@0.2.0-rc.2` into a user-space npm prefix: `/home/nexuslink/.hermes/cache/scratch/dsh-probe/node_modules` (538 packages, 496 MB). No system packages, no sudo.
- Stood up a **mock OpenAI-compatible endpoint** on `127.0.0.1:19999` (Python, logs requests, returns canned replies). It is not the llama-swap server and loads no model. Probe files are in the scratch dir.
- Pointed dsh's headless profile at it via a custom `openai-completions` provider (`cordis.patch.yml` in a scratch `DSH_HOME`). Results:
  - **Plain text round-trip: PASS** (streaming request, `stream: true`, text reply returned).
  - **Native tool-call round-trip: PASS.** Mock returned an OpenAI `tool_calls` entry for `bash`; dsh executed it and sent `PROBE-BASH-42` back as a `role: tool` message; the model then answered. A first attempt missed a required `description` argument; dsh returned `invalid arguments: missing required property "description"` as the tool result, which is the self-correction path a small model needs.
- Measured the real request prompt (see §3).
- llama-swap at `127.0.0.1:18080` answered `GET /v1/models` (listing only). It advertises `Gemma 4 12B QAT Q4_0 + mmproj — local assistant (thinking off)`, `function_calling: true`, `vision: true`. **I did not send any inference request**, because that would load the model on the GPU (bench/.gpu.lock rule).
- `dsh web --no-open` starts on this Linux box (verified). `http://127.0.0.1:3080/` returns 401 without the per-run token printed at startup.

## 3. Criterion 1 — prompt weight (measured)

Counted with the Gemma-4 vocabulary (`ggml-vocab-gemma-4.gguf` via `llama-tokenize --show-count`, CPU, vocab-only file). Counts are over the JSON request body, not the Gemma chat template. Expect the template's tool framing to add roughly 5–15 %.

| Config | System prompt | Tool schemas | Other messages (runtime ctx, skill list, user) | First-turn total |
|---|---|---|---|---|
| **Stock `headless` profile** | 2,609 chars = **556 tok** | 24 tools, 19,260 chars compact = **4,170 tok** | 689 tok | **≈5,445 tok** (≈7,030 with pretty-printed schemas) |
| **Lean overlay** (`--patch lean.yml`: disables pwsh, jobs, skill, subagent×3, workflow, todo, goal, ralph, web) | 884 chars | 8 tools: bash, edit, exit_plan_mode, glob, grep, read, read_image, write | same | **≈1,879 tok** |

- Stock: `workflow` alone is 3,549 chars of schema; `bash` 2,325; `edit` 1,159; `subagent_fork` 1,083.
- On the 16K context: stock eats about one third of the window before the user speaks. Lean is about 12 %.
- The stock system prompt is a coding-agent persona ("You are a coding agent powered by the gemma-4-12b model", bash/grep/glob rules, workflow and subagent rules). A JARVIS persona is not in it. The `dsh-persona` package is in the install and the prompt-section API has a `order: 0` deployment-persona slot [10], so a persona fix looks possible. **Not tested.**
- The request also sends `max_completion_tokens: 32768`, which is above the 16K context. The Models page exposes a per-model max-output setting [11]. Whether llama-server clips or rejects the value: **unverified**.

## 4. Scoring against BRIEF-28 (1 = poor, 5 = best for local models)

| # | Criterion | Score | Evidence / status |
|---|---|---|---|
| 1 | Prompt weight | **2** stock / **4** lean | Measured §3. Lean overlay is a documented `--patch` mechanism [11][12]. |
| 2 | Tool-calling robustness, small local models | **3** | Native OpenAI `tools` passed and round-trip verified with mock (§2). Validation errors are fed back as tool results, which helps retries. **No** text-format fallback, grammar or JSON constraint, or small-model repair found in docs or package list. **Not run against real Gemma** (GPU rule). |
| 3 | Any OpenAI-compatible local endpoint; per-request params | **4** | Custom provider with `api: openai-completions` and `baseURL` verified end-to-end (streaming and non-streaming, `GET /models`). Per-model `input: [text, image]` documented [11]. Thinking toggle via `reasoningEfforts` plus `compat.thinkingFormat` documented [11]; **not tested** on llama-swap, whose thinking toggle is a model alias. |
| 4 | Background / daemon, on-demand invocation, Linux | **3** | Verified: `dsh web --no-open` runs on this box as a local HTTP server with token auth. `dsh --profile headless "task"` one-shot verified. SDK (JSON-RPC) and ACP server packages exist [11]. **No** hotkey, wake-word or socket daemon for voice. Secondary sources say no Linux desktop app; the npm/CLI route works. |
| 5 | Voice loop, screen/vision | **2** | `dsh-experimental-speech-to-text` (+ sensevoice, API, voice-input bundle) exist, marked experimental [3]. **No TTS package** and **no barge-in** in the rc.2 package list. Vision input works via `read_image` plus per-model image input [11]. **No screen-capture or computer-use package** in rc.2. |
| 6 | Computer control, extensibility, memory | **3** | Extensibility **5**: Cordis plugins, MCP client (`dsh-mcp-client`), skills, patch overlays, SDK/ACP [4][10]. Computer control **1**: bash and filesystem only; no GUI package in rc.2. Memory: append-only session log and skills; no dedicated long-term memory plugin found. |
| 7 | Stability, maintenance, licence, telemetry | **3** | Licence MIT: PASS. Activity high (26 releases, npm tags move every few weeks). **Stability is preview:** README says "THERE WILL BE COMPATIBILITY-BREAKING CHANGES", and `SAFETY.md` says it has **not** had a security audit [1][13]. Telemetry: the `web` profile disables product analytics (only `desktop` enables it). Session telemetry defaults to `FEEDBACK_ONLY`: records leave the box to `dsh-otel-collector.deepseeksvc.com` only after explicit user feedback. `DSH_TELEMETRY_MODE=DISABLED` turns it off [14]. The DeepSeek adapter has a `plugin-package-inventory-deepseek` row that is on by default [10]; I did not check whether it applies to custom providers. |
| 8 | Escalation to cloud models for hard tasks | **5** | Built-in catalog covers DeepSeek V4 and third-party providers (`anthropic`, `openai`, `moonshotai`, `zai`, …), and the model picks per session [11]. Subagent providers can delegate to Claude Code or Codex binaries (off by default) [5]. |

**Totals, unweighted:** stock 2+3+4+3+2+3+3+5 = **25/40**; lean overlay 4+3+4+3+2+3+3+5 = **27/40**. Scores 3 and 4 are my judgement from docs plus mock tests, not a live Gemma run.

**Codewhale (B), not scored:** its docs list native `ollama`, `vllm` and `sglang` routes with localhost defaults and no key required [5][6]. That is a stronger local-first fit on criteria 3 and 1 by documentation. I did not measure its prompt or tool set. Evaluate it in the 28d lane if Marcel means that project.

## 5. Verdict

1. "The DeepSeek harness" = `deepseek-ai/deepseek-harness` (`dsh`): official, MIT, Node, developer preview since 2026-08-13. It is a plugin framework with a DeepSeek-first default, not a local-model product.
2. It can drive Gemma 4 through the llama-swap OpenAI endpoint. The custom-provider path, plain replies and the native tool-call round trip work (verified against a mock).
3. Its stock prompt is too heavy for a 16K 12B model (≈5.4K tokens, coding persona, 24 tools). A lean `--patch` overlay gets it to ≈1.9K, measured. Voice output, barge-in and computer control are missing.
4. It does not replace Hermes today: preview stability, no audit, no TTS, no screen control. As a local on-demand tier it is viable only with the lean overlay, `DSH_TELEMETRY_MODE=DISABLED`, and version pinning.
5. For a pure local-first comparison, Codewhale (B, independent, native Ollama/vLLM routes) is the stronger candidate to check in 28d.

## 6. Self-check (BRIEF-28)

- **Every claim cited or marked unverified.** Unverified items: Gemma tool-calling on the real model; thinking toggle on llama-swap; llama-server handling of `max_completion_tokens: 32768`; the Gemma chat-template token overhead; whether `plugin-package-inventory-deepseek` applies to custom providers; Linux desktop app absence (secondary sources only); Zhihu/Juejin sources (none found).
- **Criteria covered:** 1 PASS (measured), 2 PARTIAL (mock only), 3 PASS (mock; thinking toggle partial), 4 PARTIAL (web and headless verified; no daemon or hotkey), 5 FAIL (no TTS, no screen control, experimental STT only), 6 PARTIAL (extensibility PASS; computer control FAIL), 7 PARTIAL (MIT PASS; preview and unaudited FAIL; telemetry PASS with setting), 8 PASS.
- **No installs beyond user-space npm, no sudo, no model loads, no GPU use.** Only a mock OpenAI endpoint on `127.0.0.1:19999` was run, and it was stopped after each probe.

## Sources

[1] https://github.com/deepseek-ai/deepseek-harness (README, MIT, developer-preview warning; also README.zh.md)
[2] https://api.github.com/repos/deepseek-ai/deepseek-harness (owner, created date)
[3] https://registry.npmjs.org/@deepseek-ai/dsh (dist-tags, versions, maintainers; `npm view` output)
[4] https://deepseek.com/harness/en/ (official product page; Agent = Model + Harness)
[5] https://github.com/Hmbown/Codewhale (Codewhale README; history; install; local model connect)
[6] https://github.com/Hmbown/CodeWhale/blob/main/docs/CONFIGURATION.md and docs/PROVIDERS.md (search-result excerpts; ollama/vllm/sglang routes, localhost defaults)
[7] https://github.com/HenryZ838978/deepseek-harness (protocol adapter; excluded)
[8] https://github.com/libukai/awesome-deepseek-harness (Chinese curated list)
[9] https://github.com/sandbaseai/deepseek-harness-handbook ("not an official DeepSeek AI project")
[10] https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/system-prompt.md; docs/architecture.md (plugin list, turn flow, persona slot); local install `node_modules/@deepseek-ai/*` (package list, `dsh-base/cordis.patch.yml`)
[11] https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/guide/providers.md (custom `openai-completions` provider; per-model input; reasoningEfforts; thinkingFormat; defaultInput; troubleshooting)
[12] `dsh --profile headless --dump-config` and `--patch` overlay (verified behaviour, §2)
[13] https://github.com/deepseek-ai/deepseek-harness/blob/master/SAFETY.md (experimental; not audited; sandbox not isolation)
[14] local `node_modules/@deepseek-ai/dsh-session-telemetry-otel/README.md` and `lib/index.js` (FEEDBACK_ONLY default; DISABLED mode); `dsh-base/cordis.patch.yml` (collector URL)

Probe artefacts: `/home/nexuslink/.hermes/cache/scratch/dsh-probe/` (requests.jsonl, requests-standard.jsonl, requests-tool.jsonl, lean.yml, p_*.txt token inputs, mock_openai.py, mock_tool.py).
