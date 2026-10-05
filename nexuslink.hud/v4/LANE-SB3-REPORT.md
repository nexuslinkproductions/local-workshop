# LANE-SB3-REPORT — Navigator + AppGrid visual quality pass

Scope honored: `v4/Navigator.qml`, `v4/AppGrid.qml`, this report. No other
file touched. Mirror synced with `cp` to
`~/.config/omarchy/plugins/nexuslink.hud/v4/` (no shell restart).

Everything visual was preserved in intent: mounts, jumps, preview, the keyboard
contract, the IPC handlers, category decoding, usage-count ordering, XDG merge
precedence, the `gtk-launch` argv path. Nothing was removed from the data model
or the key map.

## 0. How the defects were found

No claim in this report is estimated. Layout was measured with Pango against
the exact faces the `FontLoader`s pin (`Michroma-Regular.ttf`,
`KodeMono-VF.ttf`) at the exact pixel sizes and `letterSpacing` values shipped,
and the numbers below are before/after from the same harness
(`/tmp/opencode/measure.py` → `measure2.py`).

Two of my own first-pass measurements were wrong and were corrected before any
code was written: the MODIFIED column **does** already align with the delegate
(584/584 and 714/714), so the tail-column geometry was left alone; and the
longest non-file `meta` string (384 px) **fits** in the 660 px available, so
the meta cell was clamped and headered rather than reported as overflowing.

Lint was also run with the Quickshell type descriptions on the import path
(`-I /usr/lib/qt6/qml`), which upgrades the check from "unresolvable" to real
type checking. A negative control confirmed the harness catches a bogus
property, so the zero-diagnostic result below is meaningful.

## 1. Measured layout overflow — FIXED

**The rail did not fit.** It was one `Column` whose children needed **933 px
inside 774 px**:

| block | px |
|---|---|
| SECTIONS hdr + 6 × 38 buttons | 287 |
| MOUNTS hdr + list (cap 264) | 288 |
| JUMPS hdr + list (cap 200) | 224 |
| CONTEXT hdr + text | 70 |
| Column spacing | 56 |
| **needed** | **933** |
| **available** | **774** |
| **overflow** | **+159** |

The `Column` had no `clip`, so the CONTEXT block and the tail of the JUMPS
list painted straight over the list column.

Rebuilt as three explicit zones (`Navigator.qml:1690-2010`):

- **A — sections, fixed:** 22 hdr + 6 × 34.
- **B — mounts + jumps, flex:** `listZone.free` = slack after both 20 px
  headers and the gap; MOUNTS takes 62 %, JUMPS the rest. Each list is
  `min(contentHeight, cap)` and scrolls when it exceeds the cap.
- **C — context, pinned bottom:** header + a fixed 2-line, `ElideRight` block.

Re-measured: **sum 776 / available 776 / overflow 0.** MOUNTS cap 243 px
(12 entries = 465 px → scrolls), JUMPS 149 px (358 px → scrolls). The caps are
now honest and field-relative instead of hardcoded constants that overflowed
anyway.

## 2. Measured action-chip overflow — FIXED

Four chips at `(372 − 27)/4 = 86.2 px` had to hold **"TERMINAL HERE" = 90.0 px**
— unclamped, unelided, no width — so the label spilled into its neighbour.
Five chips (the `+x` case) left only 5.2 px of slack.

The even split is gone. The row is a `Flow` of intrinsic-width chips
(`Navigator.qml:2640-2712`): label + a real keycap well + 20 + 12. Measured:

| action set | chips | widest | usable | result |
|---|---|---|---|---|
| file | OPEN 109, TERMINAL HERE 127, COPY PATH 104, REVEAL 86 | 127 | 376 | fits, 2 rows |
| exec (+x) | RUN 103, OPEN 74, TERM HERE 103, COPY PATH 104, REVEAL 86 | 104 | 376 | fits, 2 rows |
| proc | FOCUS WINDOW 157, SIGNAL TERM 116, OPEN /PROC 110 | 157 | 376 | fits, 2 rows |
| repo | TERMINAL HERE 163, COPY PATH 104, REFRESH 92 | 163 | 376 | fits, 1 row |

The key moved from a second text line inside the chip to an engraved cap,
which is both shorter and the thing a real product shows.

## 3. Elide starvation — FIXED

