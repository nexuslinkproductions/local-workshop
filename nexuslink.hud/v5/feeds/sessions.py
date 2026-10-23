#!/usr/bin/env python3
"""Crew sessions reader: ``~/.hermes/state.db`` -> the crews array W2 CrewOrb draws.

Live mode opens the Hermes state database through a read-only URI
(``file:...?mode=ro&immutable=0``), runs exactly one SELECT, and closes. It never
writes, never takes a write lock, and holds its shared lock only for the length
of that one query (measured at 2.7 ms on the 2.9 GB live store). ``--db PATH``
exists so the self-check can exercise the same code path against a generated
database instead of Marcel's live one.

Fixture mode reads a snapshot with the live payload shape
(``v5/fixtures/sessions.json``): an array of session objects, or an object with
a ``sessions`` array.

Shape of one session in the payload:

    {"id": "683c2c", "full": "<session id>", "parent": "a1d052" | null,
     "model": "sonnet-5-5", "agent": "default", "source": "local",
     "state": "active" | "idle" | "stale",
     "tools": 9, "tokens": 3645,
     "started_at": 1792703143, "started_iso": "2026-10-22T21:05:43Z",
     "last_activity_at": 1792703205, "last_activity_iso": "2026-10-22T21:06:45Z",
     "idle_s": 17, "age_s": 62,
     "title": "Composition study s1: widget-and-icon-first HUD",
     "activity": "receiving stream response"}

``tokens`` is input + output for that session. ``model`` carries the short form
the fixtures already use (``claude-`` stripped, ``deepseek-`` -> ``ds-``), so a
fixture read and a live read look the same to the kit.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sqlite3
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as common  # noqa: E402

SOURCE = "sessions"
DEFAULT_DB = "~/.hermes/state.db"

# Columns we want, in payload order. Missing ones are simply not selected, so a
# schema addition or removal upstream degrades to a warning instead of a crash.
WANTED = (
    "id",
    "source",
    "model",
    "parent_session_id",
    "started_at",
    "ended_at",
    "last_activity_at",
    "last_activity_description",
    "title",
    "display_name",
    "tool_call_count",
    "input_tokens",
    "output_tokens",
    "profile_name",
    "archived",
    "hidden",
)

SHORT_MODEL_PREFIXES = (("claude-", ""), ("deepseek-", "ds-"), ("cursor/", ""))


# --------------------------------------------------------------------------- db


def connect_ro(path):
    """Open ``path`` read-only. Raises Missing when the file is absent or the
    driver refuses, never a bare exception."""
    target = os.path.abspath(os.path.expanduser(str(path)))
    if not os.path.exists(target):
        raise common.Missing("no sessions database at %s" % common.tilde(target))
    if not os.path.isfile(target):
        raise common.Missing("sessions database path is not a file: %s" % common.tilde(target))
    uri = "file:%s?mode=ro&immutable=0" % urllib.parse.quote(target, safe="/")
    try:
        con = sqlite3.connect(uri, uri=True, timeout=1.5)
    except sqlite3.Error as exc:
        raise common.Missing(
            "cannot open %s read-only: %s" % (common.tilde(target), exc)
        )
    try:
        con.row_factory = sqlite3.Row
        # No implicit transaction: a SELECT releases its shared lock on close.
        con.isolation_level = None
        con.execute("PRAGMA busy_timeout=1500")
        con.execute("PRAGMA query_only=1")
    except sqlite3.Error as exc:
        con.close()
        raise common.Malformed(
            "%s is not a usable sqlite database: %s" % (common.tilde(target), exc)
        )
    return con


def table_columns(con, table="sessions"):
    try:
        return [row[1] for row in con.execute("PRAGMA table_info(%s)" % table)]
    except sqlite3.Error:
        return []


def live(args):
    con = connect_ro(args.db)
    warnings = []
    try:
        columns = table_columns(con)
        if "id" not in columns:
            raise common.Malformed(
                "%s has no sessions table with an id column" % common.tilde(args.db)
            )
        selected = [name for name in WANTED if name in columns]
        missing = [name for name in WANTED if name not in columns]
        if missing:
            warnings.append("columns absent upstream: %s" % ", ".join(missing))

        now = common.utc_now_epoch()
        since = now - int(args.since_min * 60)
        where = []
        params = []
        if "started_at" in columns:
            where.append("(started_at > ? OR COALESCE(last_activity_at, 0) > ?)")
            params.extend([since, since])
        elif "last_activity_at" in columns:
            where.append("COALESCE(last_activity_at, 0) > ?")
            params.append(since)
        else:
            raise common.Malformed(
                "%s has no started_at or last_activity_at column" % common.tilde(args.db)
            )
        if "ended_at" in columns:
            where.append("ended_at IS NULL")
        if "archived" in columns:
            where.append("archived = 0")
        if "hidden" in columns:
            where.append("hidden = 0")
        order = "COALESCE(last_activity_at, started_at)" if "last_activity_at" in columns else "started_at"
        sql = "SELECT %s FROM sessions WHERE %s ORDER BY %s DESC LIMIT ?" % (
            ", ".join(selected),
            " AND ".join(where),
            order,
        )
        params.append(int(args.limit))
        rows = [dict(row) for row in con.execute(sql, params).fetchall()]
        if not rows:
            warnings.append("no open session in the last %d min" % int(args.since_min))
    except sqlite3.Error as exc:
        raise common.Malformed(
            "querying %s failed: %s" % (common.tilde(args.db), exc)
        )
    finally:
        con.close()

    entries = [normalise(row, now=now) for row in rows]
    return payload(args, entries, warnings, db=common.tilde(args.db))


def payload(args, entries, warnings, db):
    entries.sort(key=lambda item: item.get("last_activity_at") or 0, reverse=True)
    out = common.envelope(
        SOURCE,
        "fixture" if args.fixture else "live",
        window_min=int(args.since_min),
        limit=int(args.limit),
        count=len(entries),
        sessions=entries,
    )
    if db is not None:
        out["db"] = db
    if warnings:
        out["warnings"] = warnings
    return out


# ----------------------------------------------------------------------- shaping


def short_model(value):
    model = common.text(value)
    if model is None:
        return None
    for prefix, replacement in SHORT_MODEL_PREFIXES:
        if model.startswith(prefix):
            model = replacement + model[len(prefix):]
            break
    return model


def short_id(value):
    """Six-character id the fixtures and CrewOrb use; the tail is the unique part."""
    ident = common.text(value)
    if ident is None:
        return None
    return ident[-6:] if len(ident) > 6 else ident


def state_of(idle_s):
    if idle_s is None:
        return "unknown"
    if idle_s <= 90:
        return "active"
    if idle_s <= 600:
        return "idle"
    return "stale"


def normalise(entry, now):
    """One raw session (sqlite row or fixture object) -> payload object."""
    full = common.text(entry.get("full")) or common.text(entry.get("id"))
    ident = short_id(entry.get("id")) if entry.get("id") else short_id(full)
    parent_raw = common.text(entry.get("parent")) or common.text(entry.get("parent_session_id"))

    started = common.number(entry.get("started_at"))
    last = common.number(entry.get("last_activity_at"))
    if started is None and entry.get("started_iso"):
        started = common.epoch_from_iso(entry.get("started_iso"))
    if last is None and entry.get("last_activity_iso"):
        last = common.epoch_from_iso(entry.get("last_activity_iso"))
    if last is None:
        last = started

    # Fixture snapshots carry their own idle_s (the reader is not their clock);
    # live rows get it measured against now.
    idle = common.integer(entry.get("idle_s"))
    if idle is None and last is not None:
        idle = max(0, int(now - last))

    tools = common.integer(entry.get("tools"))
    if tools is None:
        tools = common.integer(entry.get("tool_call_count"))
    if tools is None:
        tools = common.integer(entry.get("tool_calls"))

    tokens = common.integer(entry.get("tokens"))
    if tokens is None:
        token_in = common.integer(entry.get("input_tokens"))
        token_out = common.integer(entry.get("output_tokens"))
        if token_in is not None or token_out is not None:
            tokens = (token_in or 0) + (token_out or 0)

    title = common.text(entry.get("title")) or common.text(entry.get("display_name"))
    activity = common.text(entry.get("activity")) or common.text(
        entry.get("last_activity_description")
    )

    return {
        "id": ident,
        "full": full,
        "parent": short_id(parent_raw),
        "model": short_model(entry.get("model")),
        "agent": common.text(entry.get("agent"))
        or common.text(entry.get("profile_name"))
        or common.text(entry.get("source")),
        "source": common.text(entry.get("source")),
        "state": state_of(idle),
        "tools": tools,
        "tokens": tokens,
        "started_at": int(started) if started is not None else None,
        "started_iso": common.iso(started),
        "last_activity_at": int(last) if last is not None else None,
        "last_activity_iso": common.iso(last),
        "idle_s": idle,
        "age_s": max(0, int(now - started)) if started is not None else None,
        "title": title,
        "activity": activity,
    }


# ---------------------------------------------------------------------- fixture


def fixture(args):
    root = common.read_json(args.fixture, "sessions fixture")
    if isinstance(root, dict):
        root = root.get("sessions")
    if not isinstance(root, list):
        raise common.Malformed(
            "sessions fixture must be an array of sessions (or an object with a sessions array)"
        )
    now = common.utc_now_epoch()
    entries, warnings = [], []
    for index, item in enumerate(root):
        if not isinstance(item, dict):
            warnings.append("entry %d is not an object, skipped" % index)
            continue
        if not (common.text(item.get("full")) or common.text(item.get("id"))):
            warnings.append("entry %d has no id, skipped" % index)
            continue
        entries.append(normalise(item, now))
    if root and not entries:
        raise common.Malformed("sessions fixture has no usable entries")
    return payload(args, entries, warnings, db=None)


# ------------------------------------------------------------------- self-check


def _sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _stamp(path):
    info = os.stat(path)
    return {"sha256": _sha256(path), "size": info.st_size, "mtime_ns": info.st_mtime_ns}


def _sidecars(path):
    parent = os.path.dirname(path) or "."
    base = os.path.basename(path)
    found = []
    for name in sorted(os.listdir(parent)):
        if name.startswith(base + "-") or name == base + "-journal":
            found.append(name)
    return found


def _run_cli(argv):
    """Run this file as a subprocess and return (exit code, parsed json, stderr)."""
    import subprocess

    proc = subprocess.run(
        [sys.executable, os.path.abspath(__file__)] + argv,
        capture_output=True,
        text=True,
    )
    payload = None
    if proc.stdout.strip():
        try:
            payload = json.loads(proc.stdout)
        except ValueError:
            payload = None
    return proc.returncode, payload, proc.stderr


def _make_db(path):
    """A generated stand-in for the live store: same columns, real rows."""
    now = common.utc_now_epoch()
    con = sqlite3.connect(path)
    con.executescript(
        """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            model TEXT,
            parent_session_id TEXT,
            started_at REAL NOT NULL,
            ended_at REAL,
            last_activity_at REAL,
            last_activity_description TEXT,
            title TEXT,
            display_name TEXT,
            tool_call_count INTEGER DEFAULT 0,
            input_tokens INTEGER DEFAULT 0,
            output_tokens INTEGER DEFAULT 0,
            profile_name TEXT,
            archived INTEGER NOT NULL DEFAULT 0,
            hidden INTEGER NOT NULL DEFAULT 0
        );
        """
    )
    rows = [
        # open parent, active, tool-rich
        ("local-parent-000001", "local", "claude-sonnet-5-5", None, now - 1500, None,
         now - 20, "receiving stream response", "Enable marcel-mode", None, 158, 120000, 19559, "default", 0, 0),
        # open child of the parent, active
        ("local-child-000002", "local", "deepseek-v4.1-flash", "local-parent-000001",
         now - 120, None, now - 5, "delegate_task: subagent receiving stream", "Composition study s1", None,
         9, 3000, 645, "yamato", 0, 0),
        # open, quiet for 5 min: inside the 30 min window, idle
        ("local-quiet-000003", "oneshot", "deepseek-v4.1-flash", None, now - 3600, None,
         now - 300, "", "Draft vari8-beta issues", None, 33, 100000, 25381, "default", 0, 0),
        # open, quiet for 25 min: inside the window, stale
        ("local-asleep-000008", "local", "claude-sonnet-5-5", None, now - 2000, None,
         now - 1500, "waiting", "Asleep run", None, 12, 500, 500, "shino", 0, 0),
        # ended: must never appear
        ("local-ended-000004", "local", "claude-sonnet-5-5", None, now - 60, now - 30,
         now - 30, "cli_close", "Finished run", None, 4, 10, 10, "default", 0, 0),
        # archived: must never appear
        ("local-arch-000005", "local", "claude-sonnet-5-5", None, now - 60, None,
         now - 10, "", "Archived run", None, 1, 1, 1, "default", 1, 0),
        # hidden: must never appear
        ("local-hidden-000006", "local", "claude-sonnet-5-5", None, now - 60, None,
         now - 10, "", "Hidden run", None, 1, 1, 1, "default", 0, 1),
        # open but outside the window: must not appear
        ("local-old-000007", "local", "claude-sonnet-5-5", None, now - 99999, None,
         now - 99999, "", "Ancient run", None, 2, 2, 2, "default", 0, 0),
    ]
    con.executemany(
        "INSERT INTO sessions (id, source, model, parent_session_id, started_at, ended_at,"
        " last_activity_at, last_activity_description, title, display_name, tool_call_count,"
        " input_tokens, output_tokens, profile_name, archived, hidden)"
        " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        rows,
    )
    con.commit()
    con.close()


def self_check(args):
    import tempfile

    ok = []
    bad = []

    def check(name, condition, detail=""):
        if condition:
            ok.append(name)
            print("PASS %s" % name)
        else:
            bad.append(name)
            print("FAIL %s %s" % (name, detail))

    root = tempfile.mkdtemp(prefix="w8-sessions-", dir=os.environ.get("TMPDIR"))
    db_path = os.path.join(root, "state.db")
    _make_db(db_path)
    before = _stamp(db_path)
    before_sidecars = _sidecars(db_path)

    # 1. live path against the generated database
    code, payload, stderr = _run_cli(["--db", db_path, "--json"])
    check("read-exit-0", code == 0, "exit=%s stderr=%s" % (code, stderr.strip()[:200]))
    check("read-one-object", isinstance(payload, dict), repr(payload)[:200])
    payload = payload or {}
    ids = [item.get("id") for item in payload.get("sessions", [])]
    check("read-ok-true", payload.get("ok") is True, str(payload.get("reason")))
    check("read-mode-live", payload.get("mode") == "live", str(payload.get("mode")))
    check("read-count-4", payload.get("count") == 4, "ids=%s" % ids)
    check("read-filters", sorted(ids) == ["000001", "000002", "000003", "000008"], "ids=%s" % ids)
    check(
        "read-newest-first",
        ids == ["000002", "000001", "000003", "000008"],
        "ids=%s" % ids,
    )
    child = next((item for item in payload.get("sessions", []) if item.get("id") == "000002"), {})
    parent = next((item for item in payload.get("sessions", []) if item.get("id") == "000001"), {})
    quiet = next((item for item in payload.get("sessions", []) if item.get("id") == "000003"), {})
    asleep = next((item for item in payload.get("sessions", []) if item.get("id") == "000008"), {})
    check("read-parent-link", child.get("parent") == "000001", "parent=%s" % child.get("parent"))
    check("read-parent-null", parent.get("parent") is None, "parent=%s" % parent.get("parent"))
    check("read-model-short", child.get("model") == "ds-v4.1-flash", "model=%s" % child.get("model"))
    check("read-model-claude-stripped", parent.get("model") == "sonnet-5-5", "model=%s" % parent.get("model"))
    check("read-tokens-sum", child.get("tokens") == 3645, "tokens=%s" % child.get("tokens"))
    check("read-tools", child.get("tools") == 9, "tools=%s" % child.get("tools"))
    check("read-state", child.get("state") == "active", "state=%s" % child.get("state"))
    check("read-idle-state", quiet.get("state") == "idle", "state=%s" % quiet.get("state"))
    check("read-stale-state", asleep.get("state") == "stale", "state=%s" % asleep.get("state"))
    check("read-iso-utc", str(child.get("last_activity_iso", "")).endswith("Z"), str(child.get("last_activity_iso")))
    check("read-title", parent.get("title") == "Enable marcel-mode", str(parent.get("title")))
    check("read-no-home-path", common.HOME not in json.dumps(payload), "absolute home path in payload")

    # 2. the database is untouched: bytes, mtime, no journal sidecars
    after = _stamp(db_path)
    print(
        "sqlite fixture: before sha256=%s mtime_ns=%d size=%d"
        % (before["sha256"], before["mtime_ns"], before["size"])
    )
    print(
        "sqlite fixture: after  sha256=%s mtime_ns=%d size=%d sidecars=%s"
        % (after["sha256"], after["mtime_ns"], after["size"], _sidecars(db_path) or "none")
    )
    check("db-hash-unchanged", before["sha256"] == after["sha256"], "%s -> %s" % (before["sha256"][:16], after["sha256"][:16]))
    check("db-mtime-unchanged", before["mtime_ns"] == after["mtime_ns"], "%s -> %s" % (before["mtime_ns"], after["mtime_ns"]))
    check("db-size-unchanged", before["size"] == after["size"], "%s -> %s" % (before["size"], after["size"]))
    check("db-no-sidecars", _sidecars(db_path) == before_sidecars, str(_sidecars(db_path)))

    # 3. the connection really is read-only
    con = connect_ro(db_path)
    try:
        try:
            con.execute("CREATE TABLE writable_probe (x INTEGER)")
            wrote = True
        except sqlite3.OperationalError as exc:
            wrote = "readonly" in str(exc).lower() or "read-only" in str(exc).lower()
        check("db-write-refused", wrote is True, "write probe did not fail read-only")
        check("db-query-only", con.execute("PRAGMA query_only").fetchone()[0] == 1, "query_only off")
    finally:
        con.close()

    # 4. malformed, missing and empty inputs are answers, not crashes
    bad_json = os.path.join(root, "broken.json")
    with open(bad_json, "w", encoding="utf-8") as handle:
        handle.write("{\"sessions\": [")
    code, payload, _ = _run_cli(["--fixture", bad_json, "--json"])
    check("bad-json-exit-0", code == 0, "exit=%s" % code)
    check("bad-json-ok-false", (payload or {}).get("ok") is False, str(payload))
    check("bad-json-kind", (payload or {}).get("kind") == "malformed", str((payload or {}).get("kind")))

    wrong_type = os.path.join(root, "wrong.json")
    with open(wrong_type, "w", encoding="utf-8") as handle:
        json.dump({"rows": []}, handle)
    code, payload, _ = _run_cli(["--fixture", wrong_type, "--json"])
    check("wrong-shape-ok-false", (payload or {}).get("ok") is False, str(payload))

    code, payload, _ = _run_cli(["--fixture", os.path.join(root, "nope.json"), "--json"])
    check("missing-exit-0", code == 0, "exit=%s" % code)
    check("missing-kind", (payload or {}).get("kind") == "missing", str(payload))
    check("missing-reason", bool((payload or {}).get("reason")), str(payload))

    code, payload, _ = _run_cli(["--db", os.path.join(root, "nope.db"), "--json"])
    check("missing-db-ok-false", (payload or {}).get("ok") is False, str(payload))

    empty = os.path.join(root, "empty.json")
    with open(empty, "w", encoding="utf-8") as handle:
        json.dump([], handle)
    code, payload, _ = _run_cli(["--fixture", empty, "--json"])
    check("empty-ok-true", (payload or {}).get("ok") is True, str(payload))
    check("empty-count-0", (payload or {}).get("count") == 0, str(payload))

    mixed = os.path.join(root, "mixed.json")
    with open(mixed, "w", encoding="utf-8") as handle:
        json.dump([{"id": "abc123", "title": "Kept"}, "not an object", {"title": "no id"}], handle)
    code, payload, _ = _run_cli(["--fixture", mixed, "--json"])
    check("mixed-keeps-good", (payload or {}).get("count") == 1, str(payload))
    check("mixed-warns", bool((payload or {}).get("warnings")), str(payload))

    # 5. the shipped fixture parses
    shipped = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "fixtures", "sessions.json"))
    if os.path.exists(shipped):
        code, payload, _ = _run_cli(["--fixture", shipped, "--json"])
        check("shipped-fixture-ok", code == 0 and (payload or {}).get("ok") is True, str(payload)[:300])
        check("shipped-fixture-count", (payload or {}).get("count") == 3, str((payload or {}).get("count")))
    else:
        check("shipped-fixture-present", False, shipped)

    print(
        "\nself-check %s: %d passed, %d failed"
        % ("ok" if not bad else "FAILED", len(ok), len(bad))
    )
    if bad:
        print("failed: %s" % ", ".join(bad))
    return 0 if not bad else 1


# --------------------------------------------------------------------------- cli


def parse(argv):
    parser = argparse.ArgumentParser(
        description="Crew sessions feed for the v5 HUD (read-only)."
    )
    common.add_common_args(parser)
    parser.add_argument("--db", default=DEFAULT_DB, help="state database (default %s)" % DEFAULT_DB)
    parser.add_argument(
        "--since-min",
        type=float,
        default=30.0,
        help="consider sessions touched in the last N minutes (default 30)",
    )
    parser.add_argument("--limit", type=int, default=8, help="most sessions to emit (default 8)")
    parser.add_argument("--self-check", action="store_true", help="run the built-in checks and exit")
    args = parser.parse_args(argv)
    if args.since_min <= 0:
        parser.error("--since-min must be positive")
    if args.limit <= 0:
        parser.error("--limit must be positive")
    return args


def build(args):
    if args.fixture:
        return fixture(args)
    return live(args)


def main(argv=None):
    args = parse(argv)
    if args.self_check:
        return self_check(args)
    return common.run(SOURCE, build, args)


if __name__ == "__main__":
    sys.exit(main())
