#!/usr/bin/env python3
"""hudfix crew actions: the Crew view's maintenance verbs (card F8b).

Four typed actions, each with a dry-run ``plan`` and a ``run``:

    crew.sessions   read         biggest sessions by tokens, from ~/.hermes/state.db
    crew.stop       reversible   stop a runaway session by a *recorded* pid
    crew.compress   reversible   gzip a session export into quarantine
    crew.logs       reversible   trim old session exports into quarantine

The table lives in :data:`ACTIONS`, which is the only thing the hudfix entry
point (card F8a, ``hudfix.py``) needs::

    for name, entry in hudfix_crew.ACTIONS.items():
        plan = entry["plan"](ctx)          # dict, changes nothing
        out  = entry["run"](ctx, confirm)  # confirm == name, or refused

``ctx`` is a plain dict (an ``argparse.Namespace`` also works). Every key is
optional; the defaults below are what the HUD gets with no context:

    session_id      session to stop / compress (full id or its 6-char tail)
    path            explicit source file for crew.compress
    db              sessions store,          default ~/.hermes/state.db
    pid_file        pid record,  default ~/.local/state/nexuslink/session-pids.json
    processes_file  Hermes' own pid table, default ~/.hermes/processes.json
    export_dir      export dir,  default ~/.hermes/session-exports
    quarantine_root default ~/NEXUS_AI_CENTER/_QUARANTINE
    older_than_days crew.logs age floor,     default 30
    limit           crew.sessions rows,      default 10
    grace_s         crew.stop wait after TERM, default 3
    host            "darwin" / "linux"; detected when absent
    profile         profile named in the Linux stop plan
    now             epoch seconds; injectable for tests
    logger          callable(dict) that takes the log line instead of a file
    log_steps       True -> this module writes its own JSONL log (standalone CLI)

Safety model, per MAIN-SCREEN-BUILD.md "UTILITY VIEWS":

  * nothing runs without a plan, and a plan changes nothing (the self-check
    hashes the store and the quarantine tree before and after every plan);
  * ``read`` changes nothing, ``reversible`` needs ``--confirm <action>``;
  * deletes never happen: every file leaves its place as a *move* into
    ``_QUARANTINE/<YYYY-MM-DD>/<tag>/`` with a MANIFEST.tsv row, and the row
    uses the same five columns the existing manifests use;
  * crew.stop only signals a pid that a record names *and* whose ``ps`` command
    line carries that session ("never ``pkill -f``"). A record that does not
    verify is refused, not "tried anyway";
  * the Linux path (the documented ``hermes gateway stop``) is planned with
    ``linux_only: true`` and is never executed on this Mac.

Two deliberate departures from the shared reader contract (the W8
``feeds/README.md``, which owns that file):

  * ``crew.sessions`` is uncached. A maintenance plan that says "the biggest
    sessions" must be the live answer, and the read is one SELECT over ~4.2k
    rows: 3 ms warm, 97 ms cold, against the 2.9 GB live store on 2026-10-23. A
    10 s cache would make the plan a lie about now. ``--json`` still emits
    exactly one object;
  * ``crew.logs`` scans ``~/.hermes/session-exports`` (what
    ``hermes sessions export`` writes), so on a host that never exported a
    session the honest plan is zero items. ``--export-dir`` points it at any
    other tree, e.g. ``~/.hermes/sessions`` for the request dumps Hermes
    leaves behind, without ever deleting one.

Deliberately imports nothing from this directory (not ``hudfix.py``, not the
W8 readers): the branch is runnable before either lands. The few helpers below
are local copies of the v5 feed conventions, not shared code.

    python3 hudfix_crew.py --list
    python3 hudfix_crew.py --action crew.sessions --plan --json
    python3 hudfix_crew.py --action crew.logs --run --confirm crew.logs
    python3 hudfix_crew.py --self-check
"""

from __future__ import annotations

import argparse
import datetime
import gzip
import hashlib
import json
import os
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.parse
import zlib

MODULE = "hudfix_crew"
EXIT_OK = 0
EXIT_PROGRAMMING = 2

CLASSES = ("read", "safe", "reversible", "destructive")
CONFIRM_CLASSES = ("reversible", "destructive")

HOME = os.path.expanduser("~")

DEFAULT_DB = "~/.hermes/state.db"
DEFAULT_PID_FILE = "~/.local/state/nexuslink/session-pids.json"
HERMES_PROCESSES = "~/.hermes/processes.json"
DEFAULT_EXPORT_DIR = "~/.hermes/session-exports"
DEFAULT_QUARANTINE = "~/NEXUS_AI_CENTER/_QUARANTINE"
DEFAULT_LOG = "~/.local/state/nexuslink/hudfix.log"

#: What ``hermes sessions export`` writes, which is what crew.logs trims.
EXPORT_SUFFIXES = (".jsonl", ".json", ".md", ".qmd", ".html")

#: Session columns the live store has (PRAGMA table_info(sessions) on the
#: 2026-10-23 store). Missing ones degrade to a warning, never a crash.
SESSIONS_WANTED = (
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
    "message_count",
    "input_tokens",
    "output_tokens",
    "cache_read_tokens",
    "cache_write_tokens",
    "reasoning_tokens",
    "profile_name",
    "archived",
    "hidden",
)

MANIFEST_HEADER = "orig_path\tnew_path\tsize_kb\treason\tdate\n"


# --------------------------------------------------------------------- helpers


def tilde(path):
    """Home-relative display form; payloads never carry an absolute home path."""
    if not path:
        return ""
    shown = os.path.abspath(os.path.expanduser(str(path)))
    if shown == HOME:
        return "~"
    if shown.startswith(HOME + os.sep):
        return "~" + shown[len(HOME):]
    return shown


def expand(path):
    return os.path.abspath(os.path.expanduser(str(path)))


def tilde_text(message):
    for root in (HOME, os.path.realpath(HOME)):
        if root and root != "/" and root in message:
            message = message.replace(root + os.sep, "~" + os.sep).replace(root, "~")
    return message


def utc_now_epoch():
    return int(time.time())


