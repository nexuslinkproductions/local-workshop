# Build the v5 launcher glyphs as standalone SVGs.
# One 24 grid, solid glyphs, explicit ink fill (#eaf4f8 = Tokens.ink),
# no outlines, no masks (Qt SVG is SVG 1.2 Tiny: mask is not rendered, so
# negative space is cut with fill-rule="evenodd" subpaths instead).
# Brand marks: real simple-icons paths from the s3 design tree, with the same
# optical scale and the same round-joined stroke fattening that s3/src/icons.py
# applies to thin marks. The marks are trademarks of their owners; the icon
# files are CC0 (see simple-icons-LICENSE-CC0.md and -DISCLAIMER.md here).
#
# Run: python3 nexuslink.hud/v5/live/assets/build_icons.py
# Output: this directory, one <id>.svg per glyph.
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "icons")
# s3 design truth (read only). Set HUD_S3 to point elsewhere.
S3 = os.environ.get("HUD_S3", os.path.expanduser(
    "~/NEXUS_AI_CENTER/04_PROJECTS/HUD/hud-candidates/comp-r1/s3"))
BRAND_DIR = os.path.join(S3, "src", "brand")
INK = "#eaf4f8"

# id: (simple-icons file, scale about (12,12), stroke width to fatten)
BRAND = {
    "chrome":     ("googlechrome", 0.94, 0.5),
    "x":          ("x",            0.96, 0.95),
    "discord":    ("discord",      0.96, 0.0),
    "youtube":    ("youtube",      0.98, 0.0),
    "whatsapp":   ("whatsapp",     0.97, 0.8),
}

# id: markup on the 24 grid. Every hole is a closed subpath of the same path
# (fill-rule evenodd); never an overlay in a second colour.
CUSTOM = {
    # slanted-stem H with a rising crossbar
    "hermes": '<rect x="3.8" y="3.2" width="4.2" height="17.6" rx="2.1"/>'
              '<rect x="16" y="3.2" width="4.2" height="17.6" rx="2.1"/>'
              '<path d="M7 14.6L17 8.6V12.6L7 18.6z"/>',
    # D with an offset counter
    "devin": '<path fill-rule="evenodd" d="M4.2 4.4h6.6a7.6 7.6 0 0 1 0 15.2H4.2z'
             'M8.2 8.2v7.6h2.6a3.8 3.8 0 0 0 0-7.6z"/>',
    # folder with a slot between tab and body
    "files": '<path fill-rule="evenodd" d="M2.4 7.2A2.7 2.7 0 0 1 5.1 4.5h3.9'
             'c.6 0 1.1.2 1.5.7l1.1 1.4c.3.4.8.6 1.3.6h6A2.7 2.7 0 0 1 21.6 9.9v8'
             'A2.7 2.7 0 0 1 18.9 20.6H5.1A2.7 2.7 0 0 1 2.4 17.9z'
             'M2.4 10.2h19.2v1.3H2.4z"/>',
    # rounded square with a prompt cut: triangle plus bar
    "terminal": '<path fill-rule="evenodd" d="M7 3.8h10A4.6 4.6 0 0 1 21.6 8.4v7.2'
                'A4.6 4.6 0 0 1 17 20.2H7A4.6 4.6 0 0 1 2.4 15.6V8.4A4.6 4.6 0 0 1 7 3.8z'
                'M7.2 8.9L11.1 12 7.2 15.1z'
                'M13.1 14.3h4v1.8h-4z"/>',
    # arch plus dot
    "arc-raiders": '<path d="M2.6 20.6v-7.4a9.4 9.4 0 0 1 18.8 0v7.4h-4.9v-7.4'
                   'a4.5 4.5 0 0 0-9 0v7.4z"/>'
                   '<circle cx="12" cy="14.6" r="1.9"/>',
    # 3 x 3 dot glyph
    "all-apps": "".join(
        '<circle cx="%s" cy="%s" r="2"/>' % (x, y)
        for y in (5.5, 12, 18.5) for x in (5.5, 12, 18.5)),
}


def brand_path(name):
    with open(os.path.join(BRAND_DIR, name + ".svg"), "r", encoding="utf-8") as fh:
        src = fh.read()
    m = re.search(r'<path d="([^"]+)"', src)
    if not m:
        raise SystemExit("no path in brand/" + name + ".svg")
    return m.group(1)


def svg(gid):
    head = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" '
            'width="24" height="24" fill="%s">' % INK)
    if gid in BRAND:
        name, scale, stroke = BRAND[gid]
        stroke_attr = (' stroke="%s" stroke-width="%.2f" stroke-linejoin="round"'
                       % (INK, stroke)) if stroke else ""
        body = ('<g transform="translate(12 12) scale(%.2f) translate(-12 -12)">'
                '<path d="%s"%s/></g>' % (scale, brand_path(name), stroke_attr))
    else:
        body = CUSTOM[gid]
    # Explicit ink fill on every drawn node: Qt's SVG renderer is not reliable
    # about inheriting fill from the root element.
    body = re.sub(r'<(path|rect|circle)\b(?![^>]*\bfill=)',
                  r'<\1 fill="%s"' % INK, body)
    return head + body + "</svg>\n"


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    ids = list(BRAND) + list(CUSTOM)
    for gid in ids:
        out = os.path.join(OUT_DIR, gid + ".svg")
        with open(out, "w", encoding="utf-8") as fh:
            fh.write(svg(gid))
        print("wrote", out)
    print(len(ids), "icons")


if __name__ == "__main__":
    main()
