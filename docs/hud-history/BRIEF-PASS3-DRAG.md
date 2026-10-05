# BRIEF-PASS3-DRAG — NEXUS HUD drag-to-move panels + settings sheet + persistence

## Context

Quickshell/QML (Qt6) desktop HUD for Omarchy/Hyprland, `service` plugin on
`WlrLayer.Bottom`, one fullscreen `PanelWindow` per `Quickshell.screens`.

**Base file (READ FIRST):**
`/run/media/nexuslink/82CC5F65CC5F5311/Users/mikek/NEXUS_AI_CENTER/nexuslink.hud/candidates/HudN.qml`
(~4300 lines — current deployed standard: per-monitor roles, ambient.qsb
shader field, masked interactivity, shared animClock/sv easing, IPC).

Collector contract (`recon/stream-keys.md`) is FROZEN — read stats keys only.

## Mission

Give the user **full layout control**: drag panels to reposition them, watch
siblings morph/reflow to fit, and a **settings sheet** to customize the HUD —
all persisted across restarts.

## Requirements

### 1. Drag-to-move + morph reflow (CORE)

- Every telemetry panel is wrapped in the existing `CPanel` frame pattern.
  Its header is already click-to-collapse; make **press-and-drag >8px** start
  a move instead (click without drag still collapses).
- During drag: the dragged panel floats (lift opacity/shadow, `z` raised),
  a ghost outline previews the drop slot.
- Layout model: each screen is divided into named regions/columns
  (keep the current role layouts as the DEFAULT map). On drop, the panel
  snaps to the nearest valid slot; siblings animate (NumberAnimation on
  x/y/w/h, ~200ms OutCubic — reuse `animT`/easing idiom) to reflow: vacated
  space collapses, displaced panels shift down/aside. Nothing may overflow
  the bezel frame — clamp to it.
- Panels may swap between columns within their own screen only. Role-bound
  panels (e.g. ops panels) stay on their own screen; do NOT allow cross-
  monitor drags.
- While a panel is being dragged its MaskedRegion entry should drop out of
  `mask:` so it can't eat clicks mid-flight (re-add on drop).

### 2. Settings sheet (CORE)

- A small gear/tune button on the title plate (top-center) opens a modal
  sheet centered on that screen: dark plate styling, dismiss via a close
  chip or clicking the scrim. `WlrKeyboardFocus.None` means **mouse-only**:
  toggles, sliders (drag/click), swatches — NO text inputs.
- Settings (per screen where sensible, global where not):
  - Panel visibility toggles — checkbox per panel id present on that role.
  - Accent palette preset: cyan / green / magenta / amber (recolors accent
    lines, dial comet, glows — keep the fixed alert color).
  - Ambient shader: on/off + intensity slider (drives ShaderEffect opacity).
  - Tick rate: 15 / 30 / 60 Hz (drives animClock.interval).
  - "Reset layout" button — restores the role default map.
- The sheet itself must be inside `mask:`; the scrim swallows clicks (blocks
  pass-through) while open.

### 3. Persistence (CORE)

- Layout map + settings persist to
  `~/.config/omarchy/nexuslink/hud-state.json` (create the dir if missing).
  Keyed by screen name → role → {panel order/slots, hidden list} plus
  global {accent, shaderOn, shaderIntensity, tickHz}.
- Load on Component.onCompleted; tolerate missing/corrupt file → defaults.
- Write debounced (~500ms after last change), via `Quickshell.Io.FileView`
  write API if available in this Quickshell version, else a `Process`
  spawning `tee`/python — pick whichever actually works; verify the file
  round-trips (values survive a simulated reload = re-read path).

### 4. Constraints (MUST hold — same as pass-2)

- PanelWindow per screen, `WlrLayer.Bottom`, `ExclusionMode.Ignore`,
  `WlrKeyboardFocus.None`, no implicitWidth/Height on PanelWindow.
- Keep IPC (`toggleAll/refresh/status/stats/section`), collapse map,
  collector Process machinery, all existing panels & stats keys,
  ambient.qsb ShaderEffect reference (relative URL — file ships alongside).
- Palette unchanged. Synthwave palette, no bright-white UI.
- Everything still works if the user never touches settings: defaults =
  current HudN layout.

## Verification

- `/usr/lib/qt6/bin/qmllint HudO.qml` — 0 errors (warnings ok).
- Re-read: every dragged-panel state path, mask coverage for sheet+panels,
  persistence read/write both present, no TODOs.
- Report: path, lines, drag mechanics summary, settings surface, persistence
  format, known risks.

Do NOT deploy or restart anything — produce `candidates/HudO.qml` only.