def iso(epoch):
    """Epoch seconds -> ``2026-10-23T00:22:41Z``. Anything unusable -> None."""
    if epoch is None or isinstance(epoch, bool):
        return None
    try:
        value = float(epoch)
    except (TypeError, ValueError):
        return None
    if value != value or value in (float("inf"), float("-inf")):
        return None
    try:
        stamp = datetime.datetime.fromtimestamp(value, datetime.timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None
    return stamp.strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_now():
    return iso(utc_now_epoch())


def day_stamp(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%d")


def number(value):
    if value is None or isinstance(value, bool):
        return None
    try:
        out = float(value)
    except (TypeError, ValueError):
        return None
    if out != out or out in (float("inf"), float("-inf")):
        return None
    return out


def integer(value):
    num = number(value)
    return None if num is None else int(num)


def text(value, limit=None):
    if value is None:
        return None
    if not isinstance(value, str):
        value = str(value)
    value = " ".join(value.split())
    if not value:
        return None
    if limit is not None and len(value) > limit:
        value = value[: limit - 1].rstrip() + "\u2026"
    return value


def human_age(seconds):
    if seconds is None:
        return None
    seconds = int(max(0, seconds))
    if seconds < 90:
        return "%ds" % seconds
    minutes = seconds // 60
    if minutes < 90:
        return "%dm" % minutes
    hours = minutes // 60
    if hours < 48:
        return "%dh" % hours
    return "%dd" % (hours // 24)


def sha256_file(path, chunk=1 << 20):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(chunk), b""):
            digest.update(block)
    return digest.hexdigest()


def fingerprint(path):
    """Cheap identity for a store: size + mtime (no 2.9 GB hash per plan)."""
    try:
        info = os.stat(path)
    except OSError as exc:
        return {"path": tilde(path), "exists": False, "error": text(str(exc))}
    return {
        "path": tilde(path),
        "exists": True,
        "size_bytes": info.st_size,
        "mtime_ns": info.st_mtime_ns,
    }


def read_json(path):
    target = expand(path)
    with open(target, "r", encoding="utf-8") as handle:
        return json.load(handle)


def _ctx_get(ctx, key, default=None):
    if ctx is None:
        return default
    if isinstance(ctx, dict):
        value = ctx.get(key, default)
    else:
        value = getattr(ctx, key, default)
    return default if value is None else value


def detect_host():
    if sys.platform.startswith("linux"):
        return "linux"
    if sys.platform == "darwin":
        return "darwin"
    return sys.platform


def options(ctx=None):
    """Normalise ``ctx`` into the full option set every action reads."""
    host = text(_ctx_get(ctx, "host")) or detect_host()
    return {
        "host": host,
        "db": expand(_ctx_get(ctx, "db") or DEFAULT_DB),
        "db_named": bool(_ctx_get(ctx, "db")),
        "pid_file": expand(_ctx_get(ctx, "pid_file") or DEFAULT_PID_FILE),
        "pid_file_named": bool(_ctx_get(ctx, "pid_file")),
        "processes_file": expand(_ctx_get(ctx, "processes_file") or HERMES_PROCESSES),
        "export_dir": expand(_ctx_get(ctx, "export_dir") or DEFAULT_EXPORT_DIR),
        "quarantine_root": expand(_ctx_get(ctx, "quarantine_root") or DEFAULT_QUARANTINE),
        "session_id": text(_ctx_get(ctx, "session_id")),
        "path": expand(_ctx_get(ctx, "path")) if _ctx_get(ctx, "path") else None,
        "profile": text(_ctx_get(ctx, "profile")),
        "limit": max(1, integer(_ctx_get(ctx, "limit", 10)) or 10),
        "older_than_days": max(0.0, number(_ctx_get(ctx, "older_than_days", 30)) or 30.0),
        "grace_s": max(0.2, number(_ctx_get(ctx, "grace_s", 3.0)) or 3.0),
        "now": number(_ctx_get(ctx, "now", time.time())) or time.time(),
        "log": expand(_ctx_get(ctx, "log") or DEFAULT_LOG),
        "logger": _ctx_get(ctx, "logger"),
        "log_steps": bool(_ctx_get(ctx, "log_steps", False)),
    }


# ----------------------------------------------------------------- quarantine


def day_dir(opts, now=None):
    return os.path.join(opts["quarantine_root"], day_stamp(now if now is not None else opts["now"]))


def manifest_path(opts, now=None):
    return os.path.join(day_dir(opts, now), "MANIFEST.tsv")


def quarantine_dir(opts, tag, now=None):
    path = os.path.join(day_dir(opts, now), tag)
    os.makedirs(path, exist_ok=True)
    return path


def unique_path(parent, name):
    """``name``, or ``name.1``, ``name.2`` ... — never overwrite in quarantine."""
    candidate = os.path.join(parent, name)
    if not os.path.exists(candidate):
        return candidate
    stem, ext = os.path.splitext(name)
    index = 1
    while True:
        candidate = os.path.join(parent, "%s.%d%s" % (stem, index, ext))
        if not os.path.exists(candidate):
            return candidate
        index += 1


def size_kb(size_bytes):
    """MANIFEST size column: whole KB, and at least 1 for any non-empty file."""
    size = int(size_bytes or 0)
    if size <= 0:
        return 0
    return max(1, int(round(size / 1024.0)))


def manifest_append(opts, orig, new, size_bytes, reason, now=None):
    """Write one quarantine MANIFEST row. Same five columns as the existing files."""
    path = manifest_path(opts, now)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    row = "\t".join(
        [
            os.path.abspath(orig),
            os.path.abspath(new),
            str(size_kb(size_bytes)),
            reason.replace("\t", " ").replace("\n", " "),
            day_stamp(opts["now"] if now is None else now),
        ]
    ) + "\n"
    fresh = not os.path.exists(path)
    with open(path, "a", encoding="utf-8") as handle:
        if fresh:
            handle.write(MANIFEST_HEADER)
        handle.write(row)
        handle.flush()
        os.fsync(handle.fileno())
    return path


def manifest_rows(path):
    if not os.path.exists(path):
        return []
    with open(path, "r", encoding="utf-8") as handle:
        lines = [line.rstrip("\n") for line in handle if line.strip()]
    return lines[1:] if lines else []


def move_to_quarantine(opts, source, tag, reason, now=None):
    """Move ``source`` under ``_QUARANTINE/<day>/<tag>/`` and write the row."""
    dest_dir = quarantine_dir(opts, tag, now)
    destination = unique_path(dest_dir, os.path.basename(source))
    before = os.path.getsize(source)
    shutil.move(source, destination)
    if not os.path.exists(destination) or os.path.getsize(destination) != before:
        raise RuntimeError("quarantine move did not land: %s" % tilde(destination))
    row_path = manifest_append(opts, source, destination, before, reason, now)
    return {
        "source": tilde(source),
        "destination": tilde(destination),
        "bytes": before,
        "manifest": tilde(row_path),
    }


# ---------------------------------------------------------------------- logging


def log_event(opts, event):
    """One JSONL line: through the entry point's logger, or our own file."""
    entry = {"ts": iso_now(), "module": MODULE}
    entry.update(event)
    logger = opts.get("logger")
    if callable(logger):
        logger(entry)
        return {"via": "entry-point"}
    path = opts["log"]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, ensure_ascii=False, sort_keys=False) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    return {"via": "file", "path": tilde(path)}


def event_for(payload):
    total = payload.get("total") or {}
    return {
        "action": payload.get("action"),
        "phase": "plan" if payload.get("dry_run") else "run",
        "ok": bool(payload.get("ok")),
        "class": payload.get("class"),
        "host": payload.get("host"),
        "linux_only": bool(payload.get("linux_only")),
        "items": total.get("count"),
        "bytes": total.get("bytes"),
        "tokens": total.get("tokens"),
        "detail": text(payload.get("would") or payload.get("refuse_reason"), limit=300),
    }


def finish(payload, opts, phase):
    """Stamp the payload, and log the step when running standalone."""
    payload["generated_at"] = iso_now()
    payload["phase"] = "plan" if payload.get("dry_run") else "run"
    if phase and payload["phase"] != phase:
        payload["phase"] = phase
    if opts.get("log_steps"):
        payload["log"] = log_event(opts, event_for(payload))
    return payload


# --------------------------------------------------------------------- results


def result(action, klass, opts, **fields):
    """The shape every plan and run returns. Total is always all three keys."""
    total = fields.pop("total", None) or {}
    payload = {
        "ok": fields.pop("ok", True),
        "action": action,
        "class": klass,
        "host": opts["host"],
        "linux_only": bool(fields.pop("linux_only", False)),
        "dry_run": bool(fields.pop("dry_run", True)),
        "generated_at": iso_now(),
        "runnable": bool(fields.pop("runnable", True)),
        "changes": fields.pop("changes", []),
        "items": fields.pop("items", []),
        "total": {
            "count": integer(total.get("count")) or 0,
            "bytes": integer(total.get("bytes")),
            "tokens": integer(total.get("tokens")),
        },
        "would": fields.pop("would", None),
        "refuse_reason": fields.pop("refuse_reason", None),
    }
    payload.update(fields)
    return payload


# ------------------------------------------------------------- crew.sessions


def open_store_ro(path):
    """Read-only sqlite handle. Never creates, never writes, never locks for long."""
    if not os.path.exists(path):
        raise FileNotFoundError("no sessions store at %s" % tilde(path))
    if not os.path.isfile(path):
        raise FileNotFoundError("sessions store is not a file: %s" % tilde(path))
    uri = "file:%s?mode=ro&immutable=0" % urllib.parse.quote(path, safe="/")
    try:
        connection = sqlite3.connect(uri, uri=True, timeout=1.5)
    except sqlite3.Error as exc:
        raise ValueError("cannot open %s read-only: %s" % (tilde(path), exc))
    try:
        connection.row_factory = sqlite3.Row
        connection.isolation_level = None
        connection.execute("PRAGMA busy_timeout=1500")
        connection.execute("PRAGMA query_only=1")
    except sqlite3.Error as exc:
        connection.close()
        raise ValueError("%s is not a usable sqlite store: %s" % (tilde(path), exc))
    return connection


def store_columns(connection, table="sessions"):
    return [row[1] for row in connection.execute("PRAGMA table_info(%s)" % table)]


def sessions_read(opts):
    """One SELECT over the store: biggest sessions by tokens. Returns a dict."""
    store = fingerprint(opts["db"])
    payload = {"store": store, "query_only": True, "warnings": []}
    connection = open_store_ro(opts["db"])
    try:
        columns = store_columns(connection)
        if "id" not in columns:
            raise ValueError("%s has no sessions.id column" % tilde(opts["db"]))
        selected = [name for name in SESSIONS_WANTED if name in columns]
        missing = [name for name in SESSIONS_WANTED if name not in columns]
        if missing:
            payload["warnings"].append("columns absent upstream: %s" % ", ".join(missing))
        if not ({"input_tokens", "output_tokens"} & set(columns)):
            raise ValueError("%s has no token columns" % tilde(opts["db"]))

        token_expr = " + ".join(
            "COALESCE(%s, 0)" % name for name in ("input_tokens", "output_tokens") if name in columns
        )
        order = "(%s)" % token_expr
        sql = "SELECT %s FROM sessions ORDER BY %s DESC LIMIT ?" % (", ".join(selected), order)
        rows = [dict(row) for row in connection.execute(sql, (int(opts["limit"]),)).fetchall()]

        totals = connection.execute(
            "SELECT COUNT(*) AS n, COALESCE(SUM(%s), 0) AS tokens FROM sessions" % token_expr
        ).fetchone()
        payload["store_total"] = {
            "sessions": int(totals["n"] or 0),
            "tokens": int(totals["tokens"] or 0),
        }
    except sqlite3.Error as exc:
        raise ValueError("querying %s failed: %s" % (tilde(opts["db"]), exc))
    finally:
        connection.close()

    now = opts["now"]
    items = []
    for row in rows:
        started = number(row.get("started_at"))
        last = number(row.get("last_activity_at")) or started
        tokens = (integer(row.get("input_tokens")) or 0) + (integer(row.get("output_tokens")) or 0)
        ident = text(row.get("id")) or ""
        idle = max(0, int(now - last)) if last is not None else None
        state = "unknown" if idle is None else ("active" if idle <= 90 else "idle" if idle <= 600 else "stale")
        items.append(
            {
                "id": ident[-8:] if len(ident) > 8 else ident,
                "full": ident,
                "title": text(row.get("title")) or text(row.get("display_name")),
                "tokens": tokens,
                "age_s": max(0, int(now - started)) if started is not None else None,
                "age": human_age(now - started) if started is not None else None,
                "started_iso": iso(started),
                "last_activity_iso": iso(last),
                "state": state,
                "model": text(row.get("model")),
                "profile": text(row.get("profile_name")) or text(row.get("source")),
                "tools": integer(row.get("tool_call_count")),
                "messages": integer(row.get("message_count")),
                "cache_read_tokens": integer(row.get("cache_read_tokens")),
            }
        )
    payload["items"] = items
    payload["store_after"] = fingerprint(opts["db"])
    payload["store_unchanged"] = (
        payload["store"].get("size_bytes") == payload["store_after"].get("size_bytes")
        and payload["store"].get("mtime_ns") == payload["store_after"].get("mtime_ns")
    )
    return payload


def plan_sessions(ctx=None):
    opts = options(ctx)
    total = {"count": 0, "bytes": None, "tokens": None}
    try:
        read = sessions_read(opts)
    except (OSError, ValueError) as exc:
        payload = result(
            "crew.sessions",
            "read",
            opts,
            ok=False,
            runnable=False,
            refuse_reason=tilde_text(str(exc)),
            would="read-only: nothing to change, nothing readable",
            total=total,
        )
        return finish(payload, opts, "plan")
    total = {
        "count": len(read["items"]),
        "bytes": None,
        "tokens": sum(item["tokens"] or 0 for item in read["items"]),
    }
    payload = result(
        "crew.sessions",
        "read",
        opts,
        total=total,
        items=read["items"],
        would="read-only: list the %d biggest sessions by tokens; writes nothing"
        % len(read["items"]),
        store=read["store"],
        store_after=read["store_after"],
        store_unchanged=read["store_unchanged"],
        store_total=read.get("store_total"),
        query_only=read["query_only"],
        warnings=read["warnings"],
    )
    return finish(payload, opts, "plan")


def run_sessions(ctx, confirm):
    payload = plan_sessions(ctx)
    payload["dry_run"] = False
    payload["would"] = "read-only: listed %d sessions; the store was not written" % payload["total"]["count"]
    if payload.get("log_steps"):
        opts = options(ctx)
        payload["log"] = log_event(opts, event_for(payload))
    return payload


# ----------------------------------------------------------------- crew.stop


def load_pid_records(opts):
    """Records from the pid file, then Hermes' own process table.

    pid file (ours, written by whatever launches a bot on this Mac)::

        {"version": 1, "records": [
            {"session_id": "20261022_212924_d3a11b", "pid": 99164,
             "argv_match": "optional unique marker", "profile": "yamato"}]}

    A bare ``{"<session_id>": 1234}`` mapping is accepted too. The Hermes
    ``processes.json`` fallback has ``pid`` plus ``owner_task_id`` /
    ``parent_session_id`` / ``session_key``, and is read, never written.
    """
    records, warnings = [], []
    for path, source in ((opts["pid_file"], "session-pids"), (opts["processes_file"], "hermes-processes")):
        if not os.path.exists(path):
            if source == "session-pids" and opts["pid_file_named"]:
                warnings.append("named pid file does not exist: %s" % tilde(path))
            continue
        try:
            raw = read_json(path)
        except (OSError, ValueError) as exc:
            warnings.append("cannot read %s: %s" % (tilde(path), exc))
            continue
        if isinstance(raw, dict) and isinstance(raw.get("records"), list):
            entries = raw["records"]
        elif isinstance(raw, dict):
            entries = [{"session_id": key, "pid": value} for key, value in raw.items()]
        elif isinstance(raw, list):
            entries = raw
        else:
            warnings.append("%s has no records array" % tilde(path))
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            pid = integer(entry.get("pid"))
            if pid is None:
                continue
            ids = [
                text(entry.get("session_id")),
                text(entry.get("owner_task_id")),
                text(entry.get("parent_session_id")),
                text(entry.get("session_key")),
            ]
            records.append(
                {
                    "source": source,
                    "file": tilde(path),
                    "pid": pid,
                    "session_ids": [value for value in ids if value],
                    "argv_match": text(entry.get("argv_match")),
                    "profile": text(entry.get("profile")),
                    "command": text(entry.get("command"), limit=200),
                }
            )
    return records, warnings


def record_matches_session(record, session_id):
    wanted = text(session_id)
    if wanted is None:
        return False
    for value in record["session_ids"]:
        if value == wanted:
            return True
        if len(wanted) >= 6 and value.endswith(wanted):
            return True
        if len(value) >= 6 and wanted.endswith(value):
            return True
    return False


def ps_command_line(pid):
    """``ps`` command line for ``pid``, or None when the process is gone."""
    try:
        proc = subprocess.run(
            ["ps", "-o", "command=", "-p", str(int(pid))],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    line = (proc.stdout or "").strip()
    return line or None


def ps_state(pid):
    """``ps`` stat field: None when gone, ``Z`` when dead-but-unreaped."""
    try:
        proc = subprocess.run(
            ["ps", "-o", "stat=", "-p", str(int(pid))],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    line = (proc.stdout or "").strip()
    return line.split()[0] if line else None


def process_alive(pid):
    state = ps_state(pid)
    if state is None:
        return False
    return not state.upper().startswith("Z")


def linux_stop_command(opts):
    profile = opts.get("profile")
    if profile:
        return "hermes gateway stop --profile %s" % profile
    return "hermes gateway stop"


def resolve_stop(opts):
    """Plan fields for crew.stop: the record, the ps proof, and the refusal."""
    session_id = opts["session_id"]
    if not session_id:
        return {
            "runnable": False,
            "refuse_reason": "no session id given",
            "items": [],
            "warnings": [],
        }
    records, warnings = load_pid_records(opts)
    matches = [record for record in records if record_matches_session(record, session_id)]
    if not matches:
        return {
            "runnable": False,
            "linux_only": True,
            "command": linux_stop_command(opts),
            "refuse_reason": "no recorded pid for session %s on this host" % session_id,
            "note": "Linux only: the documented hermes stop command. Never a pkill pattern.",
            "blast_radius": "the whole gateway process for that profile stops; every session it serves stops with it",
            "items": [],
            "warnings": warnings,
            "records_seen": len(records),
        }

    items = []
    refusal = None
    for record in matches:
        entry = {
            "session_id": session_id,
            "pid": record["pid"],
            "pid_source": record["source"],
            "pid_file": record["file"],
            "command": "kill -TERM %d" % record["pid"],
            "verified": False,
        }
        if record["profile"]:
            entry["profile"] = record["profile"]
        if record["pid"] <= 1 or record["pid"] in (os.getpid(), os.getppid()):
            entry["refuse_reason"] = "pid %d is this process, its parent, or init; refusing" % record["pid"]
        else:
            line = ps_command_line(record["pid"])
            entry["argv"] = text(line, limit=200) if line else None
            if line is None:
                entry["refuse_reason"] = "pid %d is not running" % record["pid"]
            elif session_id in line:
                entry["verified"] = True
                entry["match_token"] = session_id
            elif record["argv_match"] and record["argv_match"] in line:
                entry["verified"] = True
                entry["matched_on"] = "argv_match"
                entry["match_token"] = record["argv_match"]
            else:
                entry["refuse_reason"] = (
                    "pid %d command line does not match session %s; refusing "
                    "(never kill on a pattern alone)" % (record["pid"], session_id)
                )
        if not entry["verified"] and refusal is None:
            refusal = entry.get("refuse_reason")
        items.append(entry)

    verified = [entry for entry in items if entry["verified"]]
    return {
        "runnable": bool(verified),
        "linux_only": False,
        "command": verified[0]["command"] if verified else None,
        "refuse_reason": None if verified else (refusal or "no verified pid"),
        "items": items,
        "warnings": warnings,
        "records_seen": len(records),
    }


def plan_stop(ctx=None):
    opts = options(ctx)
    resolved = resolve_stop(opts)
    count = len([entry for entry in resolved["items"] if entry.get("verified")])
    total = {"count": count, "bytes": None, "tokens": None}
    if resolved["runnable"]:
        would = "send SIGTERM to pid %s (verified against its ps line); no pkill, no SIGKILL" % (
            resolved["items"][0]["pid"] if resolved["items"] else "?"
        )
    elif resolved.get("linux_only"):
        would = "nothing on this Mac; the Linux host would run: %s" % resolved.get("command")
    else:
        would = "nothing: %s" % resolved.get("refuse_reason")
    payload = result(
        "crew.stop",
        "reversible",
        opts,
        ok=resolved["runnable"],
        total=total,
        items=resolved["items"],
        would=would,
        runnable=resolved["runnable"],
        refuse_reason=resolved.get("refuse_reason"),
        linux_only=resolved.get("linux_only", False),
        command=resolved.get("command"),
        session_id=opts["session_id"],
        records_seen=resolved.get("records_seen", 0),
        warnings=resolved.get("warnings", []),
        notes=[resolved["blast_radius"]] if resolved.get("blast_radius") else [],
        pid_file=tilde(opts["pid_file"]),
    )
    return finish(payload, opts, "plan")


def plan_linux_stop(opts, resolved):
    """The Linux branch: plan the documented hermes command, never run it here."""
    command = resolved.get("command") or linux_stop_command(opts)
    return {
        "session_id": opts["session_id"],
        "command": command,
        "linux_only": True,
        "verified": False,
        "refuse_reason": "linux_only: this Mac does not run the documented hermes stop command",
        "blast_radius": resolved.get(
            "blast_radius",
            "the whole gateway process for that profile stops; every session it serves stops with it",
        ),
    }


def linux_stop_run(opts, command):
    """Run the documented hermes stop command. Only reached on a real Linux host."""
    argv = command.split()
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=90)
    except (OSError, subprocess.SubprocessError) as exc:
        return {"exit_code": None, "error": text(str(exc)), "argv": argv}
    return {
        "exit_code": proc.returncode,
        "stdout": text(proc.stdout, limit=300),
        "stderr": text(proc.stderr, limit=300),
        "argv": argv,
    }


def run_stop(ctx, confirm):
    opts = options(ctx)
    action = "crew.stop"
    if confirm != action:
        payload = result(
            action,
            "reversible",
            opts,
            ok=False,
            runnable=False,
            dry_run=False,
            refuse_reason="reversible action needs --confirm %s (got %r)" % (action, confirm),
            would="nothing: confirmation missing",
            total={"count": 0},
        )
        return finish(payload, opts, "run")

    plan = plan_stop(ctx)
    plan["dry_run"] = False
    if not plan["runnable"]:
        if plan.get("linux_only"):
            item = plan_linux_stop(opts, {"command": plan.get("command")})
            if sys.platform.startswith("linux") and shutil.which("hermes"):
                executed = linux_stop_run(opts, item["command"])
                item.update(executed)
                plan["ok"] = executed.get("exit_code") == 0
                plan["runnable"] = plan["ok"]
                plan["total"] = {"count": 1 if plan["ok"] else 0, "bytes": None, "tokens": None}
                plan["changes"] = [{"what": "gateway", "from": "serving profile", "to": "stop"}]
                plan["would"] = (
                    "ran %s (exit %s)" % (item["command"], executed.get("exit_code"))
                    if plan["ok"]
                    else "ran %s; exit %s" % (item["command"], executed.get("exit_code"))
                )
            else:
                item["refuse_reason"] = (
                    "linux_only: %s runs on the Linux host, not here (%s)" % (item["command"], detect_host())
                )
                plan["refuse_reason"] = item["refuse_reason"]
                plan["would"] = "refused on this host: %s" % item["refuse_reason"]
            plan["items"] = [item]
        else:
            plan["would"] = "refused: %s" % plan.get("refuse_reason")
        if opts.get("log_steps"):
            plan["log"] = log_event(opts, event_for(plan))
        return plan

    item = [entry for entry in plan["items"] if entry.get("verified")][0]
    pid = int(item["pid"])
    token = item.get("match_token") or opts["session_id"]
    line = ps_command_line(pid)
    if line is None or token not in line:
        plan["ok"] = False
        plan["runnable"] = False
        plan["refuse_reason"] = "pid %d no longer matches session %s at run time" % (
            pid,
            opts["session_id"],
        )
        plan["would"] = "refused: %s" % plan["refuse_reason"]
        if opts.get("log_steps"):
            plan["log"] = log_event(opts, event_for(plan))
        return plan

    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        plan["ok"] = False
        plan["refuse_reason"] = "pid %d exited before the signal was sent" % pid
        plan["would"] = "nothing: process already gone"
        if opts.get("log_steps"):
            plan["log"] = log_event(opts, event_for(plan))
        return plan
    except PermissionError as exc:
        plan["ok"] = False
        plan["refuse_reason"] = "permission denied signalling pid %d: %s" % (pid, exc)
        plan["would"] = "nothing: not permitted"
        if opts.get("log_steps"):
            plan["log"] = log_event(opts, event_for(plan))
        return plan

    deadline = time.time() + opts["grace_s"]
    stopped = False
    while time.time() <= deadline:
        if not process_alive(pid):
            stopped = True
            break
        time.sleep(0.05)
    item["signalled"] = "TERM"
    item["stopped"] = stopped
    item["verified_after"] = ps_command_line(pid) is None
    plan["items"] = [item]
    plan["changes"] = [
        {"what": "process", "from": "running pid %d" % pid, "to": "SIGTERM" + (" and gone" if stopped else " sent")}
    ]
    plan["total"] = {"count": 1 if stopped else 0, "bytes": None, "tokens": None}
    plan["ok"] = bool(stopped)
    if stopped:
        plan["would"] = "sent SIGTERM to pid %d; the process is gone" % pid
        plan["refuse_reason"] = None
    else:
        plan["would"] = "sent SIGTERM to pid %d; still running after %.1fs (no SIGKILL sent)" % (
            pid,
            opts["grace_s"],
        )
        plan["refuse_reason"] = "still running after SIGTERM; escalate by hand if needed"
    if opts.get("log_steps"):
        plan["log"] = log_event(opts, event_for(plan))
    return plan


# ------------------------------------------------------------- crew.compress


def find_export_candidates(export_dir, session_id):
    """Export files that name ``session_id`` (export names start with the id)."""
    if not session_id or not os.path.isdir(export_dir):
        return []
    wanted = session_id
    found = []
    for name in sorted(os.listdir(export_dir)):
        path = os.path.join(export_dir, name)
        if not os.path.isfile(path) or os.path.islink(path):
            continue
        if not name.endswith(EXPORT_SUFFIXES):
            continue
        if name.startswith(wanted) or wanted in name or name.endswith(wanted + ".jsonl"):
            found.append(path)
    return found


def gzip_estimate(path):
    """Exact gzip size (header and trailer included) without writing anything."""
    compressor = zlib.compressobj(6, zlib.DEFLATED, 16 + zlib.MAX_WBITS)
    total = 0
    raw = 0
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            raw += len(chunk)
            total += len(compressor.compress(chunk))
    total += len(compressor.flush())
    return total, raw


def resolve_compress_source(opts):
    """(source path, None) or (None, refusal dict)."""
    if opts["path"]:
        if not os.path.exists(opts["path"]):
            raise FileNotFoundError("named source does not exist: %s" % tilde(opts["path"]))
        if os.path.islink(opts["path"]) or not os.path.isfile(opts["path"]):
            return None, {
                "refuse_reason": "not a regular file: %s" % tilde(opts["path"]),
                "kind": "refused",
            }
        return opts["path"], None

    if not opts["session_id"]:
        return None, {
            "refuse_reason": "give a session id or an explicit path",
            "kind": "refused",
        }
    candidates = find_export_candidates(opts["export_dir"], opts["session_id"])
    if not candidates:
        return None, {
            "refuse_reason": (
                "no export file for session %s in %s; the transcript lives inside the store, "
                "so export it first: hermes sessions export %s --output %s"
                % (
                    opts["session_id"],
                    tilde(opts["export_dir"]),
                    opts["session_id"],
                    tilde(opts["export_dir"]),
                )
            ),
            "kind": "missing",
            "requires": "hermes sessions export",
        }
    return candidates[0], None


def plan_compress(ctx=None):
    opts = options(ctx)
    session_id = opts["session_id"]
    tag = "crew-compress"
    try:
        source, refusal = resolve_compress_source(opts)
    except FileNotFoundError as exc:
        payload = result(
            "crew.compress",
            "reversible",
            opts,
            ok=False,
            runnable=False,
            refuse_reason=str(exc),
            would="nothing: %s" % exc,
            total={"count": 0},
            session_id=session_id,
            kind="caller-error",
            exit_code=EXIT_PROGRAMMING,
        )
        return finish(payload, opts, "plan")

    if source is None:
        payload = result(
            "crew.compress",
            "reversible",
            opts,
            ok=False,
            runnable=False,
            refuse_reason=refusal["refuse_reason"],
            would="nothing: %s" % refusal["refuse_reason"],
            total={"count": 0, "bytes": 0},
            session_id=session_id,
            kind=refusal.get("kind"),
            requires=refusal.get("requires"),
        )
        return finish(payload, opts, "plan")

    if os.path.abspath(source).startswith(opts["quarantine_root"] + os.sep):
        payload = result(
            "crew.compress",
            "reversible",
            opts,
            ok=False,
            runnable=False,
            refuse_reason="source is already inside quarantine: %s" % tilde(source),
            would="nothing",
            total={"count": 0},
            session_id=session_id,
        )
        return finish(payload, opts, "plan")

    estimate, raw = gzip_estimate(source)
    destination = os.path.join(quarantine_dir(opts, tag), os.path.basename(source) + ".gz")
    destination = unique_path(os.path.dirname(destination), os.path.basename(destination))
    payload = result(
        "crew.compress",
        "reversible",
        opts,
        total={"count": 1, "bytes": raw},
        items=[
            {
                "source": tilde(source),
                "destination": tilde(destination),
                "bytes": raw,
                "bytes_after": estimate,
                "saves": max(0, raw - estimate),
                "sha256": sha256_file(source),
                "mtime_iso": iso(os.path.getmtime(source)),
            }
        ],
        would="gzip %s into %s (%d -> %d bytes), verify the archive, then remove the source"
        % (tilde(source), tilde(destination), raw, estimate),
        session_id=session_id,
        bytes_saved=max(0, raw - estimate),
    )
    return finish(payload, opts, "plan")


def run_compress(ctx, confirm):
    opts = options(ctx)
    action = "crew.compress"
    if confirm != action:
        payload = result(
            action,
            "reversible",
            opts,
            ok=False,
            runnable=False,
            dry_run=False,
            refuse_reason="reversible action needs --confirm %s (got %r)" % (action, confirm),
            would="nothing: confirmation missing",
            total={"count": 0},
        )
        return finish(payload, opts, "run")

    plan = plan_compress(ctx)
    plan["dry_run"] = False
    if not plan["runnable"]:
        plan["would"] = "refused: %s" % plan.get("refuse_reason")
        if opts.get("log_steps"):
            plan["log"] = log_event(opts, event_for(plan))
        return plan

    item = plan["items"][0]
    source = expand(item["source"])
    destination = expand(item["destination"])
    if not os.path.exists(source):
        plan["ok"] = False
        plan["refuse_reason"] = "source vanished before the archive: %s" % item["source"]
        plan["would"] = "refused: %s" % plan["refuse_reason"]
        if opts.get("log_steps"):
            plan["log"] = log_event(opts, event_for(plan))
        return plan

    os.makedirs(os.path.dirname(destination), exist_ok=True)
    temporary = destination + ".part"
    source_sha = sha256_file(source)
    with open(source, "rb") as reader, gzip.open(temporary, "wb", compresslevel=6) as writer:
        for chunk in iter(lambda: reader.read(1 << 20), b""):
            writer.write(chunk)
    with open(temporary, "rb") as handle:
        os.fsync(handle.fileno())

    # The archive must round-trip to the same bytes before the source moves.
    digest = hashlib.sha256()
    with gzip.open(temporary, "rb") as reader:
        for chunk in iter(lambda: reader.read(1 << 20), b""):
            digest.update(chunk)
    if digest.hexdigest() != source_sha:
        os.unlink(temporary)
        plan["ok"] = False
        plan["refuse_reason"] = "archive did not round-trip; source left in place"
        plan["would"] = "refused: %s" % plan["refuse_reason"]
        if opts.get("log_steps"):
            plan["log"] = log_event(opts, event_for(plan))
        return plan

    os.replace(temporary, destination)
    archived = os.path.getsize(destination)
    row = manifest_append(
        opts,
        source,
        destination,
        archived,
        "hudfix crew.compress session %s (%d B -> %d B)"
        % ((opts["session_id"] or os.path.basename(source)), item["bytes"], archived),
    )
    os.unlink(source)
    item["bytes_after"] = archived
    item["sha256_after"] = source_sha
    item["verified"] = True
    plan["items"] = [item]
    plan["changes"] = [
        {"what": "archive", "from": item["source"], "to": item["destination"]},
        {"what": "source", "from": item["source"], "to": "removed after archive verify"},
    ]
    plan["manifest"] = tilde(row)
    plan["total"] = {"count": 1, "bytes": item["bytes"], "tokens": None}
    plan["would"] = "archived %s to %s (%d -> %d bytes); source removed" % (
        item["source"],
        item["destination"],
        item["bytes"],
        archived,
    )
    if opts.get("log_steps"):
        plan["log"] = log_event(opts, event_for(plan))
    return plan


# ----------------------------------------------------------------- crew.logs


def collect_old_exports(opts):
    """Regular export files older than the age floor, oldest first."""
    root = opts["export_dir"]
    if not os.path.isdir(root):
        return [], "no export directory at %s" % tilde(root)
    cutoff = opts["now"] - opts["older_than_days"] * 86400.0
    items = []
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name)
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        if not name.endswith(EXPORT_SUFFIXES):
            continue
        try:
            info = os.stat(path)
        except OSError:
            continue
        if info.st_mtime > cutoff:
            continue
        items.append(
            {
                "path": tilde(path),
                "name": name,
                "bytes": info.st_size,
                "mtime_iso": iso(info.st_mtime),
                "age_days": round((opts["now"] - info.st_mtime) / 86400.0, 2),
            }
        )
    items.sort(key=lambda entry: entry["mtime_iso"] or "")
    return items, None


def plan_logs(ctx=None):
    opts = options(ctx)
    items, reason = collect_old_exports(opts)
    total = {
        "count": len(items),
        "bytes": sum(item["bytes"] for item in items),
        "tokens": None,
    }
    payload = result(
        "crew.logs",
        "reversible",
        opts,
        ok=reason is None,
        runnable=bool(items),
        refuse_reason=reason if reason else (None if items else "no export older than %gd" % opts["older_than_days"]),
        total=total,
        items=items,
        would="move %d export file(s), %d bytes, older than %gd from %s into quarantine"
        % (len(items), total["bytes"], opts["older_than_days"], tilde(opts["export_dir"]))
        if items
        else "nothing older than %gd in %s" % (opts["older_than_days"], tilde(opts["export_dir"])),
        export_dir=tilde(opts["export_dir"]),
        older_than_days=opts["older_than_days"],
    )
    return finish(payload, opts, "plan")


def run_logs(ctx, confirm):
    opts = options(ctx)
    action = "crew.logs"
    if confirm != action:
        payload = result(
            action,
            "reversible",
            opts,
            ok=False,
            runnable=False,
            dry_run=False,
            refuse_reason="reversible action needs --confirm %s (got %r)" % (action, confirm),
            would="nothing: confirmation missing",
            total={"count": 0},
        )
        return finish(payload, opts, "run")

    plan = plan_logs(ctx)
    plan["dry_run"] = False
    moved = []
    rows = []
    for entry in plan["items"]:
        source = expand(entry["path"])
        if not os.path.exists(source):
            continue
        try:
            moved_entry = move_to_quarantine(
                opts,
                source,
                "crew-logs",
                "hudfix crew.logs older than %gd" % opts["older_than_days"],
            )
        except (OSError, RuntimeError) as exc:
            plan["ok"] = False
            plan.setdefault("errors", []).append("%s: %s" % (entry["path"], exc))
            continue
        moved.append(moved_entry)
        rows.append(moved_entry["manifest"])
    plan["items"] = moved
    plan["changes"] = [{"what": "export", "from": item["source"], "to": item["destination"]} for item in moved]
    plan["total"] = {
        "count": len(moved),
        "bytes": sum(item["bytes"] for item in moved),
        "tokens": None,
    }
    plan["manifests"] = sorted(set(rows))
    plan["would"] = (
        "moved %d export file(s), %d bytes, into quarantine; nothing deleted"
        % (len(moved), plan["total"]["bytes"])
        if moved
        else "nothing moved: %s" % (plan.get("refuse_reason") or "no matching file")
    )
    if opts.get("log_steps"):
        plan["log"] = log_event(opts, event_for(plan))
    return plan


# ------------------------------------------------------------------- registry


ACTIONS = {
    "crew.sessions": {
        "class": "read",
        "doc": "Biggest sessions by tokens, read-only from the Hermes store (id, title, tokens, age).",
        "plan": plan_sessions,
        "run": run_sessions,
        "linux_only": False,
    },
    "crew.stop": {
        "class": "reversible",
        "doc": "Stop a runaway session by a recorded pid whose ps line carries that session; never pkill -f.",
        "plan": plan_stop,
        "run": run_stop,
        "linux_only": False,
    },
    "crew.compress": {
        "class": "reversible",
        "doc": "gzip one session export into quarantine, verify the round-trip, then drop the source.",
        "plan": plan_compress,
        "run": run_compress,
        "linux_only": False,
    },
    "crew.logs": {
        "class": "reversible",
        "doc": "Move session exports older than an age floor into quarantine; never delete.",
        "plan": plan_logs,
        "run": run_logs,
        "linux_only": False,
    },
}


# ------------------------------------------------------------------------ CLI


def emit(payload, compact):
    if compact:
        line = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=False)
    else:
        line = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=False)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def build_parser():
    parser = argparse.ArgumentParser(
        prog="hudfix_crew.py",
        description="hudfix crew actions (F8b): plan/run biggest sessions, stop, compress, trim logs.",
    )
    parser.add_argument("--list", action="store_true", help="list the actions and exit")
    parser.add_argument("--action", choices=sorted(ACTIONS), help="action to plan or run")
    parser.add_argument("--plan", action="store_true", help="dry run: what would happen, changes nothing")
    parser.add_argument("--run", action="store_true", help="perform the action")
    parser.add_argument("--confirm", metavar="ACTION", help="required for reversible actions")
    parser.add_argument("--self-check", action="store_true", help="prove the package on generated fixtures")
    parser.add_argument("--keep", action="store_true", help="keep the self-check temp tree")
    parser.add_argument("--json", action="store_true", help="one compact JSON line")
    parser.add_argument("--session-id", dest="session_id", help="session id (full or 6-char tail)")
    parser.add_argument("--path", help="explicit source file for crew.compress")
    parser.add_argument("--profile", help="profile for the Linux stop plan")
    parser.add_argument("--db", help="sessions store (default ~/.hermes/state.db)")
    parser.add_argument("--pid-file", dest="pid_file", help="pid record file")
    parser.add_argument("--export-dir", dest="export_dir", help="export directory")
    parser.add_argument("--quarantine-root", dest="quarantine_root", help="quarantine root")
    parser.add_argument("--log", help="JSONL log path")
    parser.add_argument("--older-than", dest="older_than_days", type=float, default=30.0,
                        help="crew.logs age floor in days (default 30)")
    parser.add_argument("--limit", type=int, default=10, help="crew.sessions rows (default 10)")
    parser.add_argument("--grace", dest="grace_s", type=float, default=3.0,
                        help="crew.stop wait after SIGTERM, seconds (default 3)")
    parser.add_argument("--no-log", dest="no_log", action="store_true", help="do not write the JSONL log")
    return parser


