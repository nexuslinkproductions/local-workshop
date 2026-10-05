# LANE-SB2 — visual quality pass, HDMI-A-3 WORKBENCH

Owner: **SB2**. Files owned: `v4/Workbench.qml`, `v4/DeviceBay.qml`.
Mirror: `/home/nexuslink/.config/omarchy/plugins/nexuslink.hud/v4/` (byte-identical, shell **not** restarted).

The visual idea is unchanged — same pane column, same knot watermark, same
tab strip, same glyph device cards, same 8-cell dock. What changed is the
craft under it: one written-down grid, one pane chassis, honest fit
arithmetic, and a measured proof that nothing overflows.

---

## 0. Verification method (this is the evidence base)

`qmllint` proves types, not geometry. So the pass was verified three ways.

**0.1 — Lint, both copies, exit 0**

```
$ /usr/lib/qt6/bin/qmllint v4/Workbench.qml   ; echo $?   -> 0   (zero warnings)
$ /usr/lib/qt6/bin/qmllint v4/DeviceBay.qml  ; echo $?   -> 0   (zero warnings)
$ /usr/lib/qt6/bin/qmllint $DEPLOY/Workbench.qml  ; echo $?  -> 0
$ /usr/lib/qt6/bin/qmllint $DEPLOY/DeviceBay.qml ; echo $?  -> 0
```

Lint drove three real fixes that reasoning alone had missed, all of them
found by the linter and not by me: `left`/`right` as property names on a
`QQuickItem` subclass shadow final members and turn `parent.left` into a
QString inside every child (renamed to `meta`/`note`); a Repeater delegate
that reads `index` must declare `required property int index`; and
`implicitSize: 16` against a `size` property needs an int-typed stub.

**0.2 — A real Qt 6 engine, at the real window size**

`qmllint` cannot instantiate. A headless harness was built at
`/tmp/opencode/t/` (`refresh.sh` re-stages the two files verbatim, stubbing
only the three Quickshell C++ surfaces — `execDetached`, `iconPath`,
`Process`/`StdioCollector` — plus `Topology`, `AppGrid`, `UtilityDock`).
Driven by PyQt6 under `QT_QPA_PLATFORM=offscreen` at **1824x1128**, which is
the shipped size (`hud-state-v4.json` -> `fw 0.95 / fh 0.94` of 1920x1200).

Six data configurations x both tabs, **8 runs, all clean**:

| mode | tab | overflow | pane sum | slack | QML warnings |
|---|---|---|---|---|---|
| full stats + live Topology | APPS | 0 | 870 | 40 (= the 4 gaps) | 0 |
| full stats + live Topology | DEVICES | 0 | 870 | 40 | 0 |
| cold (no stats keys, no ledger) | APPS | 0 | 870 | 40 | 0 |
| cold | DEVICES | 0 | 870 | 40 | 0 |
| Topology answers "unknown" everywhere | APPS | 0 | 870 | 40 | 0 |
| Topology answers "unknown" everywhere | DEVICES | 0 | 870 | 40 | 0 |
| every node `state: "absent"` | APPS | 0 | 870 | 40 | 0 |
| every node `state: "absent"` | DEVICES | 0 | 870 | 40 | 0 |

`overflow` is a full-tree audit: every child of every `clip: true` item is
measured against its parent's box, across all **616 items**. `slack` is
`leftCol.height - sum(pane heights)`; 40 is exactly the four 10px inter-pane
gaps, so the five panes tile the column with no dead space and no clip.

**0.3 — Runtime text dump, as an honesty check**

Every `Text` in the tree was dumped in the cold configuration. That dump is
what caught two of the bugs below (`-1 events`, dash-soup telemetry chips)
which no static check would have flagged.

A screenshot was attempted and abandoned: the offscreen/vnc QPA backends
here cap the backing store and `grabWindow()` segfaults above 946x1200. The
geometry + text audits are stronger evidence for this pass than a picture
would have been, and the shipped size is what got measured.

---

## 1. Defects found and fixed (the "kill the noise" list)

