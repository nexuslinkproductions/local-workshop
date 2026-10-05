# BRIEF-PASS2 — NEXUS HUD per-monitor roles + ambient shader + interactive features

## Context

You are reworking a Quickshell/QML (Qt6) desktop HUD plugin for Omarchy/Hyprland.
The plugin runs inside `omarchy-shell` as a `service` plugin. Everything on screen
must be QML — no DOM, no web engine.

**Base file (READ FIRST, this is your starting point):**
`/run/media/nexuslink/82CC5F65CC5F5311/Users/mikek/NEXUS_AI_CENTER/nexuslink.hud/candidates/HudL.qml`
(~2200 lines — the smooth-motion cockpit: shared 30 Hz animClock, eased scalars in
`sv`, gliding traces via `scrollPhase` + `dsp*` copies, machined-bezel CPanel,
reactor dial with comet, double frame, alert lerp.)

WARNING: `nexuslink.hud/Hud.qml` in the project dir is the OLD v1 side-panel —
do not base on it. HudL.qml is the current visual standard. Installed copy lives
at `~/.config/omarchy/plugins/nexuslink.hud/` (deployed file has no `import "../"`).

Reference for ambition: `nexuslink.hud/ASTRALMON-REFERENCE.qml` (KDE HUD with
dials/traces/alert palettes).

## Mission

Transform the identical-per-screen cockpit into **three different screens**, add
the new telemetry panels below, add a **GLSL ShaderEffect ambient layer**, and add
**interactive features**. This is a desktop *background* surfaces: windows float
above it; only the drawn panel regions take clicks (mask).

### Per-monitor roles (REQUIRED)

`Variants` iterates `Quickshell.screens`; `modelData.name` identifies the output:

- **DP-1** (Samsung LC27G7xT, user calls it "Samsung", primary): THE COMMAND
  COCKPIT — reactor dial center stage, hero stats, traces, bottom strip
  (NETWORK / AGENTS / STATUS), title plate. This is the showcase screen.
- **DP-2** (HP E24i G4): HARDWARE DETAIL page — expanded GPU0 (Intel B580) and
  GPU1 (AMD Raphael) panels with every sensor, enlarged per-core matrix, STORAGE
  detail, PERIPHERALS battery panel, MEMORY. Hardware-watcher screen.
- **HDMI-A-3** (HP Z24n G3): OPS/DEV console — AGENTS expanded (per-harness
  chips + tmux sessions + devin acp count), REPO ACTIVITY (github feed),
  TOP PROCS, WINDOWS/workspaces nav panel, LAUNCH rail. The work screen.

