# Lane C · TACTILE INSTRUMENT PANEL

## Direction

A physical control deck, not a web page. The screen is a dark soft-extruded
hardware surface: every module is either a raised machined plate (two offset
soft shadows: dark below-right, faint light above-left) or a recessed well
holding a dark glass instrument window. Readouts are dot-matrix amber like
segment displays; state is carried by indicator LEDs (amber primary, cyan
secondary, green ok, red fault); the knot is engraved into the deck and lit to
half. Cybercore grain and scanlines sit at machine-room whisper level (fixed
overlays, ~5% opacity, never per-frame). Where the frosted-glass lane uses
translucency and the chrome lane uses reflections, this lane uses extrusion:
depth you could physically press.

## Font pairing

- **Tektur** (nameplates, headings): squarish technical DIN-style face that
  reads like machined hardware lettering; engraved with a 1px light catch.
- **Chakra Petch** (body, insights): squared technical humanist, legible at
  small sizes, no "AI default" smell.
- **Doto** (dot-matrix readouts): a true dot-matrix face; used only for
  instrument values so it never has to work at body sizes.
- **Share Tech Mono** (ledgers, data rows, paths): instrument-label mono for
  dense tabular data.

## Files

- `index.html` cover plate (2560x1440)
- `dp1.html` Command Hub (2560x1440): reactor instrument at exact screen
  centre on dark glass disc + drop shadow, etched knot at ~50% behind it,
  10 press-in hub tiles with live insight sentences, 16-switch utility bank.
- `dp2.html` Board Schematic (1920x1200): all 78 inventory nodes from
  recon/devices-bus.json as socketed chips, 12 static bus traces + 6 animated
  flow stubs (13 flow sources hoverable), heat-lens toggle, per-link/per-node
  hover readouts.
- `hdmi.html` Workbench + Patch Bay (1920x1200): workspace cards, 12 agent
  session slots (3 live), process ledger in "% of one core", repos with real
  git state, token ledger day/week/month, patch bay with jack sockets, live
  patch cables, knobs and battery readouts.
- `nav.html` The Navigator (2560x1440 overlay): breadcrumbs, search-as-you-type
  (recursive over the modelled tree), arrow/Enter/Backspace/`/` keys all
  wired, text-file previews with line numbers, action buttons that print the
  real command they would run; Files + Processes sections.

## What changed vs round 1

- Type: Adwaita Sans / JetBrains Mono replaced by the pairing above; labels are
  engraved nameplates, not tracked uppercase captions.
- Palette: dark warm-grey deck with amber+cyan indicator lights instead of
  cyan-on-navy; accent survives in LEDs and readouts, not in lines everywhere.
- Reactor: knot stays lit at ~50% but is now etched metal; reactor sits on a
  recessed dark glass disc with bezel, screws and a real drop shadow, so the
  dense face reads on top of it.
- Every module is a physical object (plate, well, glass window, switch, jack,
  knob, LED) instead of a bordered box; text hierarchy follows the hardware.
- Content is real: stream snapshot 2026-09-28, tokens.json, devices-bus.json
  (78/78 nodes), integrations-desktop.json values, real repo states.

## Notes for QML graft

No backdrop-filter anywhere; glass = layered translucent fills + inner shadows,
neumorphic depth = two offset Rectangles with soft shadows, dot-matrix font is
a plain QFont, flows are dash-animated Shape paths, the knot is a one-shot
Canvas paint. No per-frame filters over large areas.
