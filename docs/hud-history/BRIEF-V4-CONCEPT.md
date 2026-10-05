# BRIEF: HUD v4 concept (full reimagination, not a polish)

## TASK
Design a complete reimagination of a three-monitor desktop-background HUD. The
operator rejected v3 as "cleaned and polished a bit from what we had". They want
the whole background re-thought: the machine shown as a living system, with deep
insight into machinery and every connected component/device, brought to life.

## INPUTS (read these; do not crawl elsewhere)
- Current build: nexuslink.hud/candidates/HudV3.qml (6.6k lines QML, Quickshell).
  Read the header comment + defaultRects() + the role sections; skim the rest.
- Telemetry already available: nexuslink.hud/recon/stream-keys.md, recon/untapped.md
- Device inventory (may land while you work): nexuslink.hud/recon/devices.md
- Typography/alpha tokens: nexuslink.hud/recon/design-pass.md
- Agent API that exists: IPC focus/move/resize/show/hide/layout/panels/say
- Monitors: `hyprctl monitors -j`. Measured: DP-1 2560x1440 (main, centre),
  DP-2 1920x1200 (right), HDMI-A-3 1920x1200 (left).
All paths are under /run/media/nexuslink/82CC5F65CC5F5311/Users/mikek/NEXUS_AI_CENTER/.

## FIXED DECISIONS (do not re-open)
- Stack: QML on Quickshell, wlr "bottom" layer, windows float above. Tools are
  Canvas, QtQuick.Shapes, ShaderEffect (qsb packs), Text. No web views.
- Click-through outside drawn panels (window mask). Free-canvas drag/resize/snap
  engine and JSON persistence stay.
- The reactor dial stays (operator likes it) as DP-1's centrepiece, centred on the
  SCREEN (not the free space). The NLP celtic-knot pixel logo sits centred behind
  it, always lit at ~50%, with ttfx-style transitions (see recon/tte-engine.md).
- DP-1 = agentic OS command surface: full overview, navigable by agents.
- Fonts: Adwaita Sans (UI) + JetBrainsMono Nerd Font (numbers). Cyberpunk /
  synthwave palette, cyan accent, restrained glow. Motion over filters.
- CPU budget: whole shell under ~15% of one core at idle. Canvases repaint only
  on data change; one shared clock.

## WHAT THE CONCEPT MUST ANSWER
1. The organizing idea. One sentence per monitor on what that screen IS
   (e.g. "DP-2 is a live schematic of the machine's buses").
2. Machinery insight. How CPU/CCDs/cores, both GPUs (Arc B580 + Raphael iGPU),
   PCIe tree, NVMe + USB storage, USB devices, peripherals with batteries, audio
   devices, displays, network interfaces, bluetooth are shown. Prefer a topology
   view with live flows along links (throughput drives particle rate/brightness)
   over rows of bars. Every device node shows identity + one live vital.
3. Per-monitor composition as an ASCII wireframe with proportions (fractions of
   width/height), for all three monitors.
4. Module list: each visual module, the data keys it needs (existing key names
   where they exist; proposed `dev_*` style names otherwise), its interaction,
   its repaint trigger.
5. Motion language: the 5-8 recurring motions (flow particles, state-change
   flashes, knot transitions, etc.), each with duration/easing and what triggers it.
6. What gets deleted from v3. Be explicit; subtraction is part of the concept.

## REQUIRED OUTPUT
Write your concept document to the path named in your dispatch prompt. Write the
document incrementally: section headers first, then fill each section.
Target 250-450 lines. No code beyond small QML snippets that clarify a technique.

## FORBIDDEN
Do not edit any .qml, .rs, or anything under ~/.config. Do not deploy. No git.

## ACCEPTANCE
All six questions answered; three wireframes present; every module names its
data source; deletions list present.
