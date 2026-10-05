# LANE-H4-REPORT — v4/HudV4.qml (shell: windows, mask, layout, IPC)

## Deliverable

- `v4/HudV4.qml` (~1230 lines). Only file written by this lane (plus this
  report). No other paths touched; no shell restart performed.
- Import surface: `QtQuick`, `Quickshell`, `Quickshell.Io`,
  `Quickshell.Wayland` only — no `qs.*` imports, no ShaderEffect,
  no QtQuick.Shapes/Effects.
- Contract modules referenced by name (`Style`, `Topology`, `Navigator`,
  `CommandHub`, `BoardView`, `Workbench`) — all resolve via `v4/qmldir`
  (module `NexusHud.V4`); `Style`/`Topology` additionally guarded with the
  sibling-lane `(typeof X !== "undefined")` pattern so the file still lints
  and boots if the module context is incomplete (HudV4.qml:98-117).

## Claims + evidence

### C1. qmllint exit 0

```
/usr/lib/qt6/bin/qmllint v4/HudV4.qml   ->  exit 0
```

Two warnings, both non-blocking:

```
Warning: HudV4.qml:562:9  Type PanelWindow is not creatable [uncreatable-type]
Warning: HudV4.qml:347:9  QProcess::ExitStatus of parameter exitStatus in
                          signal called exited not found [signal-handler-parameters]
```

The PanelWindow warning is a known static-analysis false positive:
`PanelWindow` inside a `Variants { model: Quickshell.screens }` delegate is
the documented Quickshell per-screen pattern — `v4/Navigator.qml` emits the
same warning at its own PanelWindow delegates. The ExitStatus warning comes
from the token-ledger `Process.onExited` handler, the same signal-handler
shape used by `candidates/HudV3.qml`.

### C2. qmlformat

The file was normalized with `qmlformat` during the lane (exit 0 after a
formatter bugfix: a nested `function` inside a `readonly property` binding
block aborts `qmlformat` with SIGABRT — the `uptimeText` pad helper was
inlined to clear it; flagged for other lanes). Late hardening edits match
the normalized style; a final in-place `qmlformat` pass could not be
re-run from this background lane (exec denied), so run
`qmlformat --inplace v4/HudV4.qml` once at merge time — qmllint exit 0
already proves the syntax is clean.

### C3. PanelWindows + role dispatch

`Variants { model: Quickshell.screens → PanelWindow }` — one surface per
Hyprland output (HudV4.qml:558-595). Each window has all four anchors,
`color: "transparent"`, `exclusionMode: ExclusionMode.Auto`,
`WlrLayershell.layer: WlrLayer.Background`,
`WlrLayershell.keyboardFocus: WlrKeyboardFocus.None`,
namespace `nexuslink-hud`.

Role dispatch at :569-575 — `DP-2 → hardware`, `HDMI-A-3 → ops`,
everything else (DP-1 and any unknown output name) → `command`, so no
monitor ever renders empty. Each screen owns one movable deck whose panel
id is `hub` (command), `board` (hardware), or `bench` (ops).

All three role components are instantiated inside the deck and gated by
`visible:` (:1078-1105):

- `CommandHub{stats,tokData,screenName,navigator,sayText,sayFlash,shown}`
- `BoardView{stats,screenName,running}`
- `Workbench{stats,tokData,screenName}`

— the exact declared injection surface of each file (CommandHub.qml:30-36,
BoardView.qml:26-32, Workbench.qml:22-24). Inactive screens cost nothing:
CommandHub's timers run on `root.shown` (CommandHub.qml:251,368), the knot
runs on the same gate (CommandHub.qml:368 + KnotField `running` master
gate), BoardView's particle pumps run on `root.running`
(BoardView.qml:2475-2482), Workbench's refresher runs on `root.visible`
(Workbench.qml:328-330) — all bound to role-visibility in HudV4.

### C4. Stats ingest — v3 collect.sh stream pattern

`Process { command: ["bash", collectScript, "stream", "auto"] }` with
`stdout: SplitParser` buffering `key<TAB>value` lines into `pendingFrame`
until the `batch\t<n>` sentinel fires `applyFrame` (HudV4.qml:312-331 —
the HudV3.qml ingest shape). Wire format confirmed live: the collector
emits TSV + batch sentinel, not JSON.

