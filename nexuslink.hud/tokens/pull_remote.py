#!/usr/bin/env python3
"""pull_remote — snapshot a remote host's Hermes and Devin usage rows.

One ssh per run: a remote POSIX loop prints an `@@<path>` header before
each Hermes store's `sqlite3 -readonly -json` output (session_model_usage
rows -> {"profile": <name>, ...13 columns}); then an `@@devin` section with
the Devin CLI sessions.db message rows (`kind: "devin"`, metrics extracted
on the Mac exactly as ledger.collect_devin reads them); then an `@@kanban`
section with `hermes kanban list --json` (the remote board). Merged records
are written atomically to $XDG_STATE_HOME/nexuslink/remote/<host>.jsonl, one
JSON object per line. Full snapshot per run — ledger's rid-dedup makes
re-feeding identical tuples harmless. On any failure the previous file is kept.
Stdlib only.

The `@@kanban` section is a SECOND output of the SAME ssh call — it never
opens a second connection. It is parsed into
$XDG_STATE_HOME/nexuslink/remote/<host>-kanban.json, a separate file, so the
token lane (`<host>.jsonl`) is byte-identical with and without the board
feed. The board feed is a separate lane precisely so one failing can never
disturb the other: a broken/absent `@@kanban` section keeps the previous
board file and marks it stale instead of touching the token snapshot.
"""
import argparse
import json
import os
import shlex
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

from ledger import HERMES_PROVIDER_MAP

REMOTE_HOST = "mac"
REMOTE_ROOT = "/Users/marcelspatz/.hermes"
DEVIN_DB = "/Users/marcelspatz/.local/share/devin/cli/sessions.db"
DEVIN_TAG = "devin"
KANBAN_TAG = "kanban"
# The board feed rides the same ssh call as the token feed.
KANBAN_BIN = "/Users/marcelspatz/.local/bin/hermes"
STATE_HOME = Path(os.environ.get("XDG_STATE_HOME") or
                  Path.home() / ".local/state").expanduser()
OUT_DIR = STATE_HOME / "nexuslink" / "remote"
# Board cards the HUD keeps: everything not done, plus everything done in
# the last 24 h. Older done cards are noise on a status strip.
DONE_WINDOW_S = 24 * 3600
# Field caps. The board carries untrusted, free-form text; the HUD must
# never receive more than a fixed budget per field.
TITLE_MAX = 60
ERROR_MAX = 80
# Keys carried to the HUD. `body` and `result` are deliberately absent:
# card bodies are untrusted text and are the bulk of the payload.
CARD_KEYS = ("id", "title", "status", "assignee", "model_override",
             "started_at", "completed_at", "last_failure_error")
COLS = ("session_id, model, billing_provider, billing_base_url,"
        " billing_mode, task, input_tokens, output_tokens,"
        " cache_read_tokens, cache_write_tokens,"
        " estimated_cost_usd, cost_status, last_seen")
SQL = ("SELECT %s FROM session_model_usage WHERE billing_provider IN (%s)"
       % (COLS, ",".join("'%s'" % p for p in HERMES_PROVIDER_MAP)))
# metrics = metadata.metrics (else metadata.usage), acu/model = metadata
# fields — the inputs collect_devin's _metrics() reads. CASE guards bad JSON.
_J = "CASE WHEN json_valid(chat_message) THEN %s END"
DEVIN_SQL = (
    "SELECT row_id, session_id, created_at, metrics, acu, model FROM ("
    "SELECT row_id, session_id, created_at, "
    + _J % "COALESCE(json_extract(chat_message,'$.metadata.metrics'),"
           " json_extract(chat_message,'$.metadata.usage'))" + " AS metrics, "
    + _J % "json_extract(chat_message,'$.metadata.committed_acu_cost')" + " AS acu, "
    + _J % "json_extract(chat_message,'$.metadata.generation_model')" + " AS model "
    "FROM message_nodes) WHERE metrics IS NOT NULL OR acu IS NOT NULL")
