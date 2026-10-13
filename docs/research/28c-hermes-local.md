# 28c: Hermes as the local Gemma 4 platform (prompt weight + lean profile)

Date: 2026-10-13. Scope: Hermes only (other platforms are 28a/28b/28d). No config changes, no profile created, no models loaded, no GPU use, no servers started.

## 1. Measured prompt weight (exact tokens, Gemma 4 vocab)

Tokens: Gemma 4 12B QAT GGUF tokenizer via `llama-tokenize` (vulkan build, tokenizer only, no GPU), counted by the orchestrator into `~/.hermes/cache/scratch/28c/tokens-gemma4.txt`. Chars: Hermes' own `build_system_prompt()` and `model_tools.get_tool_definitions()` run in-process, cwd `~/NEXUS_AI_CENTER`.

| Case | What is loaded | System tokens | Tool-schema tokens | Total tokens | Fits 16,384 ctx? |
|---|---|---:|---:|---:|---|
| A default CLI | Marcel's current config: 25 tools, Yuri SOUL, skills index, AGENTS.md | 17,454 | 15,753 | **33,207** | **No** (exceeds 16K and 32K) |
| B no skills | as A, minus skills toolset (no index) | 9,817 | 4,639 | 14,456 | Barely (≈1.9K left) |
| C lean terminal/file/web | 10 tools, short SOUL stand-in, no AGENTS.md, no memory | 2,231 | 3,125 | **5,356** | Yes (≈11K left) |
| D lean terminal/file | 8 tools | 2,231 | 2,637 | 4,868 | Yes |
| E lean + vision/tts | 12 tools | 2,231 | 3,737 | 5,968 | Yes (≈10.4K left) |

Char counts, same runs: A system 81,809 chars (stable 26,684 / context 3,384 / volatile 51,737), tools 45,897 chars. Note: C's SOUL is a ~135-char stand-in, so the real persona adds more (see §3).

Where the weight comes from (A, chars, from section ranges of the built prompt):

- Skills index (`<available_skills>`): ~41,000 chars. Single largest item. Gated by the skills toolset.
- Yuri SOUL persona (SOUL.md, slot 1): ~18,500 chars. Lives in the profile home, so a profile can replace it.
- Tool schemas: `delegate_task` 4.8K, `manage_connections` 4.2K, `skill_manage` 3.7K, `browser_exec` 3.7K, `memory` 3.5K, `execute_code` 3.1K, plus 17 `kanban_*` tools (28K chars when that toolset is on).
- Guidance blocks: Tool-use enforcement + Google model directives (~4.5K chars; the Google block is keyed on "gemma" in the model name, so it applies to our model), parallel/task-completion guidance (~3.6K).
- AGENTS.md from cwd (3.4K) and hindsight memory block (0.7K).

Per-toolset schema cost (chars): kanban 28,348 (17 tools); connections 6,338; file 5,675 (4 tools); terminal 5,020; skills 4,961; delegation 4,707; memory 3,526; code_execution 1,779; web 1,910; vision 843; tts 1,520; clarify 1,812. Toolsets `browser`, `cronjob`, `session_search`, `todo`, `video`, `computer_use` each contribute only the 3-tool deferred bridge (~2.3K chars), which is the same bridge that appears in every case.

## 2. Hard blockers found

1. **64K minimum context floor.** `agent/agent_init.py::_enforce_minimum_context` raises `ValueError` when the endpoint serves less than `MINIMUM_CONTEXT_LENGTH = 64_000` (`agent/model_metadata.py:272`). Hermes refuses to start against our 16K llama-swap entry. Only two exits exist in code: (a) `provider: lmstudio` with an explicit `model.context_length` below the floor (code path exists, **not tested**), or (b) `model.ollama_num_ctx >= 64000` for a local endpoint (only honoured for Ollama-style num_ctx, and it would lie about the real window). Option (c): run llama-swap at `-c 65536` (VRAM and KV cost **unmeasured**). The brief's 16K and 32K/q8 settings cannot run Hermes as configured.
2. **Default prompt does not fit any local window we have.** A = 33,207 tokens. Even with the floor patched, the default Marcel session cannot run on 16K or 32K. The lean profile is required, not optional.
3. **Privacy leaks in the current config (for a local profile).** `auxiliary.vision` → anthropic claude-haiku-5-5 (screenshots leave the box); `hindsight` extraction LLM → DeepSeek endpoint with `auto_retain: true`; `auxiliary.skills_hub`, `auxiliary.mcp`, `auxiliary.goal_judge` → cloud (haze/deepseek); `auxiliary.review` → openai-codex. A local profile must repoint or disable all of them. `telemetry.shared_metrics_harness.send: false` is already off.

## 3. Lean local profile (proposal, not applied)

Put it in a new profile home (e.g. `~/.hermes/profiles/jarvis-local/`), so the main `config.yaml` and SOUL.md stay untouched. Shape:

