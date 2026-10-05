# Omarchy HUD dedupe map v2 (rev 2026-10-05)

Folds in the independent verification (`evidence/01-ban-dedupe-verify.md`) and Marcel's
decisions. v1 preserved at `evidence/dedupe-map.v1-gowther.md`. v1's MAP rows held; its
REMOVAL LIST did not (27/39 ranges cut mid-construct). Changes: removal spec is now
ANCHOR-BASED (QML id / function name / case label; `~:` lines are hints only, builders
re-locate by anchor). Missed duplicates M1-M9 added as rows. Breakage B1-B7 folded in
as per-edit "refs to fix". Every anchor below was re-grepped live today.
Abbr (under `~/.config/omarchy/plugins/nexuslink.hud/v4/`): CH=CommandHub OPS=OpsView
BV=BoardView WB=Workbench UD=UtilityDock NAV=Navigator DB=DeviceBay; NO=medianotch/Notch.qml.

## Decision rule

The surface whose role owns the datum keeps it: CH (DP-1) = summary dial + entry-point
tiles; BV+OPS (DP-2) = hardware topology, per-component sensors, liveness feed/services;
WB (HDMI-A-3, incl. AppGrid/DeviceBay/UtilityDock) = ops/process/token/agents/devices
detail; medianotch = media. A state flag (tileHot) or pure router (openNav) is NOT a
duplicate. Dock cells = actions, no values.

## Decisions applied (orchestrator defaults pending Marcel's confirmation; each reversible)

D1 Agents: CH agents tile becomes the Hermes/CREW status surface (bots running/idle,
   HANDOFF item 6). WB AGENT SESSIONS keeps harness session/process detail. Values the
   tile would copy from WB (`devsess_count`, per-harness `ag_*_cpu`/`_procs`) are deleted
   from the tile, so the two show different datums.
D2 OpsView reduces to LIVE FEED + SERVICES: PERF, NET, TOP PROCS, HOST panes deleted
   WITH their sampler plumbing (samplePerf, pushHist, sampleNet, hostVal, call sites,
   hist/net props).
D3 Bar modules incl. nexuslink.taskbar: OUT OF SCOPE this pass (chrome, not dashboard).
   Notes column carries "bar:" overlap; no shell.json removals.
D4 Storage: CH storage/files tiles own mounts/fill%.
D5 Navigator = on-demand search/action overlay, not a dashboard: all its rendered lists
   are KEPT this pass, marked "(overlay) kept".
In-scope dashboards: CH | BV+OPS | WB(+AppGrid/DeviceBay/UtilityDock) | medianotch.

## Map

