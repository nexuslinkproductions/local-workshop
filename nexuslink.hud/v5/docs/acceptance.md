# I1 acceptance evidence — v5 DP-2 deck

Card: `t_f7a6561e` (I1 integrator). Branch `v5/integrator`, base `origin/v5/main-deck`.
Target surface: 2560x1440. Every number below is from a command run on this Mac
(macOS 26.4.1, arm64, Qt 6.12.0, Metal).

> **Knot.** The deck composes W1's `kit/Knot.qml` (PR #51, the 540 px triquetra
> rebuilt on the s2 trace) at `Tokens.knotCentreX/Y` with `Tokens.knotDiameter`.
> That PR was in a repair round while this branch was being built; the layout,
> word count, overlap audit, motion and perf below were all measured again after
> the component replaced the 540x540 guide placeholder that stood in for it.

## 1. Render path

`tools/qml-shot.sh` is the project's one offscreen renderer (QQuickRenderControl
+ RHI readback; the plain offscreen window path draws `ShaderEffect` as a black
frame on this Mac). The deck needs the `NexusHud.V5` module import path, so
`v5/tools/deck-shot.sh` sets it up (`NexusHud/V5 -> v5/kit`) and calls it:

```
nexuslink.hud/v5/tools/deck-shot.sh nexuslink.hud/v5/stills/i1-deck-rest.qml \
    nexuslink.hud/v5/stills/i1-deck-rest.png
```

| still | command | exit | harness line |
|---|---|---|---|
| rest | `deck-shot.sh stills/i1-deck-rest.qml stills/i1-deck-rest.png` | 0 | `mode=rhi api=metal image=2560x1440 distinct=182` |
| crew focus | `deck-shot.sh stills/i1-deck-crew-focus.qml …` | 0 | `mode=rhi api=metal distinct=248` |
| launcher focus | `deck-shot.sh stills/i1-deck-launcher-focus.qml …` | 0 | `mode=rhi api=metal distinct=164` |

Stills: `v5/stills/i1-deck-rest.png`, `v5/stills/i1-deck-crew-focus.png`,
`v5/stills/i1-deck-launcher-focus.png` (PNG, 2560x1440) and the same three at
full size as JPEG (`.jpg`, 116 to 196 KB) for reading in chat. The harness fails
below `QML_SHOT_MIN_DISTINCT`, which `deck-shot.sh` sets to 64, so a silently
flat frame exits 1.

### Fonts

Every render above is Satoshi, and that is measured, not assumed.

* The still harness itself reports the resolved family. `tests/i1/FontProof.qml`
  composes the same deck and prints what the engine has:

  ```
  nexuslink.hud/v5/tools/deck-shot.sh nexuslink.hud/v5/tests/i1/FontProof.qml \
      "$TMPDIR/font-proof.png" 2>&1 | grep -E 'FONT|Cannot load font'
  qml: FONT {"family":"Satoshi","familiesHasSatoshi":true,"familiesCount":249,
    "clockDigit96":63.359,"clockDigit96Fallback":58.203,"clockOne96":63.359,
    "clockColon96":27.063,"clockColon96Fallback":20.797,
    "label16":101.672,"label16Fallback":102.188,
    "value20":62.984,"value20Fallback":62.047}
  ```

  The `grep` covers both halves of the claim: the FONT line prints, and no
  `Cannot load font` line does.

* `deck-audit.py` compares every painted `Text` three ways (its own advance, a
  Satoshi twin, a fallback twin): at rest **16 of 16 decisive texts carry the
  Satoshi advance, 0 the fallback one**; crew focus **16 of 16** with one elided
  session title not decisive. The audit's own widths (`STORAGE` 101.672 at 16 px,
  `412 GB` 62.984 at 20 px, section 3) equal the proof's Satoshi numbers exactly.
* The clock's fixed advance is the W7 check, unchanged:
  `tests/w7/ClockProof.qml` at 168 px gives `implicitWidth` 461.000 for `01:11`,
  for `18:48` and for the resting clock, and `TNUM on 0000=443.500 1111=443.500
  delta=0.000` against `delta=236.516` with the feature off. At the deck's 96 px
  that is the `63.359` digit advance, 0.660 em.
