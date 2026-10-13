#!/usr/bin/env python3
"""grounding-rescore.py — re-score a crop-and-zoom run from its audit dump.

    grounding-rescore.py <dump.tsv> <targets.tsv> [--rewrite] [--row-ts TS] [--strategy S] [--results F]

No model is loaded: the dump already holds every crop region and every RAW model reply,
so the score is recomputed with bench/grounding-score.py (the one scorer). --rewrite
replaces tool_call_pass + notes of the row whose timestamp == TS and test == grounding-<S>,
keeping that row's metadata (img_tokens, projector, dev, ...) from its old notes.
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from importlib import import_module  # noqa: E402

gs = import_module("grounding-score")
row_mod = import_module("matrix-row")

# a dump record starts at a line "<strategy>\t"; a raw reply may contain newlines (nojson rows
# were written unflattened), so records are split on that start marker, not on lines.
RECORD = re.compile(r"(?m)^(?=(?:topstrip|quadrant|none)\t)")


def load_answers(dump):
    """-> {strategy: {label: (raw, (px,py)|None, err|None)}}"""
    out = {}
    for rec in RECORD.split(open(dump).read()):
        f = rec.split("\t")
        if len(f) < 8 or f[0] not in ("topstrip", "quadrant", "none"):  # header / junk
            continue
        strat, lab, raw, parsed = f[0], f[1], f[6].strip(), f[7].strip()
        if raw.startswith("ERR"):
            ans = (raw, None, raw)
        elif parsed in ("", "nojson"):
            ans = (raw, None, "nojson")
        else:
            ans = (raw, tuple(int(v) for v in parsed.split(",")), None)
        out.setdefault(strat, {})[lab] = ans
    return out


def old_extra(note):
    """Metadata of an existing note (everything after by-class[...] but without cover=)."""
    m = re.search(r"by-class\[[^\]]*\](.*?) \| ", note)
    return re.sub(r"\s*cover=\S+", "", m.group(1)).strip() if m else ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dump")
    ap.add_argument("targets")
    ap.add_argument("--results", default=os.path.join(HERE, "results-matrix.tsv"))
    ap.add_argument("--row-ts", default="")
    ap.add_argument("--strategy", default="")
    ap.add_argument("--rewrite", action="store_true")
    a = ap.parse_args()

    targets = gs.parse_targets(a.targets)
    answers = load_answers(a.dump)
    lines, rows = [], {}
    if a.rewrite:
        lines = open(a.results).read().splitlines()
        for i, ln in enumerate(lines):
            f = ln.split("\t")
            if len(f) == len(row_mod.COLS):
                rows[(f[0], f[9])] = (i, f)

    for strat, ans in answers.items():
        if a.strategy and strat != a.strategy:
            continue
        r = gs.score(strat, targets, ans)
        # invariants: by-class covers every target, sums to the hits, hits never exceed cover
        assert sum(v[0] for v in r["by_class"].values()) == r["n"] == len(targets), r
        assert sum(v[1] for v in r["by_class"].values()) == r["hits"], r
        assert r["hits"] <= r["covered"], r
        tool, note = gs.summary(strat, r)
        print(f"[{strat}] {note}")
        if not a.rewrite:
            continue
        key = (a.row_ts, f"grounding-{strat}")
        if key not in rows:
            print(f"  (no row {key} in {a.results} — skipped)", file=sys.stderr)
            continue
        i, f = rows[key]
        tool, note = gs.summary(strat, r, extra=old_extra(f[18]))
        f[15], f[18] = tool, note
        lines[i] = "\t".join(f)
        print(f"  rewrote row {key} -> {tool}")
    if a.rewrite and rows:
        open(a.results, "w").write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
