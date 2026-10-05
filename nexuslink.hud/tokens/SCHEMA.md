# token-ledger schema — `tokens.json`

Produced by `tokens/ledger.py` (stdlib only) →
`$XDG_STATE_HOME/nexuslink/tokens.json` (default `~/.local/state/nexuslink/tokens.json`),
written atomically (mkstemp + `os.replace`). Cursor state (incremental offsets,
dedupe set, accrued per-day rows) lives beside it in `ledger-cursor.json`.
HUD renders `tokens.json` only — the cursor is internal.

## Top level

```json
{
  "updated":   "2026-09-28T12:00:00+00:00",   // ISO-8601, run time
  "generator": "token-ledger/1",
  "providers": { "<id>": { ... } },
  "history":   { "<id>": [ {day row}, ... ] },
  "sources":   { "<id>": ["<file that fed it>", ...] }
}
```

Provider ids seen: `claude`, `codex`, `fireworks` (from omarchy records),
`opencode`, `devin`, `haze`. Unknown/missing sources are simply omitted —
an absent provider key means "no local feed".

## Provider object

```json
{
  "label": "Claude Code",                  // display name
  "kind":  "sub",                          // "api" | "sub" | "team"
  "day":   {"in": 0, "out": 0, "cost": null},
  "week":  {"in": 0, "out": 0, "cost": null},
  "month": {"in": 0, "out": 0, "cost": null},
  "undated": {"in": 0, "out": 0, "cost": 0.0},   // only if undated records exist
  "meta":  { ... }                          // per-source extras, see below
}
```

Bucket semantics:

- `in` / `out`: integer tokens. `in` includes cache-read/cache-write tokens
  (they're prompt-side bytes); `out` includes reasoning tokens.
- `cost`: USD float, `null` when unknown/not-applicable (never render as $0).
- `acu` (optional): Devin ACU units, when the source reports them.
- `msgs` (optional): message/call count in the window.
- `total` (optional): reporter-native combined total — present on
  snapshot-sourced providers. **`total` may overlap `in`+`out`; never sum both.**
- Two-lane providers (`claude`, `codex`): the omarchy snapshot and Hermes
  state.db feed one row. `in`/`out`/`cost` then carry the **Hermes event
  lane only** (`session_model_usage`, providers `anthropic`/`openai-codex`);
  `total` carries the **snapshot lane only** (Codex CLI / Claude Code
  rollup). The two lanes measure disjoint traffic — the snapshot collectors
  never scan Hermes paths — so they are neither duplicates nor a single
  quantity: render them separately, never add `total` into `in`+out, and
  never treat one as a corrected version of the other. `build()`'s
  snapshot-only nulling (`in: null, out: null`) no longer applies to a
  lane pair; it still applies to providers with no event feed at all
  (`fireworks`).
- `day` = local today; `week` = ISO week (Mon-start) containing today;
  `month` = calendar month. Windows are computed from record timestamps.
- Snapshot-only providers (no per-event feed) emit `"in": null, "out": null`
  with `total` as the real figure.

`meta` extras (all optional): `label`, `ready`, `tier`, `status`
(free-text usage status e.g. "Waiting for auth"), `limits` (raw omarchy
`limits[]` array), `today_tokens`, `today_prompts`, `today_sessions`,
`today_by_model`, `models` (lifetime `{model: {in,out}}` from event feeds),
`upstreams` (haze: underlying providers like `opencode-go`/`openai-codex`),
`sessions_db` (devin: "present" when only enrichment table found).

## `history` rows (per provider, ≤90 days, date-sorted)

```json
{"d": "2026-09-28", "in": 59498, "out": 47163, "cost": null,
 "msgs": 12, "acu": 0.4, "total": 858021}
```

`acu`/`msgs`/`total` optional. Snapshot-only days have `in`/`out` = `null`.
Use `in`/`out` (or `total` when they're null) for sparklines; `msgs` is a
fallback activity series.

## Sources → provider mapping

| Provider | Source | Record / dedupe key | Timestamp |
|---|---|---|---|
| `claude`/`codex`/`fireworks`/… | `~/.local/state/omarchy/agents/usage/<id>.json` (schemaVersion 1: `todayTotalTokens`, `todayTokensByModel`, `recentDays[]`, `limits[]`, `tierLabel`, `updatedAt`) | snapshot — overwritten, not summed | `updatedAt`, `recentDays[].date` |
| `opencode` | `$XDG_DATA_HOME/opencode/opencode.db` — `message.data` JSON `tokens{input,output,reasoning,cache{read,write}}` + `cost`; fallback `session.tokens_*`/`cost` columns | `oc:` + `message.id` / `ocs:` + `session.id` | `time_updated` / `time_created` (epoch ms) |
| `devin` | `~/.local/share/devin/cli/sessions.db` — `message_nodes.chat_message` JSON `metadata.metrics{input_tokens,output_tokens,…}`, `metadata.committed_acu_cost`; plus `cli/transcripts/*.json` `steps[].metadata.committed_acu_cost` if present | `dv:` + session_id:row_id / `dvt:` + file:step | `created_at` (epoch s/ms) |
| `claude` (merge) | `~/.claude/projects/**/*.jsonl`, `~/.local/share/claude/**/*.jsonl` — per-line `message.usage{input_tokens,output_tokens,cache_*}` | `cl:` + uuid/message.id/requestId | line `timestamp` (ISO) |
| `claude`/`codex` (merge) | `~/.hermes/state.db` + `~/.hermes/profiles/*/state.db` — `session_model_usage` cumulative row per (session, model, provider, base_url, mode, task); `billing_provider anthropic`→claude, `openai-codex`→codex, other providers skipped; `in = input+cache_read+cache_write`, `out = output_tokens` (reasoning already inside) | `hm:` + profile:session_id:model:provider:base_url:mode:task, delta-folded via `seen` | `last_seen` (epoch s) |
| `haze` | `~/.hermes/usage/*.json` rollups (`input_tokens`,`output_tokens`,`cache_*`,`reasoning_tokens`,`estimated_cost_usd`,`session_id`,`provider`) + `~/.hermes/cron/usage_audit.jsonl` (`prompt_tokens`,`completion_tokens`,`fire_id`,`ts`; error rows skipped) + `~/.local/share/haze/**/*.{json,jsonl}` same shapes | `hz:`/`hzf:`/`hzl:`/`hzs:` + session_id/fire_id/file | `session_id` `YYYYMMDD_HHMMSS` prefix → file mtime → `undated`; audit rows `ts` |

Hermes/state.db overlap with `haze`: the 8 stale (Aug 10) `~/.hermes/usage/*.json`
rollup sessions also exist in `session_model_usage`; the 4 `openai-codex` ones
therefore appear under both `haze` and `codex` on 2026-08-10 — outside every
rendered window. state.db is the superset; if those rollups ever go live again,
retire `collect_haze`'s rollup branch rather than deduping across providers.

`kind` mapping: claude/codex/devin/opencode → `sub`, fireworks → `api`,
haze → `team`. opencode is a harness — its upstream auth decides sub vs api;
revisit `kind` if the HUD cares.

## Cursor (`ledger-cursor.json`, internal)

```json
{"version": 1, "saved": "...",
 "files":  {"<path>": byte_offset},                 // jsonl tails
 "sqlite": {"opencode": {"mark": max_time_updated}, "devin": {"mark": max_row_id}},
 "seen":   {"<prov>": {"<rid>": [in,out,cost,acu]}},// delta-dedupe (capped 20k)
 "days":   {"<prov>": {"YYYY-MM-DD": {in,out,cost,acu,msgs,snap}}},
 "undated":{"<prov>": {in,out,cost,acu,msgs}}}
```

Idempotency: records keyed by rid accumulate only the *delta* vs the stored
tuple — safe for opencode rows whose token fields update mid-stream. Omarchy
snapshots never go through `seen`; they overwrite `snap`/`msgs` per date.
Truncated jsonl files reset their offset (rids still dedupe unless `seen`
was pruned at cap). `--reset` rebuilds everything.

Records with no usable timestamp land in `undated` (still summed, emitted
per-provider) rather than being dropped.

## Not found locally (HUD: show "API-only / no local feed")

- **Claude Code transcripts** — `~/.claude/projects/` absent on this box;
  `claude` shows only the omarchy snapshot (currently `ready:false`,
  "Waiting for auth"). Collector path is live if transcripts appear.
- **Devin transcripts** — `~/.local/share/devin/cli/transcripts/` absent;
  `sessions.db` exists and is mined via `message_nodes`. ACU has no
  USD rate → `cost` stays `null`, ACU surfaces under `acu`.
- **opencode `session_message` v2 table** — exists in some versions but
  empty vs legacy `message`/`part`; ledger uses `message`.
- **`~/.local/share/haze/`** — absent; haze data comes from `~/.hermes/`
  (`usage/*.json`, `cron/usage_audit.jsonl`) instead.
- **Hermes sqlite stores** (`~/.hermes/{sessions,response_store}.db`)
  — no token-usage table; still not mined. `~/.hermes/state.db` (and
  `profiles/*/state.db`) ARE mined since WS-08a via `session_model_usage`
  (see the sources table; `hermes insights` reads the same table).

Never-read list enforced by a path denylist: `credentials*`, `auth.json`,
`mcp_config*`, `service.json`, `*cookie*`, `*.vscdb`, `*mcp-tokens*`,
`*.lock`, `*bus-principals*`, `*secret*`.
