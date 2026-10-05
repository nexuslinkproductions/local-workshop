# LANE-D3-REPORT — v4/Workbench.qml (HDMI-A-3 workbench + patch bay)

## Deliverable

- `v4/Workbench.qml` (1379 lines). Only file written. No other paths touched.
- Imports: `QtQuick`, `Quickshell.Io` only. Contract modules (`Style`,
  `Topology`, `GlassPane`, `UtilityDock`) are referenced by name per
  BRIEF-V4-BUILD §Contracts and resolved at runtime once lanes S/T/D1 land.

## Claims + evidence

### C1. qmllint exit 0

Command:
```
/usr/lib/qt6/bin/qmllint /run/media/nexuslink/82CC5F65CC5F5311/Users/mikek/NEXUS_AI_CENTER/nexuslink.hud/v4/Workbench.qml > /dev/null 2>&1; echo $?
```
Observed: `0`.

Remaining warnings (all expected, none block):
- 2× `Unqualified access` at lines 29–30: the `typeof Style !== "undefined"`
  / `typeof Topology !== "undefined"` contract guards. Same pattern as the
  coordinator's `v4/lintprobe.qml`, which also exits 0 with the same warning.
- `GlassPane was not found` (11×), `UtilityDock was not found` (1×), and
  downstream `Cannot assign binding of type GlassPane to QQuickItem`
  (11×): parallel-lane modules not yet on disk. Lane S owns
  `GlassPane.qml`, lane D1 owns `UtilityDock.qml`. These resolve at
  integration.

Command:
```
/usr/lib/qt6/bin/qmllint .../v4/Workbench.qml 2>&1 | grep "^Warning" | grep -v "Unqualified access" | grep -v "was not found" | grep -v "incompatible-type"
```
Observed: empty output (no other warnings).

### C2. qmlformat normalized

Command:
```
/usr/lib/qt6/bin/qmlformat .../v4/Workbench.qml > /tmp/fmt2.qml && diff -q .../v4/Workbench.qml /tmp/fmt2.qml
```
Observed: `format stable` (file is byte-identical to qmlformat output;
qmlformat exit 0).

### C3. Visual spec conformance (candidates/mock2/B/hdmi.html)

Structure mirrors the mock (QML structure need not mirror DOM, proportions
and content do — BRIEF-V4-BUILD §Screens):

- Masthead: `WORKBENCH+PATCH BAY` title (Michroma, acid `+PATCH BAY`),
  `HDMI-A-3 · 1920×1200 · OPERATIONS LEDGER` sub, live counts
  (`N WS · N WINDOWS · N PROC SLOTS`), HH:mm:ss clock, holographic
  top-rim gradient (ice → magenta → acid → mint).
- Left column (56% width): WINDOWS/WORKSPACES panel (30% height),
  AGENT SESSIONS (17%), PROCESS LEDGER (16%), REPOS/CI (16%),
  TOKEN LEDGER (21%).
- Right column (44% width): NETWORK INTERFACES (16%), AUDIO ROUTES (19%),
  BLUETOOTH + PERIPHERALS (15%), DISPLAYS (15%), USB FABRIC (16%),
  LINK FLOWS (remainder).
- Bottom: `UtilityDock` strip (lane D1's component, `stats` passed through).
- Palette: graphite/ink panels, acid `#c8f31d` ticks before section titles,
  ice `#8fd8e8` values, `—` unknown glyph in `unknown` color. Fonts:
  Michroma display, Kode Mono body, loaded via `FontLoader` from `fonts/`
  with contract fallback chain.

Evidence: code structure at `v4/Workbench.qml` lines 309–end; mock at
`candidates/mock2/B/hdmi.html` lines 82–218.

### C4. Workspaces strip with live window lists and click-to-focus

- Workspace chips from `ws{i}_{id,name,mon,wins}` collector keys
  (recon/stream-keys.md §hyprland), sorted by id, this screen's workspaces
  highlighted with acid border. Click dispatches
  `hyprctl dispatch workspace <id>` via a dormant `Quickshell.Io.Process`
  pulsed `running: false → true` (v3 pattern, HudV3.qml line 2329 comment).
- Window cards from `win{i}_{addr,ws,wsid,class,title,mon}` (cap 12),
  this monitor's clients first then by workspace id (same sort as v3
  `winList`). Each card: thumbnail recess, title, class + short address,
  workspace badge, monitor label. Click dispatches
  `hyprctl dispatch focuswindow address:<addr>` (disabled when addr empty).

Evidence: `v4/Workbench.qml` `wsList()`/`winList()` (lines 140–175),
delegates with `Process { id: wsDispatch }` / `Process { id: focusProc }`
in the WINDOWS/WORKSPACES panel.

### C5. Agent/session lane

- Four harness rows (devin, opencode, haze, claude) from
  `ag_{id}_{procs,cpu}` keys. State pill: `LIVE ×n` (acid) when procs > 0,
  `IDLE` (dim) when 0, `—` (unknown color) when the key is absent. CPU
  column renders `—` when `ag_{id}_cpu` is absent.
- Devin row appends `ag_devin_acp` count + `devsess_count` session-lock
  count; both render `—` when absent.

Evidence: `v4/Workbench.qml` `agRow()`, `devinAcp`, `devsessCount`
(lines 177–187) and the AGENT SESSIONS panel delegates.

### C6. Token ledger day/week/month per recon/tokens.md

- Reads `tokData` (parsed `~/.local/state/nexuslink/tokens.json`, injected
  by HudV4) and renders one row per provider present, in fixed order
  devin/opencode/haze/claude/codex/fireworks.
