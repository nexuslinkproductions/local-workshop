# I1 acceptance evidence — v5 DP-2 deck

Card: `t_f7a6561e` (I1 integrator). Branch `v5/integrator`, base `origin/v5/main-deck`.
Target surface: 2560x1440. Every number below is from a command run on this Mac
(macOS 26.4.1, arm64, Qt 6.12.0, Metal).

> **Knot slot.** `kit/Knot.qml` is not on `v5/main-deck` while this file was
> written: W1 shipped PR #51 and its verifier returned REPAIR (scope creep into
> `Swarm.qml`, palette lime instead of s2 azure, the 0.90 IoU bar unreachable),
> so the deck composes a plain 540x540 `Item` on the guide instead and the
> `Knot` block is kept one copy-paste away in `DeckSurface.qml`. Layout,
> word count, overlap audit, motion and perf below are all real with it; the
> **knot row of the layout table and the four render lines marked "with Knot"**
> are re-measured and updated the moment `kit/Knot.qml` appears. A placeholder
> is not shippable.

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
| rest | `deck-shot.sh stills/i1-deck-rest.qml stills/i1-deck-rest.png` | 0 | `mode=rhi api=metal image=2560x1440 distinct=128` (placeholder knot; **distinct=185 with Knot**) |
| crew focus | `deck-shot.sh stills/i1-deck-crew-focus.qml …` | 0 | `mode=rhi api=metal distinct=290` |
| launcher focus | `deck-shot.sh stills/i1-deck-launcher-focus.qml …` | 0 | `mode=rhi api=metal distinct=210` |

Stills: `v5/stills/i1-deck-rest.png`, `v5/stills/i1-deck-crew-focus.png`,
`v5/stills/i1-deck-launcher-focus.png` (PNG, 2560x1440, plus `-view.jpg` at 1400
wide for reading in chat). `QML_SHOT_MIN_DISTINCT` defaults to 64 inside
`deck-shot.sh`, so a silently flat frame exits 1.

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
   knot         MISSING (nothing above the floor)          <-- placeholder, see above
   crew         centre    measured (421.7, 547.6)   expected (426.5, 550.0)   delta  4.8 px  ok
   local        xcentre   measured (2133.5, 663)    expected (2133.5, 666.5)  delta  3.5 px  ok
   mac          origin    measured (314, 866)       expected (310, 865.7)     delta  4.0 px  ok
   storage      origin    measured (2021, 866)      expected (2017, 865.7)    delta  4.0 px  ok
   find         centre    measured (2133.0, 213.5)  expected (2133.5, 214.0)  delta  0.5 px  ok
   clock        centre    measured (1285.4, 146.9)  expected (1280.0, 144.0)  delta  5.4 px  ok
   launcherM    yonly     measured (1190.0,)        expected (1192.0,)        delta  2.0 px  ok
   arc extent   x 1139..2403 (planned 1135..2407)  ok
```

Notes on the measurement, because a centroid is the wrong statistic for a gauge:

* the dot bars are measured by their **origin** (lit dots only cover the left
  share of the bar, so their centroid is not the widget centre);
* the vertical LOCAL stack by its **x-centre plus bottom edge** (the lit dot sits
  at the bottom of the level);
* the launcher by the **row** of its middle tile plus the outer extent of the
  first tile ring (1135) and the 1.3x Arc Raiders hero (2407), because the hero
  sits 40 px apart so the arc's optical centre is not its box centre.

The measured clock centre is 5.4 px right of 1280 at 96 px type; that is the
glyph advance of "00:18" in Satoshi, inside the 8 px tolerance, and the Clock
component centres its own row - the deck does not nudge it.

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
   '00:18'    x= 1148.0 y= 96.0   w= 263.0        'CREW'     x= 394.5 y=675.0
   'FRI'      x= 1077.9 y=134.0                   '3'        x= 420.5 y=695.0
   '23 OCT'   x= 1446.0 y=134.0                   'LOCAL'    x=2098.0 y=687.5
   'Find'     x= 2028.0 y=197.5                   '0.3 GB'   x=2103.0 y=707.5
   'MAC'      x=  403.0 y=914.3                   '8 ms'     x= 405.0 y=934.3
   'STORAGE'  x= 2083.0 y=914.3                   '412 GB'   x=2103.0 y=934.3
   min px 16   overlaps 0
   PASS
```

* **16 words** at rest (limit 40). `CREW 3`, `LOCAL 0.3 GB`, `MAC 8 ms`,
  `STORAGE 412 GB`, `00:18`, `FRI`, `23 OCT`, `Find`.
* **Smallest type 16 px** (`Tokens.sizeCaption`, the labels). Values are 20 px,
  the clock 96 px, the Find placeholder 26 px (`Tokens.sizeBody`).
* **Zero overlaps** across all 16 text boxes (pairwise intersection area > 0 is a
  failure, exit 1).
* The crew focus state is audited too (`tests/i1/audit-crew-focus.qml`): 29 words
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
| this branch, with `kit/Knot.qml` present | 4 | 0 | 0 |
| this branch, `kit/Knot.qml` absent | 24 | 0 | 0 |

The 4 are the base's own: two pre-existing `[missing-property]` notes in
`HudV4.qml` (a `Process` narrowed to `var` in `selftestData()`) and the two
`pragma Singleton` notes `qmllint` prints when it lints a singleton file
directly. The 20 extra warnings are one root cause repeated: `Knot.qml is listed
as component in qmldir but does not exist`, cascading into every file that
imports the module. They disappear on their own when W1 merges.

`deck-shot.sh`/`deck-audit.py`/`deck-trace.py` build the import path themselves,
so no one has to hand-edit `tools/qml-lint.sh` (the `-I` request W4 raised is
still open; the scripts here are the workaround).

## 5. What is deliberately not here

* The live shell perf gate (idle CPU over 60 s warm, RSS) is Linux's check on the
  real compositor; see `perf.md` for the local frame-time number it will compare
  against.
* Find results are fixture data (`v5/fixtures/find.json`) until `yuri search` is
  wired; `DeckMain.qml` already carries the `query`/`filter` IPC hooks.
* `kit/icons/*` under the launcher: `LauncherArc` loads `icons/<slug>.qml` by URL
  while the merged files are `Hermes.qml`, `XMark.qml`, … so every tile falls
  back to its dot letterform, and `spotify`/`obsidian` have no glyph at all. That
  is a W4/W5 integration defect, filed as a repair card rather than patched here.