# One read per store. `-readonly` sees everything (it may create the WAL
# side files, as any sqlite WAL reader does). It fails with "unable to open
# database file (14)" when the db is WAL-mode and its side files are gone
# (stopped gateway) -> fall back:
#   * a non-empty `-wal` still holds uncheckpointed rows -> read it with
#     vfs=unix-none (heap wal-index, no -shm needed). A WAL-blind read
#     (immutable) would silently undercount, so it is NOT used here.
#   * no `-wal` -> the db file is fully checkpointed -> immutable=1 is exact.
# A store that fails every way is UNREADABLE -> exit nonzero -> the pull
# keeps the previous snapshot instead of writing a partial one.
_SQLITE = ('sq() { o=$(sqlite3 -readonly -json "$1" "$2" 2>/dev/null) &&'
           ' { printf "%s\\n" "$o"; return 0; };'
           ' if [ -s "$1-wal" ]; then'
           ' o=$(sqlite3 -json "file:$1?vfs=unix-none" "$2" 2>/dev/null) &&'
           ' { printf "%s\\n" "$o"; return 0; };'
           ' echo "pull_remote: $1 unreadable (WAL present)" >&2; return 1;'
           ' fi;'
           ' sqlite3 -json "file:$1?immutable=1" "$2"; };')
REMOTE_CMD = (_SQLITE +
              ' for f in %s/state.db %s/profiles/*/state.db; do'
              ' [ -f "$f" ] || continue; echo "@@$f";'
              ' sq "$f" %s || exit 3; echo; done;'
              ' if [ -f %s ]; then echo "@@%s";'
              ' sq %s %s || exit 4; echo; fi;'
              # board feed: same ssh, one more section. A failure here must
              # NOT abort the token feed, so it is guarded and never exits
              # nonzero — the Linux side decides staleness.
              ' if [ -x %s ]; then echo "@@%s";'
              ' %s kanban list --json 2>/dev/null || true; echo; fi'
              % (REMOTE_ROOT, REMOTE_ROOT, shlex.quote(SQL),
                 DEVIN_DB, DEVIN_TAG, shlex.quote(DEVIN_DB),
                 shlex.quote(DEVIN_SQL),
                 shlex.quote(KANBAN_BIN), KANBAN_TAG,
                 shlex.quote(KANBAN_BIN)))


def _profile(db_path):
    """Store path -> profile dir name ('default' for the root state.db)."""
    name = Path(db_path).parent.name
    return "default" if name == Path(REMOTE_ROOT).name else name


def parse(text):
    """ssh output (`@@<path>` sections + JSON bodies) -> record list.

    Only the token lanes (Hermes stores + devin) are returned. The
    `@@kanban` section is a different shape and is handled by
    `parse_kanban`, so it never reaches the token record list.
    """
    recs, path, buf = [], None, []

    def flush():
        body = "".join(buf).strip()
        if path == DEVIN_TAG and body:
            for r in json.loads(body):
                recs.append({"kind": "devin", **r})
        elif path is not None and path != KANBAN_TAG and body:
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


def split_sections(text):
    """ssh output -> {section tag: raw body text}.

    The tag is everything after the leading `@@`. Sections keep their raw
    text so a malformed board section can be detected instead of silently
    parsing to an empty list.
    """
    out, tag, buf = {}, None, []
    for line in text.splitlines():
        if line.startswith("@@"):
            if tag is not None:
                out.setdefault(tag, []).append("".join(buf))
            tag, buf = line[2:], []
        else:
            buf.append(line)
    if tag is not None:
        out.setdefault(tag, []).append("".join(buf))
    return {k: "\n".join(v) for k, v in out.items()}


def _clip(text, limit):
    """Hard cap on a free-text field. Never grows the string."""
    s = str(text if text is not None else "")
    return s if len(s) <= limit else s[:limit]


def _num(value):
    """Epoch seconds as a number, or None when absent/unusable.

    Ints stay ints: the board stores epoch seconds as integers, and the
    HUD reads them as timestamps — a float would be a needless format
    change on the wire.
    """
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if value > 0 else None
    try:
        n = float(value)
    except (TypeError, ValueError):
        return None
    return n if n > 0 else None


def trim_card(card):
    """One raw board card -> the exact shape the HUD receives.

    `body` and `result` are dropped here and nowhere else: the card body
    is untrusted free text and is the bulk of the payload. Only CARD_KEYS
    survive, each capped.
    """
    if not isinstance(card, dict):
        return None
    out = {
        "id": str(card.get("id") or ""),
        "title": _clip(card.get("title"), TITLE_MAX),
        "status": str(card.get("status") or ""),
        "assignee": _clip(card.get("assignee"), 40),
        "model_override": card.get("model_override") or None,
        "started_at": _num(card.get("started_at")),
        "completed_at": _num(card.get("completed_at")),
        "last_failure_error": (_clip(card.get("last_failure_error"), ERROR_MAX)
                               or None),
    }
    return out