| # | Defect | How it showed up | Fix |
|---|---|---|---|
| D1 | **Every pane body overran its box by 2px.** `GlassPane` insets the face by `edgeWidth` *before* `padding` applies, so the content box is `h - 2*edge - 2*pad`, not `h - 2*pad`. All five bodies were 2px too tall, so each pane's foot was shaved by the face clip. | harness: `ih=239 in h=237` on all five pane columns | `contentH` now reads each pane's own `edgeWidth` + `padding`; `leftCol.chrome` includes the 2px rim |
| D2 | **Masthead overflowed 12px.** The elastic spacer subtracted `4 * spacing` for a 6-child Row (5 gaps), so the clock was pushed 12px past the masthead's right inset. | harness: `mastRow implicitWidth 1780 vs width 1768` | masthead rebuilt as two groups — identity pinned left, counters+clock pinned right, the elastic gap implicit. No gap arithmetic left to get wrong |
| D3 | **`-1 events` in the GitHub foot.** `ghEvCount` is `-1` when the collector never reported; the foot printed the sentinel raw. | cold-mode text dump | `root.cnt(root.ghEvCount)` |
| D4 | **Dash soup on device cards.** With no telemetry the headset read `VOL — · —` and the radio `×— PAIRED · ×— LINK` — four dashes impersonating data. | bare-mode text dump | `joinParts()` takes `[text, known]` pairs; a part with no reading behind it is dropped, and a card with nothing to say says one `—` |
| D5 | **`"PULLRE"` as a label.** `substr(0, 6)` on `PullRequestEvent`. | full-mode text dump | `ghTypeTag()` maps GitHub's event names to `PUSH / PULL / ISSUE / ICMT / RVW / RVW-C / CMT / FPR / WATCH / FORK / NEW / DEL / REL / MEMB / PUB / GULM` |
| D6 | **Windows clipped mid-card, silently.** `winListCol` was a `Column` with no height and no fit: 12 windows were drawn until the face clipped them, with no indication anything was hidden. | audit of the old geometry | row count derived from the pane's content box; the overflow is declared in the foot |
| D7 | **The workspace strip could overflow the pane.** Chips were `min(textWidth + 16, 124)` wide with a plain `Row` — 14 long-named workspaces needed ~1736px in a 957px strip and were simply cut off. | code audit | fixed 66px pitch, deterministic fit count, and a `+N` fold chip that counts what it swallowed |
| D8 | **Token table could push a row past the pane's right edge.** `tokCFlex` was `Math.max(60, …)` — the floor protected the division but not the total, so a narrow window pushed ~50px past the face. | code audit | responsive `tokCSplit` (38% of the remainder, floored at 0) and `tokCFlex` (floored at 0); `TokBar`'s value column is a share of the cell, not a fixed 58px |
| D9 | **The token table's left edge floated 10px right of the pane inset** and did not line up with anything. `tokPad: 10` was double-counting GlassPane's padding. | alignment audit | `tokPad: 0` — the table, the row hairlines and the other four panes' cards now share one left edge |
| D10 | **The agent row's tail column was measured against the pill's *text* width**, not the pill's width, leaking 14px of padding past the row's right margin. | code audit | measured against the pill (`stPill.width`) |
| D11 | **A device whose nodes the collector never enumerated read `DOWN`** — a warn-coloured claim about a device nobody had looked at. | bare-mode text dump | `devState()` distinguishes "not enumerated" from "answered, nothing live" |
| D12 | **A non-present mic state leaked as a state name** (`VOL 42% · ABSENT`). | down-mode text dump | only a live mic is a reading; the full map stays in the popover |
| D13 | **"1 procs" / "1 locks".** | full-mode text dump | pluralised |
| D14 | **The masthead asserted a resolution it could not know**: a hardcoded `1920×1200` on a window the user can drag and resize anywhere. | code audit | `Math.round(root.width) + "×" + Math.round(root.height)` |
| D15 | **`"0 PROC SLOTS"` read as a process count.** It is a slot fill count — the collector only fills a slot above 0.5% of a core, and only from the second frame. | code audit + `collector/src/main.rs:517` | `"PROC 3/6"`, and the pane sub says `% of one core` / the foot says `N of 6 slots` |
| D16 | **`?` used as an unknown placeholder** for a window's class/workspace and a repo event's type — a literal question mark where the contract says `—`. | code audit | `root.unk` throughout |
| D17 | **Five hand-rolled pane headers that could drift** apart in tracking, baseline and inset, and one of them (the token pane) had already drifted into a different structure. | code audit | one `PaneHead` component |

One thing I *believed* was a defect and was wrong: the knot watermark. I
suspected a 0x0 Canvas, "fixed" it, and the A/B measurement showed the field
at 672x686 both before and after. Qt 6 propagates `implicitWidth` to `width`
for an item with no explicit width (proved with a minimal Canvas/Rectangle/
Item case). The change was reverted and the comment rewritten to state what
is actually true. Reported here rather than quietly dropped.