| # | Datum | Surfaces today (anchor, live) | Survivor | Dropped copies -> action | Notes / bar overlap |
|---|---|---|---|---|---|
| 1 | Token usage (tokens.json) | WB pane `TOKEN LEDGER` (~:1899); CH `tileInsight case "tokens"` (~:1127) + `tileFacts case "tokens"` chart/today/top (~:1511-1545); NAV `buildUsageRows` (~:923) | WB TOKEN LEDGER | CH tile -> deep-link, no value (`activateTile` already `openNav("usage")`) | overlay kept; shared data path `tokData` HudV4:85/336 untouched |
| 2 | Peripheral state (battery/conn) | DB `devs`+`tele()` (~:225/:263); BV `battOf()` rendered in `trayData()` (~:1462); CH `tileInsight case "devices"` bat tail (~:1076-1081) | WB DEVICES (DeviceBay) | BV: delete `battOf` + its sole `nv:` render; CH tile -> deep-link | bar: `omarchy.bluetooth/audio` overlap, out of scope (D3) |
| 3 | Device topology (tree/links/VID:PID) | BV usb leaf specs + `trayData()` pairs; NAV `buildDeviceRows` (~:766) | BV | none | overlay kept |
| 4 | Processes (top-CPU table) | WB `PROCESS LEDGER` (~:1640); OPS `procPane` (~:1113); CH `tileInsight/ case "procs"` + `tileFacts case "procs"` (~:1328) + dial `proc0_name` chip (~:2081); NAV PROCESSES | WB PROCESS LEDGER | OPS pane -> D2, but KEEP its `procRows` model - SERVICES + LIVE FEED events consume it; CH tile -> deep-link; chip -> delete | overlay kept; feed enter/exit events = transitions, kept |
| 5 | Agents / harness / sessions / crew | WB `AGENT SESSIONS` (~:1504); CH `tileInsight/ case "agents"` + `tileFacts case "agents"` (~:1363); OPS HOST row + feed AGT delta (~:443); NAV `buildAgentRows` (~:790) | split per D1: WB = harness sessions detail; CH tile = crew status | delete `devsess*`/`ag_*_cpu` values from CH insight+facts cases; OPS row -> D2; `tileHot agents` kept (state) | overlay kept; bar: `omarchy.agents` = provider lane, out of scope; later bar crew module must reuse this tile |
| 6 | NET aggregate rates | CH dial R/W line (~:2063) + dial NET ring (`aNet` ~:1833); CH `tileInsight/`+`tileFacts case "network"` (~:1419); OPS `netPane`+`sampleNet`; BV eth tray rx/tx `ns:` (~:1387) | CH dial | OPS -> D2; CH network tile -> deep-link (activation toggles bar = action, fine); BV tray: drop rx/tx `ns:` line | bar: `omarchy.network` out of scope |
| 7 | NET link state/speed | dial R/W-line tail "enp15s0 up/link lost"; BV `case "nic_eth"` state; `tileHot network` | BV | tail deleted with 6's line rewrite; `tileHot` kept | B6 resolved |
| 8 | CPU/MEM/GPU busy % (aggregate) | CH `heroNum` (~:1965) + MEM line + rings; OPS `perfPane`+history (~:873, ~:908) | CH dial | OPS -> D2 incl. sampler (B2) | bar: `omarchy.monitor` out of scope |
| 9 | Component temps/power | BV k10temp/DIMM/gpu/nvme cases + `trayData()` TEMP/POWER + CPU-package Tctl (~:2748); CH dial temp line (~:2043); CH storage insight worst-nvme; OPS HOST cpu | BV | CH dial line deleted (also M6); storage insight rewritten without nvme-temp probe; `tileHot storage` heat kept; OPS -> D2 | v1's "temp tail" mislabel (ban) fixed: it was a whole `case` rewrite |
| 10 | Disk throughput | CH storage `tileFacts` io row; BV nvme/flash per-device flows; OPS HOST disk | BV (per-device) | CH row deleted in `tileFacts` rewrite; OPS -> D2 | - |
| 11 | Mounts / fill % | CH `tileInsight case "files"` + `mountRows()`/`tileFacts` files+storage cases; UD `cellValue case "disk"`; OPS HOST fs; NAV mounts sidebar | CH storage/files tiles (D4) | UD -> action-only (drop value/sub/meter, keep jump); OPS -> D2; BV partition label keeps name not pct | overlay kept; no WB storage pane exists - CommandHub owns it per D4 |
| 12 | Windows/workspaces | WB `WINDOWS / WORKSPACES` (~:1274) + `mastCounts` foot counts (~:1150); UD `cellValue case "ws"` (~:320); NAV files n/a | WB pane | WB foot text -> drop WS/WINDOWS counts (keep PROC slots); UD -> action-only: drop ws value, delete `wsIdLine()` | bar: `omarchy.workspaces` + in-repo `nexuslink.taskbar` overlap = out of scope (D3) |
| 13 | GitHub activity | WB `GITHUB ACTIVITY` (~:1774, `ghUnread` ~:504); CH repos `tileInsight`+`tileFacts` (~:1094/~:1398); OPS HOST gh; feed gh delta (~:400, event=state, kept) | WB pane | CH repos tile -> deep-link (`openNav("repos")` exists); OPS -> D2 | overlay kept; NAV REPOS = local git status, different datum |
| 14 | Clock | CH `mastClock` (~:709) + dial line clock concat (~:2072); WB `mastClock` Text (~:1159-1167, `clockText` :761) | CH mast | CH dial line -> uptime-only rewrite; WB whole `mastClock` Text deleted (v1 range left `Text {` opener) | bar: `omarchy.clock`+centerAnchor = chrome, kept. BV/OPS/Notch clock-free (verified) |
| 15 | Uptime/load | CH `mastUp` (~:718-729); dial load line `loadText` (~:2033, M8) + uptime line (~:2072); CH `tileInsight case "system"` tail + `tileFacts` uptime/psi row; OPS HOST rows; OPS `feedTs()` (~:184) | CH dial face (uptime+load lines ~:2033/:2072) | CH mast `mastUp` deleted + `mastRight` width ref fixed (B1); system-tile tail/row deleted; OPS -> D2 | M7: `feedTs` KEPT, annotated - functional event stamp, not a readout |
| 16 | Media now-playing | NO `text: root.title` (~:568), artist (:579), progress (:80), collapsed-pill marquee `pillLabel` (:845-847); CH `tileInsight/ case "media"` + `tileFacts` (~:1487-1510); UD `cellValue case "media"` + `MediaCell {}` host (~:931) | medianotch | CH media tile -> action-only (transport via F8 poller); UD -> drop media value/sub/artUrl text, keep transport click | bar: `omarchy.media` out of scope; v1 pill range short (real ~:786-864), fixed |
| 17 | Weather | CH `mastWx` (~:700); UD `wthr` cell: registry + `cellValue`/`cellSub` cases + `wthrShort()`+`wthrCity()`; OPS HOST wx | CH mast | UD cell deleted fully (B4-safe via anchors); OPS -> D2 | bar: `omarchy.weather` out of scope |
| 18 | Pkg updates | CH `tileInsight case "system"` + `tileFacts` pkg row + `tileHot`; UD `cellValue case "upd"`; OPS HOST pkg | CH system tile | UD -> action-only (keep `activate` update trigger); OPS -> D2; tileHot kept | bar: `omarchy.system-update` out of scope |
| 19 | Device battery (bat0) | folded into rows 2/15 | WB DEVICES | CH bat tail with 2; OPS bat row with D2 | cross-cutting pin |
| 20 | "HOST · raw stats keys" dump | OPS `hostPane`/`hostRows` (~:1218-1221) via `hostVal()` (~:585) | (none - all 15 rows mapped to other survivors) | pane + `hostVal` deleted per D2. v1 "swap/zram/psi/theme have no other surface" WRONG (ban): zram=M1, psi=M2, theme=M3 rows below; SWAP truly sole -> dies with pane unless Marcel re-homes it | biggest single dup source |
| 21 | M1 zram ratio | CH dial MEM line zram tail (~:2053); BV mem-node tray zram tail (~:1274); OPS HOST zram | CH dial MEM line | BV: drop " · zram ×" tail from that `nv:` binding; OPS -> D2 | - |
| 22 | M2 PSI | BV datafabric `ns:` psi (~:1270) + pkg Tctl line psi (~:2748); CH `tileFacts` system uptime/psi row; OPS HOST psi | BV | CH psi deleted with row 15's facts edit; OPS -> D2 | - |
| 23 | M3 theme name | UD `cellValue case "theme"` (~:338); OPS HOST theme | CH system tile (new sole home) | UD theme cell deleted; OPS -> D2; ADD theme row to CH `tileFacts case "system"` | - |
| 24 | M4 power profile | CH `tileFacts` power-profile row (~:1556) + insight tail; UD PWR cell (`case "pwr"`) | CH system tile | UD pwr value deleted, `activate` power toggle kept; CH insight tail deleted with 15 | - |
| 25 | M5 sink/mic volume | CH `tileFacts case "media"` sink-vol/mic rows (~:1498-1507); UD `case "vol"`/`case "mic"` (`volFrac`/`micFrac`, `cellBar`); BV per-sink `volOf()` | split: BV = per-device audio state (device detail); UD VOL/MIC cells = machine-level controls | CH rows deleted with 16; UD -> drop % value lines + `cellBar` vol/mic branches, keep mute-toggle actions (`cellHot` mute state kept) | BV `volOf` kept |
| 26 | M6 cpu_temp | CH dial temp line (~:2043); BV k10temp + Tctl (~:2748); OPS HOST cpu | BV | CH line deleted (= row 9 drop); OPS -> D2 | heroNum = busy %, not temp |
| 27 | M7/M8 load + feed timestamps | see rows 15/20 (`feedTs`, dial `loadText` line, BV Tctl load1) | CH dial | mast copy deleted (B1); BV load1 stays inline (per-node telemetry, flag if Marcel disagrees) | - |
| 28 | AI CENTER entry count | CH `aiKey` (~:2131); NAV jump-pin = label only (~:406) | CH aiKey | none (router, not duplicate) | v1 ruling stands |