- **Mount name column** was handed `232 − 14 − fsW − 32 = 166 px` where 178 px
  was available — 12 px short, so mount paths elided early. The tail block is
  now anchored (`iconGlyph.right → fstype.left`) instead of hand-summed, and
  the path elides **left**, keeping the tail of a long mountpoint, which is
  what actually distinguishes two mounts.
- **JUMPS label** was 196 px against 208 px available. Same fix.
- **AppGrid name cell** was 11 px short (measured across four meta samples),
  giving a 10 px icon→name gap against a 23 px name→meta gap. Now anchored
  (`iconWell.right → right margin wMeta+g2+wCount+g2`).

## 4. Column alignment

Replaced the hand-summed `Row` + `Math.max(40, parent.width − …)` in the
delegate with an anchored tail block, and made the column header read the same
three numbers (`listCol.wSize` / `wMtime` / `wMeta` / `tailW`). Header and data
can no longer drift apart. Verified: NAME at 42 = 14 gutter + 16 glyph + 12
gap, tail right edge 726 = 740 − 14, both identical on the header and the
delegate, for files (188 px tail) and the other five sections (220 px).

`metaText` was unbounded and unelided. It is now a fixed right-aligned column
that renders `—` rather than blank when the value is missing.

## 5. Type hierarchy

The wordmark and the breadcrumb sat in the same optical band (disp 12 / 133 px
vs mono 12), so the header read as one run of text.

- Wordmark → disp 13 / ls 3.0, preceded by a 3 px acid tick.
- Breadcrumb → mono 11, bounded to `searchBox.x − 16 − 20` so it can never
  collide with the field (the old bound was a guessed `card.width − 560`).
- A type ramp (`th.pxWord … th.pxMicro`) replaced the scattered 8/9/10/11/12
  literals, and a 4 px spacing ramp (`th.g1 … th.g5`) replaced ad-hoc margins.
- Section rail labels: `charAt(0) + slice(1).toLowerCase()` produced
  "Files"/"Processes" in mono 12, fighting every other engraved caps label in
  the HUD. Now the raw caps at disp 10 / ls 1.6 (109 px for PROCESSES).
- Rail section buttons 38 → 34 px, rows 32 px, AppGrid rows 30 → 34 px.

## 6. Selection, hover, and the three-identical-fills problem

Active mount, active section, and selected row were **all** `#161a20` — three
different selection semantics sharing one fill, with no hover state anywhere
in the rail or list. Now:

- Selection = 2 px acid bar + a `selFill` lift + a 1 px `accentDim` keyline.
- Hover = a separate, weaker `hovFill` step + a `ruleDark` keyline.
- `Behavior on color/opacity`, 180 ms `OutCubic` — event-driven on pointer and
  selection changes, **not** a clock.
- `border.width` is now a constant 1 px in both delegates. It used to be
  `sel ? 1 : 0`, and since a QML `Rectangle` draws its border inside its own
  rect, every selection move shifted the row's entire contents 1 px.

Type glyphs all rendered the same ice regardless of type, which is what made
`typeIcon()` decorative. `fileIconColor()` / `rowIconColor()` now tint by kind:
folders and media cool, executables and agents acid, archives warn, code/doc
neutral.

## 7. Preview pane

- **`previewTitle` was written by every `refreshPreview()` branch and never
  rendered** — the pane had no heading. It is now a 20 px title with the kind
  as an engraved ice badge (`previewKind()`), and `—` when unknown.
- The readout was flat `Text.PlainText` at 11/1.62, so `#` command lines,
  `key␣␣value` pairs and parenthesised notes all rendered identically.
  `previewRich()` styles them — command lines ice, key/value split dim-key /
  lit-value, notes italic and receded. Every interpolated value goes through
  `escHtml()`, lines join with `<br/>` (a raw `\n` is not a reliable break in
  QTextDocument), and styling is bounded to a 16 KiB window with the remainder
  appended as escaped plain text, so nothing that used to be visible is hidden.
- The readout had **no scroll affordance** — long files were silently cut off.
  A 2 px ice indicator now appears only when `contentHeight > height`, and
  brightens while the view is moving.
- `previewInfo` was a second recessed well stacked under the first. It is now
  a 20 px rule-and-detail line with a right-aligned `sel/total` position
  counter.
- The well got a recess gradient plus a top shade and bottom inner light, so it
  reads as a screen rather than a flat swatch.

## 8. Empty states

