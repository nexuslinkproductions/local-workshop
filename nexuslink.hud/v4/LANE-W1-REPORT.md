# LANE-W1-REPORT — HDMI-A-3 workbench polish + DEVICES tab

Scope honored: `v4/Workbench.qml` (edited), `v4/DeviceBay.qml` (new),
`v4/qmldir` (LANE-D/N block: one line + marker comment), this report.
No other files touched. Mirror synced to
`~/.config/omarchy/plugins/nexuslink.hud/v4/` (cp; no shell restart).

## 1. Token ledger cutoff — FIXED

Root cause: the five left-column panes took `height = leftCol.height × f`
with fractions summing to 1.00 (0.30/0.17/0.16/0.16/0.21), then the Column
added 4×12 px of inter-pane spacing — the column overran by exactly 48 px
and the token ledger painted on behind the UtilityDock strip.

Fix (Workbench.qml:607-612, 618, 815, 938, 1061, 1186-1195):

- `leftCol.bodyH = leftCol.height − 4 × leftCol.spacing` — the
  distributable pane height after the gaps. All fractions now apply to
  `bodyH`, not the raw column height.
- `tokPanel.height` is the *remainder* (`column − other four panes − gaps`,
  floored at 40) — bounded no matter how the fractions drift; it also
  recovers the px the tightening frees (~217 px ≈ 0.23 share at 1920×1200).
- `clip: true` on `leftCol` as the second line of defence — nothing in the
  ledger column can ever paint past its bounds again. (GlassPane's face was
  already clipping each pane's *content*; the defect was the pane itself
  overrunning the column, which only a column-level clip guards.)

## 2. Left-column tightening

- `layoutRoot` margins 18→14, spacing 12→10; `grid` spacing 14→12;
  `mastRow` margins 18→14, spacing 18→14.
- Left column share 0.56→0.55 (panels less wide; ~+20 px to the tab pane).
- Every panel body: `anchors.margins` 12→10, `spacing` 8→6.
- Row density: window cards 46→40, ws chips 20→18 (cap 132→124), agent
  rows 30→27 (st chip 16→15), tok rows 26→23; inter-row spacing 6→5 / 5→4;
  proc bar 120×5→100×4; header/provider columns 96→84 / 88→76.
- New `root.fs(key, fb)` helper (Workbench.qml:41-45) reads the Style.f
  ramp; row fonts converted: head titles `pxLabel`(10), sub-labels
  `pxMicro`(8), primary row text `pxLabel`(10), secondary `pxTag`(9) —
  was scattered hardcoded 10/11.

## 3. Window-row app icons

- `winIcon(cls)` (Workbench.qml:265-349): `Quickshell.iconPath(cls, true)`
  first (most classes are theme icon names), then lowercase, then a bounded
  DesktopEntries walk over [class, alias-table hit, reverse-domain tail]
  via `byId(id)`/`byId(id+".desktop")` → `entry.icon` → `iconPath`, then
  `DesktopEntries.heuristicLookup` when the runtime has it (guarded with
  typeof, try/catch everywhere — resolution can never throw into the UI).
  Results cached per class in `iconCache` so the per-frame `winList()`
  rebuild stays O(rows).
- Delegate (Workbench.qml:715-732): the decorative 58×34 thumbnail sketch
  was replaced by a 26-px recessed well holding an 18-px `IconImage`
  (`Quickshell.Widgets`, import added); unresolved classes draw the `▢`
  glyph — never a fake image.

## 4. REPOS / CI → GITHUB ACTIVITY

Header text only (Workbench.qml:1084); sub-label "github events · unread"
unchanged. Panel id/behavior unchanged.

## 5. Knot watermark

Workbench.qml:459-482 — flat `pal.bg` field (CommandHub parity) behind a
`KnotField` centered on the screen, `px ≈ 15` (0.62·min-dim/49, ≈720×735).

