# LANE SB1 — DP-1 visual quality pass: CommandHub.qml + UtilityDock.qml

## Scope owned
- `v4/CommandHub.qml` (edited) — 1769 → 2111 lines
- `v4/UtilityDock.qml` (edited) — 914 → 1033 lines
- `v4/LANE-SB1-REPORT.md` (this file)

No other repo file touched. `Style.qml` / `Theme.qml` / `GlassPane.qml` /
`EmbossedTile.qml` / `KnotField.qml` / `MediaCell.qml` were read as API
contract only and are byte-identical to before. Import lines unchanged
(`QtQuick`, `Quickshell`, `Quickshell.Io`) — no new dependencies, no new
modules registered in `qmldir`.

Mirror synced: `~/.config/omarchy/plugins/nexuslink.hud/v4/{CommandHub,UtilityDock}.qml`
(`diff -q` against the repo copies → identical). No shell restart.

**Verification:** `/usr/lib/qt6/bin/qmllint` exits **0** on all four files
(repo + deploy, both components).

---

## How this was measured

Pixel truth, not eyeballing:

1. **Live before-capture.** `grim -o DP-1` on the running shell →
   `/tmp/opencode/sb1/before-DP-1.png`. Column profiles (`magick … txt:`
   scanline reader) measured the real panel luminance and tile extents.
2. **Offline render harness** (`/tmp/opencode/sb1/h`, throwaway). `qmlscene`
   cannot load `Quickshell`, so the harness ships a stub `Quickshell` /
   `Quickshell.Io` module (`execDetached` inert, `Process` / `StdioCollector` /
   `FileView` no-ops) plus a 4-node `Topology` fixture, then instantiates the
   **real** `CommandHub` through the real `NexusHud.V4` module at 2560×1440
   with one synthetic collector frame, and `grabToImage()`s the result. Fully
   offscreen (`QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software`) — it never
   touched the running shell or the user's desktop.
   - before: `h/base-small.png`, `h/base-tile.png`, `h/tok2.png`, `h/dev-tile.png`
   - after: `h/final-small.png`, `h/final-mast.png`, `h/final-dock.png`,
     `h/v4-dial.png`, `h/v4-storage.png`, `h/v5-tokens.png`, `h/v5-media.png`
   - compact regression: `h/compact-v2.png` (separate `compact.qml`, 8 cells)
3. **Font coverage audit** (`/tmp/opencode/sb1/glyphaudit.py`) — parses the
   `cmap` of both shipped faces (format 4 + format 12) and flags every non-ASCII
   character in the two files against the face that actually renders it.
4. **Boundary arithmetic** re-derived in Python to confirm the integer cell
   split is exact and ≤1 px spread.

The live HUD was left alone. `DP-1` later had other windows over it, so no
"after" live grab was forced; the offscreen render is the stronger evidence
anyway (true 2560×1440, deterministic frame, component isolated).

---

## What was wrong, and what changed

### 1. Flank columns were 750 px — the loudest source of mud
The mock's `.band` is `1fr 940px 1fr`, drawn at 1600×900 where each `1fr` is
≈270 px. On the 2560 px panel the same track inflates to **750 px**, so every
fact row carried ~450 px of dead space between its label and its value.

`colW` is now capped (`colWMax: 500`) and the slack becomes gutter. The columns
are pinned to the outer padding and the reactor is centred on the screen, so the
gutters stay symmetric for free (449 px each) and the knot — 816 px wide —
occupies the middle. Tile 750×222 → **500×222**; fact module 722 → 452 px.

The label column is now a real table: labels align on one left edge, values on
one right edge, `1fr auto` with the mock's 10 px column gap (was 8).

### 2. The TOKENS chart overflowed its own module
`MiniChart` was a fixed 44 px inside a 33.75 px equal slot, so it poked ~5 px
through the glass rim top and bottom. Row slots are now **cumulative integer
heights from a per-row `weight`** (`htile.slots`), the chart row carries
`weight: 1.7`, and the chart fills `max(28, slot − 4)`.

Each bar was a **250 px slab** (a 4-bar chart stretched across the tile). Bar
width is now capped at 48 px and centred in its slot, with the mock's vertical
gradient (`accent → accent @ 0.25`) instead of a flat fill.

