# Token/Credit Ledger Recon — nexuslink

Verdict: **the richest local ledger is `opencode.db`** (per-message tokens + cost + model + provider + epoch-ms, real-time). `omarchy/agents/usage/*.json` are display rollups (today + 7-day), not a durable ledger. Claude/Codex/Devin/Haze have **no non-zero local token history** — they need API/OTEL taps.

## Local sources

### opencode — the real ledger
- `~/.local/share/opencode/opencode.db` (SQLite, WAL). Read-only conn safe while running (`mode=ro`, `PRAGMA query_only=ON`).
- `message` table: `session_id`, `data` JSON blob. Assistant msgs carry `providerID` (`anthropic`/`openai`/`fireworks-ai`/`haze`…), `modelID`, `tokens:{input,output,reasoning,cache:{read,write}}`, `time:{created,completed}` (epoch **ms**), `cost`.
- Sessions: `ses_*` ids, `cost`, `tokens.*`, `projectID`, `directory`, `model`.
- Rules: `outputTokens = output + reasoning`; Codex `input_tokens` includes cached tokens — subtract cache parts.
- **Haze rows appear here** (`providerID=="haze"`) — partial local visibility without the haze API.

### omarchy aggregate layer (already `aguse*` in collector)
- `~/.local/state/omarchy/agents/usage/{claude,codex,fireworks}.json` — written by `/usr/bin/omarchy-agent-usage-*` collectors.
- Schema: `todayTotalTokens, todayTokensByModel{}, recentDays[{date,messageCount/*token total*/}] (7d only), modelUsage{model:{input,output,cacheRead,cacheCreation}} (all-time), limits[{label,percent,resetsAt}], tierLabel, usageStatusText`.
- Staleness ~20s cache. **No per-day in/out split beyond 7 days** — rollup feed only.
- Currently all zeros (claude unauth, codex ready-but-zero, fireworks no key).

### Claude Code — ABSENT
- `~/.claude/projects/**/*.jsonl` not present. Per-record: `message.usage.{input_tokens,output_tokens,cache_read_input_tokens,cache_creation_input_tokens}`, `message.model/id`, `sessionId`, `timestamp`.
- Limits API: `GET api.anthropic.com/api/oauth/usage` (Bearer from `.credentials.json`) → `five_hour`, `seven_day`, scoped `limits[]` w/ `utilization`, `resets_at`.

### Codex — ABSENT
- `~/.codex/sessions/**/*.jsonl` not present. Per-record: `type=="token_count"` → `payload.info.last_token_usage.*` (delta only, never sum `total_token_usage`); `turn_context` → model.
- Limits via `codex app-server` JSON-RPC: `account/rateLimits/read` → `{usedPercent, windowDurationMins, resetsAt}` — headless, cheapest authoritative Codex tap.

### Devin — NO per-message local usage (verified via sqlite3)
- `~/.local/share/devin/cli/sessions.db`: `sessions{id,model,created_at,last_activity_at,cogs_json,metadata}`, `message_nodes{session_id,node_id,chat_message,created_at,metadata}`.
- `chat_message` JSON keys: content/message_id/metadata/role/thinking/tool_call_id/tool_calls. `metadata` = `{summarized_from,num_tokens_preceding,is_system_prefix}` — **context size only, no billing tokens**.
- Options: (1) OTEL tap — `otel.endpoint` in `~/.config/devin/config.json` exports `devin.token.usage` + `api_request` metrics (needs local OTLP collector; not configured); (2) `GET api.devin.ai/v3/enterprise/sessions/{id}` → `acus_consumed` (needs API key from credentials.toml — read programmatically, never display); (3) `num_tokens_preceding` as context-size telemetry.
- No headless usage subcommand; `/usage` + `/session-stats` are TUI-only.

### Haze — no local store
- No data dir under `~/.local/share` (app id `ai.legionedge.haze`); webview localStorage only.
- Server truth: `GET /usage` → `{promptTokens,completionTokens,cachedTokens,weeklyTokensUsed/Limit,fiveHTokensUsed/Limit/ResetsAt,cloudAgentsUsed/Limit,credits{remaining,total},windows[]}`.
- Local coverage comes free via opencode.db `providerID=="haze"` rows.

### Fireworks — dormant
- No config/key on this box. API: `GET api.fireworks.ai/v1/accounts/{id}/billingUsage?groupBy=model_name` — day-bucketed, model-attributed, 30d window, true `cost`-grade.

### Hermes — unexamined
- `~/.hermes/{sessions.db,lcm.db,…}` sqlite; token columns unknown; ccusage lists hermes as supported — worth a `.schema` pass later.

## OSS trackers
- **ccusage** (ryoppippi): multi-source unified ledger (claude/codex/opencode + amp/droid/hermes/pi/goose/kimi/etc); `--json` → `{date,models[],inputTokens,outputTokens,cacheCreationTokens,cacheReadTokens,totalTokens,costUSD}`; cost via LiteLLM pricing; dedup by message id; codex counts deltas not totals.
- `opencode stats` built-in: `--days --models --tools --project`.
- `expensive`, `oc-stats`, `codex-usage-tracker`, `cxusage` — same pattern (normalize → sqlite → rollups).

## Recommended tokens.json schema
`~/.local/state/nexuslink/tokens.json`: `schemaVersion`, `generatedAt`, `sources{provider:{kind,path,staleness}}`, `days{"YYYY-MM-DD":{provider:{inputTokens,outputTokens,cacheReadTokens,cacheWriteTokens,costUsd|null,sessions,messages,byProvider{},byModel{}}}}`. ISO local day; week/month = summation. `costUsd:null` = subscription-billed (estimate only, flag `estimated:true`). Devin carries `acus`/`credits` beside tokens, not inside.
