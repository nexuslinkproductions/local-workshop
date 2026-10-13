#!/usr/bin/env python3
"""Turn `llama-bench -o json` output into rows in results.tsv.

JSON comes on stdin (or argv[1]). Metadata via env:
  BENCH_TS BENCH_SHA BENCH_CFG BENCH_MODEL BENCH_NOTE BENCH_RESULTS

Row: timestamp, git_sha, config, model, depth, test, tps_mean, tps_std, vram_note
llama-bench's JSON has no "test" field, so it is derived: n_prompt>0 -> pp<n>,
otherwise -> tg<n>. Both builds (stock a97cce86a, prism adfffbe41) share this
field layout: n_prompt, n_gen, n_depth, avg_ts, stddev_ts.
"""
import json
import os
import sys


def rows(json_text, env):
    data = json.loads(json_text)
    if isinstance(data, dict):
        data = data.get("results", [])
    for r in data:
        n_prompt, n_gen = r.get("n_prompt", 0), r.get("n_gen", 0)
        yield [
            env["BENCH_TS"],
            env.get("BENCH_GITSHA", env.get("BENCH_SHA", "unknown")),
            env["BENCH_CFG"],
            env["BENCH_MODEL"],
            str(r.get("n_depth", 0)),
            f"pp{n_prompt}" if n_prompt else f"tg{n_gen}",
            f"{float(r['avg_ts']):.2f}",
            f"{float(r.get('stddev_ts', 0.0)):.2f}",
            env.get("BENCH_NOTE", ""),
        ]


def append(json_text, env):
    path = env["BENCH_RESULTS"]
    first = not os.path.exists(path) or os.path.getsize(path) == 0
    written = list(rows(json_text, env))
    with open(path, "a") as f:
        if first:
            f.write("timestamp\tgit_sha\tconfig\tmodel\tdepth\ttest\ttps_mean\ttps_std\tvram_note\n")
        for row in written:
            f.write("\t".join(row) + "\n")
    return len(written)


def selftest():
    """Canned 2-test run -> assert the derived columns. Fails if parsing breaks."""
    canned = json.dumps([
        {"n_prompt": 512, "n_gen": 128, "n_depth": 0, "avg_ts": 431.61, "stddev_ts": 4.2},
        {"n_prompt": 0, "n_gen": 128, "n_depth": 4096, "avg_ts": 25.13, "stddev_ts": 0.3},
        {"n_prompt": 512, "n_gen": 128, "n_depth": 0, "avg_ts": 100.0},
    ])
    got = list(rows(canned, {"BENCH_TS": "T", "BENCH_SHA": "abc", "BENCH_CFG": "c",
                             "BENCH_MODEL": "m.gguf", "BENCH_NOTE": "n"}))
    assert got[0] == ["T", "abc", "c", "m.gguf", "0", "pp512", "431.61", "4.20", "n"], got[0]
    assert got[1][4:7] == ["4096", "tg128", "25.13"], got[1]
    assert got[2][7] == "0.00", got[2]          # missing stddev defaults, not crashes
    wrapped = json.dumps({"results": json.loads(canned)})
    assert len(list(rows(wrapped, {"BENCH_TS": "T", "BENCH_CFG": "c", "BENCH_MODEL": "m"}))) == 3
    print("selftest ok: 3 rows, pp/tg derivation + defaults + wrapped-object all hold")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
    text = sys.argv[1] if len(sys.argv) > 1 else sys.stdin.read()
    print(f"appended {append(text, os.environ)} row(s) to {os.environ['BENCH_RESULTS']}")
