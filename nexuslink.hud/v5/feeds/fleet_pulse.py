#!/usr/bin/env python3
"""Fleet pulse feed for the v5 HUD deck (F2).

Emits the Mac Kanban pulse as one JSON object: card counts per status, the
"needs me" list (blocked + failed, newest first), and how many cards finished
since this machine booted. The deck reads the cached file; a Quickshell
Process/FileView never waits on a 1.5 s CLI read.

    {"ok": true, "generated_at": "...", "source": "live",
     "counts": {"running": N, "blocked": N, "ready": N, "review": N,
                "todo": N, "triage": N, "done_since_boot": N, "other": N, ...},
     "needs_me": {"count": N, "cards": [{"id", "title", "assignee",
                                         "status", "age_s"}]},
     "boot_time": "<UTC ISO>", "reason": null, "cached": false, ...}

Source of truth is the Mac board, read through ``hermes kanban list --json``.
That command carries every field this feed needs (id, title, assignee, status,
created_at, started_at, completed_at), so ``kanban show`` is called only to fill
a missing title on one of the (at most eight) needs-me cards. Read only: this
module never runs a mutating kanban verb.

Modes
  live      ``hermes kanban list --json`` (inherits the caller's environment)
  fixture   ``--fixture PATH``  a recorded list: a JSON array of tasks, or an
            object {"tasks": [...], "boot_time": "<ISO>"} from the recorder
  board     ``--board PATH``    a board file: the board's SQLite kanban.db
            (read-only; falls back to ``immutable=1`` when a WAL-marked copy
            has no ``-shm``), or a JSON list. Sniffed by the SQLite header.

Cache
  10 s, ``~/.local/state/nexuslink/fleet_pulse.json``, written atomically
  (temp file + ``os.replace``). The file holds exactly the emitted payload.
  A second call inside the window runs no command and returns the payload with
  ``"cached": true`` and ``"cached_age_s"``. ``generated_at`` is stamped when
  the read finished, so a slow read still buys a full window. Fixture and board
  runs only use a cache when ``--cache-path`` is explicit, so a manual fixture
  run can never overwrite the file the HUD reads.

Contract (cards/feeds-brief.md)
  stdlib only, one JSON object on stdout, UTC ISO times, exit 0 for data or
  honest absence (``{"ok": false, "reason": "..."}``), exit 2 only for a
  programming error (bad arguments, a missing file the caller named). Missing
  or malformed input never raises. Unknown statuses are bucketed under
  ``other`` and counted, never dropped silently. If the boot time cannot be
  read, ``done_since_boot`` is null with a reason, never a guess.

Self-check: ``python3 fleet_pulse.py --self-check`` (no arguments needed).
"""

from __future__ import annotations

import argparse
import copy
import datetime
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time


EXIT_OK = 0
EXIT_PROGRAMMING = 2

HOME = os.path.expanduser("~")
DEFAULT_CACHE = os.path.join(HOME, ".local", "state", "nexuslink", "fleet_pulse.json")
CACHE_TTL_S = 10
NEEDS_ME_STATUSES = ("blocked", "failed")
NEEDS_ME_CAP = 8
DOT_STATUSES = ("running", "blocked", "ready", "review", "todo", "triage")
LIST_TIMEOUT_S = 20.0
SHOW_TIMEOUT_S = 10.0


# --------------------------------------------------------------------------
# Small value helpers (same conventions as the other v5 feeds)
# --------------------------------------------------------------------------


class DataProblem(Exception):
    """A source is missing, empty or malformed: always an answer, never a crash."""

    kind = "data"

    def __init__(self, reason):
        super(DataProblem, self).__init__(reason)
        self.reason = str(reason)


class Missing(DataProblem):
    kind = "missing"


class Malformed(DataProblem):
    kind = "malformed"


class CommandFailed(DataProblem):
    kind = "command"


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc)


def iso(epoch):
    """Epoch seconds -> ``2026-10-22T21:07:02Z``. Anything unusable -> None."""
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


def iso_now(now_epoch=None):
    return iso(int(time.time()) if now_epoch is None else int(now_epoch))


def epoch_from_iso(value):
    """Tolerant ISO-8601 -> epoch seconds. Naive stamps are read as UTC."""
    if not isinstance(value, str) or not value.strip():
        return None
    raw = value.strip().replace("Z", "+00:00").replace("z", "+00:00")
    try:
        parsed = datetime.datetime.fromisoformat(raw)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.timezone.utc)
    try:
        return parsed.timestamp()
    except (OverflowError, OSError, ValueError):
        return None


def tilde(path):
    """Home-relative display form. Output never carries a bare home path."""
    if not path:
        return ""
    shown = os.path.abspath(os.path.expanduser(str(path)))
    if shown == HOME:
        return "~"
    if shown.startswith(HOME + os.sep):
        return "~" + shown[len(HOME):]
    return shown


def tilde_text(message):
    for root in (HOME, os.path.realpath(HOME)):
        if root and root != "/" and root in message:
            message = message.replace(root + os.sep, "~" + os.sep).replace(root, "~")
    return message


def text(value, limit=None):
    """Trimmed single-line string or None. Never returns a non-string."""
    if value is None:
        return None
    if not isinstance(value, str):
        value = str(value)
    value = " ".join(value.split())
    if not value:
        return None
    if limit is not None and len(value) > limit:
        cut = value[:limit]
        if " " in cut:
            cut = cut.rsplit(" ", 1)[0]
        value = cut.rstrip(" ,;:-") + "\u2026"
    return value


def integer(value):
    """Finite int or None. Accepts numeric strings, rejects bools/NaN/inf."""
    if value is None or isinstance(value, bool):
        return None
    try:
        num = float(value)
    except (TypeError, ValueError):
        return None
    if num != num or num in (float("inf"), float("-inf")):
        return None
    try:
        return int(num)
    except (OverflowError, ValueError):
        return None


def write_json(path, payload):
    """Atomic write: temp file in the same directory, then ``os.replace``."""
    target = os.path.expanduser(str(path))
    parent = os.path.dirname(target) or "."
    os.makedirs(parent, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=parent, prefix=".tmp-fleet-pulse-",
        suffix=".json", delete=False,
    )
    try:
        with handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=False)
            handle.write("\n")
        os.replace(handle.name, target)
    except BaseException:
        try:
            os.unlink(handle.name)
        except OSError:
            pass
        raise