* `DeckSurface.qml` carries the deck's four `FontLoader`s, from `Tokens.fontFiles`,
  and `DeckMain.qml` carries none: it instantiates `DeckSurface`, so the shell
  gets them too. (Other loaders exist in the tree for other owners — `kit/Clock.qml`
  keeps its own four module-relative ones, the W2/W3 still harnesses and
  `tests/w7/ClockProof.qml` load what they paint. None of them is the deck's.)
  `deck-shot.sh`, `deck-audit.py` and `deck-trace.py` mirror `v5/fonts` to
  `<imports>/NexusHud/fonts`, which is where a kit component's `../fonts/...`
  lands through the module import path.

What round 2 saw, and what it was: at `cfdee53` each render printed four
`FontLoader: Cannot load font` lines, and all four were `kit/Clock.qml`'s
module-relative loaders, not the deck's. The deck itself was already Satoshi.
Measured, not argued: rendering this still with the fonts mirror and without it
gives the same image — no pixel differs by more than one channel value, and the
number that differs is the same order as render-to-render noise. Four renders of
this still, compared with `sips` + numpy:

| comparison | pixels differing | max channel delta |
|---|---|---|
| link run 1 vs link run 2 (same configuration) | 24 | 1 |
| link run 1 vs no-link run 1 | 34 | 1 |
| no-link run 1 vs no-link run 2 (same configuration) | 26 | 1 |

So the mirror is not what makes the deck Satoshi (the audit reports the Satoshi
advance on all 16 painted texts either way); it is what stops four per-render
error lines and what makes a kit component rendered on its own resolve its own
faces. The repair closes the class anyway: the deck's loaders now live where every
non-shell render gets them, and the audit exits non-zero if a painted text ever
regresses to the fallback face.

## 2. Layout against the guides and against s2

`v5/tools/deck-layout.py` measures the render, not the intent: it converts the
still to BMP with `sips`, reads it with numpy (this python3 has no Pillow) and
compares the measured blob of each widget with the place the layout asks for.
Tolerance is 8 px, which is the acceptance criterion. Run:

```
nexuslink.hud/v5/tools/deck-layout.py nexuslink.hud/v5/stills/i1-deck-rest.png
```

```
== layout check i1-deck-rest.png
   knot         bboxcentre measured (1278.0, 543.5)  expected (1280.0, 550.0)  delta  6.5 px  ok
   crew         centre    measured (421.7, 547.6)   expected (426.5, 550.0)   delta  4.8 px  ok
   local        xcentre   measured (2133.5, 663)    expected (2133.5, 666.5)  delta  3.5 px  ok
   mac          origin    measured (314, 866)       expected (310, 865.7)     delta  4.0 px  ok
   storage      origin    measured (2021, 866)      expected (2017, 865.7)    delta  4.0 px  ok
   find         centre    measured (2133.0, 213.5)  expected (2133.5, 214.0)  delta  0.5 px  ok
   clock        centre    measured (1285.4, 146.9)  expected (1280.0, 144.0)  delta  5.4 px  ok
   launcherM    yonly     measured (1190.0,)        expected (1192.0,)        delta  2.0 px  ok
   knot extent  476x459 at (1040,314), inside the 540 px box  ok
   arc extent   x 1139..2403 (planned 1135..2407)  ok
   PASS
```

Notes on the measurement, because a centroid is the wrong statistic for most of
these:

* the knot by its **bounding box centre**, not its ink centroid: the triquetra's
  lobes put more ink low and left, so the centroid sits 44 px below the guide
  while the box (476x459 inside 540) is centred at 6.5 px;
* the dot bars are measured by their **origin** (lit dots only cover the left
  share of the bar, so their centroid is not the widget centre);
* the vertical LOCAL stack by its **x-centre plus bottom edge** (the lit dot sits
  at the bottom of the level);
* the launcher by the **row** of its middle tile plus the outer extent of the
  first tile ring (1135) and the 1.3x Arc Raiders hero (2407), because the hero
  sits 40 px apart so the arc's optical centre is not its box centre.

The measured clock centre is 5.4 px right of the 1280 guide. The audit puts the
Clock item's own box at x 1148.0 with cells 4 x 59.52 + 24.96 = 263.04, so the
box centre is 1279.5: the deck centres the clock on the guide and does not nudge
it. The 5.4 px is where the glyph ink falls inside those fixed cells (the 0.660 em
tabular digit is wider than its 0.62 em cell, so the outer digits overhang their
cells while the `1` stem does not). Inside the 8 px tolerance, and not tuned.

**Nothing moved.** Section 1 renders and this layout were re-run after the fonts
fix and every number above is unchanged: the deck was already composing in
Satoshi (section 1, Fonts), so there was no metric to move.

**Against s2.** Where s2 and the deck share a guide, s2's own numbers are the
expectation: the s2 knot crop is 540x540 at (1010, 280) (measured by W1 for
`docs/knot-iou.md`), which is exactly `Tokens.knotCentreX/Y - 270` and what the
deck places; s2's launcher tile row is y 1192 (s2 README §4, "centre y 1192") and
the deck measures 1190. Everything else is a deliberate, documented move:

| element | s2 | deck | why |
|---|---|---|---|
| knot | (1280, 550) 540 px | same | unchanged |
| clock | 168 px numerals | 96 px | amendment "CLOCK TOO BIG … about 96 px" |
| crew | thirds point (853, 480) | (426.5, 550) | amendment "move Crew and Find further out toward the margins (14 to 20 %)" — 16.7 % |
| find | 150 px magnifier at (1707, 480) | slim pill, box centred on the margin column at 2133.5 | amendment "no magnifying glass, no doc count, a slim pill" |
| mac | dot ring at (853, 960) | segmented dot field at (426.5, 883.5) | amendment "Mac as a dot-matrix or segmented bar field" |
| storage | sphere at (1707, 960) | stacked dot bars at (2133.5, 883.5) | amendment "Storage as stacked dot-bars or a squared cell grid" |
| local AI | sphere at (1707, 960) | vertical level stack at (2133.5, 550) | amendment "Local AI as a vertical level stack or waveform" |
| launcher | arc centred, 8 apps + hero | arc bottom right, 9 apps + hero | card: "launcher arc at the bottom right with Arc Raiders larger at the end" |

Round elements on screen at rest: two (the knot and the crew swarm). The
amendment allows at most one beyond the knot. `PulseRing`, `DotArc` and
`LocalOrb` are still registered and composed, but they live in the deep views,
where only one is crisp at a time.

## 3. Word count, type size, overlaps at rest

`v5/tools/deck-audit.py` drives a QML probe that walks the live item tree, so the
numbers come from the composed deck, not from a grep of the source:

```
nexuslink.hud/v5/tools/deck-audit.py nexuslink.hud/v5/tests/i1/audit-rest.qml
```

```
== rest
   texts  16 items, 16 words after merging glyph cells
   '00:18'                x= 1148.0 y=   96.0 w= 263.0
   'FRI'                  x= 1077.9 y=  134.0 w=  36.1
   '23 OCT'               x= 1446.0 y=  134.0 w=  80.3
   'Find'                 x= 1977.5 y=  197.5 w= 184.0
   'CREW'                 x=  394.5 y=  675.0 w=  64.3
   'LOCAL'                x= 2098.0 y=  687.5 w=  71.3
   '3'                    x=  420.5 y=  695.0 w=  11.4
   '0.3 GB'               x= 2103.0 y=  707.5 w=  62.0
   'MAC'                  x=  403.0 y=  914.3 w=  48.2
   'STORAGE'              x= 2083.0 y=  914.3 w= 101.7
   '8 ms'                 x=  405.0 y=  934.3 w=  43.1
   '412 GB'               x= 2103.0 y=  934.3 w=  63.0
   min px 16   overlaps 0
   fonts  Qt.fontFamilies() has Satoshi: True   16 of 16 decisive texts painted in the Satoshi advance, 0 in the fallback face
   PASS
```

Two differences from the round-2 evidence, both re-measured rather than argued:
`Find` sits at x **1977.5** (the 2028.0 in round 1's copy of this block was stale
from before the W6 token fold in `FindField`; the pill's measured centre, 2133.0,
is unchanged), and the `fonts` line is new.

* **16 words** at rest (limit 40). `CREW 3`, `LOCAL 0.3 GB`, `MAC 8 ms`,
  `STORAGE 412 GB`, `00:18`, `FRI`, `23 OCT`, `Find`.
* **Smallest type 16 px** (`Tokens.sizeCaption`, the labels). Values are 20 px,
  the clock 96 px, the Find placeholder 26 px (`Tokens.sizeBody`).
* **Zero overlaps** across all 16 text boxes (pairwise intersection area > 0 is a
  failure, exit 1).
* The crew focus state is audited too (`tests/i1/audit-crew-focus.qml`): 27 words
  with the three session titles, min 16 px, still zero overlaps.

## 4. qmllint before and after

Same file set, same import path, base worktree vs this branch:

```
qmllint -I <NexusHud/V5 -> kit> \
  nexuslink.hud/v5/kit/{Tokens,Motion,PulseRing,DotArc,DotBar,LocalOrb,FindField}.qml \
  nexuslink.hud/v4/HudV4.qml
```

| tree | warnings | errors | exit |
|---|---|---|---|
| `origin/v5/main-deck` (base) | 4 | 0 | 0 |
| this branch | 4 | 0 | 0 |

The 4 are the base's own: two pre-existing `[missing-property]` notes in
`HudV4.qml` (a `Process` narrowed to `var` in `selftestData()`) and the two
`pragma Singleton` notes `qmllint` prints when it lints a singleton file
directly. While `kit/Knot.qml` was missing from the base the same run reported 24
warnings and all 20 extra were one root cause repeated (`Knot.qml is listed as
component in qmldir but does not exist`, cascading into every file that imports
the module); they are gone now that the component is in the tree.

Round-1's repair files and this round's are clean against the module, not just
against the file set above. With the import path built the way the tools build it:

```
qmllint -I <NexusHud/V5 -> kit, NexusHud/fonts -> v5/fonts> \
  nexuslink.hud/v5/DeckSurface.qml nexuslink.hud/v5/tests/i1/DeckAudit.qml \
  nexuslink.hud/v5/tests/i1/FontProof.qml
```
0 warnings, exit 0. (`DeckMain.qml` keeps its 15, unchanged: they are all
`import Quickshell` being absent on this Mac. Linting `DeckSurface.qml` by file
path without `-I` prints 129 `[unqualified]` notes for `Tokens.*`, which is the
import path missing, not the file.)

`deck-shot.sh`/`deck-audit.py`/`deck-trace.py` build the import path themselves,
so no one has to hand-edit `tools/qml-lint.sh` (the `-I` request W4 raised is
still open; the scripts here are the workaround).

## 5. Token hoist count

76 literals that used to be local read-only properties in the kit now live in
`kit/Tokens.qml` / `kit/Motion.qml`: 61 from the first pass, plus 15 folded in
I1 repair round 1 (W3's `orbTilt` and the 14 W6 `FindField` values). Another 7
(`FindResults`' `resultColumns`, `tileHeight`, `markSize`, `markDotFactor`,
`markAlphaRest`, `markAlphaLift`, `subtitleGap`) are added as the token home
while `kit/FindResults.qml` keeps its own copies — that file is W6-owned and its
read side is a W6 follow-up card. 83 token values in all.

The VI verifier's own `vi_checks.py`, run at this head against base `7ee2b21`:

```
[7a] literal->token pairs checked: 76  value mismatches: 0
[7b] changed declarations that are not a plain token read: 0 (check by hand)
[7c] FindField local numeric declarations: none
```

`[7a]` walks every base declaration whose head value changed, requires the head
value to be a plain `Tokens.<name>` or `Motion.<name>` read, and compares the
token's value against the base literal, so a hoist that moved a number is caught
there. `[7c]` still lists one `springDamping` in `PulseRing`, `DotArc` and
`LocalOrb` — that declaration is the formula
`2 * Motion.expandZeta * Motion.expandOmega`, not a literal — and the seven
`FindResults` literals that stay with W6.

Motion evidence for criterion 3 is in `motion.md`: the expand overshoot there is
read off the curve's closed form plus a duration-stretched run of the same easing
(`CrewOrb.transitions[0].animations[0]`, read live), because the offscreen frame
clock here is 25 to 100 ms and cannot resolve a 347 ms curve's ~10 ms vertex.
`deck-trace.py`'s exit status is that closed form, and only that: the
frame-sampled runs are printed as a two-sided bound with their sample counts, so
a frame landing off the vertex cannot fail a clean head (round 2 saw exactly that
twice). Five consecutive runs on this head all exit 0.

## 6. What is deliberately not here

* The live shell perf gate (idle CPU over 60 s warm, RSS) is Linux's check on the
  real compositor; see `perf.md` for the local frame-time number it will compare
  against.
* Find results are fixture data (`v5/fixtures/find.json`) until `yuri search` is
  wired; `DeckMain.qml` already carries the `query`/`filter` IPC hooks.
* `kit/icons/*` under the launcher: `LauncherArc` loads `icons/<slug>.qml` by URL
  while the merged files are `Hermes.qml`, `XMark.qml`, … so every tile falls
  back to its dot letterform, and `spotify`/`obsidian` have no glyph at all. That
  is a W4/W5 integration defect, filed as a repair card rather than patched here.
