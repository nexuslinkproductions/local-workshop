# tools/linux/measure/knot: evidence that the knot breathes locally

Four tools plus two templates for KNOT-SPEC.md. Everything is pure numpy and
PIL; no GPU is needed except for the renders. All numbers below were measured
on this machine on 2026-10-23 (700x700 item, knotPx 540, 1 unit = 0.6 px).

## knot_port.py

CPU port of the vertex stage (spec A to F), reading the point texture exactly
like knot.vert: 4 texels per point, 16 bit xyz, normal, s, q, cls. With
`texels_per_point=5` it also reads the v2 texel (u in red, occl in green) and
uses u instead of s. `motion="base"` reproduces the original commit dacc1c5
model (yaw 30, pitch 18, scale 2 percent, per lobe phase 0..0.07, no local
terms). `soft_limit=True` applies the same soft limit the shader uses
(dloc *= lim*(1-exp(-dl/lim))/dl with lim = R*0.045).

    python3 knot_port.py --t 1.5 --json

Checked against the original GPU shader: compare_gpu.py on a baseline frame
gave a median nearest neighbour distance of 0.744 px (p95 1.738), so the
decode and the projection are right.

## knot_report.py

6 s at 24 fps. 32 arc length bins per class (ribbon, ring), local displacement
is B..E only (pos_full - pos, so yaw, pitch and scale are excluded).
Writes report.csv, heatmap.png, report.json and a PASS/FAIL text verdict.

    python3 knot_report.py --outdir <dir> --text report.txt
    python3 knot_report.py --motion base --prefix base- --text baseline.txt

Measured, v2 model as specified: local displacement mean 4.24 px, peak 9.76 px,
frame to frame jump max 2.01 px (global pose alone 0.233 px), raw sum of B..E
peaks at 7.644 percent of R (B 2.800, C 2.907, D 1.800, E 2.636) and drops to
3.677 percent with the shader soft limit. Spectral test: only 12.5 percent of
bins keep their strongest frequency under 35 percent of the power, so a shared
breath clock (about 6 s) still dominates the bin means. The FFT removes a
linear trend per bin first.

Baseline (original model): zero local displacement everywhere, 2 of 6 criteria.

## render_seq.sh

    tools/linux/measure/knot/render_seq.sh <scene.qml-template> <outdir> [stride]

One process per frame through tools/linux/v5-shot.sh at 700x700, t substituted
for the TVALUE placeholder by sed. 6 s at 24 fps, frame i is t = i/24, stride
12 renders 12 frames (t = 0, 0.5 ... 5.5), stride 1 all 144. Writes frames.txt
("t path" per line).

## contact_sheet.py

    python3 contact_sheet.py <framesdir-or-frames.txt> <out.png> [cols rows]

4x3 by default, time written under every frame in Satoshi.

## compare_gpu.py

    python3 compare_gpu.py <gpu.png> <t> [--motion v2|base] [--port-png out.png]

Rasterises the port's points as dots (radius 2.3 * knotPx/540 * mix(0.6,1.22,d))
and reports the nearest neighbour distance from every GPU dot centroid to the
nearest port dot. On a live (K1 shader) frame at t=0 the median was 1.346 px,
p95 3.200 px, 99.2 percent within 4 px, so two independent implementations of
the spec agree to about a pixel.

## Templates

knot-seq.qml.tmpl (live worktree deck) and knot-base.qml.tmpl (dacc1c5
snapshot), both with TVALUE and a Tokens.field background.
