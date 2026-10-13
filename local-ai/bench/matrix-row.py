#!/usr/bin/env python3
"""matrix-row.py — append rows to bench/results-matrix.tsv (fixed 20-column schema).

Contract (column order is what the report is built from):

    timestamp engine git_sha model quant placement ctx kv_type depth test
    tps_mean tps_std ttft_ms peak_rss_gib vram_used_mib tool_call_pass
    start end notes

Every column not supplied is written blank. Tabs/newlines inside a value are
flattened so the file stays parseable TSV.

As a module (used by matrix-bench.sh / matrix-server.sh):

    from importlib import import_module
    row = import_module("matrix-row")
    row.append(path, engine="llama.cpp-vulkan-tip", ...)

As a CLI:

    matrix-row.py OUT.tsv key=value key=value ...
    matrix-row.py --selftest
"""
import os
import sys

COLS = ["timestamp", "engine", "git_sha", "model", "quant", "placement", "ctx", "kv_type",
        "depth", "test", "tps_mean", "tps_std", "ttft_ms", "peak_rss_gib", "vram_used_mib",
        "tool_call_pass", "start", "end", "notes"]
HEADER = "\t".join(COLS) + "\n"


def _cell(v):
    if v is None:
        return ""
    return str(v).replace("\t", " ").replace("\n", " ").replace("\r", " ").strip()


def render(data):
    """dict -> TSV line (no trailing newline). Raises on unknown keys."""
    unknown = set(data) - set(COLS)
    if unknown:
        raise KeyError(f"unknown column(s): {sorted(unknown)}")
    return "\t".join(_cell(data.get(c, "")) for c in COLS)


def append(path, **data):
    first = not os.path.exists(path) or os.path.getsize(path) == 0
    with open(path, "a") as f:
        if first:
            f.write(HEADER)
        f.write(render(data) + "\n")
    return render(data)


def selftest():
    import tempfile
    p = os.path.join(tempfile.mkdtemp(), "m.tsv")
    append(p, timestamp="T", engine="e", model="m", tps_mean="1.50")
    append(p, timestamp="T2", engine="e2", notes="has\ttab\nand newline")
    lines = open(p).read().splitlines()
    assert len(lines) == 3, lines                      # header + 2 rows
    assert lines[0].split("\t") == COLS, lines[0]
    r1 = lines[1].split("\t")
    assert len(r1) == len(COLS) == 19, len(r1)
    assert r1[0] == "T" and r1[8] == "" and r1[10] == "1.50", r1
    r2 = lines[2].split("\t")
    assert len(r2) == 19 and r2[18] == "has tab and newline", r2   # flattened, still 19 cols
    assert r2[10] == "", r2
    print("selftest ok: 19 cols, blank defaults, tabs/newlines flattened")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
    if len(sys.argv) < 3:
        sys.exit("usage: matrix-row.py OUT.tsv key=value [key=value ...] | --selftest")
    kv = dict(a.split("=", 1) for a in sys.argv[2:] if "=" in a)
    print(append(sys.argv[1], **kv))