## Removal list - anchor-based; one builder per file; the 5 files are DISJOINT (no file appears in two builders' sets; run in parallel or any order)

Locate every construct by the quoted anchor (grep it; verified live today), delete/rewrite
the WHOLE balanced block. Within a file, work bottom-up so hints stay valid until reached.

### Builder 1 - CH CommandHub.qml
- DELETE block `Text { id: mastUp ... }` (~:718-729). REF TO FIX: `mastRight.width`
  (~:694) contains `mastUp.width` - rewrite same pass (B1).
- `tileInsight(id)` REWRITE cases: `"procs"`,`"devices"`,`"repos"`,`"network"`,`"media"`,
  `"tokens"` -> no-value/deep-link string; `"agents"` -> crew-status (D1; deletes
  `devsess_count` + `ag_*_cpu` reads); `"storage"` -> root % only (drop nvme-temp probe);
  `"system"` -> pkg/profile only (drop uptime/load head + bat tail). KEEP `tileHot(id)` unchanged.
- `tileFacts(id)` REWRITE by case anchor: `"procs"`,`"agents"`,`"repos"`,`"network"`,
  `"tokens"` -> action-only rows; `"media"` -> transport rows minus vol/mic (25);
  `"files"`/`"storage"` keep mount/pct rows, drop io-rate row; `"system"` drop uptime/psi
  row + kernel/power rows stay per 18/24, ADD theme row (23). REF: `mountRows()` kept.