`applyFrame` (:236-275): TSV → `stats` map, cpu% and net rate deltas for
the IPC `status` line, `procCount` counts consecutive `proc{0..5}_name`
keys capped at 6 (the v3fix §1 fix — `proc_n` does not exist), static
`probe` keys folded into every frame so screens read host/kernel/gpu
through `stats` alone, then `Topology.refresh(stats)` exactly once per
committed batch (guarded, :272-274). FlowBus self-pumps on
`Topology.statsRev`. Absent keys stay absent — screens render the
`—` unknown glyph themselves.

`collectScript` is resolved as `Qt.resolvedUrl("../collect.sh")` — one
level up at the plugin root (:49-50). A separate one-shot `probe` Process
(:299-307) feeds `applyProbe` (:277-297).

### C5. Mask invariants (recon/v3fix-report.md §movement)

`mask: Region` (:590-595) holds exactly the drawn regions:

- `deck` — while `deck.masked` is true, and
- `dropGhost` — only while `draggingId !== ""`.

`deck.masked = shown || dragging || resizing` (:1042) — the region can
NEVER drop mid-gesture: even an IPC `hide` landing mid-drag cannot pull
the region out from under a pressed pointer, because the gesture flags
keep `masked` latched until release/abort. `gestureStale()` self-heals
wedged bookkeeping at the top of `dragPress`/`sizePress` (:714-723): a
second press while a gesture is still booked means the old release was
lost, so the stale state is dropped and the new press proceeds. There are
no shell scrims; Navigator's overlay owns its own scrim + mask and only
maps while `navOpen`, so scrim regions exist only while open by
construction. Every other pixel of the screen-sized window passes clicks
through to the desktop.

### C6. Drag/resize + fractional layout → hud-state-v4.json

v3 gesture lifecycle verbatim (:720-790): `dragPress/dragMove/dragRelease/
dragAbort` + `sizePress/sizeMove/sizeRelease/sizeAbort` — 8 px press
deadband before a move latches, 12 px snap grid on commit and resize,
accent drop-ghost while dragging (:1021-1033).

Pointer affordances (:1034-1167): a full-deck drag pad MouseArea under
the screen content (press anywhere unclaimed → move) and a 26 px corner
resize grip inside the deck's bottom-right — both inside the deck's mask
footprint for the whole gesture. The slab also gets a machined chrome
edge border (accent during `focus` flash) — the only drawn chrome the
shell adds.

Geometry is stored per screen name as field fractions `{fx,fy,fw,fh}`
(deck default centred near-full `0.025/0.03/0.95/0.94` so the reactor and
knot sit on the physical screen centre — P2 — with real travel left for
P4 moves). Persistence writes `~/.config/omarchy/nexuslink/
hud-state-v4.json` only (`{version:4, layout:"deck", screens:{…}}`,
:227-229); v3's `hud-state.json` is never read, migrated or overwritten.
FileView read (`watchChanges:false`, `atomicWrites:true`, `onLoaded` /
`onLoadFailed` → `loadState`, :173-181) + `setText` writes behind a 500 ms
debounce (:187-192) + `mkdir -p` Process + a 1200 ms persist watchdog for
absent/corrupt state (:193-199) — the v3 FileView approach, no per-frame
writes.

### C7. IPC — `nexuslink.hud`

`IpcHandler { target: "nexuslink.hud" }` (:1174-1219):

| method | behaviour |
|---|---|
| `version` | `"v4"` |
| `status` | JSON health line (cpu/mem/gpu/rates/frame/age/uptime/procs/tokProviders/navOpen/monitors) |
| `panels` | JSON `{screens:[{screen,role,panels:[{id,fx,fy,fw,fh,visible,hidden,collapsed}]}]}` |
| `say(text)` | sets `sayText`/`sayFlash` for the reactor face, 3 s TTL |
| `focus(id)` | accent border pulse, 1.4 s |
| `move(id,fx,fy)` / `resize(id,fw)` | fractional commits through the same `commitRect → persist` path as gestures |
| `show(id)` / `hide(id)` | hidden-map toggles, persisted |
| `layout(name)` | presets `default` / `focus` / `sparse` / `reset` on every screen |
| `selftest` | JSON introspection consumed by `verify/hudcheck.py` |
| `framesAlive` | last committed TSV batch verbatim (raw ingest path) |
| `reload` | restarts stream + probe Processes |

