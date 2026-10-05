# BRIEF-V4-BUILD — nexuslink.hud v4 "Chrome Cybercore"

Locked direction: `candidates/mock2/B/` (chrome cybercore). Operator approved DP-1, DP-2, HDMI-A-3, navigator.
Read before writing a line: `BRIEF-V4-COMMON.md`, `recon/devices-bus.json`, `recon/navigator.md`, `recon/tte-engine.md`, `recon/v3fix-report.md`, `PLAN-V4.md`, and your screen's mock under `candidates/mock2/B/`.

## Non-negotiables (the gate will check these)

1. **Knot logo.** Exact 48×49 source matrix (copy from `candidates/HudV3.qml` `KnotMark`), always lit ~50% alpha idle (idleA 0.56 × mark opacity 0.9), effects land back on the lit base state, pause() settles to base — the v3fix mechanics are the floor, keep them.
2. **Reactor.** True circle centred on the SCREEN (`width/2`, `height/2` of the monitor window, not free space), dark glass backing disc + layered drop shadow behind it so the knot at 50% never drowns the readout.
3. **No fabricated telemetry.** A key the collector does not emit renders as an explicit unknown glyph (`—` or `?`), never 0, never a fake value. All new collector keys prefixed `dev_`.
4. **CPU budget.** No global animation clock, no always-on Canvas repaint, no permanently dirty ShaderEffect. Repaint only on telemetry delta or explicit effect trigger. Idle target ≤15% of one core (v3 baseline measured 76.4%).
5. **Input mask discipline.** Only drawn regions join `mask:`; a region must NEVER drop mid-gesture (the v3 "nothing movable" bug — `masked: shown` for the whole gesture, self-healing `gestureStale()` on fresh presses). Overlay scrims join the mask only while open.
6. **Fonts.** Michroma for display numerals/titles, Kode Mono for data/body. Installed at `~/.local/share/fonts`; load via `FontLoader` with fallback chain `Kode Mono, monospace`. Never Adwaita Sans / JetBrains Mono.
7. **File ownership.** Write ONLY inside your lane's paths. Import neighbours' modules by the contract below, never by copying their internals.

## File layout (ownership)

```
v4/
  Style.qml          + qmldir singleton        — lane S
  Theme.qml          (fonts, palette, easing)  — lane S
  GlassPane.qml EmbossedTile.qml Tag.qml ScanOverlay.qml — lane S
  KnotField.qml      (pixel-knot + TTE-derived effect engine) — lane S
  Topology.qml       (singleton: node/edge registry) — lane T
  FlowBus.qml        (throughput → particle events) — lane T
  HudV4.qml          (screen windows, mask, layout, IPC) — lane H
  CommandHub.qml     (DP-1)                    — lane D1
  BoardView.qml      (DP-2)                    — lane D2
  Workbench.qml      (HDMI-A-3)                — lane D3
  UtilityDock.qml    (shared dock strip, owned by lane D1, imported by D3)
  Navigator.qml      (overlay + IpcHandler)    — lane N
collector/src/main.rs + src/devices.rs (new)   — lane C
```

## Contracts

**Style singleton** (`Style`, `Theme`): exposes `c` (colors: bg `#0b0e11`, pane `glass rgba(255,255,255,0.05)`, edge `#2a3138`, accent `#c8f31d` acid-lime, accent2 `#8fd8e8` ice, warn, unknown `#5a646c`), `f` (font families/pixel sizes), `r` (radii), `shadow(color, blur)` helper, `easing` curves. Components: `GlassPane` (rounded rect, 1px gradient edge, inner glow, optional `busy` border), `EmbossedTile` (neumorphic: top-light edge + bottom shadow), `Tag` (F-key chip), `ScanOverlay` (static scanline texture, painted once).

**Topology singleton**: `nodes` (dict id → {id, kind, label, temp, load, power, link, state, extra}), `edges` (list of {a, b, kind, bw, active}), `flows` (id → bytes/s), `refresh()` populates from stats keys + `recon/devices-bus.json` static scaffold, `unknown` sentinel. Kinds: cpu, ccd, core, gpu, mem, dimm, bridge, nvme, part, usb, nic, audio, disp, bt, smbus, fabric.

**HudV4.qml**: three PanelWindows (one per screen, WlrLayer.Background, ExclusionMode.Auto, mask=drawn regions only), `stats` ingestion identical to v3 `applyFrame`, layout persistence to `hud-state-v4.json` (new file, do not migrate v3), IPC target `nexuslink.hud` keeping `status`/`panels`/`say`/`move`/`show`/`hide` + new `nav` passthrough, `version "v4"`.

**Navigator**: `Navigator.qml`, own PanelWindow `WlrLayer.Overlay`, `keyboardFocus: navOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None`, namespace `nexuslink-nav`, scrim dismiss, sections FILES/PROCESSES/DEVICES/AGENTS/REPOS/USAGE (F1–F6), `FolderListModel` files (Enter descend, Backspace/Left up, `/` or type to filter, Esc clears then closes, breadcrumb, preview pane with bounded reads ≤64KB text only), IPC `nexuslink.nav` open/back/close/state per `recon/navigator.md`. execArgv only — never raw shell string concat for paths.

**Collector (lane C)**: add `devices.rs` emitting `dev_core{i}_mhz`, `dev_core{i}_pct`, `dev_ccd{0,1}_t`, `dev_dimm{i}_t`, `dev_gpu{i}_{temp,pct,pw,mhz,vram}`, `dev_pcie_{bdf}_{gen,width}`, `dev_nvme{i}_{t,rd,wr}`, `dev_nic{name}_{up,rx,tx}`, `dev_usb_{vid:pid}_{name,batt}`, `dev_audio{i}_{name,sink,vol}`, `dev_bt_{paired,conn}`, `dev_fans{i}_rpm` when present. 1 Hz cadence, reuse existing key emission pattern. Missing hardware → key absent (never emit 0 for absent).

**Screens**: read `B/mocks/*.html` as the visual spec; QML structure need not mirror DOM but proportions, grid rhythm, and content must. CommandHub: F1–F10 tiles each = destination + one live insight line; bottom UtilityDock (media, DND/notifs, volume, mic, clipboard, capture, idle-inhibit, weather, reminders, updates, workspaces, night light, power profile, disk, downloads, theme) — every dock cell is a real launch/toggle action via existing Omarchy commands (see `recon/integrations-desktop.json`). BoardView: traced wiring topology from `devices-bus.json` (root complex → bridges → endpoints; USB tree to leaf devices; audio routes; displays), live vitals per node, flow-rate-driven edge particles ONLY while traffic nonzero, lens toggle LINK/HEAT. Workbench: workspaces+windows w/ focus actions, agent/session lane (Devin/OpenCode/Haze/claude procs + token ledger day/week/month), repos/CI strip, patch-bay endpoints column, and UtilityDock import.

## Verify per lane

`/usr/lib/qt6/bin/qmllint` exit 0 on every touched file; `qmlformat` normalized; collector `cargo build` green + `cargo test` if tests exist; write a `LANE-<id>-REPORT.md` listing claims + evidence (no claims without a command). Coordinator runs integration gate after merge: qmllint all, real `omarchy-restart-shell`, screenshots of 3 monitors, IPC probes, 60s CPU sample.