### 3. Fabricated zeros on the dial (hard-rule violations)
- `rxRate` / `txRate` initialised to `0` and derived from a single counter when
  a key was absent → the face printed **"R 0 B/s · W 0 B/s"** before the second
  frame, and `aNet` clamped that to a real 0 % arc. Now both default to `-1`,
  require **both** counters plus a previous frame, and `aNet` maps to `-1`
  (bare track). `fmtRate()` returns `Style.unknownGlyph` for negative /
  non-finite input, so every call site inherits the rule.
- Hero numeral printed a hand-rolled `"--"` → now `Style.unknownGlyph`, and the
  `%` suffix hides entirely when the value is unknown.
- `loadText` gated on `load1` only → `3.14 · undefined · undefined` was
  reachable. Now requires all three keys.
- `tokBars()` pushed `v: 0` for a provider with no ledger entry → a
  zero-height bar that reads as "0 tokens". Now carries `unknown: true`, which
  renders a 2 px baseline stub in `Style.c.unknown` with a dimmed label.

### 4. Six glyph sites were silently falling back to a second font
`cmap` audit against `KodeMono-VF.ttf`: it carries `… → · ° × é — ↗ ↓ ↑` but
**not** `U+25CF ●`, `U+25C6 ◆`, `U+25B2 ▲`, `U+25B6 ▶`, `U+275A ❚`. Those five
were rendering out of an unrelated fallback face, off-baseline, in the middle of
otherwise monospaced lines — a large part of why the dial rows and the media
cell "looked like stock output". Replaced with marks the face actually has:
`◊` (U+25CA) for the identity band, `•` (U+2022) for the three status slots and
the top-consumer row, and ASCII `> ` / `|| ` for media transport. Michroma was
audited too — every one of its sites is pure ASCII, so no display-face fallback.
Re-running the audit now reports **zero** fallback sites.

### 5. Ring labels staircased into the face
CPU/GPU/MEM/NET were drawn right-aligned at the sweep start, so they stacked
diagonally down-right and the NET tag landed on top of the face readout. Each
tag now **rides its own ring in the sweep gap, rotated to the tangent**. Added
a 0° **index hairline** across the whole telemetry band (0.44 R → 0.90 R) so the
four rings read as one instrument with a defined origin.

### 6. The reactor was pasted on, not grounded
Two hard-edged black discs (1.22× / 1.10×, offset 7.5 % / 4.5 %) read as one
flat blob. Replaced with **one feathered contact shadow** — a transparent core,
a dark plateau, transparent again (`EllipseWash` with `core: 0.66`). The dark
glass backing that stops the ~50 % knot flood drowning the readout is still
painted by `discCanvas`; that comment is preserved verbatim.

`EllipseWash` is a new inline `Canvas` component in `CommandHub.qml` (QML's
`Gradient` is linear only — it has no radial orientation, verified by qmllint).
It is painted on geometry change only, never per frame. It does triple duty:
the field's top ice wash, the field's bottom acid lift, and the reactor bloom.

### 7. The field was a flat fill
Now: flat `#0b0e11` base (unchanged, zero cost) + three static elliptical
washes reproducing the mock's `.field` radial-gradients — ice off the top edge,
acid off the bottom, and a soft bloom behind the reactor so the dial sits in
light rather than on a void. All static.

### 8. Masthead: 1400 px void and a vertical wobble
- The right cluster was a `Row` with each item `anchors.verticalCenter`, so the
  22 px clock and the two 10 px data lines were each centred on the pane's
  middle instead of sharing a baseline. Now an `Item` with weather, clock and
  UP/LOAD all hung off **one shared bottom edge** = one optical baseline. Clock
  gained `letterSpacing: 2` (mock `.clock{letter-spacing:.1em}`) and the mock's
  extra 14 px before the UP/LOAD block. `loadText.replace(/ · /g," ")` preserves
  the original space-separated form, now safely.
- The centre void now carries a **feathered hairline split by a live cadence
  read-out**: `COLLECT 1.01 s`, or `—` until a second frame has been observed.
  The number is the measured `lastFrameGapMs`; there is no hardcoded "1 Hz"
  claim anywhere.

### 9. Dial face: a 100 px hole and no overflow guarantee
- Michroma's default line box is ~1.44 em, which left a 100 px void between the
  roll label and the numeral. `lineHeight: 0.86` (mock `.hero`) plus the
  mock's 4.5 % roll→hero margin and 3.4 % rows margin.
