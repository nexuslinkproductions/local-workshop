#!/usr/bin/env python3
"""Boot briefing for the v5 HUD: facts first, phrasing second.

Runs at boot on the box that owns the deck and answers one question: *what
happened while the screen was off, and does anything need me?* It writes two
files into the run directory (default ``~/.local/state/nexuslink``, override
with ``--out DIR``), atomically:

``brief.json``
    The fact object. This is the contract every consumer (HUD, chief, tests)
    reads. Shape::

        {"ok": true, "generated_at": "<UTC ISO>", "source": "fixture|live",
         "since": "<UTC ISO>",
         "since_source": "boot|brief|both|none",
         "fleet": {"finished": N, "blocked": N, "failed": N, "still_running": N},
         "highlights": [{"id", "title", "status", "assignee", "at"}],
         "needs_me": [{"id", "title", "status"}],
         "slack": {"available", "unread", "reason"},
         "digest": {"available", "reason", ...},
         "phrasing": "<template with {placeholders}, never invented numbers>",
         "board": {"source": "cli|db|fixture", "cards": N, "reason": ...}}

``brief.txt``
    The same facts as five short plain lines for the deck to show and for chief
    to read aloud. No numbers that are not in ``brief.json``.

Facts, and what is honest about each one
----------------------------------------
* **Board.** ``hermes kanban list --json`` (the named input); when the CLI is
  unavailable, the same board is read read-only from ``$HERMES_KANBAN_DB`` (or
  ``~/.hermes/kanban.db``) via the stdlib ``sqlite3`` module. ``board.source``
  says which path answered and ``board.reason`` says why the CLI did not.
* **Since.** ``max(kern.boottime, previous brief.json generated_at)``: the brief
  covers what happened since the machine was last up *or* since the last brief,
  whichever is later. ``--since`` overrides it (tests). ``since_source`` says
  which of the two won: ``boot``, ``brief``, ``both``, ``override`` or ``none``.
* **Buckets.** ``fleet.finished`` is *windowed*: cards ``done`` whose
  ``completed_at`` is at or after ``since``. A card marked ``done`` with no
  ``completed_at`` is never counted as finished. ``blocked``, ``failed`` and
  ``still_running`` describe the board *now*, because a blocked card is a
  present-tense problem rather than an event. ``failed`` means: not done, not
  blocked, and ``last_failure_error`` is set (the board's own record that the
  last attempt crashed). The buckets never overlap.
* **Digest.** ``bridge-digest`` is Linux-only and is not installed on this Mac
  (checked 2026-10-23). The reader looks for the file the digest drops
  (``~/.local/state/nexuslink/digest.json``, override ``--digest``); if neither
  the command nor the file exists, ``digest.available`` is false with that
  reason and the brief leaves the digest out. A digest is never invented and
  a missing or malformed one never raises.
* **Slack.** A read-only probe with the ``hermes-slack`` bot token: ``auth.test``
  and ``conversations.info`` on the home channel. Slack only returns
  ``unread_count`` for the calling user's own membership, and a bot token has
  its own membership, so the field comes back ``null``; there is no read-only
  API on this host that yields Marcel's unread count. Then ``slack.available``
  is false, ``unread`` is null, ``reason`` names the call and what it answered,
  and the brief omits the count. The probe only ever issues GET requests: it
  never posts, reacts or marks anything read.

Phrasing rule
-------------
``phrasing`` is a template, never a rendered sentence and never a number the
script did not measure. Placeholders are key paths into the same JSON
(``{fleet.finished}``, ``{slack.reason}``, and ``{needs_me.#}`` for the length
of a list). ``--self-check`` asserts every placeholder resolves against the
JSON it is emitted with. No model is called from this script.

Exit codes follow the feed contract: ``0`` for data and for honest absence,
``2`` for a programming error (bad arguments). ``--self-check`` exits ``1`` when
a check fails, so drift is loud.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

EXIT_OK = 0
EXIT_CHECK_FAILED = 1
EXIT_PROGRAMMING = 2

HOME = os.path.expanduser("~")
DEFAULT_OUT = os.path.join(HOME, ".local", "state", "nexuslink")
DEFAULT_DIGEST = os.path.join(DEFAULT_OUT, "digest.json")
DEFAULT_SLACK_ENV = os.path.join(HOME, ".hermes", "profiles", "hermes-slack", ".env")
DEFAULT_BOARD_DB = os.path.join(HOME, ".hermes", "kanban.db")

CACHE_MIN_SECONDS = 10        # never re-read the board faster than this
HIGHLIGHT_LIMIT = 5
NEEDS_ME_SHOWN = 3            # names printed in brief.txt, not in the JSON
CLI_TIMEOUT = 25

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE_BOARD = os.path.normpath(os.path.join(HERE, "..", "fixtures", "boot-brief-board.json"))
FIXTURE_DIGEST = os.path.normpath(os.path.join(HERE, "..", "fixtures", "boot-brief-digest.json"))
FIXTURE_SLACK = os.path.normpath(os.path.join(HERE, "..", "fixtures", "boot-brief-slack.json"))
GOLDEN_DIR = os.path.join(HERE, "golden")
GOLDEN_JSON = os.path.join(GOLDEN_DIR, "boot-brief.json")
GOLDEN_TXT = os.path.join(GOLDEN_DIR, "boot-brief.txt")

# Fixed clock for the golden, so the committed files are byte-stable.
GOLDEN_NOW = 1792710000
GOLDEN_BOOT = 1792709000

PHRASING = (
    "While the screen was off the Mac fleet finished {fleet.finished} card(s) "
    "since {since}; {fleet.blocked} blocked, {fleet.failed} failed and "
    "{fleet.still_running} are still running. {needs_me.#} card(s) need you. "
    "Slack unread: available={slack.available} ({slack.reason}). "
    "Digest: available={digest.available} ({digest.reason})."
)

PLACEHOLDER_RE = re.compile(
    r"\{([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_#]+|\[[0-9]+\])*)\}"
)
NAME_RE = re.compile(r"^([A-Za-z0-9_]+)((?:\[[0-9]+\])*)$")


class ArgError(Exception):
    """Bad arguments: exit 2, the only programming error class here."""


# --------------------------------------------------------------- small helpers
def utc_now():
    return int(datetime.datetime.now(datetime.timezone.utc).timestamp())


def iso(epoch):
    """Epoch seconds -> ``2026-10-22T21:07:02Z``; anything unusable -> None."""
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


def parse_epoch(value):
    """Epoch seconds, numeric string, or ISO-8601 (``Z`` or offset) -> float."""
    if value is None:
        return None
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    text = str(value).strip()
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        pass
    cleaned = text[:-1] + "+00:00" if text.endswith("Z") else text
    try:
        stamp = datetime.datetime.fromisoformat(cleaned)
    except ValueError:
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=datetime.timezone.utc)
    return stamp.timestamp()


def number(value):
    """Finite float or None; bools and junk are not numbers."""
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
    if limit is not None and len(value) > limit:
        value = value[: max(0, limit - 1)].rstrip() + "\u2026"
    return value or None


def write_atomic(path, payload):
    """Temp file in the target directory, then os.replace: no half-written brief."""
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    handle, temp_path = tempfile.mkstemp(prefix=".brief.", dir=directory)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as fh:
            fh.write(payload)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(temp_path, 0o644)
        os.replace(temp_path, path)
    except BaseException:
        try:
            os.unlink(temp_path)
        except OSError:
            pass
        raise


def read_json_file(path):
    """Parsed JSON or a reason string. Never raises."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return json.load(fh), None
    except FileNotFoundError:
        return None, "missing"
    except (OSError, ValueError) as exc:
        return None, "unreadable: %s" % type(exc).__name__