---

## 2. The craft changes, in the order they appear on screen

### 2.1 One grid (`met` in Workbench.qml)

```
pad 12 · headH 13 · footH 13 · innerGap 5 · gap 10
lsHead 3 · lsMast 4 · lsTag 2
wash / litLine / selFill          — the hover + selection tones, once
```

`pad` is handed to GlassPane's own `padding`, so the glass bevel owns the
inset and no pane body restates it. The five ledger panes, the tab strip and
DeviceBay's grid all sit on the same 12px column. Before this pass the left
panes used 10 and the right column 12, side by side.

### 2.2 The pane chassis — `PaneHead`, `PaneFoot`, `EmptyNote`

Every ledger pane is now **head / content / foot**:

- `PaneHead` — 14x2 accent tick, Michroma 10 title at +3 tracking, quiet 8px
  mono sub, optional right-hand meta. This is the same three-part shape
  AppGrid already uses for its own head, so the left ledger and the right tab
  page stopped being two dialects of the same screen.
- `PaneFoot` — hairline + 8px mono status line, always present. Every pane
  declares what it holds and what it dropped, in the same place, in the same
  type. Slack above a foot reads as deliberate air above a status bar; the
  same slack with no foot reads as a list that was cut off.
- `EmptyNote` — the unknown glyph carries the "no data" statement and the
  words after it stay quiet. One component replaced five ad-hoc texts that
  disagreed with each other (`"— no process telemetry"` vs `"no windows"`
  with no glyph at all vs `"— ledger: no local feed"`).

`PaneHead` is deliberately **not** clipped: a 10px Michroma cap is ~14px tall
and the band is 13, so a clip shaves the title. Both texts elide instead.

### 2.3 The pane budget — five heights that sum to the column exactly

Each pane is sized from a **fixed row capacity** (how many rows it is
designed to hold at its minimum readable row height) rather than a fraction
of the column, so closing a window never resizes a pane and nothing shifts
under the cursor. `stretch` is the slack between the column and the five
natural heights; each pane takes a share bounded by the height its own rows
can actually fill, and the token ledger takes the largest share because it is
the one pane whose content length is unknown. Below the natural total the
same shares squeeze proportionally, so the column degrades evenly instead of
clipping the ledger away.

At the shipped size the budget is **exact** — no slack, no air, no clip:

| pane | height | rows | row height | declared in the foot |
|---|---|---|---|---|
| WINDOWS / WORKSPACES | 261 | 4 of 9 | 40 | `showing 4 of 9 windows` / `9/9 ws` |
| AGENT SESSIONS | 138 | 3 of 3 | 22 | `3 harnesses` / `4 live procs` |
| PROCESS LEDGER | 142 | 4 of 6 slots | 17 | `showing 4 of 6 slots` / `peak 63%` |
| GITHUB ACTIVITY | 142 | 4 of 6 events | 17 | `showing 4 of 6 events` / `3 unread` |
| TOKEN LEDGER | 187 | 4 of 5 feeds | 17 | `showing 4 of 5 feeds` / `ledger 3m ago` |
| | **870** | | | + 4x10 gaps = **910** = `leftCol.height` |

Each foot earns its place rather than repeating the line above it: the
windows foot adds the workspace total, the agent foot a live-process
roll-up, the process foot the busiest slot, the GitHub foot the unread
count (the only figure that earns the warn tone — a row count is not a
warning), the token foot the ledger's freshness.

### 2.4 Masthead

Identity left, live counters and clock right, one hairline between them.
- Resolution is **measured** (`Math.round(root.width) × …`), not asserted.
- `PROC 3/6` states what is actually known: a slot fill count, with the
  threshold named in the pane below it.
- Michroma 15 title at +4, Michroma 16 clock at +1.5 in ice-cyan, 9px mono
  counters — three levels, no fourth.
- The holo rim is inset 1px from the top border (the 1px edge now reads
  *above* the light bar instead of being overdrawn by it) and aligned to the
  content inset so its ends line up with the title and the clock.
- The subtitle is clamped to a fixed 340px ceiling with a note on **why**:
  deriving it from the Row's own width makes a feedback loop through
  `implicitWidth` that settles on the 60px floor and elides the whole
  subtitle away. That one was measured, not theorised.

### 2.5 Rows

