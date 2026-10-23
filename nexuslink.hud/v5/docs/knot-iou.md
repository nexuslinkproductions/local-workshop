# Knot silhouette against s2 (W1)

Status 2026-10-23: **measurement built, ceiling measured, implementation blocked.**
This file records the crop, the meters, the numbers that exist today and what the
numbers say about the "IoU above 0.9" bar. It is written so the next run does not
have to rediscover any of it.

## Reference and crop

`hud-candidates/comp-r1/s2/s2-rest.png`, 2560x1440, the approved design (s2 wins
over s1 per `MAIN-SCREEN-BUILD.md`).

Crop: **540x540 at x=1010, y=280**, i.e. centred on `Tokens.centreX` 1280 and
`Tokens.goldenY1` 550, one knot box at 1:1. Inside that crop the knot's dots
occupy x 20..480, y 15..533 (461x519 px), 16,291 pixels above luminance 0.35, and
926 discrete dots of median area 14 px (dot diameter 4.2 px, pitch 5.5 px).

Reproduce: `/usr/bin/python3 tools/knot-iou.py measure <still.png> --reference
<path to s2-rest.png>` (the tool defaults to the paths on the Mac; pass
`--reference` elsewhere).

## Meters

Both on luminance, both after one translation search (+-12 px, step 2, then
+-1 refine), because the Knot item is centred in its own frame:

| meter | definition | what it answers |
|---|---|---|
| `band_iou` **headline** | threshold at 0.10, 9 px morphological closing (dots merge into strand bands), IoU | is this the same knot shape |
| `silhouette_iou_blur6` | threshold at 0.35, 6 px box blur, threshold the blur at 0.02, IoU (the C2 verifier's `score.py` meter) | same as before, but dot-phase and dot-brightness sensitive |

`band_iou` is the headline because a dot swarm of a different lattice can never
put the same pixels in the same places as the reference; the strand band is the
part that must agree. The blur6 number is kept because it is the number already
on the board for C2 (0.260 by `score.py`), so a reader can compare like with like.

## Numbers measured today

| image | band_iou | silhouette_iou_blur6 | render coverage @0.10 / @0.35 |
|---|---|---|---|
| C2 option A, `recon/v2-verify/knot-540-render.jpg` (PR #46 head f4b285b) | **0.103** | **0.111** | 0.0376 / 0.0107 |
| s2's own point cloud re-projected by s2's own renderer ("ceiling") | **0.766** | **0.644** | 0.1174 / 0.0607 |
| reference crop (s2-rest.png) | 1.000 | 1.000 | 0.1153 / 0.0559 |

The C2 verifier's 0.260 is the same render scored by `score.py` at 720 with a
centroid alignment; the two meters and crops differ, the conclusion does not.

### The ceiling, and why it is not a bug in the meter

`tools/knot-iou.py ceiling` projects `hud-candidates/comp-r1/s2/src/knot/knot3d.json`
(4384 points, H=900, 9 crossings, centrelines with z) through the s2 engine's own
camera (`swarm3d.js`: size/H, cam 2.7 H, perspective, depth size, facing shade,
occlusion dim) and measures that image against the still. It is the best any
renderer driven by that cloud can score.

Swept, all against the same crop and meter:

- motion clock t = 0..40 s in 0.5 s steps: best band 0.770 at t=21.5 s, worst 0.756. The rest pose is not the problem.
- camera distance 1.4 to 1000 knot-heights: band 0.759..0.767. Perspective is not the problem.
- anisotropic image scale 0.86..1.04 in x and 0.96..1.04 in y: best at 1.00/1.00 (0.765). Anisotropy is not the problem.
- affine ICP (point cloud to reference dots): residual median **2.1 px**, p90 **45 px**, and the fitted transform stays at unity scale (0.997, det 0.99). So half the projected points land within about two pixels of a reference dot and a minority does not.

That pattern is visible in the 0.10 overlay: the top lobe, the lower-left lobe
and the crossings coincide (yellow), while in the **lower-right lobe the reference
sits 10 to 20 px inside the cloud's projection**. The still was therefore not
produced from this exact cloud revision, or not with this lobe in the same place.
No global transform fixes a local lobe offset, which is why every sweep stalls at
about 0.77.

## What this means for the bar

The card asks for silhouette IoU above **0.9** against this crop, and the
triage comment says to report the achieved number with the reason rather than
ship a guess. Measured facts:

1. A renderer driven by the s2 cloud (the geometry C2 used, and the best traced
   geometry available) cannot exceed **band 0.77 / blur6 0.64** on this crop,
   because the reference still disagrees with its own cloud in one lobe.
2. Therefore **0.90 as defined above is not reachable** by a render of that cloud,
   regardless of dot size, density, camera or pose. The current option A render is
   at 0.10 on top of that.
3. The reachable paths, in order of cost:
   - **Re-trace fitted to the still.** Fit the centre lines to the still's own
     dots (the card's instruction), not to `logo-r1`. The crossing/weave z-dips
     then have to be re-derived, because the still shows the weave only through
     brightness. This is the only path that can reach 0.90 on this crop, and it
     makes the geometry a fit target rather than a copy of s2's JSON.
   - **Redefine the number.** Keep the cloud and the C2 renderer, and set the bar
     to band 0.75 with this file as the evidence, since 0.77 is the ceiling of the
     reference against itself.
   - **Score against a different reference.** The knot clip (`s2-knot-frame.jpg`,
     720x720) is a 0.75 downscale of a 960 px clip; measuring both sides at the
     same downscale would damp dot-phase and could lift the ceiling, but it
     measures a resampled image, not the deck.

Do not change the meter to inflate the number. If the bar stays at 0.90, the
geometry has to be re-traced from the still.

## Open items this run could not close

- `kit/Swarm.qml` is not on `origin/v5/main-deck` (PR #46 is open with a REPAIR
  verdict), so no `Knot.qml` exists yet and no QML still can be measured. The
  card's precondition and this measurement are independent; this one is done.
- `assembling` / `assembleProgress` need one additive uniform in
  `kit/Swarm.qml`'s shader (a per-cell scatter warp). `Swarm.qml` is frozen by the
  W1 card ("do not edit Swarm.qml") so the assemble state cannot be implemented
  from `Knot.qml` alone. Requested in the PR body, not solved here.
