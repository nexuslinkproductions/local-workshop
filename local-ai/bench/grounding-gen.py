#!/usr/bin/env python3
"""grounding-gen.py — build a synthetic 1920x1080 'desktop' with labeled targets at
KNOWN bounding boxes, in realistic size classes, for grounding-test.sh.

    grounding-gen.py <out.png> <out.tsv>

<out.tsv> rows: <label>\t<x1>,<y1>,<x2>,<y2>\t<class>
classes: large-button (>=36 px tall), small-button (24-32), icon (<=24), text-link (<=20).
Requires ImageMagick (`magick`).
"""
import subprocess
import sys

W, H = 1920, 1080

# label, x1, y1, x2, y2, class, kind, colour
TARGETS = [
    ("SAVE button",          120, 120, 260, 160, "large-button", "rect",     "#2d7ff9"),
    ("CANCEL button",        280, 120, 420, 160, "large-button", "rect",     "#2d7ff9"),
    ("DOWNLOAD button",      700, 120, 880, 160, "large-button", "rect",     "#2d7ff9"),
    ("UPLOAD button",        900, 120, 1040, 160, "large-button", "rect",    "#2d7ff9"),
    ("OK button",            120, 260, 200, 288, "small-button", "rect",     "#1f6feb"),
    ("APPLY button",         220, 260, 340, 288, "small-button", "rect",     "#1f6feb"),
    ("RESET button",         360, 260, 480, 288, "small-button", "rect",     "#1f6feb"),
    ("EDIT button",         1520, 260, 1620, 288, "small-button", "rect",    "#1f6feb"),
    ("magenta circle icon",  120, 420, 144, 444, "icon", "circle",           "#d946ef"),
    ("cyan square icon",     160, 420, 184, 444, "icon", "rect",             "#22d3ee"),
    ("orange triangle icon", 200, 420, 224, 444, "icon", "triangle",         "#f97316"),
    ("lime diamond icon",   1760, 420, 1784, 444, "icon", "diamond",         "#84cc16"),
    ("Privacy link",         120, 560, 210, 578, "text-link", "text",        ""),
    ("Terms link",           240, 560, 320, 578, "text-link", "text",        ""),
    ("Help link",            350, 560, 410, 578, "text-link", "text",        ""),
    ("Logout link",         1760, 560, 1830, 578, "text-link", "text",       ""),
]

# decoys: unlabeled rectangles that make the page busier (never queried)
DECOYS = [
    (600, 400, 1300, 700, "#161b22"), (1400, 120, 1900, 380, "#161b22"),
    (100, 700, 900, 1000, "#161b22"), (1000, 760, 1500, 900, "#161b22"),
    (300, 480, 560, 540, "#161b22"),
]


def draw(cmd, kind, x1, y1, x2, y2, col, label):
    cx, cy = (x1 + x2) // 2, (y1 + y2) // 2
    if kind == "rect":
        cmd += ["-fill", col, "-draw", f"roundrectangle {x1},{y1} {x2},{y2} 6,6"]
    elif kind == "circle":
        r = (x2 - x1) // 2
        cmd += ["-fill", col, "-draw", f"circle {cx},{cy} {cx + r},{cy}"]
    elif kind == "triangle":
        cmd += ["-fill", col, "-draw",
                f"polygon {cx},{y1} {x1},{y2} {x2},{y2}"]
    elif kind == "diamond":
        cmd += ["-fill", col, "-draw",
                f"polygon {cx},{y1} {x2},{cy} {cx},{y2} {x1},{cy}"]
    elif kind == "text":
        cmd += ["-fill", "#8ab4f8", "-pointsize", "17", "-gravity", "NorthWest",
                "-annotate", f"+{x1}+{y1 + 2}", label.split()[0]]
    if kind in ("rect",) and label:
        cmd += ["-fill", "white", "-pointsize", "20", "-gravity", "NorthWest",
                "-annotate", f"+{x1 + 12}+{y1 + (y2 - y1) // 2 - 11}", label.split()[0]]


def main():
    out_png, out_tsv = sys.argv[1], sys.argv[2]
    cmd = ["magick", "-size", f"{W}x{H}", "xc:#0d1117",
           "-fill", "#1b2027", "-draw", f"rectangle 0,0 {W},44"]
    for x1, y1, x2, y2, col in DECOYS:
        cmd += ["-fill", col, "-draw", f"rectangle {x1},{y1} {x2},{y2}"]
    for lab, x1, y1, x2, y2, _cls, kind, col in TARGETS:
        draw(cmd, kind, x1, y1, x2, y2, col, lab)
    cmd += [out_png]
    subprocess.run(cmd, check=True)
    with open(out_tsv, "w") as f:
        for lab, x1, y1, x2, y2, cls, _k, _c in TARGETS:
            f.write(f"{lab}\t{x1},{y1},{x2},{y2}\t{cls}\n")
    print(f"wrote {out_png} ({W}x{H}) and {out_tsv} ({len(TARGETS)} targets)")


if __name__ == "__main__":
    main()
