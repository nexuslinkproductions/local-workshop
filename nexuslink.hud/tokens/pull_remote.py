#!/usr/bin/env python3
"""pull_remote — snapshot a remote host's Hermes session_model_usage rows.

One ssh per run: a remote POSIX loop prints an `@@<path>` header before
each store's `sqlite3 -readonly -json` output; the merged stream is parsed
into records ({"profile": <name>, ...13 columns}) and written atomically
to $XDG_STATE_HOME/nexuslink/remote/<host>.jsonl, one JSON object per
line. Full snapshot per run — ledger's rid-dedup makes re-feeding
identical tuples harmless. On any failure the previous file is kept.
Stdlib only.
"""
import argparse
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

from ledger import HERMES_PROVIDER_MAP

REMOTE_HOST = "mac"
REMOTE_ROOT = "/Users/marcelspatz/.hermes"
STATE_HOME = Path(os.environ.get("XDG_STATE_HOME") or
                  Path.home() / ".local/state").expanduser()
OUT_DIR = STATE_HOME / "nexuslink" / "remote"
COLS = ("session_id, model, billing_provider, billing_base_url,"
        " billing_mode, task, input_tokens, output_tokens,"
        " cache_read_tokens, cache_write_tokens,"
        " estimated_cost_usd, cost_status, last_seen")
SQL = ("SELECT %s FROM session_model_usage WHERE billing_provider IN (%s)"
       % (COLS, ",".join("'%s'" % p for p in HERMES_PROVIDER_MAP)))
REMOTE_CMD = ('for f in %s/state.db %s/profiles/*/state.db; do'
              ' [ -f "$f" ] || continue; echo "@@$f";'
              ' sqlite3 -readonly -json "$f" %s; echo; done'
              % (REMOTE_ROOT, REMOTE_ROOT, shlex.quote(SQL)))


def _profile(db_path):
    """Store path -> profile dir name ('default' for the root state.db)."""
    name = Path(db_path).parent.name
    return "default" if name == Path(REMOTE_ROOT).name else name


def parse(text):
    """ssh output (`@@<path>` sections + JSON bodies) -> record list."""
    recs, path, buf = [], None, []

    def flush():
        body = "".join(buf).strip()
        if path is not None and body:
            for r in json.loads(body):
                recs.append({"profile": _profile(path), **r})

    for line in text.splitlines():
        if line.startswith("@@"):
            flush()
            path, buf = line[2:], []
        else:
            buf.append(line)
    flush()
    return recs


def run():
    out = subprocess.run(["ssh", "-o", "BatchMode=yes",
                          "-o", "ConnectTimeout=10",
                          REMOTE_HOST, REMOTE_CMD],
                         capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        raise RuntimeError("ssh rc=%s: %s"
                           % (out.returncode, out.stderr.strip()[:200]))
    recs = parse(out.stdout)     # raises on malformed JSON -> nothing written
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    tmp = OUT_DIR / (REMOTE_HOST + ".jsonl.tmp")
    with open(tmp, "w") as fh:
        for r in recs:
            fh.write(json.dumps(r, separators=(",", ":")) + "\n")
    os.replace(tmp, OUT_DIR / (REMOTE_HOST + ".jsonl"))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.parse_args()
    try:
        run()
    except Exception as e:   # keep the previous <host>.jsonl untouched
        print("pull_remote: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
