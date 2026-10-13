# 57 — Snappy Chief: TTFT turn 1 vs turn 2 on Ornith-1.5-9B (qwen35, SYCL)

Sources read: llama.cpp SYCL tip at `LOCAL-AI-LAB/engines/llama.cpp-sycl-tip` (grep-level, no runs),
`serve/config.yaml` + `serve/bakeoff-launch.sh`, `~/.hermes/hermes-agent`, llama-swap docs. Read-only.

## Verdict

Turn 2..N are already cacheable and the mechanism works for hybrid qwen35. Nothing in the
current `ornith-chief` command blocks it. The two things that actually cost seconds are
(1) cold start after the 600 s llama-swap TTL and (2) first session turn, which prefill 8K
tokens from scratch. Fix warm start with ttl/preload; shrink first turn with a saved slot
prefix. No llama.cpp flag changes are needed for turn 2 itself.

## 1. How the prefix reuse works for qwen35 in OUR source

- Exact token-ID prefix match: `server_tokens::get_common_prefix` compares llama_token ids
  (`tools/server/server-common.cpp:743-755`). The server reuses them via
  `n_past = slot.prompt.tokens.get_common_prefix(input_tokens)` when `cache_prompt` is true
  (`tools/server/server-context.cpp:3602-3604`); `cache_prompt` defaults to true when the
  client does not send it (`tools/server/README.md:589`). Hermes never sends it.
- qwen35 is built as `llama_memory_hybrid` (per-layer filters: attention when
  `!is_recr`, recurrent when `is_recr`) at `src/llama-model.cpp:3107-3191`. The attention
  layers get per-token KV cells; the recurrent layers hold one state per sequence.
- The recurrent half does NOT have per-token prefix reuse, and it does not need any:
  `llama_memory_recurrent::init_update` returns `LLAMA_MEMORY_STATUS_NO_UPDATE`
  (`src/llama-memory-recurrent.cpp:490-495`). Turn 2 sends only the new suffix tokens, the
  suffix continues from the sequence's tail cell state, so the recurrent chain just keeps
  running. Positions are consecutive, so nothing is recomputed and no state is lost.
- State (attention KV + recurrent state) is written/loaded together for hybrid
  (`src/llama-memory-hybrid.cpp:190-214`); a restore or prompt-cache load rehydrates both.
- With `-np 1` there is one slot and consecutive chat turns select it by prefix similarity,
  so the reuse path is hit every turn.

## 2. The flags in the question, for qwen35

- `--cache-ram` (default 8192 MiB): in-process RAM prompt cache, created for any nonzero
  value (`tools/server/server-context.cpp:1492-1503`). Idle-slot state is saved into it when
  a task picks a slot (`server-context.cpp:1783-1802`, cache accounting in
  `tools/server/server-task.cpp:1714-1904`). Dies with the process; per-slot KV so idle
  slots are NOT cleared (`common/arg.cpp:1737` clears only in unified KV).
- `--cache-idle-slots` (default enabled): auto, keep as is.
- `--cache-reuse N` (default 0): chunk shifting for prompts where matching blocks sit at
  different offsets. Leave 0. The gate checks `llama_memory_can_shift`
  (`server-context.cpp:3624-3630`), which is true for qwen35
  (`src/llama-kv-cache.cpp:1208-1217`), but shifting calls hybrid `seq_rm`, which goes to
  the recurrent cache first (`src/llama-memory-hybrid.cpp:143-150`) and partial recurrent
  rollback is clamped off by default (`n_rs_seq = 0`, `src/llama-context.cpp:3976`,
  `src/llama-memory-recurrent.cpp:189-204`). Hermes turns are append-only, so the shift path
  never triggers anyway; the `get_common_prefix` path does all the work.
- `--ctx-checkpoints` / `--swa-checkpoints` (one flag, default 32,
  `tools/server/README.md:166`): rollback snapshots for speculative decoding and the append
  to `/slots save` files (`server-context.cpp:2534-2596`, caller at 4079). Chief runs no
  spec/MTP (`research/56`), so these cost nothing and buy nothing for TTFT. Keep default.
- `--slot-save-path DIR` + `POST /slots/{id}?action=save|restore`
  (`README.md:1152-1180`, tasks at `server-context.cpp:2901-2976`): the only mechanism that
  survives a process restart. Save = token ids + `llama_state_seq_save_file` (attention KV
  plus recurrent state for hybrid) + checkpoint appendix. Restore rehydrates the whole
  prefix, then the next matching request prefill-skips it via the common-prefix path.

## 3. Warm start (llama-swap)

- Current: `globalTTL: 600`, `ornith-chief` `ttl: 600` (`serve/config.yaml:23,162`). After
  10 min idle the model unloads; the next request pays load (~2-3 s) plus full 8K prefill
  (~6-7 s). Measured cold chat in `research/56`: 5.5 s including load.