One dim 12 px line centered on the whole list column — which also meant it
centered over the back row and the column header. Now a two-line state
centered in the rows region: glyph, engraved title, detail
(`emptyTitle()` / `emptySub()`). `emptyText()` was subsumed by that pair and
removed; its one distinct sentence ("permission denied — not readable")
survives in `emptySub()`, and the two comments that referenced it were
repointed rather than dropped.

**Fabricated-sentinel fix:** `contextText()` case 3 defaulted an absent
`agents_procs` to `"?"` and an absent `devsess_count` to `"0"` — a made-up
reading. Both now fall back to `—`.

## 9. Card, bezel, and the scanlines

- **No elevation.** A fullscreen modal with a border and no shadow reads flat
  on the scrim. Added a static offset plate (2 px halo, 10 px skirt), the
  GlassPane idiom — no filters. Inlined as `rgba(0,0,0,.385)`, which is what
  `Style.shadow(black, 26)` resolves to, to keep this file's `Style` guard.
- The top bevel was a hard 1 px white line across 1420 px; now a horizontal
  gradient that fades at both ends. Holo strip opacity 0.75 → 0.55.
- **The scanline sheet was the main source of noise.** It painted a 1 px black
  line every 3 px across the whole 1420 × 876 card at 0.5 × 0.09 — crossing
  every 11 px glyph in the list and the readout. It is now painted **only in
  the two chrome bands** (header 56 px, footer 44 px) via a single `if` in
  `onPaint`; the middle is never drawn. Same cue, same cost, zero mud on text.
  One `Connections` repaints it on card geometry change.

## 10. Footer

`anchors { left, right }` on a `Row` does not right-align its last child, so
`countText()` floated mid-bar after the legend with a dead `Item { width: 8 }`
spacer next to it. The count is now its own right-anchored item. The legend
moved from a `RichText` string with `&nbsp;&nbsp;` to real engraved keycap
wells. Both header and footer rules are now **engraved** (a lit line over a
shade, `ruleLit` / `ruleDark`) instead of a lone 1 px black line, which reads
as an aliased crack on this chassis. Same treatment on the two column
dividers.

## 11. AppGrid specifically

- **Duplicated messaging.** The pane header said "APPS NAVIGATOR … gtk-launch"
  while the workbench tab strip 34 px above already says "installed apps ·
  gtk-launch". The header now says "APPS" and carries live state (`N entries`,
  or `shown / total` while filtering).
- **Filter field**, 30 → 32 px: recess gradient + top shade + bottom inner
  light, a `⌕` glyph instead of `/`, an anchored query (the old
  `width: parent.width − …` read the `Row`'s own implicit width, which is
  self-referential), a real hover state, and an armed acid bar. The dead
  `Item { width: 1; height: 1 }` spacer is gone. "type to filter…" and the
  footer's "click field to type" said the same thing twice; the field owns the
  affordance now.
- **Section headers** were an 18 px band with a 10 × 2 bar and an 8 px label,
  no rule and no count. Now a 24 px band: title, rule filling the slack, and a
  live tally from `sectionTally()` — counted once per `refilter()` into
  `sectionCounts`, not per header render. A header that cannot say how many
  entries it holds has to be trusted blind. `MOST USED` keeps the leading acid
  tick because it is a rank, not a category.
- **Selection** was a full-acid 1 px border — the loudest element in the pane —
  and hover used the *same* fill as selection (`pal.ink`), so hover read only
  as a border change. Now a 2 px bar + `selFill`, with `hovFill` as a distinct
  weaker step.
- **Icons** sit in a 24 px recessed well at 18 px; unresolved names still draw
  the `▢` mark, never a fake image.
- The usage count left the meta string as a `"12× · "` prefix, so counts never
  formed a column. Now a dedicated right-aligned `USE` column (34 px), with the
  meta in its own 200 px column. `useCell()` returns `—` for a count it cannot
  read rather than implying zero.
- Two-line empty state, replacing a single centered `"— no match"`.
- Footer keycaps only when the grab is armed; disarmed it is a plain sentence.
  Rendering the word "click" inside a keycap well would claim a key that does
  not exist.

## 12. Rule compliance

- **No perpetual clocks.** The three repeating timers keep their
  `running: root.navOpen && root.section === N` gate (0 / 1 / 4). Zero
  `loops:` or always-running animations were added. The 14 `Behavior on`
  blocks are pointer/selection state transitions.
- **Missing data renders `—`.** Fixed the two fabricated defaults in
  `contextText()`; `previewKind()`, `sectionTally()`, `useCell()` and the empty
  state all return `—` rather than blank or zero.