def keep_card(card, now):
    """Keep everything not done, plus done cards finished in the last 24 h."""
    status = str(card.get("status") or "")
    if status != "done":
        return True
    done_at = _num(card.get("completed_at"))
    if done_at is None:
        # a done card without a timestamp is kept — dropping it would hide
        # a card that finished moments ago
        return True
    return (now - done_at) <= DONE_WINDOW_S


def parse_kanban(body, now=None):
    """raw `@@kanban` body -> (cards, error).

    Returns (cards, None) on success and (None, message) when the section
    is absent, empty or malformed. A malformed section must never look like
    "the board is empty" — that would wipe the strip.
    """
    if body is None:
        return None, "no kanban section"
    raw = body.strip()
    if not raw:
        return None, "empty kanban section"
    try:
        data = json.loads(raw)
    except ValueError as e:
        return None, "malformed kanban json: %s" % e
    if not isinstance(data, list):
        return None, "kanban payload is not a list"
    if now is None:
        now = time.time()
    cards = []
    for c in data:
        trimmed = trim_card(c)
        if trimmed is None or not trimmed["id"]:
            continue
        if keep_card(c, now):
            cards.append(trimmed)
    return cards, None


def atomic_write_json(path, obj):
    """Write JSON atomically (mkstemp + os.replace) like crew.py does."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(obj, fh, separators=(",", ":"))
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def write_kanban(cards, host=REMOTE_HOST, stale=False):
    """Write the board file the HUD reads."""
    payload = {
        "updated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "host": host,
        "cards": cards,
    }
    if stale:
        payload["stale"] = True
    atomic_write_json(OUT_DIR / (host + "-kanban.json"), payload)


def mark_kanban_stale(host=REMOTE_HOST):
    """Keep the previous board file and flag it stale.

    The cards already in the file stay visible (a stale board still shows
    the last known state) — only the staleness flag is added. If there is
    no previous file, a bare stale payload is written so the HUD renders
    "board feed stale" instead of an empty strip.
    """
    path = OUT_DIR / (host + "-kanban.json")
    previous = None
    try:
        with open(path) as fh:
            previous = json.load(fh)
    except (OSError, ValueError):
        previous = None
    if isinstance(previous, dict):
        previous["stale"] = True
        previous.setdefault("updated", datetime.now(timezone.utc).isoformat(
            timespec="seconds"))
        previous.setdefault("host", host)
        previous.setdefault("cards", [])
        atomic_write_json(path, previous)
    else:
        write_kanban([], host=host, stale=True)



def run():
    out = subprocess.run(["ssh", "-o", "BatchMode=yes",
                          "-o", "ConnectTimeout=10",
                          REMOTE_HOST, REMOTE_CMD],
                         capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        raise RuntimeError("ssh rc=%s: %s"
                           % (out.returncode, out.stderr.strip()[:200]))
    recs = parse(out.stdout)     # raises on malformed JSON -> nothing written
    if not recs:
        # an empty snapshot means every store came back unreadable/empty --
        # writing it would wipe the Mac lanes in the HUD. Keep the previous
        # file and fail loudly instead.
        raise RuntimeError("empty snapshot from %s" % REMOTE_HOST)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    tmp = OUT_DIR / (REMOTE_HOST + ".jsonl.tmp")
    with open(tmp, "w") as fh:
        for r in recs:
            fh.write(json.dumps(r, separators=(",", ":")) + "\n")
    os.replace(tmp, OUT_DIR / (REMOTE_HOST + ".jsonl"))
    # Board feed: a SEPARATE lane, written after the token snapshot. The
    # token file above is already final and is never touched again, so a
    # broken board section cannot affect it.
    update_kanban(out.stdout)


def update_kanban(stdout):
    """Parse the `@@kanban` section and write the board file.

    On any problem (absent, empty, malformed) the previous board file is
    kept and flagged stale. Returns True when a fresh board was written.
    """
    sections = split_sections(stdout)
    cards, error = parse_kanban(sections.get(KANBAN_TAG))
    if error:
        mark_kanban_stale()
        print("pull_remote: board feed stale (%s)" % error, file=sys.stderr)
        return False
    write_kanban(cards)
    return True


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
