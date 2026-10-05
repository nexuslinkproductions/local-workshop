# NEXUS HUD v2 — full-screen telemetry cockpit

Rewrite `Hud.qml` into a full-screen, per-monitor desktop HUD inspired by
astralmon's `HudView.qml` (a C++/QML telemetry cockpit for an ASUS RTX 5090 —
reference source at `~/projects/astralmon/kde/wallpaper/org.astralmon.hud/contents/ui/HudView.qml`,
READ IT for visual vocabulary: concentric reactor dial, history sparkline
traces, threshold-driven palette flips, monospace everything, corner brackets).

Target aesthetic: cyberpunk cockpit — cyan `#00e5ff`/`#35e0ff`, poison-green
`#39ff14`, magenta `#ff2bd6`, amber `#ffb300` warn, red `#ff3b4e` alert. Text
`#c9f2fb`, muted `#5e93a6`, hairlines `#0d4a61`. Panels are dark translucent
(`Util.alpha(Color.background, 0.84)`) over a near-black grid wallpaper.

## Runtime contract (do not change)

- Omarchy shell **service** plugin. Entry file `Hud.qml`, root type `Item`.
- Injected properties: `property var shell: null`, `property var manifest: null`.
- Imports available: `QtQuick`, `Quickshell`, `Quickshell.Wayland`,
  `Quickshell.Io`, `Quickshell.Hyprland`, `QtQuick.Shapes`, `QtQuick.Effects`,
  `qs.Commons` (Util, Color), `qs.Ui` (Style, ScreenMoveRemap, BorderSurface).
- One `PanelWindow` per screen via `Variants { model: Quickshell.screens }`,
  `screen: modelData`, anchors all edges, `WlrLayershell.layer: WlrLayer.Bottom`,
  `WlrLayershell.namespace: "omarchy-hud"`, `exclusionMode: ExclusionMode.Ignore`,
  `WlrLayershell.keyboardFocus: WlrKeyboardFocus.None`,
  `visible: !remapGuard.remapping` + `ScreenMoveRemap { id: remapGuard; window: win }`.
- Input: `mask: Region { item: <the panel container> }` — ONLY drawn panels
  accept clicks; all other pixels must pass through to the desktop.
- Telemetry arrives via ONE persistent process per shell instance:
  `Process { command: ["bash", collectScript, "stream"] , stdout: SplitParser }`.
  `collectScript` resolves to `Qt.resolvedUrl("collect.sh")` stripped of
  `file://`. Stream emits `key<TAB>value` lines; a `batch\t<n>` line ends each
  frame (~1s cadence). Parse each frame into a `stats` map.
- `probe` mode (same script, arg "probe") emits static keys once: `host`,
  `kernel`, `gpu0_kind`/`gpu0_name`, `gpu1_*`, plus legacy `gpu_kind`/`gpu_name`.
- IPC: `IpcHandler { target: "nexuslink.hud" }` must keep functions
  `toggleAll()`, `refresh()`, `status()` (JSON string of key stats).

## Telemetry keys available in each stream frame

System: `uptime_s`, `load1/5/15`, `cpu_idle`, `cpu_total` (jiffies — compute
delta % in QML), `cpu_count`, `cpu_cores`, `cpu_core_0..23` (busy % per core,
0-100 int), `cpu_temp`, `mem_total_kb`, `mem_avail_kb`, `swap_total_kb`,
`swap_free_kb`, `disk_read_bps`, `disk_write_bps`, `fs_root_used/size/pct/target`,
`fs_home_*`, `net_rx`, `net_tx` (byte counters — compute delta rates in QML),
`agents_tmux`, `agents_procs`, `proc0..5_name` + `proc0..5_cpu` (top CPU procs).

Intel Arc (gpu0, keys `i_*`): `i_temp_pkg`, `i_temp_vram`, `i_temp_mctrl`,
`i_temp_pcie`, `i_vram_ch_max`, `i_vram_ch_avg`, `i_fan_rpm`, `i_pwr_w`,
`i_pwr_cap_w`, `i_vram_used`/`i_vram_total` (MiB), maybe `i_util`, `i_freq_mhz`.

AMD iGPU (gpu1, keys `a_*`): `a_util`, `a_vram_used/total`, `a_temp`,
`a_pwr_w`, `a_freq_mhz`.

## Layout spec — the whole screen is the canvas

Scale everything by `ux = Math.max(0.7, Math.min(width/1600, height/900))`.
Different monitors have different sizes; all panels must lay out
proportionally, never overlap, never exceed bounds.

- **Frame**: hairline border inset ~12px with drawn corner brackets (L-shapes
  at each corner), a subtle scanline/vignette texture optional. Alert state
  (any temp > 85C or mem > 90%) flips frame color to `cAlert`.
- **Left rail** (~20% width): SYSTEM panel — aggregate CPU% big number +
  per-core bar matrix (24 thin vertical bars colored green→amber→magenta by
  load), load trio, temp, uptime; below it MEMORY panel — RAM gauge bar +
  swap bar + GB text.
- **Center** (~55%): the REACTOR — a large concentric arc dial ~min(38vh):
  outer ring CPU%, middle ring GPU0 power fraction (i_pwr_w/i_pwr_cap_w),
  inner ring mem fraction; center shows hostname + live clock (HH:MM:SS) +
  kernel + output name/workspace. Surrounding the dial: 2-4 sparkline traces
  (60-pt history of cpuPct, gpu power W, net rx rate, disk read rate) drawn as
  Shape polylines or Canvas — pick whichever is cheaper. Under the dial a
  marquee row of "top procs" (proc0..5 name + cpu%).
- **Right rail** (~22%): GPU0 `Arc B580` panel — power dial or bar w/ cap,
  temp grid (pkg/vram/mctrl/pcie), VRAM channel max/avg, fan RPM, VRAM used/total
  bar; GPU1 `AMD iGPU` panel — util bar, vram, temp, power, freq; STORAGE panel —
  root/home filesystem bars + disk r/w rates.
- **Bottom strip**: NETWORK panel — rx/tx current rates + dual sparkline;
  AGENTS panel — tmux count, agent proc count, top agent names; a status line
  with blinking cursor `▮`.
- **Panels collapse** on header click (shared state across monitors, session-
  only, `collapsedMap` pattern as in existing Hud.qml); header `◢◤ NEXUS`
  block click or IPC `toggleAll` folds/unfolds everything.
- Helpers to reuse or port: existing `HudSection.qml`/`HudRow.qml` (same dir)
  for labeled rows; keep them unchanged and compatible.

## Non-goals / rules

- No new processes per frame, no timers spawning shell commands — all data via
  the one stream Process + the probe Process.
- No images or web content; pure QML shapes/text/Canvas.
- No external fonts beyond `Style.font.family`.
- Keep animation cheap: sparkline Canvas `requestPaint` once per frame, not per
  segment; avoid `NumberAnimation` storms — a few blinking/glow accents max.
- Must `qmllint` clean enough to load inside omarchy-shell (PanelWindow etc.
  may warn as uncreatable under qmllint — ignore those; real QML syntax or
  read-only-property assignments are BLOCKERS: PanelWindow has NO writable
  implicitWidth/implicitHeight — use anchors all edges + position content).
- Deliverable: the complete rewritten `Hud.qml` at the output path given in
  your dispatch prompt. Do NOT modify collect.sh, the Rust collector,
  HudSection.qml, or HudRow.qml.