- The face `Column` had **implicit** width, so a long hostname or a full R/W row
  could push past the frosted disc's chord at the top and bottom of the stack.
  Now an explicit `0.56 × dial` with `elide` on every line.
- Uptime was printed **twice** (identity band *and* the clock row). The identity
  band is now `◊ HOST · STATE`; uptime lives with the clock. One duplicated fact
  removed.
- Minimum sizes raised one step (9→10, 8→9) — at the field's 5–7 % luminance the
  8 px tier was mush.
- Mock `.hero{text-shadow}` implemented as a 2 px larger ice ghost at 0.12 alpha
  **sharing the numeral's own box** (an earlier cross-branch anchor drifted it
  208 px left; concentric by construction now).
- `say()` chip was unclamped — a long utterance would have overflowed the dial.
  Now clamped to the face column with elide.

### 10. Labels in a tile never lined up
Rows carrying a fraction drew a 4 px bar; rows without skipped the slot, so their
label sat half a row lower than its neighbours (visible in STORAGE rows 3–4 and
all four MEDIA rows). The slot is now **always 4 px tall**, with only the inner
rectangles gated. Every label in a tile shares one baseline.

### 11. Radius scale was off by one
Facts glass was `Style.r.chip + 1` = 6, which is not on the token scale. The
scale is now monotonic inside-out and uses tokens only: pane 10 → tile 7 →
module 5. Dock chip `chip + 2` → `Style.r.emboss` (same 7 px, on-scale name).

### 12. Fact-module insets now match the mock
`anchors.margins: 9` (off-grid, and equal on all four sides) → **7 px vertical /
10 px horizontal**, the mock's `.body{padding:7px 10px}`. Column `spacing` 3 → 2
to reproduce `.body{gap:4px}` with `.fbar{margin-top:-2px}`. `FactRow`'s label
got `textFormat: Text.RichText` because `esc()` pre-encodes it — on the old
plain-text path an `&lt;` in a partition name rendered literally.

### 13. Duplicated mount field
An unlabelled partition fell back to the full mount path, so FILES/STORAGE
printed `/run/media/nexuslink/DRIVE · /run/media/nexuslink/DRIVE`. Added
`baseName()` plus a `m.mount !== m.name` guard.

### 14. Dock strip: fractional pitch, uneven gutters, no status
- The weighted pitch was `2466/17 = 145.06 px`, so every chip edge and every
  1 px hairline was smeared across two device pixels. Cell boundaries are now
  **integers**, from accumulated exact offsets rounded cumulatively. Measured:
  full profile widths `[145 ×16, 146]`, spread **1 px**; compact
  `[362, 213, 213, 213, 212, 213, 213, 213]`, spread **1 px** among the equal
  cells. (An earlier floor-and-dump-remainder version put the whole 7 px surplus
  on the last chip; caught by rendering the compact profile.)
- The first cell took `leftMargin: 0` while every other took 5 — gutter 0→1 was
  half the width of all the others. Now 5/5 everywhere → uniform 10 px gutters,
  matching the mock's `.util{gap:10px}`, with the hairline centred in the gutter.
  `cellH` retyped `real` → `int`.
- **Status dots**: a 5 px dot per cell driven by a new `cellState()` tri-state
  (0 unknown / 1 nominal / 2 attention / 3 active). It defers to `cellHot()`
  outright and otherwise reads the same keys `cellValue()` reads, so the dot
  cannot contradict the value line; a cell with no data gets a grey dot, never an
  optimistic ice one.
- **Elision killed.** 8 value lines and 6 sub lines exceeded the ~131 px usable
  width and were being silently truncated (`10 hist · DND on`, `newest:
  screensh…`, and a 25-character workspace list). All strings were re-budgeted
  to ≤14 chars (value, 12 px) / ≤19 chars (sub, 9 px), and `wsIdLine()` now shows
  three ids plus an overflow count (`1 · 2 · 3 +3`). The sub `Text` also got
  `textFormat: Text.RichText` for the same `esc()` reason.
- Three-tier type hierarchy per cell: tracked micro label (9 px, `mute`) →
  dominant value (12 px, `txt`) → faint sub / meter (9 px). Label tracking
  1.6 → 1.3.