# ------------------------------------------------------- phrasing placeholders
def lookup(obj, path):
    """Resolve ``a.b[0].c`` or ``a.#`` against ``obj``; (found, value)."""
    current = obj
    for part in path.split("."):
        if part == "#":
            if not isinstance(current, list):
                return False, None
            current = len(current)
            continue
        match = NAME_RE.match(part)
        if not match:
            return False, None
        key, indices = match.group(1), match.group(2)
        if not isinstance(current, dict) or key not in current:
            return False, None
        current = current[key]
        for raw in re.findall(r"\[([0-9]+)\]", indices):
            index = int(raw)
            if not isinstance(current, list) or index >= len(current):
                return False, None
            current = current[index]
    return True, current


def placeholders(template):
    return [match.group(1) for match in PLACEHOLDER_RE.finditer(template or "")]


def unresolved_placeholders(template, payload):
    return [name for name in placeholders(template) if not lookup(payload, name)[0]]


# ------------------------------------------------------------------ Slack probe
def read_env_file(path):
    values = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, raw = line.partition("=")
                values[key.strip()] = raw.strip().strip('"').strip("'")
    except (OSError, ValueError):
        return {}
    return values


def slack_call(token, method, timeout=6, **params):
    """One read-only Slack Web API GET. Returns a dict; failures are dicts too."""
    import urllib.parse
    import urllib.request

    url = "https://slack.com/api/%s" % method
    if params:
        url += "?" + urllib.parse.urlencode(params)
    request = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8", "replace"))
    except Exception as exc:  # network, DNS, TLS, bad JSON: all answers, not crashes
        return {"ok": False, "error": "%s: %s" % (type(exc).__name__, exc)}


