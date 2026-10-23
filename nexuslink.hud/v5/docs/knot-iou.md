# Knot silhouette against s2 (W1)

Status 2026-10-23, run 2: **`Knot.qml` shipped, the trace is fitted to s2, and the
0.90 bar is not reachable while the card's "no rings" rule holds.** This file
carries the crop, the meters, every number, and the arithmetic behind that
sentence, so the next reader does not have to take it on trust.

Summary of the numbers (all reproduced by one script, commands at the end):

| what | value |
|---|---|
| geometry: traced silhouette vs the s2 crop band | **0.9015** (`band_iou`, the fit) |
| geometry: the most any ring-free render can score on this crop | **0.9015** |
| render at rest, measured still | **0.7272** raw crop / 0.7562 with s2's ring cut / 0.7994 against its own trace |
| render `silhouette_iou_blur6` (the C2 verifier's meter) | 0.5640 |
| dot coverage at rest | 0.0592 against the reference's 0.1153 |

## Reference and crop

`hud-candidates/comp-r1/s2/s2-rest.png`, 2560x1440, the approved design (s2 wins
over s1 per `MAIN-SCREEN-BUILD.md`).

Crop: **540x540 at x=1010, y=280**, i.e. centred on `Tokens.centreX` 1280 and
`Tokens.goldenY1` 550, one knot box at 1:1. In that crop, at the meter's 0.10
luminance threshold, s2's knot plus its ring occupy 33,633 px (coverage 0.1153),
and 16,291 px (0.0559) at the 0.35 core threshold.

The still is not black: s2's page background is #0a0f1c (luminance 0.057), so
`--thr 0.10` sits 1.8x the background and the meter stays insensitive to it.

## Meters

Both on luminance, both after one translation search (+-12 px, step 2, then +-1
refine), because the Knot item is centred in its own 540 px frame:

| meter | definition | what it answers |
|---|---|---|
| `band_iou` **headline** | threshold at 0.10, 9 px morphological closing (dots merge into strand bands), IoU | is this the same knot shape |
| `silhouette_iou_blur6` | threshold at 0.35, 6 px box blur, threshold the blur at 0.02, IoU (the C2 verifier's `score.py` meter) | same as before, but dot-phase and dot-brightness sensitive |

`band_iou` is the headline because a dot swarm of a different lattice can never
put the same pixels in the same places as the reference. The blur6 number stays
for comparability with C2 (0.260 on the old render).

## The trace, fitted to s2

The previous run measured the s2 *cloud* (`hud-candidates/comp-r1/s2/src/knot/
knot3d.json`, 4384 points) through s2's own renderer and found it ceilings at
**0.766 band** against this crop: the still disagrees with its own cloud by 10 to
20 px in the lower-right lobe, so no transform fixes it (sweeps over pose,
camera, anisotropy and an affine ICP are in the run-1 history of this file).
That is why this run re-traces the knot from the still, as the card says.

`tools/knot-iou.py trace` builds the strand band like this:

1. `lum > 0.10`, then a 9 px closing: s2's dots (926 of them, median 14 px each)
   merge into continuous strand bands.
2. A 5 px opening. s2's knot is not only the ribbon: its own README says the mark
   is 9 filled pieces, **6 thick ribbon + 3 thin ring**, and the ring is dotted
   about five times more sparsely. Its arcs are 2 to 8 px thick and the closing
   attaches parts of them to the knot, so the opening drops them.
3. A radial cut at r <= 276 px, the gap between the outermost lobe tip (260 px
   from the crop centre) and the ring beyond it.
4. Components under 800 px (background grain) are dropped.

The result is a 52,507 px band: bbox x 23..506, y 9..493, perimeter 4,468 px,
strand half width **12.81 px** (median signed distance on the medial ridge; the
2A/P estimator says 23.5 px because crossings and lobe tips are thicker than a
strand and inflate it, so the ridge number is the strand).

The bake then writes `kit/assets/swarm-knot-sdf.png` (1024x1024, R = distance to
the band's centre lines, G = 1.0 so the renderer's ring channel can never hit,
A = 255 because Qt premultiplies image textures). Numbers that fall out of the
trace and are hardcoded in `Knot.qml`:

- Swarm's tube radius is a fixed 0.05640288 unit, so the renderer needs
  **227.05 px per unit** for that tube to be 12.81 px wide,
- therefore a 540 px `Knot` drives a **756.8 px** `Swarm`. The overhang is empty:
  the shader writes `vec4(0)` outside the tube,
- the lobe tip lands at 1.27 units, inside the shader's 1.34 unit march bound and
  inside the 1.45 unit texture.

The geometry's own silhouette (the level set the shader must produce) scores
**0.9015** against the reference band. That is the fit, and it is the first number
in this file.

## Why 0.90 is the ceiling, not a target

s2's reference band is 58,246 px after the same closing. The triquetra trace is
52,507 px of it. The remaining **5,739 px (9.9%)** are s2's ring: 2,597 px beyond
the r 276 cut, and 3,142 px of thinner ring arcs inside it that the opening
removes. The card says the Knot has **no rings**, so a spec-compliant render
cannot draw them, and

    52,507 / 58,246 = 0.9015

is the highest `band_iou` any ring-free Knot can reach against this crop, even if
its still reproduced the traced band exactly, pixel for pixel.

The render lands at 0.7272, so the rest of the gap is the renderer, not the
geometry. Two measured causes, both bounded by the visual law:

1. **No glow means sparse dots.** s2's dots carry a soft halo, so its band reads
   58% covered at the meter's threshold. Swarm draws hard round discs at a 0.45
   pitch ratio (C2's repair: discrete points with dark gaps). At 0.45 the discs
   cover 33% of the band at 0.10, so the closed band comes out about 1.2 px
   narrower per side than the geometry: render vs its own trace is 0.7994 at
   rest. Raising the dot radius back toward s2's ratio reintroduces the
   touching-square-tile defect C2 was repaired for; raising the gain (1.28 ->
   2.2) moved `band_iou` by 0.003. Do not expect this to close.
2. **The lobe tips.** The band is 40 px wide at the top lobe's apex, but the
   tube's height above the plane goes to zero as the band narrows, so the dots at
   the tips are the dimmest and the first to fall under the threshold.

Swept and rejected, so the next run does not redo it (all against this crop):

- silhouette dilation 0 to 2.5 px (dot-inset compensation): 0.7125, 0.7180
  (0.75), 0.7164 (1.25), 0.7053 (1.75), 0.6910 (2.5). Net zero: dilating the
  silhouette also dilates the enclosed holes and the reference has none there.
- opening 7 / 5 / 9 px on the trace: 0.7125 / 0.7358 / 0.7099. 5 px is shipped.
- gain 1.28 / 1.7 / 2.2: 0.6910 / 0.6941 / 0.6942 (measured at the then-current
  2.5 px dilation bake, hence the different baseline).

## What has to be decided (triage)

The card's own two rules disagree on this crop. Three ways out, in cost order:

- **Accept the ring-free number.** 0.9015 is the fit; 0.7272 is the render, and
  this file explains both. Nothing else about the knot is unfinished.
- **Put s2's ring back.** The renderer already has the channel (G, `u_rRing`
  0.01277046 unit = 2.9 px radius; s2's ring tube is 5.5 px, so that constant
  would roughly double). It covers the missing 5,739 px, but the same render
  would land near 0.80, still short of 0.90 for the dot-fill reason above, so it
  buys design fidelity, not the number.
- **Allow a glow.** It breaks the visual law ("no glow around the knot") and
  would lift the dot coverage toward s2's 58%.

Measured, not guessed: 0.90 on this crop needs the ring *and* a glow.

## Assembly (startup sequence)

`Knot { assembling: true; assembleProgress: 0..1 }` drives a per-cell reveal in
`swarm.frag`: a dot is drawn when `hash13(cell) <= assembleProgress`, with a
jitter of up to half a dot pitch that decays to zero, so the points stream in
scattered over the whole mark and settle into the strand as progress reaches 1.
With `assembling: false` the shader is handed exactly 1.0 and skips the branch:
the rest frame is **byte-identical** to `assembling: true, assembleProgress: 1`
(same PNG sha256, `14101ff0e25aa264`), verified in the run that produced the
stills.

A spatial scatter (each dot thrown ~38 px off its cell) was tried first and
rendered an **empty frame** at progress 0.3: fragments exist only where the ray
hits the tube, so a dot displaced further than its own radius has no fragment
left to draw it. Warping the distance field per cell instead would break the
sphere tracing (the field stops being Lipschitz). The reveal is the honest
version of "assembles from scattered points" for a raymarched renderer.

Stills (2560x1440 deck frame and the 540 crop, JPEG, all under 1 MB):

| state | deck | crop | `band_iou` | lit px |
|---|---|---|---|---|
| rest (`assembling: false`) | `docs/knot-stills/knot-rest-deck.jpg` | `knot-rest-540.jpg` | 0.7272 | 17,271 |
| progress 0.3 | `knot-a30-deck.jpg` | `knot-a30-540.jpg` | 0.2603 | 4,691 |
| progress 0.6 | `knot-a60-deck.jpg` | `knot-a60-540.jpg` | 0.6199 | 10,307 |
| progress 1.0 (`assembling: true`) | `knot-a100-deck.jpg` | `knot-a100-540.jpg` | 0.7272 | 17,271 |

The progress numbers are low on purpose: the same meter on frames that are
deliberately still assembling (30% and 60% of the dots present).

## Reproduce

From the worktree root, Python 3 with PIL + numpy (no other dependency):

    # 1. bake the trace into the shipped asset and print the fit
    /usr/bin/python3 tools/knot-iou.py trace --out nexuslink.hud/v5/kit/assets/swarm-knot-sdf.png

    # 2. render + measure one state (writes <prefix>-deck.jpg and -540.jpg/.png)
    /usr/bin/python3 tools/knot-iou.py still --rest --out /tmp/knot-rest
    /usr/bin/python3 tools/knot-iou.py still --progress 0.3 --out /tmp/knot-a30

    # 3. measure any still against the crop
    /usr/bin/python3 tools/knot-iou.py measure <still.png> --min-band 0.90

    # 4. the s2 cloud's own ceiling (why the trace is fitted to the still)
    /usr/bin/python3 tools/knot-iou.py ceiling --t 21.5

`trace` prints the band, half width, px-per-unit, Swarm size and the geometry's
predicted IoU; `measure` prints `band_iou`, `silhouette_iou_blur6`, both
coverages and the translation it found, and exits 1 below `--min-band`, so it can
gate a card. The stills on this card were made with `--rest` and
`--progress 0.3/0.6/1.0` at the default 2560x1440 deck frame; the 540 crop is
taken at x=1010, y=280.

## Files this card touches

- `nexuslink.hud/v5/kit/Knot.qml` (new, this card's)
- `nexuslink.hud/v5/kit/assets/swarm-knot-sdf.png` (re-baked from the s2 trace)
- `nexuslink.hud/v5/kit/Swarm.qml` — three additive properties whose defaults do
  not change any existing frame: `sdfSource`, `assemble`, `gain`. Requested in the
  PR body, together with the integrator's `kit/qmldir` line for Knot.
- `nexuslink.hud/v5/kit/shaders/swarm.frag` + `swarm.frag.qsb` (the assemble
  branch, skipped at `u_assemble = 1`)
- `nexuslink.hud/v5/docs/knot-stills/*` (evidence)
- `tools/knot-iou.py`, this file
