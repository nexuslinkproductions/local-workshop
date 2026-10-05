# LANE-FIX-REPORT — v4/ API-drift blocker remediation

Scope: fixes for `verify/api-drift-audit.md` findings only. Touched:
`v4/qmldir`, `v4/Workbench.qml`, `v4/UtilityDock.qml`, `v4/CommandHub.qml`.
Nothing else modified.

## B1 — qmldir missing exported component types (BLOCKER) — FIXED

`v4/qmldir` now exports `Navigator`, `CommandHub`, `BoardView`, `Workbench`,
`UtilityDock` in a new `# LANE-D/N-BEGIN/END` block; LANE-T and LANE-S
markers, singletons, and component lines untouched (qmldir:15-21).
Evidence: `cat v4/qmldir` — all five types listed; `Type ... is not a type`
can no longer occur for these components.

## B2 — unknown-sentinel contract mismatch (BLOCKER) — FIXED

`Workbench.qml`: added `isUnk(v)` matching `undefined`/`null`/
`{ "__nxUnknown": true }` (Workbench.qml:78-80) and `unk` bound to
`Style.unknownGlyph` (:77, Style.qml:100). `topoRows()` (:269-307) now
guards `link`/`temp`/`power`/`load`/`state` with `isUnk()` — sentinel
objects render `—`, never `String()`'d "[object Object]" (state → `""` →
jack column shows `—`). `flowRows()` and the flow/jack accent comparisons
now use `root.unk` instead of a hard-coded dash (:315, :1252, :1270, :1379).

## W3 — kind-enum drift in patch-bay filters (WARN) — FIXED

`topoRows()` matches `kinds.indexOf(n.kind)` OR `n.extra.cls` — Topology
keeps the scaffold class in `extra.cls` (Topology.qml:371-375) and maps
`netif→nic`, `pw_sink/pw_source→audio`, `bluetooth→bt`,
`xhci/usb_roothub/usb_hub/usb_*→usb` (Topology.qml:96-112). New filters:
- NETWORK INTERFACES `["nic"]` (Workbench.qml:1138)
- AUDIO ROUTES `["audio"]` (:1152)
- BLUETOOTH + PERIPHERALS `["bt", usb leaf classes]` (:1166) — `bt` covers
  the adapter; leaf `extra.cls` values keep peripherals here without
  pulling every `usb`-kind node (which would duplicate the fabric below)
- DISPLAYS `["disp"]` (:1180)
- USB FABRIC `["xhci","usb_roothub","usb_hub"]` as cls filters (:1194) —
  controllers/hubs only

## W4 — Style API drift (WARN) — FIXED

`pal.fMono` reads `Style.f.mono` (real key, Style.qml:56) instead of the
nonexistent `Style.f.body` (Workbench.qml:51).

## B5 — perpetual timers in UtilityDock (BLOCKER) — FIXED

`DockPoll` carries **no Timer** now: the repeating `_timer` (2–60 s per
cell) and one-shot `_refresh` are gone (UtilityDock.qml:433-474). Polls
expose `maybeFire(nowMs)` (:456-467); `refreshSoon(ms)` stores a wall-clock
deadline instead of spawning a timer (:450-455). Cadence (:619-646):
`onStatsChanged → tick()` drives polls off the real ~1 Hz stats stream;
while lane H's ingest (`HudV4.qml`) is out of tree, ONE coalesced 1 s
fallback timer (`running: dock.visible`) calls the same `tick()`. That is
the only wall-clock timer in the file — 1 Hz, nothing faster, nothing
while hidden. Periods are wall-clock (`_lastMs`/`everyMs`), so the two
tick sources can never double-fire a cell. `Component.onCompleted:
pulse()` preserves the first-fetch-on-load behaviour
(`triggeredOnStart`).

## B6 — perpetual timers in CommandHub (BLOCKER) — FIXED

The 3 s AV and 30 s power Timers are deleted (was CommandHub.qml:291-315).
`pollTick()` (CommandHub.qml:316-331) fires `avPoll`/`pwrPoll` on
wall-clock periods (3 s / 30 s) gated by `root.shown`. Drivers:
`onStatsChanged` tail-call (:218) as the primary stats-cadence path, and
the pre-existing 1 s clock timer (`running: root.shown`, :251-260) as the
single fallback tick — no new Timer was added; the file still has exactly
one 1 Hz timer. `Component.onCompleted: pollTick()` (:331) keeps
first-fetch-on-load.

## B7 — fabricated telemetry zeros in Workbench (BLOCKER) — FIXED

Absent keys now produce `-1` (→ unknown glyph downstream) instead of
`num(undefined)→0`:
- `wsCount`/`winCount` guard with `has()` (:155-156); masthead renders via
  `cnt()` → `—` (:429); empty-state labels distinguish unknown vs. true
  zero (:530-535, :649-654).
- `devsessCount` (:207) and `ghEvCount` (:227) → `-1` when absent; render
  sites show the glyph/unknown text (:763, :963-968).
- `wsList()` skips rows missing `ws{i}_id` (can't dispatch on a fake id)
  and `wins` → `-1` → `·—` on the chip (:157-173, :514); `win{i}_wsid`
  guarded (:182).
- `num()` documented coerce-only-behind-`has()` (:65-68); all remaining
  call sites are guarded or presence-derived (`procCount` counts actually
  present keys — honest).

Adjacent fabrications fixed inside the allowed files (same §3 contract):
- `UtilityDock.qml` ws cell: `win_count` guarded → `—` (:229); `bt` conn
  `-1` → `— conn` instead of `0 conn` (:211); `disk` free space computed
  only when both `fs_root_size` and `fs_root_used` exist (:234-241).

## Cadence choice (documented per contract)

Chose **both halves** of the sanctioned pattern: the real 1 Hz stats
stream is the primary driver (`onStatsChanged → tick()/pollTick()` in
both components — CommandHub already had the applyFrame delta handler;
UtilityDock gained it), AND one coalesced, visibility-gated 1 s timer per
component as fallback because `HudV4.qml` ingest is not in tree yet.
Timer census after fix: Workbench 1× (1 s clock, `running: visible`),
UtilityDock 1× (1 s fallback, `running: visible`), CommandHub 1×
(1 s clock, `running: shown`). Nothing faster than 1 Hz, nothing
perpetual while hidden; `FileView` clipboard watch unchanged
(event-driven, no timer); Navigator/BoardView untouched (outside edit
scope).

## Verify

```
/usr/lib/qt6/bin/qmllint Workbench.qml UtilityDock.qml CommandHub.qml
→ exit 0, no warnings
```
(`v4/qmldir` is a module manifest, not a lintable QML unit; verified by
inspection — all exports resolve to files present in v4/.)