def probe_slack(env_path):
    """Read-only unread probe. Never writes, never prints the token."""
    env = read_env_file(env_path)
    token = env.get("SLACK_BOT_TOKEN") or env.get("SLACK_USER_TOKEN") or ""
    if not token:
        return {
            "available": False,
            "unread": None,
            "reason": "no SLACK_BOT_TOKEN in hermes-slack profile on this host",
        }

    auth = slack_call(token, "auth.test")
    if not auth.get("ok"):
        return {
            "available": False,
            "unread": None,
            "reason": "auth.test failed (%s)" % (auth.get("error") or "unknown"),
        }

    home = env.get("SLACK_HOME_CHANNEL") or ""
    listing = slack_call(token, "conversations.list",
                         types="public_channel,private_channel",
                         exclude_archived="true", limit="200")
    channels = listing.get("channels") or [] if listing.get("ok") else []
    if not home and channels:
        home = channels[0].get("id") or ""
    if not home:
        return {
            "available": False,
            "unread": None,
            "reason": "auth.test ok, no home channel id to ask conversations.info about",
        }

    info = slack_call(token, "conversations.info", channel=home)
    channel = (info.get("channel") or {}) if info.get("ok") else {}
    unread = integer(channel.get("unread_count"))
    if unread is None:
        return {
            "available": False,
            "unread": None,
            "reason": (
                "auth.test ok, conversations.list ok (%d channels), "
                "conversations.info unread_count null for a bot token: "
                "Slack returns it only for the calling user's own membership, "
                "so no read-only unread count is available on this host"
            ) % len(channels),
        }
    return {
        "available": True,
        "unread": unread,
        "reason": "conversations.info unread_count for the home channel",
        "channel": text(channel.get("name")),
    }


def slack_from_fixture(path, reason_default):
    if not path:
        return {"available": False, "unread": None, "reason": reason_default}
    payload, problem = read_json_file(path)
    if problem or not isinstance(payload, dict):
        return {
            "available": False,
            "unread": None,
            "reason": "slack fixture %s (%s)" % (problem or "not an object", "fixture"),
        }
    available = bool(payload.get("available"))
    unread = integer(payload.get("unread")) if available else None
    if available and unread is None:
        return {
            "available": False,
            "unread": None,
            "reason": "fixture claimed available with no integer unread count",
        }
    return {
        "available": available,
        "unread": unread,
        "reason": text(payload.get("reason")) or ("fixture" if not available else
                                                  "unread_count from fixture"),
    }


