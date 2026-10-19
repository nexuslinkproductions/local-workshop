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

Provider ids: `build()` output is allow-listed. Local ids must be in
`LIVE_PROVIDERS` — `claude`, `codex`, `devin`, `opencode`, `opencode-go`.
Remote lanes `<id>@<host>` are emitted only when `<id>` is in
`REMOTE_PROVIDERS` — `opencode-go@mac`, `devin@mac` — fed from
`remote/<host>.jsonl` written by `pull_remote.py` (systemd timer every
5 min, full snapshot per run; units in `systemd/`, not installed).
Everything else (`fireworks`, `haze`, `codex@mac`, `claude@mac`, legacy
ids) stays in the cursor but is not emitted. `<id>@<host>` kind = the base
id's kind; label = base label + ` (<host>)`; rids read
`hm:<host>:<profile>:…` (session_model_usage) or `dv:<host>:<session>:<row>`
(devin). Unknown/missing sources are simply omitted — an absent provider
key means "no local feed".

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
  lane pair; it still applies to providers with no event feed at all.
- `day` = local today; `week` = ISO week (Mon-start) containing today;
  `month` = calendar month. Windows are computed from record timestamps.
- Snapshot-only providers (no per-event feed) emit `"in": null, "out": null`
  with `total` as the real figure.
- OpenCode runs two disjoint EVENT lanes (unlike the snapshot `total`
  split): `opencode` = local `opencode.db` CLI events, `opencode-go` =
  Hermes `session_model_usage` rows billed to opencode-go (the crew lane).
  They are both real usage of different traffic — sum only under an
  explicitly combined label, never silently folded.

`meta` extras (all optional): `label`, `ready`, `tier`, `status`
(free-text usage status e.g. "Waiting for auth"), `limits` (raw omarchy
`limits[]` array), `today_tokens`, `today_prompts`, `today_sessions`,
`today_by_model`, `models` (lifetime `{model: {in,out}}` from event feeds),
`sessions_db` (devin: "present" when only enrichment table found).

## `history` rows (per provider, ≤90 days, date-sorted)

```json
{"d": "2026-09-28", "in": 59498, "out": 47163, "cost": null,
 "msgs": 12, "acu": 0.4, "total": 858021}
```

