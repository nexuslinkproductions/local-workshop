# LANE-W2-REPORT — DP-1 CommandHub: reactor −22%, DEVICES tile → Navigator

Scope honored: edits confined to `v4/CommandHub.qml` + this report. Synced to
the deployed mirror `/home/nexuslink/.config/omarchy/plugins/nexuslink.hud/v4/`
(the inotify plugin watcher picks up `close_write` — no shell restart needed).
`qmllint` exit 0 on both copies.

## 1. REACTOR SMALLER (−22%)

Geometry block (`CommandHub.qml:346-351`):

- New `readonly property real dialSpec` holds the **unshrunk** spec size —
  `min(w*0.30, h*0.53, bandH-24)` (≈763 px on the 2560×1440 DP-1 panel).
- `dialSize` is now `Math.max(300, Math.round(dialSpec * 0.78))` → **≈595 px**
  on DP-1, a 22% reduction (inside the requested 20-25%).
- Everything downstream is relative and follows automatically: the reactor
  `Item` keeps `width == height == dialSize` (perfect circle) and
  `anchors.centerIn: parent` (screen-centre, the P2-gate anchor); the two
  translucent shadow discs (1.22×/1.10×) and the disc/arcs Canvases all key off
  `reactor.width`, and every face font scales with it — hero numeral ≈82 px,
  stat rows ≈11 px, all clamps intact.

Knot exposure (`knotWrap` → `KnotField`, `CommandHub.qml:369-377`):

- `px` was `dialSize/48`, which shrank the knot in lockstep with the dial — and
  at the old size the knot field (≈768 px) already sat fully under the 1.22×
  shadow disc (≈931 px), which is why it never read.
- Now `px: Math.max(6, Math.round(root.dialSpec / 44))` — sized off the
  **pre-shrink** spec with one step wider divisor. On DP-1: `px` 16→17, knot
  field ≈816×833 px against a 726 px outer shadow / 592 px opaque dial →
  ~45-53 px of full-lit knot ring beyond the shadow stack (plus dimmed
  show-through under the translucent shadows), and the apex tips now clear
  the shadow top. Flanks: knot spans 872..1688 px centred on 2560 — clear of
  both tile columns (34..784 / 1776..2526), so nothing overlaps.

## 2. DEVICES TILE → Navigator devices section

Mechanism (verified, unchanged): `activateTile("devices")` already calls
`openNav("devices")` (`CommandHub.qml:696-698`). `openNav` (lines 124-130)
uses the **injected Navigator scope** first — HudV4 instantiates
`Navigator { id: nav }` (HudV4.qml:526) and passes `navigator: nav`
(HudV4.qml:1060) — calling `navigator.openSection("devices", "")`, which maps
to `sectionIds[2]` and sets `navOpen` (Navigator.qml:39,494-519). Fallback is
the documented IPC `omarchy-shell -q nexuslink.nav open devices ""`
(IpcHandler `target: "nexuslink.nav"`, Navigator.qml:761-766). Tile click path
is `EmbossedTile.clicked → activateTile`; the row-launch overlay stays
disabled for this tile (no `launch` rows), so single-click routing is intact.

What changed — the tile body (`tileFacts`, `CommandHub.qml:1004-1020`):

- Removed the detailed device listing (2 battery rows + up to 4 recon-verified
  leaf-peripheral rows: Kiyo, Corsair/Logi receivers, ASUS kbd, MSI Mystic,
  BT radio, Kingston flash) — that detail view moved to the Workbench.
- Body is now a two-line entry-point affordance: `usb tree · batteries ↗
  navigator · F3` and `device detail → workbench · hdmi-a-3`.

What stays (per dispatch): the tile itself in `leftTiles` with F3 tag, the
**peripheral-count insight** (`tileInsight` — "N peripherals · bat0 %"),
and the low-battery `hot` flag (`tileHot`, bat0 ≤25% discharging).

## 3. Verification

```
$ cd v4 && /usr/lib/qt6/bin/qmllint CommandHub.qml        → exit 0, no output
$ cd <mirror>/v4 && /usr/lib/qt6/bin/qmllint CommandHub.qml → exit 0, no output
$ md5sum repo & mirror CommandHub.qml                     → 3a659016… (match)
```

DP-1 numbers: dialSpec ≈763 → dialSize ≈595 (−22%); knot px 16→17, field
816×833; shadow outer 726 — knot ring ≈45 px lit beyond shadow, ≈112 px
beyond the opaque dial edge.

## 4. Notes / follow-ups for the conductor

- `omarchy-shell -q nexuslink.nav state` returned no output in this session —
  likely the plugin IPC isn't reachable from this shell context. Harmless:
  the primary path is the injected `nav` scope (IPC is only the documented
  fallback) and no live-fire test was run to avoid popping the Navigator
  overlay on the operator's screen.
- The Workbench-side detailed devices view is another lane's file
  (Workbench.qml currently has no devices panel — nothing referenced it here).
- `peripheralCount()` and `topoNode()` are still used (insight + network
  rows); no dead code left behind by the fact-row trim.