- llama-swap (v264 installed) supports `ttl: 0` = never unload, and a top-level
  `preload:` list of model ids loaded at startup
  (https://github.com/mostlygeek/llama-swap/blob/main/docs/config.example.yaml,
  "preloading model: %s" present in the installed binary strings).
- VRAM budget check: loaded Ornith leaves ~1.1-1.25 GiB free of the 12 GiB B580
  (`research/56`), so pinning it 24/7 (`ttl: 0`) is a real cost to the desktop session.
  `ttl: 3600` keeps it warm through a day and frees the GPU after an idle hour.

## 4. Hermes side: the prefix is already byte-stable

- System prompt is built once per session and cached on `agent._cached_system_prompt`; only
  context compression triggers a rebuild (`agent/system_prompt.py:3-8`, `:796-805`,
  `:808-827`; caller `agent/conversation_compression.py:3150`).
- The date line is date-only and session-anchored ("Conversation started" comes from the
  session id, not the clock: `_session_start_like`, `agent/system_prompt.py:176-223`,
  `:489-513`). No per-turn clock in the prompt.
- Tiers are ordered stable, context, volatile, with volatile last so a change re-prefills
  from the tail only (`:730-793`).
- Tool schemas: no `cache_prompt` is sent, so the true default applies; schemas are stable
  within a session.
- Voice transcripts carry no per-turn timestamp (`hermes_cli/cli_voice_mixin.py`), and
  steer messages append a user row at the end, so they extend the prompt without breaking
  the prefix.
- Known prefix breakers, all one-off per event: context compaction (rebuild once per ~32K
  tokens, chief `compression.threshold_tokens` 32768), a skill installed mid-session (the
  skills index is the head of the volatile tail, so it re-prefills the full 8K), a
  per-API-call `system_message` injecting into the context tier (`system_prompt.py:766-768`),
  and image turns, which switch matching to mtmd chunk ids (`server-common.cpp:758-770`).

## 5. Streaming and early TTS (already mostly wired)

- Hermes voice streams sentence one to the speaker while the rest generates
  (`hermes_cli/voice.py:563-587`, sentence splitter `tools/tts_streaming.py:67`).
- Keep `stream: true`, and keep the wake path on `ornith-chief` (thinking off). The
  `ornith-chief-think` alias adds thinking tokens before the first spoken word
  (`serve/config.yaml:163-167`); that is a user choice, not a default.
- `-b/-ub 256`: turn 2's suffix (~30-80 tokens) is a single ubatch, so the small batch size
  does not hurt warm turns. Cold turn 1 chunks into 256-token ubatches, already measured at
  ~1200 t/s (`research/56`).

## 6. Ordered changes and 1-run test plans

Numbers to expect: cold turn 1 TTFT ~6-7 s (8K at ~1200 t/s); warm turn 2 TTFT
~30-150 ms (suffix only; gemma measured 80 ms, `serve/config.yaml:30`); load ~2-3 s
(`research/56` measured 5.5 s cold total incl. load).

1. `serve/config.yaml`: `ornith-chief` `ttl: 600` -> `3600`. Test: leave 15 min, send
   "hi", read `timings.prompt_ms` and wall TTFT. Expect: no 2-3 s load gap, TTFT ~6-7 s.
2. `serve/config.yaml`: add top-level `preload: ["ornith-chief"]`. Test: restart llama-swap,
   wait for "preloading model" in its log, then send "hi". Expect: first-request TTFT
   ~5.5 s total minus the load, i.e. save the ~2-3 s of step 1's cold path.
3. Add `--slot-save-path LOCAL-AI-LAB/serve/slotcache` to the chief launch (via the per-model
   `env: BAKEOFF_EXTRA=...` in `serve/config.yaml`, or `bakeoff-launch.sh`), then after one
   real Chief turn 1 call `POST /slots/0?action=save&filename=chief-prefix.bin`. Test: restart
   the stack, `POST /slots/0?action=restore&filename=chief-prefix.bin` (check `restore_ms`),
   then run the exact Chief first request. Expect `n_prompt_tokens_cache` ~7.5-8.5K and
   `timings.prompt_ms` under ~500 ms versus ~6-7 s.
4. Leave `--cache-reuse` unset (0) and leave `--cache-ram` default. Test: send three back-to-back
   chat turns in one session; turn 2 and 3 responses should report `n_prompt_tokens_cache`
   equal to the whole previous prompt and TTFT under ~150 ms. If turn 2 shows a full re-prefill,
   the prefix changed: check for a mid-session skill install or a compaction event.
5. Hermes: keep new skill installs between sessions, not mid-session; do not inject an
   ephemeral `system_message` into the voice loop. Test: 10-turn voice session, TTFT only
   spikes once at the compaction boundary (~every 32K tokens) or after a skill install.
6. Voice: wake path on `ornith-chief` (thinking off), `stream: true`. Test: speak one
   question, time from end-of-speech to first audio; expect roughly warm TTFT (~50-150 ms)
   plus TTS provider latency, with sentence one spoken while the model still streams.