`acu`/`msgs`/`total` optional. Snapshot-only days have `in`/`out` = `null`.
Use `in`/`out` (or `total` when they're null) for sparklines; `msgs` is a
fallback activity series.

## `sessions` rows (top 10 by tokens, last 14 days, all Hermes stores)

```json
{"id": "20261005_175320_c70720", "bot": "neji", "provider": "opencode-go",
 "model": "deepseek-v4.1-flash", "title": "HUD verify WS-05",
 "in": 8110000, "out": 220000, "tokens": 8330000, "calls": 150,
 "start": 1791230000.0, "last": 1791240000.0}
```

Additive top-level key from `collect_sessions` (reads the `sessions` table
of `~/.hermes/state.db` + `~/.hermes/profiles/*/state.db`, read-only —
the same store list as `collect_hermes`). Rebuilt fresh every run, ranked
by `in`+`out` desc, capped at `SESS_TOP = 10`. `provider` is the RAW
`billing_provider` (`opencode-go`, `anthropic`, `openai-codex`,
`nous`, … — `haze` rows are skipped) — session attribution, not the
`HERMES_PROVIDER_MAP` fold used for day buckets. `bot` is the profile
dir name (`default` for the shared store). `start`/`last` are epoch
seconds; sessions with `archived`/`hidden` set or zero tokens are
skipped.

## Sources → provider mapping

| Provider | Source | Record / dedupe key | Timestamp |
|---|---|---|---|
| `claude`/`codex`/`fireworks`/… | `~/.local/state/omarchy/agents/usage/<id>.json` (schemaVersion 1: `todayTotalTokens`, `todayTokensByModel`, `recentDays[]`, `limits[]`, `tierLabel`, `updatedAt`) | snapshot — overwritten, not summed | `updatedAt`, `recentDays[].date` |
| `opencode` | `$XDG_DATA_HOME/opencode/opencode.db` — `message.data` JSON `tokens{input,output,reasoning,cache{read,write}}` + `cost`; fallback `session.tokens_*`/`cost` columns | `oc:` + `message.id` / `ocs:` + `session.id` | `time_updated` / `time_created` (epoch ms) |
| `devin` | `~/.local/share/devin/cli/sessions.db` — `message_nodes.chat_message` JSON `metadata.metrics{input_tokens,output_tokens,…}`, `metadata.committed_acu_cost`; plus `cli/transcripts/*.json` `steps[].metadata.committed_acu_cost` if present | `dv:` + session_id:row_id / `dvt:` + file:step | `created_at` (epoch s/ms) |
| `claude` (merge) | `~/.claude/projects/**/*.jsonl`, `~/.local/share/claude/**/*.jsonl` — per-line `message.usage{input_tokens,output_tokens,cache_*}` | `cl:` + uuid/message.id/requestId | line `timestamp` (ISO) |
| `claude`/`codex`/`opencode-go` (merge) | `~/.hermes/state.db` + `~/.hermes/profiles/*/state.db` — `session_model_usage` cumulative row per (session, model, provider, base_url, mode, task); `billing_provider anthropic`→claude, `openai-codex`→codex, `opencode-go`→`opencode-go` (own lane), other providers skipped; `in = input+cache_read+cache_write`, `out = output_tokens` (reasoning already inside) | `hm:` + profile:session_id:model:provider:base_url:mode:task, delta-folded via `seen` | `last_seen` (epoch s) |
| `<id>@<host>` | `$XDG_STATE_HOME/nexuslink/remote/<host>.jsonl` — full snapshot per pull, one JSON record per `session_model_usage` row (`profile` + the 13 columns), written by `pull_remote.py` over ssh; same provider map. Each store is read with `sqlite3 -readonly`, falling back to the `file:…?immutable=1` URI when the WAL side files are gone (stopped gateway); a store unreadable both ways aborts the pull (previous file kept) | `hm:` + `<host>:` + profile:session_id:… (same tuple), delta-folded via `seen` | `last_seen` (epoch s) |
| `devin@<host>` | same `remote/<host>.jsonl`, records tagged `"kind": "devin"`: one per Devin message row from the host's `~/.local/share/devin/cli/sessions.db` `message_nodes` (read-only, same ssh call). Fields: `row_id`, `session_id`, `created_at`, `metrics` (`metadata.metrics`, else `metadata.usage`), `acu` (`metadata.committed_acu_cost`), `model` (`metadata.generation_model`). Ledger reads them with `_metrics()` exactly as `collect_devin` does | `dv:<host>:` + session_id:row_id, dedupe via `seen` | `created_at` (epoch s/ms) |

`kind` mapping: claude/codex/devin/opencode/opencode-go → `sub`,
fireworks → `api`; `<id>@<host>` inherits the base id's kind. opencode is
a harness — its upstream auth decides sub vs api; revisit `kind` if the
HUD cares.

## Cursor (`ledger-cursor.json`, internal)

```json
{"version": 2, "saved": "...",
 "files":  {"<path>": byte_offset},                 // jsonl tails
 "sqlite": {"opencode": {"mark": max_time_updated}, "devin": {"mark": max_row_id},
            "hermes": {"<db path>": max_last_seen,
                       "__folded__": {"<db path>": ["<billing_provider>"]}}},
 "seen":   {"<prov>": {"<rid>": [in,out,cost,acu]}},// delta-dedupe (capped 20k)
 "days":   {"<prov>": {"YYYY-MM-DD": {in,out,cost,acu,msgs,snap}}},
 "undated":{"<prov>": {in,out,cost,acu,msgs}}}
```

`__folded__` (v2): per-store set of Hermes `billing_provider`s already
covered. A provider added to `HERMES_PROVIDER_MAP` later gets a one-time
backfill of its own rows (`WHERE billing_provider IN (new)`); the
incremental mark alone cannot reach rows scanned past while unmapped.
Rid-dedup keeps the two passes disjoint. A v1 cursor has no `__folded__`,
so every mapped provider counts as new and backfills once.

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
- **Hermes sqlite stores** (`~/.hermes/{sessions,response_store}.db`)
  — no token-usage table; still not mined. `~/.hermes/state.db` (and
  `profiles/*/state.db`) ARE mined since WS-08a via `session_model_usage`
  (see the sources table; `hermes insights` reads the same table).

Never-read list enforced by a path denylist: `credentials*`, `auth.json`,
`mcp_config*`, `service.json`, `*cookie*`, `*.vscdb`, `*mcp-tokens*`,
`*.lock`, `*bus-principals*`, `*secret*`.
