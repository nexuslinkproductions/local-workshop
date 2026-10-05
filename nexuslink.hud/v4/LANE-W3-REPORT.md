# LANE-W3-REPORT — BoardView: kind->shape glyph registry

Scope honored: edits confined to `v4/BoardView.qml` + this report. Synced to
the deployed mirror `/home/nexuslink/.config/omarchy/plugins/nexuslink.hud/v4/`
(inotify `close_write` watcher — no shell restart needed). `qmllint` exit 0
on both copies.

Operator verdict addressed: nodes were "identical looking squares with
names". Every recon class now renders as its real hardware silhouette via a
new `KindGlyph` Canvas component + a cls->geometry/tag registry, with the
name/vitals demoted to captions beside the shape.

## 1. Registry (`BoardView.qml:1062-1159`)

- `clsByNid` — static nid -> recon-class fallback so glyph geometry is
  stable before `Topology.ready`.
- `clsOf(nid, node)` — live key is `node.extra.cls` (the raw
  recon/devices-bus.json `class`, e.g. `usb_camera` vs `usb_receiver` —
  finer than the contract `kind` which collapses them all to "usb").
- `_glyphCls` / `_glyphNid` — [w,h] footprint per class, per-node override
  (B580 card 80x30 vs Raphael iGPU chip-card 40x18).
- `_clsTag` — silkscreen micro-tag under each glyph (HUB/RCV/UVC/KBD/MSC/
  RGB/BT/OUT/IN/xHC/SPD/EDID...). pci_bridge gets none: tray-only naming.
- `tempStroke(v)` — shared cool-ice -> amber -> alert ramp for in-glyph
  temp encoding.

## 2. Shapes per kind (KindGlyph, `BoardView.qml:2599-3248`)

| class | silhouette |
|---|---|
| cpu (PkgNode) | die slab: LGA pin ticks on all 4 edges, substrate inset, dark chamfer + gold alignment triangle (notched corner), existing CCD0/CCD1 recesses + 12 core tiles kept |
| gpu | card profile: slot bracket w/ screw marks, shroud body, gold PCIe fingers; B580 = 2 fan rings w/ static tripod blades + power-plug nub; iGPU = small card, bare die square + solder dots |
| dimm | tall stick, 4 rank-chip flecks, gold contact edge with off-centre DDR5 key notch, right-flank temp stripe |
| memory | 2-stick DIMM bank (chip flecks + pin rows) |
| nvme | M.2 stick: keyed gold fingers (M-key gap), controller + NAND blocks, mount hole, temp bar under body |
| pci_root | fat diamond + inner ring + 3 fan-out prongs + live core dot |
| pci_bridge | bare 22px crosspoint diamond (X inside, live center dot); **no label on board — name/vitals only in the detail tray** |
| xhci | host-controller chip + pin stubs over a USB-A port (port ring goes acid when live) |
| sata | flat L-connector + gold contact ticks |
| audio_pci | jack ring + bore + rightward wave arcs (acid when routed) |
| pw_sink / pw_source | port disc + waves right (sink) / left (source) |
| nic | RJ45 port: clip recess, gold contacts, link+activity LED dots; `nic_wifi` variant = stub antenna + arcs |
| display | little screen: lit gradient panel (acid scanline when connected) + neck + foot |
| usb_roothub | spoked ring + core square |
| usb_hub | ring + uplink stub + 3 downstream port dots |
| usb_storage | flash stick: metal plug + body + activity dot |
| usb_receiver / rgb / bluetooth | nano dongles: plug tip + body; receiver antenna, rgb tri-color strip, BT bind-rune |
| usb_camera | webcam dongle + lens ring |
| usb_keyboard | low slab + 2x8 key grid |
| smbus | i2c chip: left pins, SDA/SCL lines out right |
| crypto | PSP/CCP shield plate + keyhole |
| bluetooth | bind-rune + presence arc |
| other | stubbed generic chip + live die dot |

## 3. BoardNode rewrite (`BoardView.qml:2114-2249`)

- Emboss/glass face plates, keyline rects and the rounded-rect rim are
  gone; the item is now `[KindGlyph][caption]` with an optional tag row.
- `bare` (pci_bridge) items shrink to glyph+pad (~32px) — wires still
  attach via the unchanged `registerBox`/`wireEnds` path, so routing
  geometry follows the smaller boxes.
- Hover/pin rim is painted **inside** the glyph, shape-aware (diamond rim
  for diamonds, box rim otherwise) — no Behaviour/opacity rectangle.
- `live` now ORs folded sibling ids (e.g. nic_eth lights via net_eth),
  re-evaluated per `Topology.statsRev` — never on a clock.
- Captions keep the old fonts/eliding; gap tightened (6px, 2px inset) so
  130px-wide USB leaves keep most of their names.
- HEAT lens: halo now hugs the glyph only; glyph strokes/fills lerp
  ice->amber->alert via `heatK` (nodes with no temp still get nothing —
  the mock's data-t contract).

## 4. Untouched per dispatch

Edges/bezier canvas, `WireDots` particles (still only while flow nonzero),
LINK/HEAT lens toggle + legend, detail tray, masthead, shelf, scanlines.
No perpetual animations: glyph canvases repaint on statsRev/lens/focus/
resize only; pinframe paints on resize only.

## 5. Verification

- `/usr/lib/qt6/bin/qmllint BoardView.qml` -> exit 0 (repo + mirror copies).
- Offscreen smoke render (`qmlscene6`, QT_QPA_PLATFORM=offscreen) of the
  pasted KindGlyph component across all 26 classes, live/hot/focus
  variants: zero JS/paint errors; per-cell pixel check confirms every
  glyph draws.
- Full-board standalone render not possible headless: Topology.qml imports
  `Quickshell.Io` (not installed outside the shell). Structural risk is
  low — layout, wiring and tray code paths are unchanged.