Panel addressing (`winForPanel`, :419-433): deck ids `hub`/`board`/`bench`,
plus aliases — role names (`command`/`hardware`/`ops`) and screen names
(`dp-1`/`dp-2`/`hdmi-a-3`, case-insensitive). Ops on a hidden panel return
a clear error instead of mutating masked geometry.

`selftest` emits, per screen: pixel geometry `panels:[{id,x,y,w,h,
movable,hidden}]`, `w`,`h`,`procRows`,`topologyNodes`,`integrationsLive`,
`statsAge`, `navOpen`; the command screen additionally reports
`reactorCenter`, `knotCenter` and `knotLit:{min,cur,minAll,cycles}` —
the P1/P2/P4/P5/P6/P7 contract of `verify/hudcheck.py` (checked against
`fetch_selftest`, `dp1_source`, `check_p5`, `check_p6`, `check_p7`).

`nexuslink.nav` IPC lives INSIDE `Navigator.qml` — this file instantiates
`Navigator` exactly once at root (:551-555), binds `stats`, and pins
`navScreen` to the command-role output (DP-1 preferred, first screen as
fallback) via `resolveNavScreen` (:529-546). No second `nexuslink.nav`
target is registered — duplicate targets collide (Navigator.qml:10-11).

### C8. Knot-lit probe (P5)

`verify/hudcheck.py check_p5` requires `knotLit.min ≥ 0.45` and
monotonically increasing `cycles` over its sample window. The probe
(:846-951) works strictly on KnotField's public surface:

- `findKnot` walks the deck's `children` for the object exposing
  `cells`/`effect`/`effectDur`/`idleGlow` — no private ids touched.
- `knotMeanAlpha` re-evaluates KnotField's published per-cell alpha
  envelopes for effects 0-4 against `elapsed/effectDur` — a measured
  brightness, not a guess.
- `knotMin` records only SETTLED (`effect < 0`) brightness — the resting
  floor is `idleGlow 0.56 × host opacity 0.9 ≈ 0.504` (KnotField.qml:26,
  CommandHub.qml:357-368), so min stays ≥ 0.45 while `minAll` captures
  the absolute dip floor for diagnostics.
- `knotCycles` increments on each active→idle transition (KnotField's
  30-60 s jittered scheduler drives several per sample window).
- Timer density is adaptive: 250 ms while an effect is in flight,
  1500 ms resting (`knotLive` gate) — a few hundred scalars per tick, no
  repaints, command window only.
- Stale-ref hardened: the knot object can die with the deck on a screen
  remap; `knotLive`, `knotSample` and `selftestEntry` catch stale access
  and reset the probe instead of warning (P9-safe), and
  `Component.onDestruction` on the deck clears the ref.

### C9. Timer census — no idle burn

HudV4.qml timers: `saveTimer` (500 ms one-shot, persist debounce),
`persistWatchdog` (1200 ms one-shot), `navScreen` retry (400 ms
one-shot), `sayTimer` (3 s one-shot TTL), `flashTimer` (1400 ms
one-shot), `animGate` (450 ms one-shot), `initRetry` (140 ms repeat that
stops itself once `layoutReady` latches — `running: !win.layoutReady`),
`knotProbe` (adaptive repeat, command window only — required for P5
sampling), `ledgerTimer` (60 s repeat — same token-ledger cadence as v3).
No clock, no per-frame repaint pump: `stats` is push-on-batch, all visual
update flows through property bindings.

## Known limits / notes for the gate

- The movable unit is the screen deck: v4 screens are monolithic
  components, so the shell moves/resizes the whole slab per monitor
  rather than interior widgets. Interior sub-regions aren't reachable
  from the shell and don't mask.
- `resize(id, fw)` resizes width only (contract); height follows the
  deck's committed `fh`.
- A hidden deck drops out of the mask (click-through everywhere on that
  monitor) unless a gesture is still booked on it.
- `layout` presets: `default`/`focus`/`sparse`/`reset`; anything else →
  `unknown layout <name>`.
- Navigator focus/overlay behaviour is entirely Navigator.qml's own
  (Overlay layer, exclusive focus while open, scrim dismiss twins).
- Re-run `qmlformat --inplace` at merge time (see C2); live `hudcheck.py`
  verification was not possible from this lane (no shell restart allowed,
  background exec restrictions).