- Cell format per tokens/SCHEMA.md: `in↓ out↑` via `fmtTok` (31.1M style),
  `· $cost` only when cost is a number (never `$0` for null), snapshot-only
  providers (in/out null) render `Σ total` and never sum in+out with total
  (SCHEMA.md line 47 rule). Empty bucket renders `—`.
- Empty ledger renders `— ledger: no local feed`.

Evidence: `v4/Workbench.qml` `tokCell()` (lines 108–125), `tokRows()` +
`tokRowCache` (lines 222–241), TOKEN LEDGER panel.

### C7. Repos/CI strip (real data per recon/integrations-dev.json)

- Streams the collector's GitHub slow-lane keys (`gh_ok`, `gh_unread`,
  `ghev_count`, `ghev{i}_{type,repo,age_s}` — recon/stream-keys.md lines
  39–40, the same feed integrations-dev.json item `github-prs-ci` ranks
  rank-5). Header shows `gh ok` / `gh unreachable` / `— gh unknown` and
  unread count (`— unread` when key absent). Up to 6 event rows with
  type chip, repo, age.
- Local git dirty/ahead/behind state (integrations-dev.json item
  `git-repos`) has no collector key today; nothing is fabricated in its
  place.

Evidence: `v4/Workbench.qml` `ghKnown/ghOk/ghUnread/ghevList()`
(lines 203–217), REPOS/CI panel.

### C8. Patch-bay endpoints column from Topology contract nodes

- Five `PatchSection` panels filter `Topology.nodes` by contract kinds
  (BRIEF-V4-BUILD §Topology): NETWORK INTERFACES (`netif`, `nic`), AUDIO
  ROUTES (`pw_sink`, `pw_source`, `audio`), BLUETOOTH + PERIPHERALS
  (`bluetooth`, `usb_bluetooth`, `usb_receiver`, `usb_keyboard`,
  `usb_camera`, `usb_storage`, `usb_rgb`, `input`), DISPLAYS (`disp`,
  `display`), USB FABRIC (`xhci`, `usb_roothub`, `usb_hub`).
- Each jack row: port LED (lit acid when `state` is `up`/`connected`),
  label, vital (first present of `link`/`temp`/`power`/`load`, else `—`),
  state text (else `—`).
- LINK FLOWS panel lists `Topology.flows` id → bytes/s via `fmtBytes`,
  `—` for non-numeric entries; empty state `— flow telemetry unknown`.
- While `Topology` is undefined (lane T in flight), every section renders
  its `— endpoints unknown` empty state. No fabricated rows.

Evidence: `v4/Workbench.qml` `topoRows()` (lines 246–279), `flowRows()` +
`flowRowCache` (lines 280–297), `PatchSection` component (end of file).

### C9. Process lane

- TOP process rows count consecutive `proc{i}_name` keys (cap 6), the
  v3fix-report defect-1 pattern (collector emits no `proc_n`). CPU bar
  scaled to 200% of one core (mock shows 99%/89%/70% values), `—` when
  `proc{i}_cpu` absent.

Evidence: `v4/Workbench.qml` `procCount` (lines 190–195), PROCESS LEDGER
panel.

### C10. No fabricated telemetry

Every collector-key read goes through `has()`/`num()` guards; absent keys
render the `—` glyph in the `unknown` color, never 0. Verified by
inspection of every `text:` binding: all conditional on key presence
(`agRow` procs/cpu use -1 sentinel → `—`; `devinAcp` -1 → `— acp`;
`ghUnread` -1 → `— unread`; topology vitals default `—`; token cells
default `—`).

### C11. No animation clocks; repaint on telemetry delta only

- No `FrameAnimation`, no Canvas, no ShaderEffect, no `NumberAnimation`/
  `Behavior` anywhere in the file. All bindings derive from `stats`,
  `tokData`, `screenName` — repaints happen only when HudV4 delivers a
  new frame.
- One 1 Hz `Timer` drives the masthead HH:mm:ss text clock (the mock's
  `16:47:31` furniture, line 88 of hdmi.html). It updates one `Text`
  binding per second; it is not an animation clock and drives no paint
  loop. This is the same `now` pattern v3 ships.

Evidence:
```
grep -n "FrameAnimation\|Canvas\|ShaderEffect\|NumberAnimation\|SmoothedAnimation\|Behavior " v4/Workbench.qml
```
Observed: exit 1, no matches (the only `Behavior` substring in the file is
the `pragma ComponentBehavior: Bound` header). `grep -n "Timer" v4/Workbench.qml`
→ one hit (the clock, lines 301–306).

### C12. Lane discipline

- Files written: `v4/Workbench.qml`, `v4/LANE-D3-REPORT.md`. Nothing else.
  Verified: `git status` not applicable (not a repo); `ls v4/` before/after
  shows only `lintprobe.qml` (pre-existing) plus the two lane files.
- No destructive operations, no shell restart, no edits under `~/.config`,
  no files deleted.
- `UtilityDock` imported by contract name only; no D1 internals copied.
- `Style`/`Topology` accessed through `typeof` guards with brief-specified
  fallback palette/fonts; no lane-S/T internals assumed beyond the
  published contract props (`c`, `f`, `nodes`, `flows`, node
  `kind/label/temp/load/power/link/state`).

## Known integration notes (for the coordinator)

1. `UtilityDock` props: this lane passes `stats: root.stats` and sets
   `width`. If D1's dock needs a different prop name, the single
   instantiation site is at the bottom of `layoutRoot`.
2. `GlassPane` usage: `width`, `height`, `busy: false`, and children
   filling via `anchors.fill: <paneId>`. If lane S's GlassPane clips or
   pads content, the body columns use `anchors.margins: 12`.
3. The clock timer is the only self-triggered repaint source; delete the
   `Timer` + `clockText` if the integration gate's CPU budget requires
   zero self-triggered repaints (the masthead clock would then freeze
   between telemetry frames).