```yaml
model:
  provider: local-ai           # 127.0.0.1:18080/v1, gemma4-12b (see §2.1 for the floor fix)
  default: gemma4-12b
  context_length: 16384        # only if the floor is solved via lmstudio path (untested)
platform_toolsets:
  cli: [terminal, file, web, vision, tts, clarify]   # = case E, 5,968 tokens
agent:
  disabled_toolsets: [memory, skills, delegation, kanban, browser, cronjob, session_search, code_execution, computer_use, todo]
  tool_output: {max_bytes: 20000, max_lines: 500}     # documented small-context setting
auxiliary:                     # every task on the local model or off
  vision: {provider: local-ai, model: gemma4-12b}
  skills_hub: {provider: local-ai, model: gemma4-12b}
  mcp: {provider: local-ai, model: gemma4-12b}
  goal_judge: {provider: local-ai, model: gemma4-12b}
  review: {provider: local-ai, model: gemma4-12b}
hindsight: off               # no DeepSeek extraction
memory: off                  # skip_memory path
skills: none                 # skills toolset off = no index (saves ~41K chars in A)
voice: {auto_tts: false}     # /voice on from CLI; Ctrl+B push-to-talk
wake_word: {enabled: false}
```

Plus two files in the profile home: `SOUL.md` of about 800–1,200 chars (replace the 18.5K Yuri persona with a short voice-assistant persona; a real Yuri-free version still needs writing and its exact token count measured), and no AGENTS.md (run from a dedicated cwd, or the cwd probe keeps adding ~1.1K chars of workspace/environment context).

Expected prompt size: about 5,400 tokens (C/E) plus the real SOUL (estimate ~250–300 tokens at 4.7 chars/token; **not measured**). That leaves about 10K tokens of a 16K window for conversation and tool results.

Not measured and not in the 5,968 figure: whether `tool_search`/`tool_describe`/`tool_call` disappear when the MCP servers in config are off (the bridge appears even with only terminal+file; the likely trigger is the enabled MCP servers, unverified).

## 4. Criteria scorecard (1–5, PASS/FAIL)

| # | Criterion | Score | Verdict | Evidence |
|---|---|---:|---|---|
| 1 | Prompt weight | 2 as shipped, 4 with profile | **FAIL as shipped** | 33,207 tokens default (A); 5,356 lean (C); exact tokens |
| 2 | Tool-calling robustness with small local models | 3 | PASS with caveat | Native tools need llama-server `--jinja` (Hermes docs); text-tool fallback exists only in `agent/acp_openai_bridge.py::extract_tool_calls_from_text` (ACP path), **CLI path not verified** |
| 3 | Any OpenAI-compatible endpoint; per-request params | 2 | **FAIL** | 64K floor blocks 16K (§2.1); per-request thinking toggle (`chat_template_kwargs`) not verified in Hermes; local-ai provider entry exists in config |
| 4 | Background/daemon, on-demand, Linux/Wayland | 3 | PASS partial | Persistent CLI/TUI session + `hermes gateway` (messaging); no evidence of a hotkey/socket API for local; Wayland not tested |
| 5 | Voice loop (STT/TTS, barge-in) and screen/vision | 4 | PASS partial | CLI `/voice on`, Ctrl+B, 3 s silence end, sentence-streamed TTS, barge-in, stop phrases (voice-mode docs); wake word CLI/TUI/desktop only, not gateway (docs + 22c); screen = `vision` tool, currently cloud aux (must repoint) |
| 6 | Computer control, extensibility, memory | 4 | PASS | plugins, MCP, skills, delegation, `computer_use` (cua backend); memory default = cloud hindsight (must disable for local) |
| 7 | Stability, maintenance, licence, privacy | 3 | PASS as profile, FAIL as shipped | MIT licence (pyproject); active upstream; privacy leaks listed in §2.3 |
| 8 | Escalation to cloud for hard tasks | 5 | PASS | `delegation`, `moa`, main model `claude-opus-5-5`; a local profile keeps the cloud lane separate |

Self-check: every number above is measured (tokens: exact; chars: in-process build) or marked unverified/estimated. No claim about Gemma's own thinking control in Hermes was tested.

## 5. Verdict

- Hermes is a strong *escalation brain* and a rich toolset host, but it does not run a 16K local model out of the box: the 64K floor and a 33K default prompt both fail.
- A dedicated lean profile is viable: 5.4K–6.0K tokens with terminal/file/web/vision/tts, no skills index, no memory, short SOUL.
- The floor is the gating decision: pick the lmstudio explicit-context route (test it) or run llama-swap at 64K (measure VRAM/KV first).
- Repoint or disable every auxiliary and hindsight cloud route before calling the profile local-only.
- Voice works in the CLI today; wake word and background operation need a long-lived CLI/TUI session, not the gateway.

## 6. Unverified / next checks

- Test the `provider: lmstudio` + explicit `context_length: 16384` route against the live endpoint (requires GPU; needs the bench lock).
- Confirm the `tool_search` bridge disappears with MCP servers off.
- Confirm Gemma's thinking toggle per request through Hermes (`chat_template_kwargs`).
- Measure the real short SOUL's token count and the VRAM/KV cost of 64K ctx.

## Files

- Created: this file; scratch measurement scripts and dumps in `~/.hermes/cache/scratch/28c/` (measure.py, variants.py, prompt-*.txt, tools-*.json, tokens-gemma4.txt).
- Modified: none (no config, skills, memory, or profile changes).