- **Window cards** — 40px: 24px icon well, 17px icon, title at 10px over
  class/address at 9px in the faint tone, workspace badge in Michroma, owning
  display right-aligned. Hover gets a 2px lit rail on the leading edge — the
  same affordance the tab chips use, so the language is shared. Unreachable
  rows (no address) do not light up: the rail and the wash are gated on
  `live`.
- **Process rows** — fixed height with a vertically centred content row
  (they used to hug their text at `implicitHeight`, 13px tall with 4px of
  spacing, which reads as leftovers). Selection is now an accent wash **and**
  a 2px rail, not a lone 1px border on a transparent fill.
- **Repo rows** — the event class drops to 8px so the repo name (the subject)
  leads and the age reads as metadata. The GitHub status left the wobbly
  `Row` it lived in — the unread count shifted left every time `gh ok`
  changed width — and is now pinned in the head and the foot.
- **Agent rows** — 22px, state pill, right-aligned CPU, and a live-process
  tail whose width is measured against the pill.
- Every card in both files shares `met.wash` / `met.litLine`; the hover tint
  used to be written out as `Qt.rgba(0.56, 0.85, 0.91, 0.07)` in six places,
  one of them at `0.06`.

### 2.6 Token ledger

- The 4-cell summary strip keeps integer cell boundaries
  (`Math.floor(width / 4)`, last cell takes the remainder) so the hairline
  dividers land on whole pixels instead of a fractional `width/4` four times.
- `TokStatCell` insets are symmetric 10/10 — a value was sitting 8px from the
  divider and 10px from the pane edge.
- Only the TODAY cell is cyan; WEEK/MONTH/BURN are `txt`; the muted sub-tail
  dropped from `t55` to `t40` so it cannot be read as a second value.
- The truncation note moved out of the table and into the foot, which frees a
  row slot: at the shipped size all 4 provider rows fit where the old
  `+N more` pseudo-row had eaten one.
- The head-right is the feed count (or `—  no feed`); the foot is what the
  table is showing plus the ledger's age. An empty ledger file and an
  unreadable one look identical from here, so the foot says
  `ledger empty or unreadable` rather than claiming `0`.

### 2.7 Tab strip

- Labels up from 8px to 9px Michroma — at 8px the `DEVICES` chip was the
  least legible type on the screen.
- Inactive chips lose their border (a tab strip does not need outlines);
  active gets the dark well, the accent border, the accent label, **and** a
  2px accent bar riding the strip's own hairline.
- The right-hand hint is now anchored between the chips and the pane edge and
  elides, so a long subtitle can no longer shove the tabs off the pane.
- `appsPanel` keeps `padding: 0` on purpose: the strip owns its own 12px
  inset so both tab pages keep the geometry AppGrid already lays out for.

### 2.8 DeviceBay cards

Card anatomy is the original — label top-left, state top-right, pictogram
centre, telemetry chip bottom-centre — with four additions that earn their
place:

- **A `sub` line under the label** (`logitech lightspeed`) in the faint
  tone, so the card identifies the model *and* the vendor line instead of
  eliding the label.
- **A hairline closing the head band**, the same 1px `edge` at 0.7 the pane
  chassis uses.
- **The state as a word** (`UP` / `DOWN` / `UNKNOWN`) under a dot that now
  sits in a static 13px ring. A 6px dot was the only signal, and it is a
  weak one. No pulse, no clock — the ring is a static border.
- **The card label promoted from `t55` to `txt`.** The card's identity was
  the *least* prominent thing on it, while the state word was the brightest.
  The state is a different hue, so both can be bright without competing.

Geometry from one place (`colW / headH / chipH / rowGap`, `gridRows` from the
model rather than a hardcoded `/4`). The glyph canvas is now sized from the
band between the head rule and the chip, at a 7:5 box so the widest pictogram
— the keyboard deck at 0.92u — still clears the canvas. Measured: **177x127
in a 383x204 card, 4 rows tiling 777x846 with 2px of slack, zero overflow.**
The detail pass is a 0.42-alpha dim *of the same ink*, so a grey "unknown"
glyph still has readable internal detail instead of vanishing into the card.