- Dial face: DELETE temp/GPU line (`text: "CPU <b>" + ... cpu_temp ...`, ~:2043); MEM
  line (~:2053) keeps zram (21); R/W line (~:2063) -> rates only, drop enp15s0 tail (7);
  uptime line (~:2072) -> drop `clockText` concat (14); top-proc chip: the Text block
  whose `visible:`/`text:` reference `proc0_name` (~:2081-2082) -> delete those bindings
  or the whole Text if it becomes empty. REFS: `linkOk` still used by `tileHot network`;
  `clockText` prop (:307) still used by `mastClock` - keep.

### Builder 2 - OPS OpsView.qml
- DELETE panes bottom-up by id anchor: `hostPane` (~:1218), `procPane` (~:1113),
  `netPane` (~:999), `perfPane` (~:873). KEEP `feedPane` (~:650), `svcPane` (~:790).
- DELETE plumbing (D2): `hostVal()`, `samplePerf()`, `pushHist()`, `sampleNet()`, props
  `histCpu/histMem/histGpu/histRev`, `rxRate/txRate/rxPeak/txPeak/_prevRx/_prevTx/
  _prevNetMs`, their calls in the 1 Hz tick (`samplePerf();` `sampleNet(now);` ~:466-467),
  net accessors (`peakOf`-style helpers reading rxPeak). (B2)
- KEEP: `procRows` + top-proc model builder + `svcProcs`/`applySvc`/`svcDef`/`feedTs`
  (B7: feed+services consume procRows; the pane is gone, the model stays). Annotate
  `feedTs()` as uptime-derived (M7).
- REF TO FIX: `hostPane` leftover-height line `Math.max(60, rail.height - svcPane.height
  - perfPane.height - netPane.height - procPane.height ...)` (~:1220) - disappears with
  the pane, but the rail Column must still lay out: after all four blocks are gone, no
  id refs remain (grep `perfPane|netPane|procPane|hostPane` must return 0). Do NOT
  partial-delete (B3).

### Builder 3 - UD UtilityDock.qml
- Per-cell edits, all inside switch funcs `cellValue(id)`, `cellSub(id)`, `cellBar(id)`,
  `cellHot(id)`, `cellState(id)`, `cellDotColor(id)` - delete/neutralize these case anchors:
  `"wthr"` (DELETE cell: registry `{ id: "wthr" }`, `compactIds` token ~:40, all switch
  cases, funcs `wthrShort()`, `wthrCity()` - B4: do not touch `wsIdLine()`, kept until
  the ws edit), `"theme"` (DELETE cell: registry + compactIds token + cases), `"pwr"`
  (value only: registry KEPT, cases in value/sub deleted; `activate` toggle kept),
  `"upd"`/`"ws"`/`"disk"` (value only: cases in `cellValue`/`cellSub` deleted;
  `cellBar` disk meter branch deleted; `wsIdLine()` deleted; actions kept), `"media"`
  (cases in value/sub; `MediaCell {}` host block: artUrl/label binding kept for controls
  or drop title text; keep transport `activate`), `"vol"`/`"mic"` (value % lines in
  `cellValue` + `cellBar` frac branches; `cellHot` mute STATE kept).