def read_json_file(path, what):
    shown = tilde(path)
    if not os.path.exists(os.path.expanduser(str(path))):
        raise Missing("no %s at %s" % (what, shown))
    if not os.path.isfile(os.path.expanduser(str(path))):
        raise Missing("%s is not a file: %s" % (what, shown))
    try:
        with open(os.path.expanduser(str(path)), "r", encoding="utf-8") as handle:
            raw = handle.read()
    except OSError as exc:
        raise Missing("cannot read %s at %s: %s" % (what, shown, exc.strerror or exc))
    if not raw.strip():
        raise Missing("%s at %s is empty" % (what, shown))
    try:
        return json.loads(raw)
    except ValueError as exc:
        raise Malformed("%s at %s is not valid JSON: %s" % (what, shown, exc))


def is_sqlite_file(path):
    try:
        with open(os.path.expanduser(str(path)), "rb") as handle:
            return handle.read(16) == b"SQLite format 3\x00"
    except OSError:
        return False


# --------------------------------------------------------------------------
# Boot time
# --------------------------------------------------------------------------


def boot_time_from_sysctl():
    """(epoch, None) or (None, reason). ``sysctl -n kern.boottime`` on macOS."""
    binary = shutil.which("sysctl")
    if not binary:
        return None, "sysctl not on PATH"
    try:
        proc = subprocess.run(
            [binary, "-n", "kern.boottime"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5.0,
        )
        out = proc.stdout.decode("utf-8", "replace").strip()
        err = proc.stderr.decode("utf-8", "replace").strip()
    except (OSError, subprocess.SubprocessError) as exc:
        return None, "sysctl failed: %s" % (exc.__class__.__name__,)
    if proc.returncode != 0:
        return None, "sysctl exit %d%s" % (
            proc.returncode, (": " + err.splitlines()[0]) if err else "",
        )
    match = re.search(r"sec\s*=\s*(\d+)", out)
    if match:
        return int(match.group(1)), None
    if out.isdigit():
        return int(out), None
    return None, "unparsed kern.boottime: %s" % (out[:80] or "empty")


def boot_from_override(value):
    """--boot-time: epoch seconds or ISO. (epoch, None) or (None, reason)."""
    raw = (value or "").strip()
    if not raw:
        return None, "boot time override is empty"
    if re.match(r"^\d+(\.\d+)?$", raw):
        return int(float(raw)), None
    stamp = epoch_from_iso(raw)
    if stamp is None:
        return None, "boot time %r is neither epoch nor ISO-8601" % (raw[:40],)
    return int(stamp), None


# --------------------------------------------------------------------------
# Sources
# --------------------------------------------------------------------------


def _rows_from_payload(payload):
    """A recorded list or an object with a ``tasks`` array -> (tasks, boot_iso)."""
    if isinstance(payload, list):
        return payload, None
    if isinstance(payload, dict):
        tasks = payload.get("tasks")
        if isinstance(tasks, list):
            boot = payload.get("boot_time")
            return tasks, boot if isinstance(boot, str) else None
        if isinstance(payload.get("task"), dict):
            return [payload["task"]], None
    raise Malformed("recorded list has no task array")


def read_fixture(path):
    target = os.path.expanduser(str(path))
    if os.path.isdir(target):
        target = _fixture_file_in_dir(target, path)
    payload = read_json_file(target, "fixture")
    return _rows_from_payload(payload)


def _fixture_file_in_dir(directory, shown_path):
    """The contract allows a fixture directory: prefer the conventional names."""
    names = ("fleet_pulse.json", "list.json", "tasks.json")
    for name in names:
        candidate = os.path.join(directory, name)
        if os.path.isfile(candidate):
            return candidate
    try:
        found = sorted(name for name in os.listdir(directory) if name.endswith(".json"))
    except OSError as exc:
        raise Missing("cannot list fixture dir %s: %s" % (tilde(shown_path),
                                                          exc.strerror or exc))
    if len(found) == 1:
        return os.path.join(directory, found[0])
    raise Missing("fixture dir %s holds %d JSON files and none of %s" % (
        tilde(shown_path), len(found), "/".join(names)))


def read_board_file(path):
    """Read a board file read-only. SQLite kanban.db or a recorded JSON list.

    Returns ``(tasks, detail)`` where detail carries how a SQLite board was
    opened (``ro``, or ``immutable`` when a WAL-marked file has no ``-shm``).
    """
    target = os.path.expanduser(str(path))
    if not os.path.exists(target):
        raise Missing("no board at %s" % tilde(path))
    if is_sqlite_file(target):
        tasks, readonly = _read_board_sqlite(target)
        return tasks, {"readonly": readonly}
    payload = read_json_file(path, "board")
    tasks, _boot = _rows_from_payload(payload)
    return tasks, None


_BOARD_COLUMNS = "id, title, assignee, status, created_at, started_at, completed_at"


def _read_board_sqlite(target):
    """(rows, readonly_mode). ``mode=ro`` first; ``immutable=1`` as a fallback.

    A board copied while its WAL was live is marked WAL in the header but ships
    without ``-shm``. A read-only connection cannot create that shm, and SQLite
    refuses the open, so the second attempt reads the file immutable (no WAL
    replay). Both paths run SELECTs only.
    """
    quoted = _quote_sqlite_path(os.path.abspath(target))
    attempts = (("ro", "?mode=ro"), ("immutable", "?mode=ro&immutable=1"))
    last_error = None
    for readonly, query in attempts:
        conn = None
        try:
            conn = sqlite3.connect("file:%s%s" % (quoted, query), uri=True, timeout=2.0)
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                "SELECT %s FROM tasks WHERE status IS NOT 'archived'" % _BOARD_COLUMNS
            ).fetchall()
            return [dict(row) for row in rows], readonly
        except sqlite3.Error as exc:
            last_error = exc
        finally:
            if conn is not None:
                conn.close()
    raise Malformed("cannot read board %s: %s" % (tilde(target), last_error))


def _quote_sqlite_path(path):
    """Percent-encode a filesystem path for a SQLite ``file:`` URI."""
    safe = "/-._~"
    out = []
    for char in path:
        if char.isalnum() or char in safe:
            out.append(char)
        else:
            out.append("".join("%%%02X" % byte for byte in char.encode("utf-8")))
    if not out or out[0] != "/":
        out.insert(0, "/")
    return "".join(out)


def _first_line(raw):
    for line in (raw or "").splitlines():
        line = line.strip()
        if line:
            return line
    return ""