- Host wrap `opacity: 0.62` × `idleGlow 0.56` ≈ **0.35 effective lit** —
  the documented watermark level, not a second reactor.
- `running: false`: the canvas paints its base frame once at build and
  never schedules `cycleTimer`/`fxTimer` — zero repaint cost, static lit
  state per the brief's "backdrop texture only".
- Declared before `layoutRoot` so it sits behind masthead, both columns
  and the dock; glass panes frost over it.
- HudV4's `findKnot`/`knotSample` probe is gated `if (!isCommand) return`
  (HudV4.qml:894) — this field is never sampled, no interference.

## 6. DeviceBay.qml — connected-peripherals tab (new, 740 lines)

Seven glyph-drawn cards in a `Flow` (2-up, odd tail card spans the row):

| card | pictogram (Canvas) | telemetry line |
|---|---|---|
| G502 X PLUS | oval + scroll line + button split | `BAT n% · link` (`input_mouse`/`rcvr_logi` batt_pct, link) |
| TUF GAMING K7 | deck + 2×4 key grid + spacebar | `480M HID` (kbd_asus link/speedSpec) |
| CORSAIR HEADSET | band + cups + mic boom | `VOL n% · MIC LIVE` (pw_sink/pw_src_corsair) |
| SLIPSTREAM RX | dongle: plug cap + body + LED + radio ticks | `12M · 2.4G` (rcvr_corsair link) |
| RAZER KIYO | lens rings + pupil + mount foot | `480M · UVC` (cam_kiyo link) |
| DATATRAVELER 3.0 | USB plug silhouette + shell + cap seam | `flowRates.fmtB · sdaN n%` (rate or link + biggest part) |
| BT RADIO | bind rune + radiating arcs | `×n PAIRED · ×n LINK` (bt_hci0 paired/connected) |

- `devState()` folds each card's `nodeIds` into up/down/unknown; absent
  vitals render `—` (BRIEF §3), pre-scaffold state is `unknown` (never a
  fabricated "down"); raw `stats` keys are only last-resort fallbacks
  (`dev_usb_046d:c547_batt`, `dev_bt_*`).
- Glyph tint follows state (ice `accent2` live / dim / grey); the Canvas
  repaints on `glyphInk` change and resize only — no clocks.
- Click card → dimmer + centered popover: label, sub, folded-node vitals
  (state/link/temp/vid:pid/battery/vol/paired/port/usb/pw/vital/src rows)
  plus mounted flash partitions; rebuilt on `Topology.statsRev` while open;
  click outside or the same card dismisses.
- Mount: `appsPanel` now hosts `appsBody` Column — 34-px pill tab strip
  (APPS | DEVICES + context hint + hairline) over `tabStack`; `AppGrid`
  keeps tab 0 (default, `rightTab: 0`), `DeviceBay` tab 1. Both stay alive;
  `visible` swaps them, and each self-sizes to its parent (the GlassPane
  content-reparenting workaround — same contract AppGrid already uses).
- Registered: `DeviceBay 1.0 DeviceBay.qml` in the qmldir LANE-D/N block
  with a `# LANE-W1:` marker.

## Verification

    $ cd v4 && /usr/lib/qt6/bin/qmllint Workbench.qml DeviceBay.qml
    EXIT: 0                       (also individually: both 0, zero output)
    $ cd <mirror>/v4 && /usr/lib/qt6/bin/qmllint Workbench.qml DeviceBay.qml
    MIRROR_LINT_EXIT: 0

## Files

- `v4/Workbench.qml` — icon imports + resolver, watermark, tab strip,
  density/overflow fixes (~+180 lines).
- `v4/DeviceBay.qml` — new.
- `v4/qmldir` — LANE-D/N block line.
- `v4/LANE-W1-REPORT.md` — this file. Synced: Workbench.qml, DeviceBay.qml,
  qmldir, LANE-W1-REPORT.md → `~/.config/omarchy/plugins/nexuslink.hud/v4/`.