### 15. Font tokens
Literal `10` / `9` / `8` pixel sizes replaced with `Style.f.pxLabel` /
`pxTag` / `pxMicro` where they existed, so the fact rows, chart caps, dock tiers
and the chassis caption all draw from one scale. The dock value stays a literal
`12` because the token set has no 12 (mock is 12.5) and 13 would elide.

### 16. The chassis caption described the renderer
`GRAPHITE CHASSIS · FROSTED CORE DISC · KNOT AT 50% FLOOD` is a design note
about the CSS, sitting in the UI. Same slot, same type treatment (9 px, 0.29 em
tracking, centred, above the dock) — now carrying the panel's own structural
identity: `DP-1 · 2560×1440 · 10 TILES · 17 CHANNELS`. Flagging this as the one
place where I changed *content* against the mock's literal string; the
composition, position and voice of the line are unchanged.

---

## Hard-rule compliance

| Rule | Status |
|---|---|
| No perpetual animation clocks | No timer added. The two existing 1 Hz timers are unchanged and are the documented telemetry-cadence poll drivers, both gated on visibility. `EllipseWash` canvases repaint on geometry change only; `discCanvas` static; `dialArcs` still telemetry-driven. No `Animation.Infinite` in either file. |
| Missing telemetry → `Style.unknownGlyph`, never a fabricated 0 | 6 sites fixed (§3). `fmtRate()` enforces it centrally. |
| Stay inside Style/Theme/KnotField/GlassPane APIs, no new deps | Import lines byte-identical; `qmldir` untouched; `EllipseWash` is a local inline component, not a module. All colours/radii/type still come from `Style`/`Theme`; `Style.tone()` used for the one new alpha. |
| Integer props get ints | `grep` for fractional `pixelSize` / `border.width` / `interval` / `duration` / `loops` → none. `cellH` retyped `int`; all `Math.max(n, Math.round(...))` integer floors retained. |
| No comments removed | Verified mechanically: every one of the 130 (`CommandHub`) + 81 (`UtilityDock`) pre-existing comment lines is still present verbatim. Net +80 / +29 comment lines. |
| `qmllint` exit 0 on both copies | repo **0/0**, deploy **0/0**, `diff -q` identical. |
| Deploy mirror, no shell restart | Copied; shell not touched. |

---

## Observed but deliberately not changed

- **`KnotField` size.** The knot renders 816 px behind a 595 px dial (the mock
  is 744 px behind a 760 px dial), so it is proportionally much larger than the
  reference. That is lane W2's documented operator decision — `px =
  round(dialSpec/44)` was deliberately widened so the knot reads *around* the
  disc edge — and the brief says keep the knot behind the reactor. Left alone;
  the new reactor bloom gives it a ground to sit on instead of competing with a
  flat field.
- **Even row distribution in tiles with fewer rows than slots** (DEVICES has 2
  rows in a 4-slot module, so they spread with air between). This is the mock's
  `.body{justify-content:space-evenly}` and is not noise; left as designed.
- **The `2 → 8` colour range of the live shell.** A profile scan of the running
  HUD reads 13–19/255 grey across the whole field. That is the established
  look (identical profile in `verify/out/*.png` from earlier lanes) and is
  shared with DP-2 / HDMI-A-3, so re-levelling it from these two files would
  break cross-screen consistency. What *was* fixed is the relative hierarchy
  inside these two files: the masthead baseline, the tile label/value grid, the
  dock's three tiers, and the dial's roll/hero/rows scale.

## Follow-ups worth another lane

- `Style.f.pxInsight` is `10.5` — the one non-integer pixel size in the token
  set, and it is what `EmbossedTile`'s insight line consumes. `Style.qml` is not
  this lane's file; flagging it because the same rule bites anywhere a pixel size
  is a token.
- `EmbossedTile`'s insight `Text` has no explicit `textFormat`, so it relies on
  `Text.AutoDetect` to render the accent markup the tiles feed it. It works, but
  it is implicit and would break on a label containing a bare `<`. Same file
  ownership note.
- `KodeMono-VF` has no geometric glyph set at all (`▪ ■ ○ ● ◆ ▲ ▸` all absent).
  A dot/diagonal set would let the HUD use real status marks instead of
  `◊`/`•`/ASCII transport. A font decision, not a code one.