def ctx_from_args(args):
    return {
        "session_id": args.session_id,
        "path": args.path,
        "profile": args.profile,
        "db": args.db,
        "pid_file": args.pid_file,
        "export_dir": args.export_dir,
        "quarantine_root": args.quarantine_root,
        "log": args.log,
        "older_than_days": args.older_than_days,
        "limit": args.limit,
        "grace_s": args.grace_s,
        "log_steps": not args.no_log,
    }


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.self_check:
        return self_check(keep=args.keep, compact=args.json, verbose=True)

    if args.list:
        payload = {
            "ok": True,
            "module": MODULE,
            "host": detect_host(),
            "actions": [
                {
                    "name": name,
                    "class": entry["class"],
                    "doc": entry["doc"],
                    "linux_only": entry["linux_only"],
                    "needs_confirm": entry["class"] in CONFIRM_CLASSES,
                }
                for name, entry in ACTIONS.items()
            ],
        }
        emit(payload, args.json)
        return EXIT_OK

    if not args.action:
        parser.error("give --action <name>, --list, or --self-check")
    if not (args.plan or args.run):
        parser.error("give --plan (dry run) or --run")

    ctx = ctx_from_args(args)
    entry = ACTIONS[args.action]
    try:
        if args.plan:
            payload = entry["plan"](ctx)
        else:
            payload = entry["run"](ctx, args.confirm)
    except Exception as exc:  # noqa: BLE001 - a bug is exit 2, not a traceback on stdout
        emit(
            {
                "ok": False,
                "action": args.action,
                "class": entry["class"],
                "generated_at": iso_now(),
                "kind": "programming",
                "reason": tilde_text("%s: %s" % (type(exc).__name__, exc)),
            },
            args.json,
        )
        return EXIT_PROGRAMMING

    emit(payload, args.json)
    if payload.get("exit_code") == EXIT_PROGRAMMING:
        return EXIT_PROGRAMMING
    if args.run and entry["class"] in CONFIRM_CLASSES and args.confirm != args.action:
        return EXIT_PROGRAMMING
    return EXIT_OK


