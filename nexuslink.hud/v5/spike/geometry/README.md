# C2 swarm spike: geometry input

Shared by all three renderer options.

`trace_knot.py` reads `knot-source.svg` (copy of `hud-candidates/logo-r1/src/knot-source.svg`,
the vector the 48x49 `PixelLogo` bitmap was rasterised from, IoU 0.931 per
`logo-r1/src/bitmap-check.txt`) and recovers the ribbon centre lines:

1. flatten all 9 SVG paths (M L C S H V Z, absolute and relative),
2. rasterise each ribbon at 2x and march inward along the outline normal to find
   the local half width,
3. keep one centre point per cross section, dedupe, order by nearest neighbour,
   split where the gap exceeds 2.6 px (caps and branch points),
4. Douglas-Peucker at 0.45 px.

Output `knot.json`: 23 chains, total centre-line length 3320 px at knot height
540 px, half width median 13.0 px (thick ribbons 26 px wide, three thin ring
lines at 5.5 to 6 px), coordinates in [-0.5, 0.5] with y up and the origin at
the knot centre.

`check_trace.py` rasterises the centre lines back to a 540x540 mask and scores
it against the s1 crop (`s1-rest.png`, box 1010..1550 x 280..820): IoU 0.65 at
luminance threshold 0.10 with the crop's 4 percent dust coverage included,
0.65 at 0.08. The gap is dot coverage, not shape: the s1 engine draws round
dots at a 3.75 px pitch, so about a third of each ribbon is dark background,
while a rasterised mask is solid. Closing both masks before the IoU removes
that difference and is the number the decision doc quotes.