- REFS: `mediaArtUrl` (~:247) becomes unused if art binding dropped - delete or keep
  inert; `volFrac/micFrac` still feed `cellHot` mute state - keep the poller (~:860).

### Builder 4 - BV BoardView.qml
- DELETE `battOf()` func + the single `nv: "batt " + vB(battOf(n))` render (~:1462) (2).
- `case "nic_eth"` tray (~:1381): DELETE the `ns: "rx ... tx ..."` line (~:1387); keep
  `nv:` state/speed line (6/7).
- mem-node tray binding (~:1274): drop the `" · zram " + ss("zram_ratio") + "×"` tail (21).
- KEEP: psi strings (~:1270/~:2748), temps, `volOf()`, `partOf()` names.

### Builder 5 - WB Workbench.qml
- DELETE `Text { id: mastClock ... }` block (~:1159-1167; v1 range left the opener).
  `clockText` prop (:761) then has no consumer outside the 1 Hz tick comment - delete prop
  or leave inert; the tick also ages the token pane, so delete ONLY the prop+Text if grep
  confirms no other `clockText` use (it has none: sole render).
- REWRITE `mastCounts` foot `text:` (~:1150) to drop `wsCount`/`winCount`, keep PROC slots.
- KEEP all other panes (survivors 1/4/5-detail/12/13). The HANDOFF "DEVICES always
  visible" tab-strip task (`rightTab`/`tabStrip` ~:278/:2197) is a DIFFERENT lane; this
  pass touches neither.

### Untouched
NO Notch.qml (16 survivor), DB DeviceBay.qml (2), NAV Navigator.qml (D5 kept - B5 moot:
`tokFile.reload()` refs at ~:1002/~:1299 stay valid), Topology.qml, HudV4.qml,
tokens/ledger.py, AppGrid/KnotField (ban-verified clean), shell.json + taskbar (D3;
bar overlaps noted in rows 2/4/5/6/8/12/14/16/17/18 for a future shell.json pass).

## Breakage notes (B1-B7 disposition)

- B1 mastUp: two-part edit in Builder 1 (construct + `mastRight.width` ref). ADDRESSED.
- B2 perf sampler: OPS plumbing deletion listed explicitly. ADDRESSED.
- B3 rail height math: four panes deleted bottom-up in ONE pass; post-check greps for
  surviving pane ids. ADDRESSED (no partial order allowed).
- B4 weather span: anchor-based (registry/cases/`wthrShort`/`wthrCity`), `wsIdLine()`
  preserved. ADDRESSED.
- B5 Navigator orphan: moot under D5 (kept). NOT BUILT.
- B6 dial link-state tail: explicit rates-only rewrite; state survives on BV + tileHot.
  ADDRESSED.
- B7 procPane residue: anchor deletion of whole `procPane` block; `procRows` kept on
  purpose. ADDRESSED.
- Watch: QML hot-reloads on save - each builder finishes its file in one pass; a
  half-rewritten switch case renders binding errors live on the desktop. Verify with
  `quickshell` reload + eyeballing each deck, and re-grep deleted ids for zero refs.
- Swap (row 20): only datum with no survivor anywhere after OPS deletion; open for
  Marcel if he wants it re-homed, otherwise accepted loss.

Every in-scope datum has exactly one survivor: WB (1,2,4,5-detail,12,13) | CH (6,8,11,14,
15,17,18,21,23,24,26-owner-dial-lines,5-crew) | BV (3,7,9,10,22,25-device,26,27-load-inline)
| OPS (services/feed) | medianotch (16). Rows 5/11/12 resolved by D1-D4; no open
needs-Marcel flag remains except the swap loss note above.
