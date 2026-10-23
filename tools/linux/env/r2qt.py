#!/usr/bin/env python3
# r2qt.py: mechanical conversion of the s6 hall fragment shader (WebGL GLSL, s6/r/src/r.frag)
# into the Qt environment fragment shader (the shaders/env.frag template).
#
#   python3 r2qt.py <r.frag> <env.frag template> <out.frag>
#
# Only the lines between the SHADE-BEGIN and SHADE-END markers of the template change: they
# get the converted hall body plus shade(P). All other template lines are kept as they are.
# Rules (the counts are printed on one line):
#   uniform ORG, R, PAR, T, LINK, AI   removed; the template #defines map them to the block
#   uniform BAY[6]                     BAY[i] -> bayAt(i)  (template helper over bayA and bayB)
#   uniform DISK[2]                    DISK[i] -> disk[i]  (vec2 block member)
#   any other uniform                  error: the block would not carry it
#   gl_FragCoord                       -> qtFragCoord()    (template helper, global via envP)
#   gl_FragColor                       -> qtColor
#   void main()                        -> void hallMain(); shade(P) calls it and returns qtColor
#   precision statement                dropped (no meaning in desktop GLSL 440; qsb adds ES precision)
#   GLSL 4.40 keyword used as a name  renamed hall_<name> (only "patch" in r.frag today)
#   any other gl_ name                 error
# Exit 0 and one line on success; exit 1 on any error, nothing written.
import re
import sys

MAP_MACRO = {"ORG", "R", "PAR", "T", "LINK", "AI"}
KEYWORDS = ["patch", "sample", "filter", "input", "output", "common", "partition", "active",
            "asm", "class", "union", "enum", "typedef", "template", "this", "resource", "goto",
            "inline", "noinline", "public", "static", "extern", "external", "interface", "long",
            "short", "half", "fixed", "unsigned", "superp", "sizeof", "cast", "namespace",
            "using", "row_major"]
BEGIN = "// SHADE-BEGIN"
END = "// SHADE-END"


def fail(msg):
    sys.stderr.write("r2qt: " + msg + "\n")
    sys.exit(1)


def split_comment(line):
    i = line.find("//")
    if i < 0:
        return line, ""
    return line[:i], line[i:]


def convert_body(src, counts):
    def bump(key, n=1):
        counts[key] = counts.get(key, 0) + n

    lines = []
    for raw in src.split("\n"):
        code, com = split_comment(raw)
        if re.match(r"\s*precision\s+\w+\s+\w+\s*;\s*$", code):
            bump("precision_dropped")
            lines.append("// precision statement dropped by r2qt: " + code.strip())
            continue

        def uni(m):
            names = m.group(2)
            for item in names.split(","):
                name = re.sub(r"\[.*\]", "", item).strip()
                if name in MAP_MACRO:
                    bump("uniform_" + name)
                elif name in ("BAY", "DISK"):
                    bump("uniform_" + name)
                else:
                    fail("unknown uniform " + name + " (not in the env block)")
            return "/* uniform " + names.strip() + " -> env.frag block */"

        code = re.sub(r"\buniform\s+(\w+)\s+([^;]+);", uni, code)
        code, n = re.subn(r"\bBAY\s*\[([^\]]+)\]", r"bayAt(\1)", code)
        bump("BAY_index", n)
        code, n = re.subn(r"\bDISK\s*\[([^\]]+)\]", r"disk[\1]", code)
        bump("DISK_index", n)
        code, n = re.subn(r"\bgl_FragCoord\b", "qtFragCoord()", code)
        bump("gl_FragCoord", n)
        code, n = re.subn(r"\bgl_FragColor\b", "qtColor", code)
        bump("gl_FragColor", n)
        code, n = re.subn(r"^(\s*)void\s+main\s*\(\s*\)", r"\1void hallMain()", code)
        bump("main_renamed", n)
        for kw in KEYWORDS:
            code, n = re.subn(r"\b%s\b" % kw, "hall_" + kw, code)
            if n:
                bump("keyword_" + kw, n)
        if re.search(r"\bgl_\w+", code):
            fail("unconverted gl_ name in: " + code.strip())
        lines.append(code + com)
    return "\n".join(lines)


def main():
    if len(sys.argv) != 4:
        sys.stderr.write("usage: r2qt.py <r.frag> <env.frag template> <out.frag>\n")
        return 64
    r_path, tpl_path, out_path = sys.argv[1:4]
    with open(r_path, encoding="ascii") as f:
        src = f.read()
    with open(tpl_path, encoding="ascii") as f:
        tpl = f.read().split("\n")
    begin = [i for i, ln in enumerate(tpl) if ln.strip() == BEGIN]
    end = [i for i, ln in enumerate(tpl) if ln.strip() == END]
    if len(begin) != 1 or len(end) != 1 or end[0] <= begin[0]:
        fail("template needs exactly one SHADE-BEGIN and one SHADE-END marker, in order")
    counts = {}
    body = convert_body(src, counts)
    if body.count("void hallMain()") != 1:
        fail("expected exactly one void main() in the hall source")
    section = [
        BEGIN,
        "// converted from the s6 r.frag by tools/linux/env/r2qt.py: do not hand-edit",
        "vec4 qtColor;",
        body,
        "vec4 shade(vec2 P) {",
        "    envP = P;",
        "    qtColor = vec4(0.0, 0.0, 0.0, 1.0);",
        "    hallMain();",
        "    return qtColor;",
        "}",
        END,
    ]
    out_lines = tpl[:begin[0]] + section + tpl[end[0] + 1:]
    text = "\n".join(out_lines)
    try:
        text.encode("ascii")
    except UnicodeEncodeError:
        fail("output is not ASCII")
    with open(out_path, "w", encoding="ascii") as f:
        f.write(text)
    print("r2qt: wrote %s lines=%d source_lines=%d counts=%s"
          % (out_path, len(out_lines), len(src.split("\n")), sorted(counts.items())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
