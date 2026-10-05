# CHROME CYBERCORE — direction B

Y2K techno chrome hardware for the NEXUS HUD. Every panel is a machined graphite
chassis part: a brushed-chrome bevel with a holographic iridescent edge light on
the rim, embossed neumorphic controls extruded from the metal, and frosted glass
readout windows set into it. Acid-lime (`#C8FF00`) is the hot/primary instrument
colour, ice-blue (`#7FD8FF`) is the cool/secondary one. Near-black graphite field,
quiet scanlines, no navy anywhere.

## Font pairing

- **Michroma** — wide technical display type. Used for mastheads, section labels,
  the reactor hero number and tile names. It is the Y2K techno voice of the
  direction: geometric, wide-tracked, machined.
- **Kode Mono** (Regular/Medium/SemiBold/Bold) — data and body. A clean
  engineering mono with tabular numerals; carries telemetry, paths and ledgers
  without the "AI template" feel of JetBrains Mono.

Both are OFL, downloaded into `fonts/` and loaded with `@font-face` from relative
paths. The mock is fully self-contained.

## What changed vs round 1

- Round 1 was generic dark-navy + hairlines + cyan. This direction replaces the
  whole material system: graphite + chrome bevels + embossed controls + frosted
  glass, with iridescent edge light instead of flat accent borders.
- Reactor readability: the knot stays lit at ~50% but the dial now sits on a
  dark glass disc (`glasdisc`) with a heavy drop shadow, so the dense face
  (hero %, loads, temps, MEM, NET, uptime, top proc) reads cleanly.
- Fonts: Adwaita Sans / JetBrains Mono replaced by Michroma + Kode Mono.
- DP-2 is the full 78-node board schematic from `recon/devices-bus.json` with a
  working power/thermal lens toggle and per-link bandwidth readout on hover.
- All values are real: `hud-collect stream` (load 7.95, Tctl 80°, Tccd1 87°,
  nvme temps, G502 94%, proc ledger, windows, workspaces), `tokens.json`
  (devin 159.6M in today, opencode $0.22), `integrations-desktop.json`
  (2 updates, 31 clipboard entries, Vienna weather, volume 95%).

## Files

- `dp1.html` — 2560×1440 command hub (reactor + 10 hub tiles + 16-chip utility strip)
- `dp2.html` — 1920×1200 board schematic (78 nodes, flows, thermal lens)
- `hdmi.html` — 1920×1200 workbench + patch bay
- `nav.html` — Navigator overlay prototype (Files + Processes, full keyboard control)
- `index.html` — direction cover
- `core.css` — shared chrome-cybercore material system
- `fonts/` — Michroma + Kode Mono TTFs

## QML implementability

Frosted glass = layered translucent rounded rects + one blurred static backdrop
(MultiEffect over the wallpaper layer, paid once). Neumorphic depth = two offset
soft shadows (inset highlight top, inset shade bottom). Holographic edge light =
a static horizontal gradient strip. Flow particles = small circles on fixed paths
(animators, not filters). No per-frame blur or shadow filters over large areas.
