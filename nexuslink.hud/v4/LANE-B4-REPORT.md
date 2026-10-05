# LANE B4 — DP-2 multi-view: BOARD | OPS tab shell + OpsView live feed

## Scope owned
- `v4/BoardView.qml` (edited — tab shell only)
- `v4/OpsView.qml` (new — second view)
- `v4/qmldir` (registration line)
- `v4/LANE-B4-REPORT.md` (this file)

No other files touched. Mirror synced: `~/.config/omarchy/plugins/nexuslink.hud/v4/`
(`BoardView.qml`, `OpsView.qml`, `qmldir`, this report). No shell restart needed —
Quickshell picks up the changed module on next deck reload / IPC.

## What was built

### Tab shell (BoardView.qml)
- `wrap` Column children are now: `mast` (unchanged, kept at top) → `tabBar` (new,
  34 px, two embossed keys BOARD | OPS, same visual idiom as the masthead LENS
  keys) → `board` + `shelf` (visible only on tab 0) → `opsPage` (OpsView, tab 1).
- Column positioners skip `visible: false` children, so each tab gets the full
  body height with **zero re-indentation** of existing board content.
- New root props: `property int viewTab` (0/1) and
  `readonly property bool boardActive = running && viewTab === 0`.
- `boardActive` gates the three WireDots `root.running` refs (particle
  `NumberAnimation`s stop while the board is behind OPS) and the `links` canvas
  `onStatsRevChanged`/`onSchemaRevChanged` repaint. `onViewTabChanged` was added
  to the root `Connections` so links repaint once on tab-back.
- Masthead `lensRow` gets `enabled: viewTab === 0` + `opacity 0.35` while on OPS —
  it is a board-only control; everything else in the masthead is untouched.
- Tab bar right caption shows `VIEW n/2 · REV <Topology.statsRev>` — a live tick,
  not decoration.

### OpsView.qml — "OPS" live system feed (~1270 lines)
All data comes from the parsed `stats` map the collector emits plus
`Topology.statsRev` as the tick. Nothing fabricated; absent keys render "—".

- **LIVE FEED** (left, ~70 % width): bounded `ListModel` (cap 80), newest on top.
  Two real sources merged per stats tick:
  - `journalctl --user -n 48 --no-pager -o short-iso -q` via
    `Process`/`StdioCollector` (Navigator's pattern) re-run every 3rd tick
    (~4.5 s) **and only while the tab is visible**; dedupe anchors on the last
    ingested line and collapses consecutive repeats into a `×N` suffix (the
    voxtype WARN spam stays one row). If journalctl fails, the header shows
    `jrnl exit <code>` and the feed still carries frame events.
  - Stats-frame diff events, each tick: top-proc enter/leave (`procN_name/cpu`),
    window open/close/retitle (`winN_addr/class/title`), workspace win-count
    changes (`wsN_*`), GitHub unread/api flips + `ghevN_*` events seeded with
    real ages, theme/pkg/battery-state/agent/session deltas, telemetry
    stale↔live transitions, service-strip state flips. Diffs are skipped when a
    key family is absent from a frame — no false "closed" spam on a partial batch.
    Event stamps use `uptime_s` (`u62h21m`); journal rows keep their ISO clock.
- **SERVICES** strip: QUICKSHELL / HUD-COLLECT / PIPEWIRE / NETMGR / BLUETOOTHD.
  Stats-only derivation, honest per brief:
  - quickshell — `up` (self-evident: this UI is rendered by it; evidence shows
    `proc#N cpu%` when it lands in the top list).
  - hud-collect — `up`/`down` from feed freshness: it *produces* `stats`, so a
    `statsRev` stall >5.5 s is real evidence (the only service that can be
    proven down). Evidence caption shows the measured frame gap.
  - pipewire / NetworkManager / bluetoothd — `up` when the name appears in
    `procN_name`, else `unknown` (absence from a top-6 is not proof of death —
    never reported "down" on a guess).
- **PERF** sparkline: Canvas, three series (cpu busy %, mem used %, gpu busy %),
  120-frame ring buffer sampled strictly on `Topology.statsRev` — **no timers**.
  cpu busy = `/proc/stat` `cpu_idle`/`cpu_total` jiffy delta between frames;
  mem = `mem_total/mem_avail`; gpu = first present of `i_util`/`a_util`/`gpu_util`.
  NaN samples are skipped segments, not zeroes. Legend shows live last values.
- **NET** rx/tx live bars: `net_rx`/`net_tx` cumulative counters ÷ measured
  wall-clock frame gap → B/s, bars scale to session peak (peak shown).
- **TOP PROCS**: `procN_name`/`procN_cpu` snapshot rows with % bars (≥90 % alert).
- **HOST**: 15-row vitals list (uptime, load, mem/swap/zram, cpu temp/mhz/cores,
  fs %, disk r/w Bps, PSI, theme, gh unread, agents, pkg updates, bat0, weather)
  — each row binds on `stats` through a key lookup (`hostVal`), so every frame
  refreshes the text.

## Honesty notes
- The only Timer in OpsView is the 2.5 s staleness watchdog that detects a dead
  collector — required to prove "down" — and it runs only while the OPS tab is
  active. The sparkline/feed/rates all sample on `statsRev` per spec.
- Journal forks are throttled to every 3rd stats tick and only while visible.
- Feed rows that lose their keys mid-stream emit nothing (guarded diffs).

## Verify
```
$ /usr/lib/qt6/bin/qmllint BoardView.qml OpsView.qml   → exit 0
  1 warning: OpsView.qml onExited — QProcess::ExitStatus is unresolvable in
  Quickshell's qmltypes; fires for ANY onExited handler (same as the repo's own
  `onExited:` sites). Cosmetic.
```
Runtime smoke (real `qs` runtime, offscreen, `qs -p <harness>`):
- `OpsView` standalone + `active` flip → **Configuration Loaded**, journal
  Process spawned, zero qml WARN/ERROR in `log.qslog`.
- `BoardView` with `viewTab` flipped 0→1 mid-run → **Configuration Loaded**,
  clean log. A latent `font.pixelSize: 8.5` int-assignment bug was caught and
  fixed by this harness before sync.