def read_live(hermes_bin="hermes", timeout=LIST_TIMEOUT_S):
    """``hermes kanban list --json`` -> task list. Never mutates the board."""
    binary = shutil.which(hermes_bin) or (hermes_bin if os.path.exists(hermes_bin) else None)
    if not binary:
        raise CommandFailed("hermes not found (looked for %r)" % (hermes_bin,))
    cmd = [binary, "kanban", "list", "--json"]
    try:
        proc = subprocess.run(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise CommandFailed("kanban list timed out after %.0f s" % (timeout,))
    except OSError as exc:
        raise CommandFailed("kanban list could not start: %s" % (exc.strerror or exc,))
    out = proc.stdout.decode("utf-8", "replace")
    err = proc.stderr.decode("utf-8", "replace")
    if proc.returncode != 0:
        raise CommandFailed("kanban list exit %d: %s" % (
            proc.returncode, tilde_text(_first_line(err)) or "no stderr"))
    if not out.strip():
        raise Malformed("kanban list printed nothing")
    try:
        payload = json.loads(out)
    except ValueError as exc:
        raise Malformed("kanban list is not valid JSON: %s" % (exc,))
    tasks, _boot = _rows_from_payload(payload)
    return tasks


def fetch_task_detail(task_id, hermes_bin="hermes", timeout=SHOW_TIMEOUT_S):
    """``hermes kanban show <id> --json`` -> task dict, or None. Best effort."""
    if not task_id:
        return None
    binary = shutil.which(hermes_bin) or (hermes_bin if os.path.exists(hermes_bin) else None)
    if not binary:
        return None
    try:
        proc = subprocess.run(
            [binary, "kanban", "show", str(task_id), "--json"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    try:
        payload = json.loads(proc.stdout.decode("utf-8", "replace"))
    except ValueError:
        return None
    if isinstance(payload, dict) and isinstance(payload.get("task"), dict):
        return payload["task"]
    if isinstance(payload, dict) and payload.get("id"):
        return payload
    return None


# --------------------------------------------------------------------------
# Summarize
# --------------------------------------------------------------------------


def _needs_card(raw, status_key, now_epoch):
    started = integer(raw.get("started_at"))
    created = integer(raw.get("created_at"))
    completed = integer(raw.get("completed_at"))
    anchor = started if started is not None else created
    if anchor is None:
        anchor = completed
    age = None
    if anchor is not None:
        age = max(0, int(now_epoch) - int(anchor))
    return {
        "id": text(raw.get("id")),
        "title": text(raw.get("title")),
        "assignee": text(raw.get("assignee")),
        "status": status_key,
        "age_s": age,
        "_anchor": anchor if anchor is not None else -1,
    }


def summarize(tasks, boot_epoch, boot_reason, now_epoch, source, source_ref):
    counts = {key: 0 for key in DOT_STATUSES}
    counts.update({
        "done_since_boot": None,
        "other": 0,
        "cards_seen": 0,
        "done_total": 0,
        "done_before_boot": None,
        "done_undated": 0,
        "malformed": 0,
    })
    other_by_status = {}
    done_since_boot = 0
    done_before_boot = 0
    needs = []

    for raw in tasks:
        counts["cards_seen"] += 1
        if not isinstance(raw, dict):
            counts["malformed"] += 1
            continue
        status_key = text(raw.get("status"))
        status_key = status_key.lower() if status_key else None
        if status_key in DOT_STATUSES:
            counts[status_key] += 1
        elif status_key == "done":
            counts["done_total"] += 1
            completed = integer(raw.get("completed_at"))
            if completed is None:
                counts["done_undated"] += 1
            elif boot_epoch is not None:
                if completed > int(boot_epoch):
                    done_since_boot += 1
                else:
                    done_before_boot += 1
        else:
            counts["other"] += 1
            label = status_key or "(missing)"
            other_by_status[label] = other_by_status.get(label, 0) + 1
        if status_key in NEEDS_ME_STATUSES:
            needs.append(_needs_card(raw, status_key, now_epoch))

    needs.sort(key=lambda card: (card["_anchor"], card.get("id") or ""), reverse=True)
    needs_total = len(needs)
    needs_cards = needs[:NEEDS_ME_CAP]
    for card in needs_cards:
        card.pop("_anchor", None)

    counts["done_since_boot"] = done_since_boot if boot_epoch is not None else None
    counts["done_before_boot"] = done_before_boot if boot_epoch is not None else None

    reason = None
    if boot_epoch is None:
        reason = "boot time unreadable (%s); done_since_boot is null" % (
            boot_reason or "no reason given",)
    elif counts["done_undated"]:
        reason = "%d done card(s) carry no completed_at and are not in done_since_boot" % (
            counts["done_undated"],)

    payload = {
        "ok": True,
        "generated_at": iso_now(now_epoch),
        "source": source,
        "source_ref": source_ref,
        "counts": counts,
        "needs_me": {"count": needs_total, "cards": needs_cards},
        "boot_time": iso(boot_epoch),
        "other_by_status": other_by_status,
        "reason": reason,
        "cached": False,
    }
    return payload


def enrich_titles(payload, hermes_bin="hermes", timeout=SHOW_TIMEOUT_S):
    """Fill a missing title on a needs-me card via ``kanban show``. At most 8."""
    filled = 0
    for card in payload.get("needs_me", {}).get("cards", []):
        if card.get("title") or not card.get("id"):
            continue
        detail = fetch_task_detail(card["id"], hermes_bin=hermes_bin, timeout=timeout)
        if isinstance(detail, dict):
            title = text(detail.get("title"))
            if title:
                card["title"] = title
                filled += 1
    return filled


# --------------------------------------------------------------------------
# Cache
# --------------------------------------------------------------------------


def _cache_source(source):
    return "live" if source == "live" else "fixture"


def cache_read(cache_path, source, source_ref, now_epoch):
    """(payload, age_s) on a hit inside the TTL, else (None, None)."""
    if not cache_path or not os.path.exists(cache_path):
        return None, None
    try:
        with open(os.path.expanduser(cache_path), "r", encoding="utf-8") as handle:
            cached = json.load(handle)
    except (OSError, ValueError):
        return None, None
    if not isinstance(cached, dict) or not cached.get("ok"):
        return None, None
    if cached.get("source") != _cache_source(source):
        return None, None
    if (cached.get("source_ref") or "") != (source_ref or ""):
        return None, None
    generated = epoch_from_iso(cached.get("generated_at"))
    if generated is None:
        return None, None
    age = int(now_epoch) - int(generated)
    if age < 0 or age >= CACHE_TTL_S:
        return None, None
    return cached, age


# --------------------------------------------------------------------------
# Pulse
# --------------------------------------------------------------------------


def pulse(mode="live", ref=None, cache_path=None, use_cache=True, boot_override=None,
          hermes_bin="hermes", timeout=LIST_TIMEOUT_S, now_epoch=None):
    """Build the payload. Returns (payload, exit_code). Raises nothing for data."""
    now = int(time.time()) if now_epoch is None else int(now_epoch)
    source = "live" if mode == "live" else "fixture"
    if mode == "live":
        board_name = (os.environ.get("HERMES_KANBAN_BOARD") or "default").strip()
        source_ref = "hermes kanban list --json"
        if board_name and board_name != "default":
            source_ref += " (board=%s)" % board_name
    else:
        source_ref = tilde(ref or "")
    cache_allowed = bool(use_cache) and (mode == "live" or cache_path is not None)
    cache_file = os.path.expanduser(cache_path) if cache_path else DEFAULT_CACHE

    if cache_allowed:
        cached, age = cache_read(cache_file, source, source_ref, now)
        if cached is not None:
            hit = copy.deepcopy(cached)
            hit["cached"] = True
            hit["cached_age_s"] = age
            return hit, EXIT_OK

    try:
        boot_iso = None
        board_detail = None
        if mode == "live":
            tasks = read_live(hermes_bin=hermes_bin, timeout=timeout)
        elif mode == "fixture":
            tasks, boot_iso = read_fixture(ref)
        elif mode == "board":
            tasks, board_detail = read_board_file(ref)
        else:
            raise ValueError("unknown mode %r" % (mode,))

        boot_epoch, boot_reason = None, None
        if boot_override:
            boot_epoch, boot_reason = boot_from_override(boot_override)
        elif boot_iso:
            boot_epoch = epoch_from_iso(boot_iso)
            if boot_epoch is not None:
                boot_epoch = int(boot_epoch)
            else:
                boot_reason = "fixture boot_time %r is not ISO-8601" % (boot_iso[:40],)
        else:
            boot_epoch, boot_reason = boot_time_from_sysctl()

        payload = summarize(
            tasks, boot_epoch, boot_reason, now, source, source_ref,
        )
        if board_detail:
            payload["board_readonly_mode"] = board_detail.get("readonly")
        if mode == "live":
            enrich_titles(payload, hermes_bin=hermes_bin,
                          timeout=min(SHOW_TIMEOUT_S, timeout or SHOW_TIMEOUT_S))
        # Stamp after the read: a 14 s `kanban list` under load must still buy a
        # full cache window, otherwise the next 10 s tick refetches immediately.
        payload["generated_at"] = iso_now(now_epoch)
    except DataProblem as problem:
        return {
            "ok": False,
            "generated_at": iso_now(now),
            "source": source,
            "source_ref": source_ref,
            "reason": tilde_text(problem.reason),
            "kind": getattr(problem, "kind", "data"),
            "counts": None,
            "needs_me": {"count": 0, "cards": []},
            "boot_time": None,
            "cached": False,
        }, EXIT_OK

    if cache_allowed:
        try:
            write_json(cache_file, payload)
        except OSError:
            pass
    return payload, EXIT_OK


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def build_parser():
    parser = argparse.ArgumentParser(
        description="Fleet pulse feed: Mac Kanban counts, needs-me and done-since-boot.",
    )
    parser.add_argument("--json", action="store_true",
                        help="emit one compact JSON line instead of the pretty object")
    parser.add_argument("--fixture", metavar="PATH",
                        help="read a recorded list instead of the live board")
    parser.add_argument("--board", metavar="PATH",
                        help="read a different board file (SQLite kanban.db or a JSON list)")
    parser.add_argument("--boot-time", metavar="WHEN",
                        help="override boot time (epoch seconds or ISO-8601)")
    parser.add_argument("--cache-path", metavar="PATH",
                        help="cache file (default %s)" % tilde(DEFAULT_CACHE))
    parser.add_argument("--no-cache", action="store_true",
                        help="neither read nor write the cache")
    parser.add_argument("--hermes", metavar="PATH", default="hermes",
                        help="hermes binary for live mode (default: hermes on PATH)")
    parser.add_argument("--timeout", type=float, default=LIST_TIMEOUT_S,
                        help="seconds for one live read (default %.0f)" % LIST_TIMEOUT_S)
    parser.add_argument("--self-check", action="store_true",
                        help="run the built-in checks against generated fixtures and exit")
    return parser


def emit(payload, compact):
    if compact:
        line = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=False)
    else:
        line = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=False)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def _caller_error(reason):
    payload = {
        "ok": False,
        "generated_at": iso_now(),
        "source": "fixture",
        "source_ref": "",
        "reason": tilde_text(reason),
        "kind": "arguments",
        "counts": None,
        "needs_me": {"count": 0, "cards": []},
        "boot_time": None,
        "cached": False,
    }
    emit(payload, True)
    return EXIT_PROGRAMMING


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.self_check:
        return self_check()

    if args.fixture and args.board:
        return _caller_error("--fixture and --board are mutually exclusive")

    mode, ref = "live", None
    if args.fixture:
        mode, ref = "fixture", os.path.expanduser(args.fixture)
    elif args.board:
        mode, ref = "board", os.path.expanduser(args.board)

    if ref and not os.path.exists(ref):
        return _caller_error("%s file not found: %s" % (
            "fixture" if mode == "fixture" else "board", tilde(ref)))

    payload, code = pulse(
        mode=mode, ref=ref,
        cache_path=os.path.expanduser(args.cache_path) if args.cache_path else None,
        use_cache=not args.no_cache,
        boot_override=args.boot_time,
        hermes_bin=args.hermes,
        timeout=args.timeout,
    )
    emit(payload, compact=bool(args.json))
    return code


# --------------------------------------------------------------------------
# Self-check
# --------------------------------------------------------------------------


SELF_CHECK_BOOT_EPOCH = 1791570618  # 2026-10-09T18:30:18Z, this Mac's boot time


def _fixture(blocked=0, extra=None, boot=None):
    """A generated fixture with known counts. Anchors are 60 s apart, oldest first."""
    base = SELF_CHECK_BOOT_EPOCH
    if boot is None:
        boot = iso(base)
    tasks = [
        # status, completed_at
        {"id": "t_run1", "title": "run one", "assignee": "shino", "status": "running",
         "created_at": base + 10, "started_at": base + 20, "completed_at": None},
        {"id": "t_run2", "title": "run two", "assignee": "yamato", "status": "running",
         "created_at": base + 30, "started_at": None, "completed_at": None},
        {"id": "t_run3", "title": "run three", "assignee": "levi", "status": "running",
         "created_at": base + 40, "started_at": base + 50, "completed_at": None},
        {"id": "t_ready1", "title": "ready one", "assignee": "kakashi", "status": "ready",
         "created_at": base + 60, "started_at": None, "completed_at": None},
        {"id": "t_ready2", "title": "ready two", "assignee": "kakashi", "status": "ready",
         "created_at": base + 70, "started_at": None, "completed_at": None},
        {"id": "t_ready3", "title": "ready three", "assignee": "kakashi", "status": "ready",
         "created_at": base + 80, "started_at": None, "completed_at": None},
        {"id": "t_ready4", "title": "ready four", "assignee": "kakashi", "status": "ready",
         "created_at": base + 90, "started_at": None, "completed_at": None},
        {"id": "t_review1", "title": "review one", "assignee": "neji", "status": "review",
         "created_at": base + 100, "started_at": None, "completed_at": None},
        {"id": "t_todo1", "title": "todo one", "assignee": None, "status": "todo",
         "created_at": base + 110, "started_at": None, "completed_at": None},
        {"id": "t_todo2", "title": "todo two", "assignee": None, "status": "todo",
         "created_at": base + 120, "started_at": None, "completed_at": None},
        {"id": "t_todo3", "title": "todo three", "assignee": None, "status": "todo",
         "created_at": base + 130, "started_at": None, "completed_at": None},
        {"id": "t_todo4", "title": "todo four", "assignee": None, "status": "todo",
         "created_at": base + 140, "started_at": None, "completed_at": None},
        {"id": "t_todo5", "title": "todo five", "assignee": None, "status": "todo",
         "created_at": base + 150, "started_at": None, "completed_at": None},
        {"id": "t_triage1", "title": "triage one", "assignee": None, "status": "triage",
         "created_at": base + 160, "started_at": None, "completed_at": None},
        {"id": "t_triage2", "title": "triage two", "assignee": None, "status": "triage",
         "created_at": base + 170, "started_at": None, "completed_at": None},
        {"id": "t_sched1", "title": "scheduled one", "assignee": None, "status": "scheduled",
         "created_at": base + 180, "started_at": None, "completed_at": None},
        {"id": "t_done1", "title": "done after boot", "assignee": "shino", "status": "done",
         "created_at": base + 190, "started_at": base + 200,
         "completed_at": base + 1000},
        {"id": "t_done2", "title": "done after boot too", "assignee": "shino", "status": "done",
         "created_at": base + 210, "started_at": base + 220,
         "completed_at": base + 2000},
        {"id": "t_done3", "title": "done before boot", "assignee": "shino", "status": "done",
         "created_at": base - 500, "started_at": base - 400,
         "completed_at": base - 100},
        {"id": "t_done4", "title": "done without a timestamp", "assignee": "shino",
         "status": "done", "created_at": base + 230, "started_at": None, "completed_at": None},
        {"id": "t_arch1", "title": "archived one", "assignee": None, "status": "archived",
         "created_at": base - 900, "started_at": None, "completed_at": base - 800},
    ]
    for index in range(blocked):
        tasks.append({
            "id": "t_block%02d" % index,
            "title": "blocked card %02d" % index,
            "assignee": "kabuto",
            "status": "blocked",
            "created_at": base + 300 + index * 60,
            "started_at": base + 310 + index * 60,
            "completed_at": None,
        })
    if extra:
        tasks.extend(extra)
    return {"board": "default", "boot_time": boot, "recorded_at": "2026-10-23T00:00:00Z",
            "tasks": tasks}


def _write_stub_hermes(root, log_path, list_path, show_dir):
    """A fake `hermes` that logs every call, answers list and show."""
    script = """#!/bin/sh
echo "$*" >> __LOG__
if [ "$1" = "kanban" ] && [ "$2" = "list" ]; then
  cat __LIST__
  exit 0
fi
if [ "$1" = "kanban" ] && [ "$2" = "show" ]; then
  if [ -f __SHOW__/"$3".json ]; then cat __SHOW__/"$3".json; exit 0; fi
  echo "no such task: $3" >&2
  exit 3
fi
echo "unexpected args: $*" >&2
exit 9
"""
    script = (script.replace("__LOG__", log_path)
                    .replace("__LIST__", list_path)
                    .replace("__SHOW__", show_dir))
    return _write_executable(os.path.join(root, "hermes"), script)


def _write_stub_sysctl(root, mode_path=None):
    if mode_path:
        script = """#!/bin/sh
if [ -f __MODE__ ] && [ "$(cat __MODE__)" = "fail" ]; then
  echo "sysctl: unknown oid" >&2
  exit 1
fi
echo "{ sec = __SEC__, usec = 630071 } Fri Oct  9 20:30:18 2026"
"""
        script = script.replace("__MODE__", mode_path)
    else:
        script = """#!/bin/sh
echo "{ sec = __SEC__, usec = 630071 } Fri Oct  9 20:30:18 2026"
"""
    script = script.replace("__SEC__", str(SELF_CHECK_BOOT_EPOCH))
    return _write_executable(os.path.join(root, "sysctl"), script)


def _write_executable(path, script):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(script)
    os.chmod(path, 0o755)
    return path


def _run_cli(argv, env=None):
    """Run this module as a subprocess; (exit_code, stdout, stderr)."""
    proc = subprocess.run(
        [sys.executable, os.path.abspath(__file__)] + list(argv),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=120,
    )
    return (proc.returncode,
            proc.stdout.decode("utf-8", "replace"),
            proc.stderr.decode("utf-8", "replace"))


class _Checker(object):
    def __init__(self):
        self.passed = 0
        self.failed = []

    def check(self, name, condition, detail=""):
        if condition:
            self.passed += 1
            sys.stdout.write("ok   %s\n" % name)
        else:
            self.failed.append((name, detail))
            sys.stdout.write("FAIL %s%s\n" % (name, ("  " + detail) if detail else ""))

    def equal(self, name, got, want):
        self.check(name, got == want, "got %r want %r" % (got, want))


def self_check():  # noqa: C901 - one linear script is the point
    checker = _Checker()
    root = tempfile.mkdtemp(prefix="fleet-pulse-selfcheck-")
    old_env = {key: os.environ.get(key) for key in ("PATH",)}
    try:
        stub = os.path.join(root, "stubs")
        os.makedirs(stub)
        hermes_log = os.path.join(root, "hermes-calls.log")
        list_path = os.path.join(root, "live-list.json")
        show_dir = os.path.join(root, "show")
        os.makedirs(show_dir)
        sysctl_mode = os.path.join(root, "sysctl-mode")
        with open(sysctl_mode, "w", encoding="utf-8") as handle:
            handle.write("ok")

        # ---- 1. counts on a fixture with known numbers ---------------------
        fixture = _fixture(blocked=3)
        fixture_path = os.path.join(root, "known.json")
        write_json(fixture_path, fixture)
        now = SELF_CHECK_BOOT_EPOCH + 89382  # 2026-10-10T21:20:00Z, after every anchor
        payload, code = pulse(mode="fixture", ref=fixture_path, use_cache=False,
                              now_epoch=now)
        counts = payload["counts"]
        checker.check("counts_ok", payload["ok"] is True, payload.get("reason") or "")
        checker.equal("counts.running", counts["running"], 3)
        checker.equal("counts.blocked", counts["blocked"], 3)
        checker.equal("counts.ready", counts["ready"], 4)
        checker.equal("counts.review", counts["review"], 1)
        checker.equal("counts.todo", counts["todo"], 5)
        checker.equal("counts.triage", counts["triage"], 2)
        checker.equal("counts.done_since_boot", counts["done_since_boot"], 2)
        checker.equal("counts.done_total", counts["done_total"], 4)
        checker.equal("counts.done_before_boot", counts["done_before_boot"], 1)
        checker.equal("counts.done_undated", counts["done_undated"], 1)
        checker.equal("counts.other", counts["other"], 2)  # scheduled + archived
        checker.equal("counts.cards_seen", counts["cards_seen"], len(fixture["tasks"]))
        checker.equal("other_by_status", payload["other_by_status"],
                      {"scheduled": 1, "archived": 1})
        checker.equal("boot_time", payload["boot_time"], iso(SELF_CHECK_BOOT_EPOCH))
        checker.check("reason_names_undated_done",
                      isinstance(payload["reason"], str) and "completed_at" in payload["reason"],
                      repr(payload["reason"]))
        checker.equal("source", payload["source"], "fixture")
        checker.equal("exit_zero", code, EXIT_OK)

        # ---- 1b. a fixture directory is allowed by the contract ------------
        fixture_dir = os.path.join(root, "fixture-dir")
        os.makedirs(fixture_dir)
        shutil.copyfile(fixture_path, os.path.join(fixture_dir, "fleet_pulse.json"))
        dir_payload, dir_code = pulse(mode="fixture", ref=fixture_dir, use_cache=False,
                                      now_epoch=now)
        checker.equal("fixture_dir_exit_zero", dir_code, EXIT_OK)
        checker.equal("fixture_dir_counts", dir_payload.get("counts"), counts)
        checker.equal("fixture_dir_source_ref", dir_payload.get("source_ref"),
                      tilde(fixture_dir))
        rc, out, _err = _run_cli(["--fixture", fixture_dir, "--json", "--no-cache"])
        checker.equal("fixture_dir_cli_exit_zero", rc, EXIT_OK)

        # ---- 2. unknown status is bucketed, not dropped --------------------
        extra = [
            {"id": "t_weird", "title": "weird status", "assignee": None,
             "status": "exploded", "created_at": now - 10, "started_at": None,
             "completed_at": None},
            {"id": "t_nostatus", "title": "no status", "assignee": None,
             "status": None, "created_at": now - 20, "started_at": None,
             "completed_at": None},
        ]
        weird = _fixture(blocked=0, extra=extra)
        weird_path = os.path.join(root, "unknown.json")
        write_json(weird_path, weird)
        weird_payload, weird_code = pulse(mode="fixture", ref=weird_path,
                                          use_cache=False, now_epoch=now)
        checker.equal("unknown_status_other", weird_payload["counts"]["other"], 4)
        checker.check("unknown_status_bucketed",
                      weird_payload["other_by_status"].get("exploded") == 1
                      and weird_payload["other_by_status"].get("(missing)") == 1,
                      repr(weird_payload["other_by_status"]))
        checker.equal("unknown_status_cards_seen", weird_payload["counts"]["cards_seen"],
                      len(weird["tasks"]))
        checker.equal("unknown_status_exit_zero", weird_code, EXIT_OK)

        # ---- 3. needs_me ordering and cap ----------------------------------
        many = _fixture(blocked=11)
        many_path = os.path.join(root, "many-blocked.json")
        write_json(many_path, many)
        many_payload, _code = pulse(mode="fixture", ref=many_path, use_cache=False,
                                    now_epoch=now)
        cards = many_payload["needs_me"]["cards"]
        checker.equal("needs_me_cap_len", len(cards), NEEDS_ME_CAP)
        checker.equal("needs_me_true_count", many_payload["needs_me"]["count"], 11)
        ids = [card["id"] for card in cards]
        checker.equal("needs_me_newest_first", ids,
                      ["t_block%02d" % i for i in (10, 9, 8, 7, 6, 5, 4, 3)])
        checker.check("needs_me_age_present",
                      all(isinstance(card.get("age_s"), int) and card["age_s"] >= 0
                          for card in cards),
                      repr([card.get("age_s") for card in cards]))
        checker.check("needs_me_age_ordering",
                      [c["age_s"] for c in cards] == sorted([c["age_s"] for c in cards]),
                      repr([c.get("age_s") for c in cards]))
        checker.equal("needs_me_fields", sorted(cards[0].keys()),
                      ["age_s", "assignee", "id", "status", "title"])

        # ---- 4. cache: second call runs no command -------------------------
        with open(list_path, "w", encoding="utf-8") as handle:
            json.dump(many, handle)
        if os.path.exists(hermes_log):
            os.unlink(hermes_log)
        _write_stub_hermes(stub, hermes_log, list_path, show_dir)
        _write_stub_sysctl(stub, sysctl_mode)
        cache_path = os.path.join(root, "cache", "fleet_pulse.json")
        os.makedirs(os.path.dirname(cache_path))
        os.environ["PATH"] = stub + os.pathsep + (old_env["PATH"] or "")

        first, first_code = pulse(mode="live", cache_path=cache_path, now_epoch=now)
        second, second_code = pulse(mode="live", cache_path=cache_path, now_epoch=now + 3)
        third, _third_code = pulse(mode="live", cache_path=cache_path, now_epoch=now + 11)
        calls = open(hermes_log, encoding="utf-8").read().splitlines() if \
            os.path.exists(hermes_log) else []
        checker.equal("cache_command_free_first", calls[:1], ["kanban list --json"])
        checker.equal("cache_hit_flag", second.get("cached"), True)
        checker.equal("cache_hit_counts", second["counts"], first["counts"])
        checker.equal("cache_second_no_command", len(calls), 2)  # first + post-TTL
        checker.equal("cache_expired_refetches", third.get("cached"), False)
        checker.equal("cache_command_total", len(calls), 2)
        checker.equal("cache_exit_zero", (first_code, second_code), (EXIT_OK, EXIT_OK))
        checker.check("cache_file_is_payload",
                      (json.load(open(cache_path, encoding="utf-8")).get("counts")
                       == first["counts"]),
                      "cache file is not the emitted payload")
        checker.check("cache_atomic_no_temp",
                      [name for name in os.listdir(os.path.dirname(cache_path))
                       if name.startswith(".tmp-")] == [],
                      repr(os.listdir(os.path.dirname(cache_path))))

        # ---- 5. empty board ------------------------------------------------
        empty_path = os.path.join(root, "empty.json")
        write_json(empty_path, {"boot_time": iso(SELF_CHECK_BOOT_EPOCH), "tasks": []})
        rc, out, err = _run_cli(["--fixture", empty_path, "--json", "--no-cache",
                                 "--boot-time", iso(SELF_CHECK_BOOT_EPOCH)])
        empty = json.loads(out) if out.strip() else {}
        checker.equal("empty_exit_zero", rc, EXIT_OK)
        checker.equal("empty_counts", empty.get("counts", {}).get("done_since_boot"), 0)
        checker.check("empty_all_zero",
                      all(empty.get("counts", {}).get(key) == 0
                          for key in DOT_STATUSES + ("other", "cards_seen")),
                      repr(empty.get("counts")))
        checker.equal("empty_needs_me", empty.get("needs_me"), {"count": 0, "cards": []})
        checker.equal("empty_ok", empty.get("ok"), True)

        # ---- 6. malformed cards do not raise -------------------------------
        malformed = {"boot_time": iso(SELF_CHECK_BOOT_EPOCH), "tasks": [
            "not a dict", None, 42, {}, {"status": 7}, {"id": "t_ok", "status": "running"},
            {"id": "t_bad_time", "status": "blocked", "started_at": "yesterday",
             "created_at": None, "title": 12},
        ]}
        malformed_path = os.path.join(root, "malformed.json")
        write_json(malformed_path, malformed)
        bad_payload, bad_code = pulse(mode="fixture", ref=malformed_path,
                                      use_cache=False, now_epoch=now)
        checker.equal("malformed_exit_zero", bad_code, EXIT_OK)
        checker.check("malformed_ok", bad_payload.get("ok") is True,
                      repr(bad_payload.get("reason")))
        checker.equal("malformed_scalars", bad_payload["counts"]["malformed"], 3)
        checker.equal("malformed_running", bad_payload["counts"]["running"], 1)
        checker.equal("malformed_blocked", bad_payload["counts"]["blocked"], 1)
        checker.equal("malformed_cards_seen", bad_payload["counts"]["cards_seen"],
                      len(malformed["tasks"]))
        checker.check("malformed_needs_age_none",
                      bad_payload["needs_me"]["cards"][0]["age_s"] is None,
                      repr(bad_payload["needs_me"]["cards"]))
        checker.equal("malformed_title_stringified",
                      bad_payload["needs_me"]["cards"][0]["title"], "12")

        # ---- 7. unreadable boot time --------------------------------------
        with open(sysctl_mode, "w", encoding="utf-8") as handle:
            handle.write("fail")
        no_boot = {"boot_time": None, "tasks": [
            {"id": "t_d", "title": "done", "status": "done", "created_at": 1,
             "completed_at": 2},
        ]}
        no_boot_path = os.path.join(root, "no-boot.json")
        write_json(no_boot_path, no_boot)
        boot_payload, boot_code = pulse(mode="fixture", ref=no_boot_path,
                                        use_cache=False, now_epoch=now)
        checker.equal("boot_unreadable_null", boot_payload["counts"]["done_since_boot"], None)
        checker.equal("boot_unreadable_time", boot_payload["boot_time"], None)
        checker.check("boot_unreadable_reason",
                      isinstance(boot_payload["reason"], str)
                      and "boot" in boot_payload["reason"].lower(),
                      repr(boot_payload["reason"]))
        checker.equal("boot_unreadable_done_total", boot_payload["counts"]["done_total"], 1)
        checker.equal("boot_unreadable_exit_zero", boot_code, EXIT_OK)
        with open(sysctl_mode, "w", encoding="utf-8") as handle:
            handle.write("ok")

        # ---- 8. caller errors ---------------------------------------------
        rc, out, _err = _run_cli(["--fixture", os.path.join(root, "nope.json"), "--json"])
        checker.equal("missing_file_exit2", rc, EXIT_PROGRAMMING)
        checker.check("missing_file_ok_false",
                      out.strip() and json.loads(out).get("ok") is False,
                      out.strip()[:120])
        rc, out, _err = _run_cli(["--fixture", many_path, "--board", many_path, "--json"])
        checker.equal("both_modes_exit2", rc, EXIT_PROGRAMMING)
        junk_path = os.path.join(root, "junk.json")
        with open(junk_path, "w", encoding="utf-8") as handle:
            handle.write("{not json")
        rc, out, _err = _run_cli(["--fixture", junk_path, "--json", "--no-cache"])
        checker.equal("malformed_json_exit0", rc, EXIT_OK)
        checker.check("malformed_json_ok_false",
                      out.strip() and json.loads(out).get("ok") is False,
                      out.strip()[:120])

        # ---- 9. board file (SQLite, read-only) -----------------------------
        board_path = os.path.join(root, "kanban.db")
        conn = sqlite3.connect(board_path)
        try:
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute(
                "CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT, assignee TEXT, "
                "status TEXT NOT NULL, created_at INTEGER NOT NULL, started_at INTEGER, "
                "completed_at INTEGER)"
            )
            rows = [
                ("t_b1", "board run", "shino", "running", 100, 110, None),
                ("t_b2", "board blocked", "yamato", "blocked", 120, 130, None),
                ("t_b3", "board ready", None, "ready", 140, None, None),
                ("t_b4", "board done", "shino", "done", 150, 160, 1791660000),
                ("t_b5", "board old done", "shino", "done", 170, 180, 1000),
                ("t_b6", "board archived", "shino", "archived", 190, None, 2000),
                ("t_b7", "board mystery", None, "mystery", 210, None, None),
            ]
            conn.executemany("INSERT INTO tasks VALUES (?,?,?,?,?,?,?)", rows)
            conn.commit()
        finally:
            conn.close()
        board_hash_before = _sha256(board_path)
        board_payload, board_code = pulse(mode="board", ref=board_path,
                                          use_cache=False, now_epoch=now,
                                          boot_override=iso(SELF_CHECK_BOOT_EPOCH))
        board_hash_after = _sha256(board_path)
        checker.equal("board_sqlite_hash", board_hash_after, board_hash_before)
        checker.equal("board_sqlite_exit_zero", board_code, EXIT_OK)
        checker.equal("board_sqlite_running", board_payload["counts"]["running"], 1)
        checker.equal("board_sqlite_blocked", board_payload["counts"]["blocked"], 1)
        checker.equal("board_sqlite_ready", board_payload["counts"]["ready"], 1)
        checker.equal("board_sqlite_done_since", board_payload["counts"]["done_since_boot"], 1)
        checker.equal("board_sqlite_done_before", board_payload["counts"]["done_before_boot"], 1)
        checker.equal("board_sqlite_archived_skipped",
                      board_payload["other_by_status"], {"mystery": 1})
        checker.equal("board_sqlite_source", board_payload["source"], "fixture")
        checker.check("board_sqlite_readonly_mode",
                      board_payload.get("board_readonly_mode") in ("ro", "immutable"),
                      repr(board_payload.get("board_readonly_mode")))
        sidecars_before = sorted(name for name in os.listdir(root)
                                 if name.startswith("kanban.db-"))
        # A copy carries only the main file, exactly like `cp kanban.db elsewhere`:
        # no -shm, so a read-only connection cannot open it and the feed must fall
        # back to immutable instead of touching the directory.
        copy_path = os.path.join(root, "copied-board.db")
        shutil.copyfile(board_path, copy_path)
        copy_payload, copy_code = pulse(mode="board", ref=copy_path, use_cache=False,
                                        now_epoch=now,
                                        boot_override=iso(SELF_CHECK_BOOT_EPOCH))
        checker.equal("board_copy_exit_zero", copy_code, EXIT_OK)
        checker.equal("board_copy_counts", copy_payload["counts"], board_payload["counts"])
        checker.equal("board_copy_immutable", copy_payload.get("board_readonly_mode"),
                      "immutable")
        checker.check("board_copy_creates_no_sidecars",
                      not os.path.exists(copy_path + "-wal")
                      and not os.path.exists(copy_path + "-shm"),
                      repr(sorted(name for name in os.listdir(root)
                                  if name.startswith("copied-board.db"))))
        checker.check("board_sqlite_no_new_sidecars",
                      sorted(name for name in os.listdir(root)
                             if name.startswith("kanban.db-")) == sidecars_before,
                      repr(sorted(name for name in os.listdir(root)
                                  if name.startswith("kanban.db-"))))

        # ---- 10. --json is exactly one object ------------------------------
        rc, out, err = _run_cli(["--fixture", many_path, "--json", "--no-cache"])
        lines = [line for line in out.splitlines() if line.strip()]
        checker.equal("single_json_line_count", len(lines), 1)
        checker.check("single_json_line_parses", json.loads(lines[0]).get("ok") is True,
                      lines[0][:120])
        checker.equal("single_json_line_exit_zero", rc, EXIT_OK)
        checker.equal("single_json_line_stderr", err.strip(), "")

        # ---- 11. `show` fills a missing title ------------------------------
        blank = _fixture(blocked=0, extra=[
            {"id": "t_blank", "title": None, "assignee": "shino", "status": "blocked",
             "created_at": 1791660000 - 5, "started_at": None, "completed_at": None},
        ])
        blank_path = os.path.join(root, "blank-title.json")
        write_json(blank_path, blank)
        with open(os.path.join(show_dir, "t_blank.json"), "w", encoding="utf-8") as handle:
            json.dump({"task": {"id": "t_blank", "title": "From kanban show",
                                "status": "blocked"}}, handle)
        if os.path.exists(hermes_log):
            os.unlink(hermes_log)
        with open(list_path, "w", encoding="utf-8") as handle:
            json.dump(blank, handle)
        enrich_payload, _code = pulse(mode="live", cache_path=None, use_cache=False,
                                      now_epoch=now)
        checker.equal("show_fills_title",
                      enrich_payload["needs_me"]["cards"][0]["title"], "From kanban show")
        calls = open(hermes_log, encoding="utf-8").read().splitlines() if \
            os.path.exists(hermes_log) else []
        checker.check("show_called_once", calls.count("kanban show t_blank --json") == 1,
                      repr(calls))

        # ---- 12. live command failure is an answer, not a crash -----------
        with open(list_path, "w", encoding="utf-8") as handle:
            handle.write("")
        failed_payload, failed_code = pulse(mode="live", cache_path=None, use_cache=False,
                                            now_epoch=now)
        checker.equal("live_empty_exit_zero", failed_code, EXIT_OK)
        checker.check("live_empty_ok_false", failed_payload.get("ok") is False,
                      repr(failed_payload.get("reason")))
        checker.check("live_empty_reason", bool(failed_payload.get("reason")),
                      repr(failed_payload.get("reason")))

    except Exception as exc:  # self-check must fail loudly, never traceback silently
        checker.failed.append(("exception", "%s: %s" % (exc.__class__.__name__, exc)))
        sys.stdout.write("FAIL exception: %s: %s\n" % (exc.__class__.__name__, exc))
    finally:
        for key, value in old_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        shutil.rmtree(root, ignore_errors=True)

    if checker.failed:
        sys.stdout.write("\nSELF-CHECK FAIL: %d passed, %d failed\n" % (
            checker.passed, len(checker.failed)))
        for name, detail in checker.failed:
            sys.stdout.write("  %s %s\n" % (name, detail))
        return 1
    sys.stdout.write("\nSELF-CHECK PASS: %d checks\n" % checker.passed)
    return EXIT_OK


def _sha256(path):
    import hashlib
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except SystemExit:
        raise
    except Exception as exc:  # a programming error: one object, exit 2, no traceback
        emit({
            "ok": False,
            "generated_at": iso_now(),
            "source": "live",
            "source_ref": "",
            "reason": "internal error: %s: %s" % (exc.__class__.__name__,
                                                 tilde_text(str(exc))),
            "kind": "programming",
            "counts": None,
            "needs_me": {"count": 0, "cards": []},
            "boot_time": None,
            "cached": False,
        }, True)
        sys.exit(EXIT_PROGRAMMING)