Implement via `property string role` derived from `modelData.name` inside each
PanelWindow, then render role-specific panel sets. Panels for other roles may be
omitted entirely (not just hidden). Keep the corner-bracket frame + title plate
on every screen (title plate centered top; it currently overlaps the bar — drop
it ~28px below the top edge or restyle so it doesn't collide).

### New panels (all REQUIRED where role-appropriate)

1. **PERIPHERALS** — battery bars. Keys: `bat_count`; per i in 0..3:
   `bat{i}_name` ("G502 X PLUS"), `bat{i}_pct` (0-100), `bat{i}_state`
   (Discharging/Charging/Full). Show icon-ish glyph, name, eased % bar, state
   color (charging=green pulse, low<20=alert). Hide gracefully when count=0.
2. **REPO ACTIVITY** — `gh_ok`, `gh_user`, `gh_unread`, `ghev_count`; per i:
   `ghev{i}_type` (PushEvent/CreateEvent/PullRequestEvent...), `ghev{i}_repo`
   (owner/name), `ghev{i}_age_s` (seconds → format "12m"/"3h"/"2d" ago).
   Render as an event feed rows + unread badge. `gh_ok=0` → offline state.
3. **AGENTS expanded** — existing `agents_tmux`/`agents_procs` PLUS per-harness
   chips: `ag_{devin,opencode,hermes,october,claude,codex,haze,build}_procs` and
   `_cpu` (aggregate %). `ag_devin_acp` = devin ACP session count. tmux sessions:
   `tmux_n`, `tmux{i}_name`, `tmux{i}_win`, `tmux{i}_att`. "build" tag lights up
   when cargo/npm/vite/rustc run — style it as an ACTIVE WORK indicator.
4. **WINDOWS / NAV** — `win_count`; per i: `win{i}_addr` (0x...),
   `win{i}_ws`, `win{i}_wsid`, `win{i}_class`, `win{i}_title`, `win{i}_mon`.
   Workspaces: `ws_count`, `ws{i}_id/name/mon/wins`. Render: workspace chips
   (name + window count, highlighted active) and/or a compact window list
   (class · title). CLICK a window row → focus it (see Interactivity).
5. **LAUNCH rail** — row of clickable launcher chips (see Interactivity).

### Ambient ShaderEffect layer (REQUIRED)

Add a screen-covering `ShaderEffect` (or Shape-free GLSL item) UNDER all panels:
animated technical ambient field — e.g. flowing circuit traces, drifting hex
grid, slow plasma nebula, or particle sweep — in the cyan/green/magenta palette
on near-black. Requirements:

- Data-reactive: expose uniforms fed by eased `sv` values (e.g. `u_load` =
  sv.cpu, `u_alert` = alertMix) so the field brightens/shifts under load.
- Cheap: fragment shader only, modest ops, `hasSwRadialGradient`-style tricks
  avoided — write real GLSL (Qt6 ShaderEffect uses GLSL 440 core; declare
  `layout(location=0) in vec2 qt_TexCoord0;` etc., or use `variant` GLSL ES —
  check what Qt6 wants: `fragmentShader: "file.qml frag"` is NOT supported;
  inline `fragmentShader` property takes GLSL source string. Verify syntax
  conventions used by Qt6 ShaderEffect — `qt_Multiplier`, `iTime` equivalent
  must be your own uniform fed by `animT`).
- Must degrade gracefully: wrap in a try/fallback — if ShaderEffect fails to
  compile at runtime the panels must still render (put the shader item behind
  everything; a compile failure renders nothing but shouldn't break siblings).
- Keep the existing static fx canvas (scanlines/vignette/grid) — the shader
  goes under or replaces its grid role, whichever looks better.

### Interactivity (REQUIRED)

MouseArea-driven, masked to drawn regions only:

- **Launcher chips**: spawn on click via `Quickshell.Io.Process` (non-blocking,
  e.g. `Process { command: ["uwsm","app","--","devin-desktop"] }` or plain
  `["gtk-launch","october"]`). Targets: Devin (`gtk-launch devin` or the
  `devin-desktop` binary), October (`gtk-launch october`), terminal
  (`gtk-launch alacritty` or `$TERMINAL`), file manager (`gtk-launch thunar`/
  nautilus — check installed .desktop ids aren't required: fall back to a
  generic exec). Also a "HAZE workspace" chip → `gtk-launch devin` is enough;
  keep it simple: 4-6 chips max.
- **Window focus**: clicking a window row runs
  `hyprctl dispatch focuswindow address:<win{i}_addr>` — via Process spawn.
- **Workspace chips**: click → `hyprctl dispatch workspace <id>`.
- **Hover affordances** on all interactive rows (highlight lift, cursor shape).
- All interactive items MUST be inside `mask:` regions (extend the existing
  Region list) — clicks elsewhere pass through to the desktop.

### Hard constraints (same as before — MUST hold)

- Single self-contained file. NO `import "../"`. Imports allowed: QtQuick,
  Quickshell, Quickshell.Wayland, Quickshell.Io, Quickshell.Hyprland,
  QtQuick.Shapes, QtQuick.Effects, qs.Commons, qs.Ui.
- `PanelWindow` per screen in `Variants`, `WlrLayer.Bottom`,
  `ExclusionMode.Ignore`, `WlrKeyboardFocus.None`, `ScreenMoveRemap`,
  fullscreen anchors + positioned content. NO `implicitWidth/implicitHeight`
  on PanelWindow.
- Keep `IpcHandler { target: "nexuslink.hud" }` with `toggleAll`, `refresh`,
  `status`, `stats`, `section(id)`. Keep shared collapse map + per-panel
  header click collapse.
- Keep every existing telemetry panel/field (they distribute across roles now:
  DP-2 gets the hardware detail, DP-1 keeps hero versions).
- One shared animation clock for the whole file (HudL already does this —
  keep `animClock`/`tick()`/`sv`/`dsp*` machinery).
- Collector contract is FROZEN — read `stats` keys only; do not change
  collect.sh/main.rs.
- Palette: cyan #00e5ff, green #39ff14, magenta #ff2bd6, amber #ffb300,
  alert #ff3b4e, plate #040e16. Synthwave/cyberpunk, never bright-white UI.

## Verification

- `qmllint` the output (available at `/usr/lib/qt6/bin/qmllint`); fix all
  errors (singleton warnings are fine).
- Re-read the file: brace balance, every id/property referenced exists,
  mask regions cover every interactive item, IPC functions present.
- Report: path, line count, panels per screen role, shader approach,
  interactions added, known risks.

Do NOT reload/restart the shell or deploy anywhere — produce the candidate file
only.
