"""Side-by-side sheet: reference knot frame, render, and the blurred silhouettes.

Usage: python3 compare.py <render.png> <out.jpg> [reference.jpg]
Writes a 3-up JPEG under 1 MB: reference | render | silhouette overlay.
"""
import sys

import numpy as np
from PIL import Image

REF = ("/Users/marcelspatz/NEXUS_AI_CENTER/04_PROJECTS/HUD/hud-candidates/comp-r1/s2/"
       "s2-knot-frame.jpg")


def lum(im):
    a = np.array(im.convert("RGB")).astype(np.float32) / 255.0
    return a @ np.array([0.2126, 0.7152, 0.0722], np.float32)


def main():
    render_path, out_path = sys.argv[1], sys.argv[2]
    ref_path = sys.argv[3] if len(sys.argv) > 3 else REF
    ref = Image.open(ref_path).convert("RGB")
    ren = Image.open(render_path).convert("RGB").resize(ref.size, Image.LANCZOS)

    # overlay: reference mask in red, render mask in green, overlap yellow
    a = lum(ren) > 0.35
    b = lum(ref) > 0.35
    ov = np.zeros((ref.size[1], ref.size[0], 3), np.uint8)
    ov[..., 0] = b * 255
    ov[..., 1] = a * 255
    ov[..., 2] = (a & b) * 90

    sheet = Image.new("RGB", (ref.size[0] * 3 + 20, ref.size[1]), (10, 12, 16))
    sheet.paste(ref, (0, 0))
    sheet.paste(ren, (ref.size[0] + 10, 0))
    sheet.paste(Image.fromarray(ov), (ref.size[0] * 2 + 20, 0))
    sheet.save(out_path, quality=88)
    print(out_path, sheet.size)


if __name__ == "__main__":
    main()