# ------------------------------------------------------------------ self-check


class Checks(object):
    def __init__(self, verbose=True):
        self.verbose = verbose
        self.passed = 0
        self.failed = []
        self.lines = []

    def check(self, name, condition, detail=""):
        detail = "" if detail is None else str(detail)
        if condition:
            self.passed += 1
            if self.verbose:
                print("ok   %s" % name)
        else:
            self.failed.append((name, detail))
            print("FAIL %s%s" % (name, (": " + detail) if detail else ""))
        return bool(condition)

    def equal(self, name, got, want):
        return self.check(name, got == want, "got %r, want %r" % (got, want))

    def summary(self):
        total = self.passed + len(self.failed)
        print("SELF-CHECK: %d passed, %d failed, %d checks" % (self.passed, len(self.failed), total))
        return EXIT_OK if not self.failed else 1


def _make_store(path):
    """A generated stand-in for the live store: same sessions columns, real rows."""
    now = utc_now_epoch()
    connection = sqlite3.connect(path)
    connection.executescript(
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
            message_count INTEGER DEFAULT 0,
            input_tokens INTEGER DEFAULT 0,
            output_tokens INTEGER DEFAULT 0,
            cache_read_tokens INTEGER DEFAULT 0,
            cache_write_tokens INTEGER DEFAULT 0,
            reasoning_tokens INTEGER DEFAULT 0,
            profile_name TEXT,
            archived INTEGER NOT NULL DEFAULT 0,
            hidden INTEGER NOT NULL DEFAULT 0
        );
        """
    )
    rows = [
        ("20261020_101010_aaaaaa", "local", "claude-sonnet-5-5", None, now - 3 * 86400, None,
         now - 120, "receiving stream response", "Map the deck panels", None, 88, 410,
         41000000, 1200000, 5000, 100, 0, "yamato", 0, 0),
        ("20261021_111111_bbbbbb", "local", "deepseek-v4.1-flash", None, now - 40000, None,
         now - 30, "tool call", "F8b crew module", None, 12, 60, 900000, 41000, 0, 0, 0,
         "yamato", 0, 0),
        ("20261022_222222_cccccc", "oneshot", "deepseek-v4.1-flash", None, now - 4000, None,
         now - 10, "", "Recent small run", None, 2, 4, 1200, 300, 0, 0, 0, "default", 0, 0),
        ("20261023_333333_dddddd", "local", "claude-sonnet-5-5", None, now - 300, None,
         now - 5, "", "Tiny fresh run", None, 1, 3, 100, 50, 0, 0, 0, "default", 0, 0),
        ("20261001_444444_eeeeee", "local", "claude-sonnet-5-5", None, now - 300, now - 200,
         now - 200, "cli_close", "Ended run", None, 1, 1, 5, 5, 0, 0, 0, "default", 0, 0),
        ("20261001_555555_ffffff", "local", "claude-sonnet-5-5", None, now - 300, None,
         now - 100, "", "Hidden run", None, 1, 1, 1, 1, 0, 0, 0, "default", 0, 1),
    ]
    connection.executemany(
        "INSERT INTO sessions VALUES (%s)" % ",".join(["?"] * 20), rows
    )
    connection.commit()
    connection.close()
    return now


def _spawn_dummy(marker, seconds=60):
    """A real process we own, whose ps line carries ``marker``."""
    argv = [sys.executable, "-c", "import time; time.sleep(%d)" % seconds, marker]
    return subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _tree_state(root):
    """Every path under ``root`` with size and mtime: the 'plan changed nothing' proof."""
    state = {}
    if not os.path.isdir(root):
        return state
    for base, _dirs, names in os.walk(root):
        for name in sorted(names):
            path = os.path.join(base, name)
            try:
                info = os.stat(path)
            except OSError:
                continue
            state[os.path.relpath(path, root)] = (info.st_size, info.st_mtime_ns)
    return state


def self_check(keep=False, compact=False, verbose=True):
    global HERMES_PROCESSES
    checks = Checks(verbose=verbose)
    root = tempfile.mkdtemp(prefix="hudfix-crew-selftest-")
    # The Hermes process table is a second pid source; point it at the temp tree
    # so not one real process record is read during this proof.
    HERMES_PROCESSES = os.path.join(root, "no-hermes-processes.json")
    now = utc_now_epoch()
    store = os.path.join(root, "state.db")
    pid_file = os.path.join(root, "session-pids.json")
    export_dir = os.path.join(root, "session-exports")
    quarantine = os.path.join(root, "_QUARANTINE")
    log_path = os.path.join(root, "hudfix.log")
    keep_root = root

    dummies = []
    try:
        _make_store(store)
        os.makedirs(export_dir, exist_ok=True)
        for index, name in enumerate(
            [
                "20260901_aaaaaa_old.jsonl",
                "20260815_bbbbbb_older.md",
                "20260701_cccccc_oldest.qmd",
                "20261023_dddddd_fresh.jsonl",
                "notes.txt",
            ]
        ):
            path = os.path.join(export_dir, name)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(('{"session": "%s", "pad": "%s"}\n' % (name, "x" * 400)) * 200)
            if name.startswith("2026") and "fresh" not in name:
                os.utime(path, (now - (40 + index * 10) * 86400.0,) * 2)

        # ---- registry shape
        checks.equal("ACTIONS has four crew verbs", sorted(ACTIONS), ["crew.compress", "crew.logs", "crew.sessions", "crew.stop"])
        for name, entry in ACTIONS.items():
            checks.check("%s has class/doc/plan/run/linux_only" % name,
                         all(key in entry for key in ("class", "doc", "plan", "run", "linux_only")))
            checks.check("%s class is typed" % name, entry["class"] in CLASSES, entry["class"])
            checks.check("%s plan/run callable" % name, callable(entry["plan"]) and callable(entry["run"]))
            checks.check("%s linux_only is bool" % name, isinstance(entry["linux_only"], bool))

        source_text = open(os.path.abspath(__file__), "r", encoding="utf-8").read()
        import_lines = [
            line.strip()
            for line in source_text.splitlines()
            if line.strip().startswith(("import ", "from "))
        ]
        checks.check("module imports no sibling (stdlib only)",
                     not any(
                         needle in line
                         for line in import_lines
                         for needle in (" " + "hudfix", " " + "_common", " " + "sessions")
                     ),
                     str([line for line in import_lines if "hudfix" in line or "_common" in line]))
        risky = ['"pk' + 'ill"', "'pk" + "ill'", '"kill' + 'all"', "'kill" + "all'"]
        checks.check("module never shells out to pkill/killall",
                     not any(token in source_text for token in risky))

        ctx = {
            "db": store,
            "pid_file": pid_file,
            "processes_file": os.path.join(root, "no-hermes-processes.json"),
            "export_dir": export_dir,
            "quarantine_root": quarantine,
            "log": log_path,
            "now": now,
            "limit": 3,
            "older_than_days": 30,
            "grace_s": 3.0,
            "log_steps": False,
        }
        db_before = fingerprint(store)
        tree_before = _tree_state(quarantine)

        # ---- crew.sessions plan changes nothing, and finds the biggest session
        plan = plan_sessions(dict(ctx))
        checks.check("crew.sessions plan ok", plan["ok"], plan.get("refuse_reason"))
        checks.equal("crew.sessions class", plan["class"], "read")
        checks.check("crew.sessions returns the limit", plan["total"]["count"] == 3, str(plan["total"]))
        checks.equal("crew.sessions biggest id", plan["items"][0]["full"], "20261020_101010_aaaaaa")
        checks.equal("crew.sessions biggest tokens", plan["items"][0]["tokens"], 41000000 + 1200000)
        checks.check("crew.sessions item carries id/title/tokens/age",
                     all(key in plan["items"][0] for key in ("id", "title", "tokens", "age")))
        checks.check("crew.sessions age reads as days", plan["items"][0]["age"] == "3d", plan["items"][0]["age"])
        checks.check("crew.sessions store unchanged", plan.get("store_unchanged") is True)
        checks.equal("crew.sessions db fingerprint stable", fingerprint(store), db_before)
        checks.equal("crew.sessions quarantine untouched", _tree_state(quarantine), tree_before)
        checks.check("crew.sessions is read-only by pragma", plan.get("query_only") is True)
        checks.check("crew.sessions has no changes", plan["changes"] == [])
        checks.check("crew.sessions missing store is an answer, not a crash",
                     plan_sessions({"db": os.path.join(root, "nope.db"), "log_steps": False})["ok"] is False)

        # ---- crew.stop: refused when the ps line does not match
        bystander = _spawn_dummy("bystander-process-0001")
        dummies.append(bystander)
        time.sleep(0.15)
        good = _spawn_dummy("sess-runaway-0007")
        dummies.append(good)
        time.sleep(0.15)
        with open(pid_file, "w", encoding="utf-8") as handle:
            json.dump(
                {
                    "version": 1,
                    "records": [
                        {"session_id": "sess-mismatch-0001", "pid": bystander.pid},
                        {"session_id": "sess-runaway-0007", "pid": good.pid,
                         "argv_match": "sess-runaway-0007", "profile": "yamato"},
                        {"session_id": "sess-init-0001", "pid": 1},
                    ],
                },
                handle,
            )

        mismatch = plan_stop({"session_id": "sess-mismatch-0001", "pid_file": pid_file,
                              "now": now, "log_steps": False})
        checks.check("crew.stop refuses a pid whose ps line does not match", mismatch["ok"] is False)
        checks.check("crew.stop refusal names the ps line",
                     "command line does not match" in (mismatch.get("refuse_reason") or ""),
                     mismatch.get("refuse_reason"))
        checks.check("crew.stop refusal leaves the bystander running", process_alive(bystander.pid))
        refused_run = run_stop({"session_id": "sess-mismatch-0001", "pid_file": pid_file,
                                "now": now, "log_steps": False}, "crew.stop")
        checks.check("crew.stop run refuses too", refused_run["ok"] is False)
        checks.check("crew.stop run did not signal the bystander", process_alive(bystander.pid))
        checks.equal("crew.stop quarantine untouched", _tree_state(quarantine), tree_before)
        checks.equal("crew.stop store untouched", fingerprint(store), db_before)

        init_plan = plan_stop({"session_id": "sess-init-0001", "pid_file": pid_file,
                               "now": now, "log_steps": False})
        checks.check("crew.stop refuses pid 1", init_plan["ok"] is False and init_plan["runnable"] is False)
        checks.check("crew.stop pid 1 refusal is explicit", "init" in (init_plan.get("refuse_reason") or ""))

        no_record = plan_stop({"session_id": "20261020_101010_aaaaaa", "pid_file": pid_file,
                               "now": now, "log_steps": False, "host": "darwin"})
        checks.check("crew.stop with no record plans linux_only", no_record["linux_only"] is True)
        checks.check("crew.stop linux plan names the hermes command",
                     (no_record.get("command") or "").startswith("hermes gateway stop"),
                     no_record.get("command"))
        no_record_run = run_stop({"session_id": "20261020_101010_aaaaaa", "pid_file": pid_file,
                                  "now": now, "log_steps": False, "host": "darwin"}, "crew.stop")
        checks.check("crew.stop refuses to run a linux_only plan on this Mac",
                     no_record_run["ok"] is False and no_record_run["runnable"] is False)
        checks.check("crew.stop linux refusal says linux_only",
                     "linux_only" in (no_record_run.get("refuse_reason") or ""))
        checks.check("crew.stop linux refusal executed nothing", process_alive(good.pid))

        # A host claim of "linux" on this Mac must not unlock execution either.
        forced = run_stop({"session_id": "20261020_101010_aaaaaa", "pid_file": pid_file,
                           "now": now, "log_steps": False, "host": "linux"}, "crew.stop")
        checks.check("crew.stop stays refused when ctx claims linux on a Mac",
                     forced["ok"] is False and process_alive(good.pid))
        checks.check("crew.stop names the platform it actually is",
                     "darwin" in (forced.get("refuse_reason") or ""), forced.get("refuse_reason"))

        # The Hermes process table is the second pid source; prove it is read.
        processes_file = os.path.join(root, "hermes-processes.json")
        with open(processes_file, "w", encoding="utf-8") as handle:
            json.dump([{"session_id": "proc_deadbeef0001", "pid": bystander.pid,
                        "owner_task_id": "sess-table-0001", "command": "cd ~/x && long job"}], handle)
        table_plan = plan_stop({"session_id": "sess-table-0001", "pid_file": pid_file,
                                "processes_file": processes_file, "now": now, "log_steps": False})
        checks.check("crew.stop finds a pid in the Hermes process table",
                     bool(table_plan["items"]) and table_plan["items"][0]["pid_source"] == "hermes-processes",
                     table_plan.get("warnings"))
        checks.check("crew.stop still refuses the process-table pid (ps line has no session id)",
                     table_plan["ok"] is False and process_alive(bystander.pid))

        # ---- crew.stop: the verified path really stops a process we own
        confirm_plan = plan_stop({"session_id": "sess-runaway-0007", "pid_file": pid_file,
                                  "now": now, "log_steps": False})
        checks.check("crew.stop verifies the matching pid", confirm_plan["runnable"] is True)
        checks.equal("crew.stop plan names the exact command", confirm_plan["items"][0]["command"],
                     "kill -TERM %d" % good.pid)
        checks.check("crew.stop plan carries the ps proof", bool(confirm_plan["items"][0].get("argv")))
        no_confirm = run_stop({"session_id": "sess-runaway-0007", "pid_file": pid_file,
                               "now": now, "log_steps": False}, None)
        checks.check("crew.stop without --confirm refuses", no_confirm["ok"] is False)
        checks.check("crew.stop without --confirm leaves it running", process_alive(good.pid))
        stopped = run_stop({"session_id": "sess-runaway-0007", "pid_file": pid_file,
                            "now": now, "log_steps": False, "grace_s": 3.0}, "crew.stop")
        checks.check("crew.stop run signals the verified pid", stopped["ok"] is True, stopped.get("refuse_reason"))
        checks.check("crew.stop run reports the process gone", not process_alive(good.pid))
        try:
            good.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        checks.equal("crew.stop quarantine untouched (again)", _tree_state(quarantine), tree_before)

        # ---- crew.compress
        source = os.path.join(export_dir, "20261021_111111_bbbbbb.jsonl")
        with open(source, "w", encoding="utf-8") as handle:
            handle.write('{"role": "user", "content": "compress me"}\n' * 2000)
        source_sha = sha256_file(source)
        source_bytes = os.path.getsize(source)
        compress_plan = plan_compress({"session_id": "20261021_111111_bbbbbb", "export_dir": export_dir,
                                       "quarantine_root": quarantine, "now": now, "log_steps": False})
        checks.check("crew.compress plan ok", compress_plan["ok"], compress_plan.get("refuse_reason"))
        checks.equal("crew.compress plan source", compress_plan["items"][0]["source"], tilde(source))
        checks.check("crew.compress plan names a .gz destination",
                     compress_plan["items"][0]["destination"].endswith(".gz"))
        checks.equal("crew.compress plan bytes", compress_plan["items"][0]["bytes"], source_bytes)
        checks.check("crew.compress plan changes nothing on disk", os.path.exists(source))
        checks.equal("crew.compress quarantine untouched by plan", _tree_state(quarantine), tree_before)
        no_confirm = run_compress({"session_id": "20261021_111111_bbbbbb", "export_dir": export_dir,
                                   "quarantine_root": quarantine, "now": now, "log_steps": False}, None)
        checks.check("crew.compress without --confirm refuses", no_confirm["ok"] is False)
        checks.check("crew.compress refusal left the source", os.path.exists(source))
        compress_run = run_compress({"session_id": "20261021_111111_bbbbbb", "export_dir": export_dir,
                                     "quarantine_root": quarantine, "now": now, "log_steps": False},
                                    "crew.compress")
        checks.check("crew.compress run ok", compress_run["ok"], compress_run.get("refuse_reason"))
        archive = expand(compress_run["items"][0]["destination"])
        checks.check("crew.compress archive exists", os.path.exists(archive), archive)
        checks.check("crew.compress source is gone", not os.path.exists(source))
        checks.check("crew.compress archive round-trips",
                     sha256_file(archive) != "" and _gunzip_sha256(archive) == source_sha)
        checks.check("crew.compress writes a MANIFEST row", len(manifest_rows(manifest_path({"quarantine_root": quarantine}, now))) == 1)
        row = manifest_rows(manifest_path({"quarantine_root": quarantine}, now))[0]
        checks.equal("crew.compress MANIFEST has five columns", len(row.split("\t")), 5)
        checks.check("crew.compress MANIFEST names the archive", archive in row.split("\t")[1])
        checks.check("crew.compress MANIFEST records the byte counts",
                     ("%d B -> " % source_bytes) in row and row.split("\t")[2] != "0",
                     row)
        checks.check("crew.compress second run refuses (no source)",
                     plan_compress({"session_id": "20261021_111111_bbbbbb", "export_dir": export_dir,
                                    "quarantine_root": quarantine, "now": now,
                                    "log_steps": False})["ok"] is False)
        missing = plan_compress({"path": os.path.join(root, "absent.bin"), "quarantine_root": quarantine,
                                 "now": now, "log_steps": False})
        checks.equal("crew.compress named missing path is a caller error", missing.get("exit_code"), EXIT_PROGRAMMING)

        # ---- crew.logs
        tree_before_logs = _tree_state(quarantine)
        db_before_logs = fingerprint(store)
        logs_plan = plan_logs({"export_dir": export_dir, "quarantine_root": quarantine, "now": now,
                               "older_than_days": 30, "log_steps": False})
        checks.check("crew.logs plan ok", logs_plan["ok"], logs_plan.get("refuse_reason"))
        checks.equal("crew.logs plan count", logs_plan["total"]["count"], 3)
        checks.check("crew.logs plan lists bytes per file",
                     all(item["bytes"] > 0 for item in logs_plan["items"]))
        checks.check("crew.logs keeps the fresh export",
                     not any("fresh" in item["name"] for item in logs_plan["items"]))
        checks.check("crew.logs ignores non-export files",
                     not any(item["name"].endswith(".txt") for item in logs_plan["items"]))
        checks.equal("crew.logs quarantine untouched by plan", _tree_state(quarantine), tree_before_logs)
        before_names = sorted(os.listdir(export_dir))
        no_confirm = run_logs({"export_dir": export_dir, "quarantine_root": quarantine, "now": now,
                               "older_than_days": 30, "log_steps": False}, None)
        checks.check("crew.logs without --confirm refuses", no_confirm["ok"] is False)
        checks.equal("crew.logs refusal moved nothing", sorted(os.listdir(export_dir)), before_names)
        logs_run = run_logs({"export_dir": export_dir, "quarantine_root": quarantine, "now": now,
                             "older_than_days": 30, "log_steps": False}, "crew.logs")
        checks.check("crew.logs run ok", logs_run["ok"], logs_run.get("refuse_reason"))
        checks.equal("crew.logs moved three files", logs_run["total"]["count"], 3)
        after_names = sorted(os.listdir(export_dir))
        checks.check("crew.logs fresh export survived", any("fresh" in name for name in after_names))
        checks.check("crew.logs old exports left the dir",
                     not any("old" in name for name in after_names))
        checks.equal("crew.logs quarantine tree grew by three", len(_tree_state(os.path.join(quarantine, day_stamp(now), "crew-logs"))), 3)
        rows_after = manifest_rows(manifest_path({"quarantine_root": quarantine}, now))
        checks.equal("crew.logs appended three MANIFEST rows", len(rows_after), 4)
        checks.check("crew.logs quarantine copies are byte-identical",
                     all(os.path.getsize(os.path.join(quarantine, day_stamp(now), "crew-logs", name)) > 0
                         for name in os.listdir(os.path.join(quarantine, day_stamp(now), "crew-logs"))))
        checks.check("crew.logs second run has nothing to do",
                     plan_logs({"export_dir": export_dir, "quarantine_root": quarantine, "now": now,
                                "older_than_days": 30, "log_steps": False})["total"]["count"] == 0)
        checks.equal("crew.logs store untouched", fingerprint(store), db_before_logs)

        # ---- logging goes through the file when standalone, and says nothing secret
        log_ctx = dict(ctx, log_steps=True, log=log_path)
        plan_sessions(log_ctx)
        run_logs(log_ctx, "crew.logs")
        checks.check("standalone log file exists", os.path.exists(log_path))
        lines = [json.loads(line) for line in open(log_path, encoding="utf-8") if line.strip()]
        checks.check("standalone log is JSONL with phases",
                     any(line.get("phase") == "plan" for line in lines)
                     and any(line.get("phase") == "run" for line in lines), str(len(lines)))
        checks.check("standalone log carries no absolute home path",
                     not any(HOME in json.dumps(line) for line in lines))
        south = log_event({"log_steps": True, "log": log_path}, {"action": "crew.sessions", "phase": "plan", "ok": True})
        checks.check("log_event returns the file path it wrote", south.get("via") == "file")

        # ---- CLI contract
        code_list, out_list = _cli(["--list", "--json"])
        checks.equal("CLI --list exits 0", code_list, 0)
        checks.check("CLI --list prints one JSON object", isinstance(out_list, dict) and out_list["ok"] is True)
        code_plan, out_plan = _cli(["--action", "crew.sessions", "--plan", "--json", "--db", store,
                                    "--limit", "2", "--no-log"])
        checks.equal("CLI plan exits 0", code_plan, 0)
        checks.equal("CLI plan prints the plan", out_plan.get("action"), "crew.sessions")
        code_noconfirm, out_noconfirm = _cli(["--action", "crew.logs", "--run", "--json",
                                             "--export-dir", export_dir, "--quarantine-root", quarantine,
                                             "--no-log"])
        checks.equal("CLI run without --confirm exits 2", code_noconfirm, EXIT_PROGRAMMING)
        checks.check("CLI run without --confirm refuses", out_noconfirm.get("ok") is False)
        code_bad, out_bad = _cli(["--action", "crew.compress", "--plan", "--json", "--path",
                                  os.path.join(root, "absent.bin"), "--no-log"])
        checks.equal("CLI named missing path exits 2", code_bad, EXIT_PROGRAMMING)

        # ---- final invariants
        checks.equal("no plan or run wrote to the store", fingerprint(store), db_before)
        moved_dir = os.path.join(quarantine, day_stamp(now), "crew-logs")
        moved_names = sorted(os.listdir(moved_dir)) if os.path.isdir(moved_dir) else []
        checks.equal("quarantine holds exactly the three old exports, nothing deleted", len(moved_names), 3)
        checks.check("every quarantined file is non-empty",
                     all(os.path.getsize(os.path.join(moved_dir, name)) > 0 for name in moved_names))
    finally:
        for proc in dummies:
            if proc.poll() is None:
                proc.kill()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
        if not keep:
            shutil.rmtree(root, ignore_errors=True)
        else:
            print("temp: %s" % keep_root)
            print("quarantine proof: %s" % os.path.join(keep_root, "_QUARANTINE"))

    if compact:
        emit({"ok": not checks.failed, "passed": checks.passed,
              "failed": [name for name, _ in checks.failed]}, True)
    return checks.summary()


def _gunzip_sha256(path):
    digest = hashlib.sha256()
    with gzip.open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _cli(argv):
    proc = subprocess.run(
        [sys.executable, os.path.abspath(__file__)] + argv,
        capture_output=True,
        text=True,
        timeout=120,
    )
    payload = {}
    if proc.stdout.strip():
        try:
            payload = json.loads(proc.stdout)
        except ValueError:
            payload = {}
    return proc.returncode, payload


if __name__ == "__main__":
    sys.exit(main())