- **Integer props get ints.** `th.g1…g5`, `rRow`, `rKey`, `cntW`,
  `pxWord…pxMicro`, `listCol.wSize/wMtime/wMeta/colGap/tailW/topPad/rowsY` and
  `pal.iconWell/wCount/wMeta` are all `property int`. The rail's `free`/`mntH`/
  `jmpH` stay `real` because they derive from a `real` height, and
  `implicitWidth`-derived widths stay `real`.
- **GlassPane reparenting.** No `anchors.fill` against a pane id was
  introduced; AppGrid still binds to `parent`, and its explanatory comment is
  intact.
- **No comments removed.** The one deletion was `emptyText()`, whose body was
  fully subsumed by `emptyTitle()` + `emptySub()`; a replacement comment
  records that, and the two comments that referenced it were repointed.
- **argv-safe exec only.** All four `execDetached` call sites are unchanged
  from baseline: `exec "$@"` positional-parameter vectors, and
  `["gtk-launch", id]`. No shell concatenation was introduced.

### Defects found in my own first pass, and fixed before shipping

1. Four keycap wells were declared `Item` while carrying `radius` / `color` /
   `border` — they would not have rendered. Caught by lint.
2. A rule in the SECTIONS header referenced `secTitle`, which is the id of the
   *button delegate's* label, not the header's own text. Reached into a
   `Repeater` scope. Renamed to `secHdrTitle`.
3. `colHead`/`foot` in AppGrid carried `anchors.top` while being children of a
   `Column`, which owns `y` for its children — a runtime positioner conflict.
   The `Column`'s own `spacing` already supplies the gap.
4. The search box's `onEntered`/`onExited` assigned `border.color`
   imperatively, which **destroys** the `root.searching ? accent : …` binding —
   the first hover would have permanently beaten the armed state. Converted to
   a `containsMouse` binding, matching AppGrid.
5. Removing the list view's 12 px side margins moved the header 12 px off the
   data. Header margins re-derived (42 / 14) and re-measured against the
   delegate.

## Verification

    $ cd v4
    $ /usr/lib/qt6/bin/qmllint Navigator.qml ; echo $?
    0
    $ /usr/lib/qt6/bin/qmllint AppGrid.qml ; echo $?
    0

Strict pass with the Quickshell type descriptions on the import path, so
`PanelWindow`, `IconImage`, `Process`, `FileView`, `FolderListModel`,
`StdioCollector`, `HyprlandFocusGrab` and `IpcHandler` are genuinely
type-checked rather than skipped:

    $ /usr/lib/qt6/bin/qmllint -I /usr/lib/qt6/qml -I . Navigator.qml
    Warning: Navigator.qml:1457:5: Type PanelWindow is not creatable.
    Warning: Navigator.qml:2782:13: Type PanelWindow is not creatable.
    $ /usr/lib/qt6/bin/qmllint -I /usr/lib/qt6/qml -I . AppGrid.qml
    (no output)
    $ # non-PanelWindow diagnostics: Navigator 0, AppGrid 0

The two `PanelWindow` warnings are pre-existing and environmental — Quickshell
exports those as C++ runtime types with no `.qmltypes` entry. They were present
at baseline. The four `unqualified-access` warnings that existed at baseline
(the action `Repeater`) are gone.

Mirror, same two commands, same results:

    $ cd ~/.config/omarchy/plugins/nexuslink.hud/v4
    $ /usr/lib/qt6/bin/qmllint Navigator.qml ; echo $?     -> 0
    $ /usr/lib/qt6/bin/qmllint AppGrid.qml ; echo $?       -> 0
    $ diff -q Navigator.qml <source> ; diff -q AppGrid.qml <source>   -> identical

## Files

- `v4/Navigator.qml` — token ramp, three-zone rail, header hierarchy, anchored
  list columns, styled preview + Flow actions, footer, bezel-only scanlines,
  elevation plate, two fabricated-sentinel fixes.
- `v4/AppGrid.qml` — `sectionCounts` + `sectionTally()` + `useCell()`, token
  ramp, header/filter/section-band/row/footer pass, anchored tail columns.
- `v4/LANE-SB3-REPORT.md` — this file. Synced: Navigator.qml, AppGrid.qml,
  LANE-SB3-REPORT.md → `~/.config/omarchy/plugins/nexuslink.hud/v4/`.

Shell not restarted.