**Deliberately not added:** a `PERIPHERALS` header band above the grid. The
tab strip already names the tab, and a second header under a `DEVICES` chip
is the exact kind of leftover this pass exists to remove. (AppGrid has the
same redundancy; it is not this lane's file.)

### 2.9 Popover

Same chassis as the panes: tick + title, sub, hairline, table, and a pinned
foot. The state moved out of the sub line and into the foot, so the foot
states something new instead of repeating the line above it. Key column
`100px` named once (`pop.keyW`) instead of a `104` and a `110` that had to
agree. `boundsBehavior: StopAtBounds` on the scroll.

Measured with a real selection (`selDev = "flash"`):

```
flash_kingston   DataTraveler 3.0
state            mounted
link             5 Gb/s
usb              sda
sda1             /media/nexuslink/KINGSTON · 71%
UP                                    click outside to close
```

### 2.10 Motion

No timers were added and no animation clocks exist. `rg` over both files
finds exactly one `Timer` — the pre-existing 1 Hz `HH:mm:ss` readout. The
knot is `running: false` (one static lit frame, no cadence timer armed),
GlassPane's `busy` rim is never armed, and there are no `Behavior on`s.

What did change: `tokAgeText` and `tokBurnPerHour` now read
`minuteNow`/`minuteTick` — a **division of the existing 1 Hz tick**, not a
second timer — so those two bindings (and the token model behind them)
re-evaluate once a minute instead of once a second. `root.now` still drives
`clockText` at 1 Hz. No new clock; 60x less work on the ledger path.

### 2.11 Watermark

`seed` pinned to a constant. KnotField documents `seed < 0` as "auto-draws at
completion (still unique per instance)"; a *static* watermark should be the
same personality on every shell reload rather than re-rolled at construction.
Also measured and recorded in the comment: the field lands 672x686 (48x49
cells at `px = 14`) and is visible.

---

## 3. Hard rules, checked

| Rule | Status |
|---|---|
| No perpetual animation clocks/timers | 1 `Timer` total, pre-existing, the `HH:mm:ss` readout; `running: root.visible`; no `Behavior on`, no `NumberAnimation`, no `SequentialAnimation` |
| Missing telemetry renders `—`, never a fabricated 0 | Verified by text dump in the cold configuration: `— WS · — WINDOWS · PROC 0/6`, `— workspaces unknown`, `— acp · — locks`, `— no process over 0.5% core`, `peak —`, `— gh`, `— repo events unknown`, `— events`, `— unread`, `ledger empty or unreadable`, `— no feed`. `PROC 0/6` and `0 of 6 slots` are slot *fill* counts, which is what the collector knows |
| Stay inside Style/Theme/KnotField/GlassPane/AppGrid APIs, no new deps | `import` lines unchanged in both files; only `Style.r.pane`, `Style.tone`, `Style.unknownGlyph` and the module's own singletons are used. Harness stubs exist only in `/tmp`, never in the deliverable |
| Integer QML props get ints | every `readonly property int` is fed `Math.floor/round/max/min` over integers; no float literal assigned to an int prop |
| GlassPane reparents children (`contentData`) | children anchor to `parent` (20 `anchors.fill: parent`); `rg` finds **zero** anchors to a pane id |
| No comments removed | 337 comment lines in Workbench, 103 in DeviceBay; nothing deleted, only added or made accurate |
| `qmllint` exit 0 on both copies | verified, zero warnings, twice (post-edit and post-deploy) |
| Compact idiomatic code | the pane budget replaced a hand-counted `spacing * n` subtraction with one `sized()` clamp shared by five panes |

---

## 4. Known limits, stated rather than hidden

- **Below ~780px of window height the floors bind and the column clips.**
  `leftCol.clip` absorbs it and the bottom of the token pane goes first. The
  floors are chrome + one row (three for the agent roster, so a harness is
  never hidden). Chosen over letting a pane show a 13px row.
- **The token table is floored at 4 provider rows by its own minimum row
  height.** With 5 providers it shows 4 and says so. Adding providers means
  either a taller window (the stretch shares give them room up to 30px rows)
  or accepting the truncation notice.
- **The harness lives in `/tmp/opencode/t/`** and is not part of the deliverable.
  It is throwaway; the report is the durable artefact. `refresh.sh` is the
  only piece worth keeping, and only because it proves the QML under test is
  byte-identical to the repo apart from the three Quickshell C++ stubs.
- **No screenshot.** The offscreen and vnc QPA backends here cap the backing
  store and `grabWindow()` segfaults above 946x1200, so the shipped
  1824x1128 could not be captured. The geometry and text audits are what
  stand in for one, and they are checked rather than eyeballed.

## 5. Files

```
v4/Workbench.qml   2303 lines   (was 1899)
v4/DeviceBay.qml    911 lines   (was 740)
```

Both copied to `/home/nexuslink/.config/omarchy/plugins/nexuslink.hud/v4/`
and `cmp`-verified byte-identical. The shell was **not** restarted.
