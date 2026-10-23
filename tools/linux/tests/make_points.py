#!/usr/bin/env python3
"""Generate the vertex-texture-fetch data texture.

64 points on a circle of radius 220 px centred in a 1280 x 720 frame, radii
normalised to [0,1] of a 240 px nominal radius, written as a 64 x 1 PNG.
The vertex shader samples this in the vertex stage with textureLod.

    python3 tools/linux/tests/make_points.py [out.png]
"""
import math
import sys

from PIL import Image

COUNT = 64
OUT = sys.argv[1] if len(sys.argv) > 1 else "tools/linux/tests/vtf-points.png"
RADIUS = 220.0
NOMINAL = 240.0

img = Image.new("RGBA", (COUNT, 1), (0, 0, 0, 255))
for i in range(COUNT):
    a = 2.0 * math.pi * i / COUNT
    # position on the unit square, [0,1] maps to -NOMINAL..+NOMINAL
    x = (math.cos(a) * RADIUS / NOMINAL + 1.0) * 0.5
    y = (math.sin(a) * RADIUS / NOMINAL + 1.0) * 0.5
    r = max(0, min(255, int(round(x * 255.0))))
    g = max(0, min(255, int(round(y * 255.0))))
    img.putpixel((i, 0), (r, g, 0, 255))

img.save(OUT)
print("wrote %s %dx%d" % (OUT, COUNT, 1))
