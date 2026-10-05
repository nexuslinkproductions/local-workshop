# LANE-B2-REPORT — TOKEN LEDGER rebuild (Haze account/usage standard)

Scope honored: `v4/Workbench.qml` only (plus this report). Deployed mirror
`~/.config/omarchy/plugins/nexuslink.hud/v4/Workbench.qml` synced via `cp`
(no shell restart — the shell picks the file up on next read).

## 1. Haze sources adapted from

All under `PROJECTS/HAZE/VERSIONS/BETA/v1.4.0/` (Tauri app):

| Haze file | What it contributed |
|---|---|
| `src/team/tabs/UsageTab.tsx` | The pane skeleton: Card → `CardTitle` (title + sub + right-side control) → summary stat strip (`grid-cols-3 divide-x` of `Stat` cells: Total / Prompt / Completion) → "By member" share rows: name left, `tokens · share%` right, thin `h-1.5` accent bar under, `Math.max(2..4, share%)` min sliver. |
| `src/team/primitives.tsx` (`Stat`, `CardTitle`) | The stat-cell contract: quiet label over a big tabular value, optional hint line — becomes `TokStatCell`. |
| `src/workspace-ui/components/settings/AccountSettings.tsx` (`Meter`, `account_overview`) | Meter row anatomy: label + amount line → thin share bar → muted subtext line carrying the reason (`detail · resets X`). The "subtext carries the reason" rule → a dead feed's `meta.status` renders in warn colour instead of faked zeros. |
| `src/components/TokenChart.tsx` (`fmtTokens`) | Single shared token formatter precedent (already matched by `fmtTok`: B/M/k magnitudes). |
| `tokens/SCHEMA.md` (this repo) | Bucket truth: `in` folds cache read/write; snapshot-only providers emit `in/out:null` + `total` (never summed); `meta.today_tokens` is the authoritative today for snapshot feeds; `cost:null` must never render as `$0`. |

## 2. Provider filtering — claude/openai/codex never render

- `tokBlocked = ["claude","codex","openai","anthropic"]`, applied by
  `tokBlockedId()` on the provider id AND the display label (exact match,
  `id-`/`id_` prefix, label prefix) — so `claude-code`, `Codex CLI`,
  `openai-*` are all caught, not just the bare ids (Workbench.qml:445-455).
- `tokRows()` now iterates **every** key in `tokData.providers` instead of
  the old 4-id whitelist (`tokOrder`) — new local feeds appear with no
  edit; blocked names are dropped even when the ledger still carries them.
- Verified against live `~/.local/state/nexuslink/tokens.json` (6
  providers): replay of the exact functions in node → `claude` and `codex`
  blocked; opencode / Devin / Haze team API / Fireworks render, sorted by
  today's spend (unknowns sink).

## 3. New pane structure (Workbench.qml token section)

1. **Head row**: `TOKEN LEDGER` + sub ("local feeds · share of window"),
   right edge shows `N feeds · ledger <age> ago` (parsed from
   `tokData.updated`, elides rather than overflowing).
2. **Summary strip** (`tokStrip`, UsageTab stat row → `TokStatCell`):
   divided cells `TODAY` (accent2, with `in↓ out↑ $cost` tail) · `WEEK` ·
   `MONTH` · `BURN` (`~X/h` = today-total / local hours elapsed, ≥15 min
   gate, else `—`). NaN aggregates render `—`, never 0.
3. **Column header**: `PROVIDER / TODAY / IN·OUT / WEEK / MONTH` on shared
   metrics (`tokPad/tokCName/tokCDay/tokCSplit/tokCFlex`) — header and
   delegate read the same numbers.
4. **Rows** (Meter anatomy, single line): name + kind tag (only when
   `kind != "sub"` → `TEAM`/`API`), emphasized today-total, in/out split
   with `· $cost · N req`, then week + month share bars (`TokBar`: thin
   accent2/accent fill on `well` track, share of that window's visible
   total, 3 px min sliver). Stalled feeds show `meta.status` in `warn`.

## 4. Fixed-height fit (the pane is the column remainder)

- `tokListWrap` gets `pane − head − strip − gaps`; rows take
  `tokRowH = clamp(avail/shown, 18, 30)` so content shrinks into the pane.
- Overflow policy: `tokFitCount` caps visible rows; excess collapses to a
  `+N more · clipped for space` line. `clip:true` on the wrap is the last
  defence — nothing paints past the face.
- At 1920×1200 the pane body leaves ~140 px for the list → 4 rows at ~30 px
  (all 4 local providers fit with room).

## 5. Verification

- `cd v4 && /usr/lib/qt6/bin/qmllint Workbench.qml` → **exit 0**, no output.
- Same on the deployed mirror → exit 0.
- Node replay of `tokBucket/tokBlockedId/tokSplitText/tokRows`/totals/burn
  against the live ledger → expected rows, strip `TODAY 633.4M · WEEK
  3.05B · MONTH 3.57B · BURN ~317.9M/h`, TODAY tail `612.4M↓ 21.0M↑ $0.452`.

## 6. Notes for other lanes

- `CommandHub.qml` `tokToday()`/`tokBars()` and `Navigator.qml` still
  enumerate **all** providers including claude/codex — out of B2 scope, but
  if the operator still sees cloud providers elsewhere, that's where.
- `HudV4.qml` `tokProviderCount` counts raw keys (6) — header of this pane
  shows the filtered count (`tokRowCount`), which is the honest "feeds
  shown" number.