# -------------------------------------------------------------- board sources
def boot_epoch():
    """kern.boottime seconds on Darwin; None anywhere else or on failure."""
    try:
        out = subprocess.run(["sysctl", "-n", "kern.boottime"],
                             capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    match = re.search(r"sec\s*=\s*([0-9]+)", out.stdout or "")
    return int(match.group(1)) if match else None


def normalise_card(card):
    if not isinstance(card, dict):
        return None
    card_id = text(card.get("id"))
    if not card_id:
        return None
    return {
        "id": card_id,
        "title": text(card.get("title"), limit=160) or "(untitled)",
        "status": text(card.get("status")) or "unknown",
        "assignee": text(card.get("assignee")),
        "completed_at": integer(card.get("completed_at")),
        "created_at": integer(card.get("created_at")),
        "last_failure_error": text(card.get("last_failure_error"), limit=200),
    }


def board_from_cli():
    binary = shutil.which("hermes") or os.path.join(HOME, ".local", "bin", "hermes")
    if not os.path.exists(binary):
        return None, "hermes CLI not on PATH"
    try:
        out = subprocess.run([binary, "kanban", "list", "--json"],
                             capture_output=True, text=True, timeout=CLI_TIMEOUT)
    except (OSError, subprocess.SubprocessError) as exc:
        return None, "hermes kanban list failed: %s" % type(exc).__name__
    if out.returncode != 0:
        first = (out.stderr or out.stdout or "").strip().splitlines()
        return None, "hermes kanban list exit %d: %s" % (
            out.returncode, text(first[0], limit=140) if first else "no output")
    try:
        payload = json.loads(out.stdout or "")
    except ValueError:
        return None, "hermes kanban list printed no JSON"
    if not isinstance(payload, list):
        return None, "hermes kanban list JSON is not a list"
    return payload, None


def board_from_db(path=None):
    """Read-only sqlite read of the same board the CLI prints. Never writes."""
    import sqlite3

    db_path = path or os.environ.get("HERMES_KANBAN_DB") or DEFAULT_BOARD_DB
    db_path = os.path.abspath(os.path.expanduser(db_path))
    if not os.path.exists(db_path):
        return None, "board db %s missing" % db_path.replace(HOME, "~")
    # ``mode=ro`` is refused on this host while the gateway holds the file, so
    # try it first and fall back to ``immutable=1`` (a consistent snapshot read).
    row = None
    error = None
    for uri in ("file:%s?mode=ro" % db_path, "file:%s?immutable=1" % db_path):
        try:
            connection = sqlite3.connect(uri, uri=True, timeout=5)
            try:
                cursor = connection.execute(
                    "SELECT id, title, status, assignee, completed_at, created_at,"
                    " last_failure_error FROM tasks WHERE status != 'archived'")
                row = cursor.fetchall()
                break
            finally:
                connection.close()
        except sqlite3.Error as exc:
            error = "%s: %s" % (type(exc).__name__, exc)
    if row is None:
        return None, "board db unreadable (%s)" % (error or "no rows")
    cards = []
    for item in row:
        cards.append({
            "id": item[0], "title": item[1], "status": item[2], "assignee": item[3],
            "completed_at": item[4], "created_at": item[5],
            "last_failure_error": item[6],
        })
    return cards, None


def board_from_fixture(path):
    payload, problem = read_json_file(path)
    if problem:
        return None, "board fixture %s" % problem
    if isinstance(payload, dict):  # tolerate {"cards": [...]} as well as a bare list
        payload = payload.get("cards")
    if not isinstance(payload, list):
        return None, "board fixture is not a list"
    return payload, None


# ------------------------------------------------------------------- bucketing
def bucket(cards, since_epoch):
    """Split the board into the four non-overlapping buckets plus lists."""
    finished, blocked, failed, running, needs_me = [], [], [], [], []
    for card in cards:
        status = card["status"]
        if status == "done":
            completed = card["completed_at"]
            if completed is not None and since_epoch is not None and completed >= since_epoch:
                finished.append(card)
            continue
        if status == "blocked":
            blocked.append(card)
            needs_me.append(card)
            continue
        if status in ("running", "review"):
            running.append(card)
            continue
        if card["last_failure_error"]:
            failed.append(card)
    finished.sort(key=lambda c: (-(c["completed_at"] or 0), c["id"]))
    blocked.sort(key=lambda c: c["id"])
    failed.sort(key=lambda c: c["id"])
    running.sort(key=lambda c: c["id"])
    return finished, blocked, failed, running, needs_me


def build_highlights(finished):
    out = []
    for card in finished[:HIGHLIGHT_LIMIT]:
        out.append({
            "id": card["id"],
            "title": card["title"],
            "status": "done",
            "assignee": card["assignee"],
            "at": iso(card["completed_at"]),
        })
    return out


def build_digest_block(digest_path, fixture):
    """Digest facts, or an honest absence. Never fabricates a digest."""
    if fixture:
        payload, problem = read_json_file(digest_path)
        if problem:
            return {"available": False,
                    "reason": "digest fixture %s" % problem}, []
        return digest_payload(payload, source_note="fixture"), digest_entry(payload)

    installed = shutil.which("bridge-digest") or shutil.which("bridge-digest.sh")
    payload, problem = read_json_file(digest_path or DEFAULT_DIGEST)
    if problem:
        if not installed:
            return {"available": False, "reason": "bridge-digest not on this host"}, []
        return {"available": False,
                "reason": "bridge-digest installed but no digest at %s"
                          % (digest_path or DEFAULT_DIGEST).replace(HOME, "~")}, []
    return digest_payload(payload, source_note="file"), digest_entry(payload)


def digest_entry(payload):
    if not isinstance(payload, dict):
        return []
    entries = payload.get("blocked")
    if not isinstance(entries, list):
        return []
    out = []
    for entry in entries:
        if isinstance(entry, dict) and text(entry.get("id")):
            out.append({"id": text(entry.get("id")),
                        "title": text(entry.get("title"), limit=160) or "(untitled)",
                        "status": "blocked"})
        elif isinstance(entry, str) and entry.strip():
            out.append({"id": entry.strip(), "title": "(untitled)", "status": "blocked"})
    return out


def digest_payload(payload, source_note):
    if not isinstance(payload, dict):
        return {"available": False, "reason": "digest is not a JSON object"}
    blocked = payload.get("blocked")
    stalled = payload.get("stalled")
    dead = payload.get("dead_events")
    return {
        "available": True,
        "reason": "bridge-digest output file" if source_note == "file" else "digest fixture",
        "generated_at": text(payload.get("generated_at")),
        "blocked": len(blocked) if isinstance(blocked, list) else 0,
        "stalled": len(stalled) if isinstance(stalled, list) else integer(stalled) or 0,
        "dead_events": len(dead) if isinstance(dead, list) else integer(dead) or 0,
        "source": source_note,
    }


# ------------------------------------------------------------------- rendering
def render_lines(payload):
    """Five short plain lines: the same numbers as brief.json, nothing new."""
    fleet = payload["fleet"]
    lines = [
        "Mac fleet since %s: %d finished, %d blocked, %d failed, %d running."
        % (payload["since"] or "unknown",
           fleet["finished"], fleet["blocked"], fleet["failed"], fleet["still_running"]),
    ]

    needs = payload["needs_me"]
    if needs:
        shown = [n["title"] for n in needs[:NEEDS_ME_SHOWN]]
        more = len(needs) - len(shown)
        suffix = " (+%d more)" % more if more > 0 else ""
        lines.append("Needs you: %s%s." % (", ".join(shown), suffix))
    else:
        lines.append("Needs you: nothing.")

    if payload["highlights"]:
        top = payload["highlights"][0]
        who = " (%s)" % top["assignee"] if top.get("assignee") else ""
        lines.append("Latest done: %s%s." % (top["title"], who))
    else:
        lines.append("Nothing finished in this window.")

    digest = payload["digest"]
    if digest.get("available"):
        lines.append("Digest: %d blocked, %d stalled, %d dead events."
                     % (digest.get("blocked", 0), digest.get("stalled", 0),
                        digest.get("dead_events", 0)))
    else:
        lines.append("Digest: not on this host.")

    slack = payload["slack"]
    if slack.get("available"):
        lines.append("Slack: %d unread." % (slack.get("unread") or 0))
    else:
        lines.append("Slack: no unread count on this host.")
    return lines


# ------------------------------------------------------------------ generation
def apply_fixture(args):
    """``--fixture PATH``: the shared feed-contract switch.

    A directory is expected to hold ``board.json``, ``digest.json`` and
    ``slack.json`` (any of them optional); a file is taken as the board.
    The specific ``--board-fixture``/``--digest-fixture``/``--slack-fixture``
    flags win over whatever the directory supplies.
    """
    path = getattr(args, "fixture", None)
    if not path:
        return args
    path = os.path.abspath(os.path.expanduser(path))
    if os.path.isdir(path):
        for attribute, name in (("board_fixture", "board.json"),
                                ("digest_fixture", "digest.json"),
                                ("slack_fixture", "slack.json")):
            candidate = os.path.join(path, name)
            if not getattr(args, attribute, None) and os.path.isfile(candidate):
                setattr(args, attribute, candidate)
    elif os.path.isfile(path):
        if not getattr(args, "board_fixture", None):
            args.board_fixture = path
    return args


def generate(args):
    """Build the brief dict + text. Pure: no writes, no clock beyond ``now``."""
    args = apply_fixture(args)
    source = "fixture" if args.board_fixture else "live"
    now = parse_epoch(args.now) if args.now is not None else utc_now()
    if now is None:
        raise ArgError("--now is not a timestamp")

    # Board.
    if args.board_fixture:
        raw_cards, board_problem = board_from_fixture(args.board_fixture)
        board_source = "fixture"
    else:
        raw_cards, board_problem = board_from_cli()
        board_source = "cli"
        if raw_cards is None:
            raw_cards, db_problem = board_from_db()
            board_source = "db"
            if raw_cards is None:
                board_problem = "%s; %s" % (board_problem, db_problem)
    cards = [card for card in (normalise_card(item) for item in (raw_cards or []))
             if card is not None]

    # Since: boot time or the previous brief, whichever is later.
    if args.since is not None:
        since_epoch = parse_epoch(args.since)
        if since_epoch is None:
            raise ArgError("--since is not a timestamp")
        since_source = "override"
    else:
        boot = parse_epoch(args.boot) if args.boot is not None else boot_epoch()
        previous = None
        if not args.board_fixture:
            previous_payload, _ = read_json_file(os.path.join(args.out, "brief.json"))
            if isinstance(previous_payload, dict):
                previous = parse_epoch(previous_payload.get("generated_at"))
        candidates = [value for value in (boot, previous) if value is not None]
        since_epoch = max(candidates) if candidates else None
        if boot is not None and previous is not None:
            since_source = "both" if boot == previous else (
                "boot" if boot > previous else "brief")
        elif boot is not None:
            since_source = "boot"
        elif previous is not None:
            since_source = "brief"
        else:
            since_source = "none"

    finished, blocked, failed, running, needs_me = bucket(cards, since_epoch)

    # Digest.
    if args.digest_fixture:
        digest, digest_needs_me = build_digest_block(args.digest_fixture, True)
    else:
        digest, digest_needs_me = build_digest_block(args.digest, False)
    for entry in digest_needs_me:
        if not any(existing["id"] == entry["id"] for existing in needs_me):
            needs_me.append(entry)

    # Slack.
    if args.slack_fixture:
        slack = slack_from_fixture(args.slack_fixture,
                                   "no slack fixture on this host")
    elif args.no_slack or args.board_fixture:
        slack = {"available": False, "unread": None,
                 "reason": "slack probe not requested in fixture mode" if args.board_fixture
                           else "slack probe disabled with --no-slack"}
    else:
        slack = probe_slack(args.slack_env)

    payload = {
        "ok": True,
        "generated_at": iso(now),
        "source": source,
        "since": iso(since_epoch),
        "since_source": since_source,
        "fleet": {
            "finished": len(finished),
            "blocked": len(blocked),
            "failed": len(failed),
            "still_running": len(running),
        },
        "highlights": build_highlights(finished),
        "needs_me": [{"id": card["id"], "title": card["title"], "status": "blocked"}
                     for card in needs_me],
        "slack": slack,
        "digest": digest,
        "phrasing": PHRASING,
        "board": {"source": board_source, "cards": len(cards)},
    }
    if board_problem:
        payload["board"]["reason"] = text(board_problem, limit=200)
    return payload


def write_outputs(payload, out_dir):
    text_body = "\n".join(render_lines(payload)) + "\n"
    json_body = json.dumps(payload, indent=2, sort_keys=False) + "\n"
    write_atomic(os.path.join(out_dir, "brief.json"), json_body)
    write_atomic(os.path.join(out_dir, "brief.txt"), text_body)
    return json_body, text_body


# ------------------------------------------------------------------ self-check
def check(name, ok, detail="", report=None):
    entry = (name, bool(ok), detail)
    if report is not None:
        report.append(entry)
    print("%s %s%s" % ("ok  " if ok else "FAIL", name,
                       ("  " + detail) if detail and not ok else ""), file=sys.stderr)
    return ok


def golden_payload():
    """Deterministic payload used for the committed golden files."""
    args = argparse.Namespace(
        board_fixture=FIXTURE_BOARD, digest_fixture=FIXTURE_DIGEST,
        slack_fixture=FIXTURE_SLACK, digest=None, now=str(GOLDEN_NOW),
        boot=str(GOLDEN_BOOT), since=None, out=tempfile.mkdtemp(prefix="bb-golden-"),
        no_slack=False, slack_env=DEFAULT_SLACK_ENV,
    )
    payload = generate(args)
    shutil.rmtree(args.out, ignore_errors=True)
    return payload


def write_golden():
    payload = golden_payload()
    text_body = "\n".join(render_lines(payload)) + "\n"
    os.makedirs(GOLDEN_DIR, exist_ok=True)
    write_atomic(GOLDEN_JSON, json.dumps(payload, indent=2) + "\n")
    write_atomic(GOLDEN_TXT, text_body)
    print("wrote %s" % GOLDEN_JSON)
    print("wrote %s" % GOLDEN_TXT)
    return EXIT_OK


def first_diff(expected, actual, label):
    expected_lines = expected.splitlines()
    actual_lines = actual.splitlines()
    for index in range(max(len(expected_lines), len(actual_lines))):
        left = expected_lines[index] if index < len(expected_lines) else "<missing>"
        right = actual_lines[index] if index < len(actual_lines) else "<missing>"
        if left != right:
            return "%s drifts at line %d: golden %r vs now %r" % (
                label, index + 1, left[:160], right[:160])
    return "%s drifts (%d vs %d lines)" % (label, len(expected_lines), len(actual_lines))


def self_check():
    report = []
    scratch = tempfile.mkdtemp(prefix="bb-check-")

    # 1. Golden: fixture board + fixture digest + fixed clock.
    payload = golden_payload()
    text_body = "\n".join(render_lines(payload)) + "\n"
    golden_json, json_problem = read_json_file(GOLDEN_JSON)
    if json_problem:
        check("golden json present", False, "%s (%s)" % (GOLDEN_JSON, json_problem), report)
    else:
        expected = json.dumps(golden_json, indent=2) + "\n"
        actual = json.dumps(payload, indent=2) + "\n"
        check("golden json matches", expected == actual,
              "" if expected == actual else first_diff(expected, actual, "brief.json"), report)

    golden_txt = None
    text_problem = None
    try:
        with open(GOLDEN_TXT, "r", encoding="utf-8") as fh:
            golden_txt = fh.read()
    except OSError as exc:
        text_problem = type(exc).__name__
    if golden_txt is None:
        check("golden txt present", False, "%s (%s)" % (GOLDEN_TXT, text_problem), report)
    else:
        check("golden txt matches", golden_txt == text_body,
              "" if golden_txt == text_body
              else first_diff(golden_txt, text_body, "brief.txt"), report)

    # 2. Known numbers, honest buckets.
    fleet = payload["fleet"]
    check("fixture buckets known", fleet == {"finished": 3, "blocked": 2, "failed": 1,
                                            "still_running": 2}, repr(fleet), report)
    check("needs_me carries board and digest blocked",
          [n["id"] for n in payload["needs_me"]] == ["t_fx1006", "t_fx1011", "t_fx9001"],
          repr([n["id"] for n in payload["needs_me"]]), report)
    check("highlight order newest first",
          [h["id"] for h in payload["highlights"]] == ["t_fx1002", "t_fx1001", "t_fx1003"],
          repr([h["id"] for h in payload["highlights"]]), report)
    check("card without completed_at is not finished",
          all(h["id"] != "t_fx1005" for h in payload["highlights"])
          and all(n["id"] != "t_fx1005" for n in payload["needs_me"]), "", report)
    check("done before since is not finished",
          all(h["id"] != "t_fx1004" for h in payload["highlights"]), "", report)

    # 3. brief.txt shape.
    line_count = len(text_body.rstrip("\n").splitlines())
    check("brief.txt is 3 to 6 lines", 3 <= line_count <= 6, "%d lines" % line_count, report)

    # 4. Phrasing: every placeholder is a key path in the same JSON.
    dangling = unresolved_placeholders(payload["phrasing"], payload)
    check("phrasing placeholders resolve", not dangling, repr(dangling), report)

    # 5. Empty board: honest zero brief, exit 0, same shape.
    empty_path = os.path.join(scratch, "empty-board.json")
    write_atomic(empty_path, "[]\n")
    empty_args = argparse.Namespace(
        board_fixture=empty_path, digest_fixture=None, slack_fixture=None,
        digest=None, now=str(GOLDEN_NOW), boot=str(GOLDEN_BOOT), since=None,
        out=os.path.join(scratch, "empty-out"), no_slack=True,
        slack_env=DEFAULT_SLACK_ENV)
    empty = generate(empty_args)
    empty_text = "\n".join(render_lines(empty))
    check("empty board is all zeros",
          empty["fleet"] == {"finished": 0, "blocked": 0, "failed": 0, "still_running": 0},
          repr(empty["fleet"]), report)
    check("empty board still has an envelope",
          empty["ok"] is True and empty["source"] == "fixture"
          and iso(parse_epoch(empty["generated_at"])) == empty["generated_at"], "", report)
    check("empty board brief.txt stays 3 to 6 lines",
          3 <= len(empty_text.splitlines()) <= 6, "", report)
    check("empty board phrasing resolves",
          not unresolved_placeholders(empty["phrasing"], empty), "", report)
    check("empty board lists nothing to do",
          empty["needs_me"] == [] and empty["highlights"] == [], "", report)

    # 6. Missing digest does not raise and is not invented.
    missing_args = argparse.Namespace(
        board_fixture=FIXTURE_BOARD, digest_fixture=None, slack_fixture=FIXTURE_SLACK,
        digest=os.path.join(scratch, "no-such-digest.json"), now=str(GOLDEN_NOW),
        boot=str(GOLDEN_BOOT), since=None, out=os.path.join(scratch, "missing-out"),
        no_slack=False, slack_env=DEFAULT_SLACK_ENV)
    missing = generate(missing_args)
    check("missing digest is an honest absence",
          missing["digest"]["available"] is False and bool(missing["digest"].get("reason")),
          repr(missing["digest"]), report)
    check("missing digest does not change the board facts",
          missing["fleet"] == payload["fleet"], repr(missing["fleet"]), report)

    # 7. A done card with no completed_at, alone: zero finished.
    null_path = os.path.join(scratch, "null-completed.json")
    write_atomic(null_path, json.dumps([{
        "id": "t_null01", "title": "half-written card", "status": "done",
        "assignee": "kakashi", "completed_at": None, "created_at": GOLDEN_BOOT - 60,
    }]) + "\n")
    null_args = argparse.Namespace(
        board_fixture=null_path, digest_fixture=None, slack_fixture=None, digest=None,
        now=str(GOLDEN_NOW), boot=str(GOLDEN_BOOT), since=None,
        out=os.path.join(scratch, "null-out"), no_slack=True, slack_env=DEFAULT_SLACK_ENV)
    null_brief = generate(null_args)
    check("done without completed_at is not finished",
          null_brief["fleet"]["finished"] == 0
          and null_brief["fleet"]["still_running"] == 0, repr(null_brief["fleet"]), report)

    # 8. Malformed card rows never raise and never get counted.
    junk_path = os.path.join(scratch, "junk-board.json")
    write_atomic(junk_path, json.dumps([
        "not a card", {"title": "no id"}, {"id": "t_junk01", "status": "running"},
        {"id": "t_junk02", "status": "done", "completed_at": "not-a-time"},
    ]) + "\n")
    junk_args = argparse.Namespace(
        board_fixture=junk_path, digest_fixture=None, slack_fixture=None, digest=None,
        now=str(GOLDEN_NOW), boot=str(GOLDEN_BOOT), since=None,
        out=os.path.join(scratch, "junk-out"), no_slack=True, slack_env=DEFAULT_SLACK_ENV)
    junk = generate(junk_args)
    check("malformed board row tolerated",
          junk["fleet"]["still_running"] == 1 and junk["fleet"]["finished"] == 0,
          repr(junk["fleet"]), report)

    # 9. Slack available path renders the count, unavailable renders the absence.
    slack_path = os.path.join(scratch, "slack.json")
    write_atomic(slack_path, json.dumps({"available": True, "unread": 4,
                                         "reason": "unread_count from fixture"}) + "\n")
    slack_args = argparse.Namespace(
        board_fixture=FIXTURE_BOARD, digest_fixture=FIXTURE_DIGEST,
        slack_fixture=slack_path, digest=None, now=str(GOLDEN_NOW),
        boot=str(GOLDEN_BOOT), since=None, out=os.path.join(scratch, "slack-out"),
        no_slack=False, slack_env=DEFAULT_SLACK_ENV)
    slack_brief = generate(slack_args)
    slack_text = "\n".join(render_lines(slack_brief))
    check("slack count renders when available",
          slack_brief["slack"]["unread"] == 4 and "Slack: 4 unread." in slack_text,
          slack_text, report)
    check("slack absence renders when unavailable",
          payload["slack"]["available"] is False
          and "Slack: no unread count on this host." in text_body, "", report)

    # 10. Files land atomically in --out, and stdout carries one JSON object.
    out_dir = os.path.join(scratch, "write-out")
    json_body, written_text = write_outputs(payload, out_dir)
    for name in ("brief.json", "brief.txt"):
        path = os.path.join(out_dir, name)
        check("wrote %s" % name, os.path.isfile(path), path, report)
    with open(os.path.join(out_dir, "brief.json"), "r", encoding="utf-8") as fh:
        reloaded = json.load(fh)
    check("brief.json round-trips", reloaded == payload, "", report)
    check("brief.txt on disk matches render", written_text == text_body, "", report)
    leftovers = [n for n in os.listdir(out_dir) if n.startswith(".brief.")]
    check("no temp files left behind", not leftovers, repr(leftovers), report)

    # 11. The live path is exercised once: it must answer, not raise.
    live = generate(argparse.Namespace(
        board_fixture=None, digest_fixture=None, slack_fixture=None, digest=None,
        now=None, boot=None, since=None, out=os.path.join(scratch, "live-out"),
        no_slack=True, slack_env=DEFAULT_SLACK_ENV))
    check("live board answers", live["ok"] is True
          and live["board"]["source"] in ("cli", "db"),
          repr(live["board"]), report)
    check("live brief.txt is 3 to 6 lines",
          3 <= len("\n".join(render_lines(live)).splitlines()) <= 6, "", report)

    # 12. --fixture DIR is the shared feed-contract switch and matches the flags.
    fixture_dir = os.path.join(scratch, "fixture-dir")
    os.makedirs(fixture_dir, exist_ok=True)
    for fixture_source, fixture_name in ((FIXTURE_BOARD, "board.json"),
                                         (FIXTURE_DIGEST, "digest.json"),
                                         (FIXTURE_SLACK, "slack.json")):
        with open(fixture_source, "r", encoding="utf-8") as handle:
            write_atomic(os.path.join(fixture_dir, fixture_name), handle.read())
    via_dir = generate(argparse.Namespace(
        fixture=fixture_dir, board_fixture=None, digest_fixture=None,
        slack_fixture=None, digest=None, now=str(GOLDEN_NOW), boot=str(GOLDEN_BOOT),
        since=None, out=os.path.join(scratch, "dir-out"), no_slack=False,
        slack_env=DEFAULT_SLACK_ENV))
    check("--fixture directory matches the explicit flags", via_dir == payload, "", report)

    shutil.rmtree(scratch, ignore_errors=True)

    failed = [name for name, ok, _ in report if not ok]
    print("\nself-check %s: %d passed, %d failed"
          % ("ok" if not failed else "FAILED", len(report) - len(failed), len(failed)),
          file=sys.stderr)
    return EXIT_OK if not failed else EXIT_CHECK_FAILED


# ------------------------------------------------------------------------ main
def build_parser():
    parser = argparse.ArgumentParser(
        description="Boot briefing for the v5 HUD: facts-only brief.json + brief.txt.")
    parser.add_argument("--out", default=DEFAULT_OUT,
                        help="run directory for brief.json and brief.txt")
    parser.add_argument("--json", action="store_true",
                        help="print the brief object on stdout instead of the text lines")
    parser.add_argument("--force", action="store_true",
                        help="ignore the 10 s cache and regenerate now")
    parser.add_argument("--fixture", metavar="PATH",
                        help="read fixtures instead of the live host: a directory of "
                             "board.json/digest.json/slack.json, or one board file")
    parser.add_argument("--board-fixture", metavar="PATH",
                        help="read the board from a fixture instead of the live board")
    parser.add_argument("--digest-fixture", metavar="PATH",
                        help="read the digest from a fixture instead of the host")
    parser.add_argument("--slack-fixture", metavar="PATH",
                        help="read the slack block from a fixture (no network)")
    parser.add_argument("--digest", metavar="PATH", default=None,
                        help="path to the bridge-digest output file")
    parser.add_argument("--slack-env", metavar="PATH", default=DEFAULT_SLACK_ENV,
                        help="profile .env holding SLACK_BOT_TOKEN")
    parser.add_argument("--no-slack", action="store_true",
                        help="skip the read-only Slack probe")
    parser.add_argument("--now", metavar="STAMP", default=None,
                        help="freeze the clock (epoch or ISO) for tests")
    parser.add_argument("--boot", metavar="STAMP", default=None,
                        help="override kern.boottime for tests")
    parser.add_argument("--since", metavar="STAMP", default=None,
                        help="override the since timestamp for tests")
    parser.add_argument("--self-check", action="store_true",
                        help="run the built-in checks and the golden comparison")
    parser.add_argument("--write-golden", action="store_true",
                        help="regenerate the committed golden files")
    return parser


def main(argv=None):
    try:
        args = build_parser().parse_args(argv)
    except SystemExit as exc:  # argparse already explained itself
        return EXIT_OK if exc.code in (0, None) else EXIT_PROGRAMMING

    try:
        if args.write_golden:
            return write_golden()
        if args.self_check:
            return self_check()

        out_dir = os.path.abspath(os.path.expanduser(args.out))
        if not args.force and not args.board_fixture:
            cached, problem = read_json_file(os.path.join(out_dir, "brief.json"))
            if problem is None and isinstance(cached, dict):
                cached_at = parse_epoch(cached.get("generated_at"))
                age = utc_now() - cached_at if cached_at is not None else None
                if age is not None and 0 <= age < CACHE_MIN_SECONDS:
                    print("brief cached: %ds old, nothing re-read" % int(age),
                          file=sys.stderr)
                    if args.json:
                        sys.stdout.write(json.dumps(cached, indent=2) + "\n")
                    else:
                        sys.stdout.write("\n".join(render_lines(cached)) + "\n")
                    return EXIT_OK

        payload = generate(args)
        json_body, text_body = write_outputs(payload, out_dir)
        sys.stdout.write((json_body if args.json else
                          "\n".join(render_lines(payload)) + "\n"))
        return EXIT_OK
    except ArgError as exc:
        print("boot_brief: %s" % exc, file=sys.stderr)
        return EXIT_PROGRAMMING
    except BrokenPipeError:
        return EXIT_OK
    except Exception as exc:  # a programming error, never a data problem
        print("boot_brief: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
        return EXIT_PROGRAMMING


if __name__ == "__main__":
    sys.exit(main())
