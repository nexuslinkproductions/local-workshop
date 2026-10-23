#!/usr/bin/env python3
"""Boot briefing for the v5 HUD: facts first, phrasing second.

Runs at boot on the box that owns the deck and answers one question: *what
happened while the screen was off, and does anything need me?* It writes its
files into the run directory (default ``~/.local/state/nexuslink``, override
with ``--out DIR``), atomically:

``brief.json``
    The fact object. This is the contract every consumer (HUD, chief, tests)
    reads. Shape::

        {"ok": true, "generated_at": "<UTC ISO>", "source": "fixture|live",
         "since": "<UTC ISO>",
         "since_source": "stored|boot|override|fixture|none",
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

``brief_anchor.json``
    The window this brief ended at, plus the completion pairs it already
    reported (see **Since** and **Dedupe** below). Written only by a live run
    that produced a brief from a readable board; ``--reset-anchor`` removes it.

When the board cannot be read at all (CLI failed and the database is missing or
unreadable, or the board fixture is malformed), ``ok`` is false, the ``fleet``
numbers and ``board.cards`` are null, ``reason`` says what failed, and
``brief.txt`` leads with ``Board unreadable`` plus that reason. An empty board
(``[]``) is not that case: it is an honest zero brief with ``ok`` true.

Facts, and what is honest about each one
----------------------------------------
* **Board.** ``hermes kanban list --json`` (the named input); when the CLI is
  unavailable, the same board is read read-only from ``$HERMES_KANBAN_DB`` (or
  ``~/.hermes/kanban.db``) via the stdlib ``sqlite3`` module. The database is
  opened ``mode=ro`` while its ``-wal`` file has content, so a committed row
  that has not been checkpointed is still counted; when the ``-wal`` is absent
  or empty the read uses ``immutable=1``, because a ``mode=ro`` open needs a
  ``-shm`` file that only a writer creates (measured 2026-10-23 on the live
  board: 22 of 40 and 34 of 60 attempts failed with no ``-shm``, and
  ``immutable=1`` read it 60 of 60 times; an empty WAL has nothing to miss).
  A non-empty board whose rows are not cards (no row carries an ``id``) is
  unreadable, not an empty board. ``board.source`` says which path answered
  and ``board.reason`` says why the CLI did not. When neither path answers,
  ``ok`` is false with that reason and no counts.
* **Since — the brief's own anchor.** The window starts where the last good
  brief ended, kept in ``brief_anchor.json`` in the run directory
  (``~/.local/state/nexuslink`` by default, ``--out`` elsewhere)::

      {"anchor": "<UTC ISO>",
       "reported": ["<task_id>@<completed_at>", ...],
       "written_at": "<UTC ISO>",
       "schema": 1}

  Resolution order, live mode: the stored anchor when that file exists and
  parses; otherwise ``kern.boottime`` (first ever run on this host); otherwise
  null with a reason in ``finished_reason``. Boot time is a *first-run fallback
  only*: it is never consulted once a stored anchor exists, because a boot time
  would silently re-open a window the last good run had already closed. The
  file is written *only* by a live run that produced a brief from readable
  inputs (``ok: true``, atomic replace); an unreadable run writes nothing and
  advances nothing. ``since_source`` says which source won: ``stored``,
  ``boot``, ``override``, ``fixture`` or ``none``. ``brief.json`` is the deck's
  cache, not an anchor. ``--reset-anchor`` removes the file -- anchor and
  reported set -- prints what it removed, and does nothing else.
* **Dedupe.** A completion counts only when ``completed_at`` is strictly after
  the anchor *and* its pair ``<task_id>@<completed_at>`` is not already in
  ``reported`` (the epoch as the board carries it, e.g. ``t_early@1792650000``).
  A successful run appends the pairs it reported and keeps the newest
  ``REPORTED_CAP`` (200), so a re-anchor cannot resurrect a card already shown.
  Pairs already in the set are named on stderr as previously reported.
* **Buckets.** ``fleet.finished`` is *windowed*: cards ``done`` whose
  ``completed_at`` is strictly after ``since``. A card marked ``done`` with no
  ``completed_at`` is never counted as finished. When there is no window start
  at all, ``since`` is null, ``fleet.finished`` is null (never ``0``) and
  ``finished_reason`` says what was missing. ``blocked``, ``failed`` and
  ``still_running`` describe the board *now*, because a blocked card is a
  present-tense problem rather than an event. ``failed`` means: not done, not
  blocked, and ``last_failure_error`` is set (the board's own record that the
  last attempt crashed). The buckets never overlap.
* **Digest.** ``bridge-digest`` is Linux-only and is not installed on this Mac
  (checked 2026-10-23). The reader looks for the file the digest drops
  (``~/.local/state/nexuslink/digest.json``, override ``--digest``); if neither
  the command nor the file exists, ``digest.available`` is false with that
  reason and the brief leaves the digest out. A file that exists but does not
  parse is named as unreadable, never reported as a missing tool. A digest is
  never invented and a missing or malformed one never raises. Fixture mode
  never reads the host digest: only a ``digest.json`` fixture (or an explicit
  ``--digest``) counts.
* **Slack.** No probe, no network call. The first build sent GETs to
  ``auth.test``, ``conversations.list`` and ``conversations.info``, which the
  feed contract forbids, and the answer was empty anyway: Slack returns
  ``unread_count`` only for the calling user's own membership, and a bot token
  has its own, so the field came back ``null`` (checked 2026-10-23). The live
  path therefore reports ``available`` false with that fixed finding as its
  reason and never touches the network; a live probe needs a contract change
  from Marcel first. A ``slack.json`` fixture still supplies the block.

Phrasing rule
-------------
``phrasing`` is a template, never a rendered sentence and never a number the
script did not measure. Placeholders are key paths into the same JSON
(``{fleet.finished}``, ``{slack.reason}``, and ``{needs_me.#}`` for the length
of a list). Every brace pair is checked, including one with spaces inside, so a
typo like ``{ fleet.finishd }`` fails instead of passing unseen. ``--self-check``
asserts every placeholder resolves against the JSON it is emitted with. No model
is called from this script.

Fixture mode
------------
``--fixture PATH`` reads from a fixture file or directory instead of the live
host, with no host state: no board CLI, no database, no cache, no ``sysctl``
boot time, no host digest, no Slack probe, and **no anchor file** -- it is
neither read nor written, because a fixture is not evidence about this host's
window. The anchor comes from ``--since``, else ``--boot``, else the board
fixture's own ``"anchor"`` field (a fixture may be ``{"cards": [...],
"anchor": "..."}``); a fixture anchor that does not parse is treated as absent.
A directory must hold ``board.json``; ``digest.json`` and ``slack.json`` are
optional, and the specific ``--board-fixture`` / ``--digest-fixture`` /
``--slack-fixture`` flags win over what the directory supplies. ``--fixture`` on
a missing path, or on a directory without ``board.json``, is a bad argument, not
a data problem.

Exit codes follow the feed contract: ``0`` for data and for honest absence
(``ok:false`` plus a reason), ``2`` for a programming error such as a bad
argument or a named file that does not exist (a missing fixture path, a fixture
directory with no ``board.json``, a named ``--digest`` that is absent).
``--self-check`` exits ``1`` when a check fails, so drift is loud.
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

# The brief's own anchor: the window it ended at plus the completion pairs it
# already reported. Written only by a live ok run, atomically, in the run dir.
ANCHOR_NAME = "brief_anchor.json"
ANCHOR_SCHEMA = 1
REPORTED_CAP = 200            # newest pairs kept; a longer list loses the oldest

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

# Fixed, not measured: the 2026-10-23 finding on this Mac. A live probe needs a
# contract change from Marcel before it comes back.
LIVE_SLACK_REASON = (
    "no read-only Slack unread count on this host (checked 2026-10-23: Slack "
    "returns unread_count only for the calling user's own membership and a bot "
    "token has its own, so the field is null; the live probe was removed and a "
    "contract change from Marcel is needed before one returns)"
)

# The phrasing an unreadable board gets: no counts to name, only the reason.
UNREADABLE_PHRASING = (
    "The board could not be read this run ({reason}), so nothing was counted. "
    "Slack unread: available={slack.available} ({slack.reason}). "
    "Digest: available={digest.available} ({digest.reason})."
)

# The phrasing a board with no window start gets: the present-tense counts hold,
# the finished count does not exist. ``finished_reason`` travels in the JSON.
UNKNOWN_WINDOW_PHRASING = (
    "The window start is unknown ({finished_reason}), so the finished count was "
    "not measured; {fleet.blocked} blocked, {fleet.failed} failed and "
    "{fleet.still_running} are still running. {needs_me.#} card(s) need you. "
    "Slack unread: available={slack.available} ({slack.reason}). "
    "Digest: available={digest.available} ({digest.reason})."
)

# Every brace pair, spaces included: a typo like ``{ fleet.finishd }`` must fail.
PLACEHOLDER_RE = re.compile(r"\{([^{}]*)\}")
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


def display_path(path):
    """A path fit for output: ``~`` under home, the leaf name anywhere else."""
    resolved = os.path.abspath(os.path.expanduser(str(path)))
    if resolved == HOME or resolved.startswith(HOME + os.sep):
        return "~" + resolved[len(HOME):]
    return os.path.basename(resolved) or resolved


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
    """Read-only unread probe. Never writes, never prints the token.

    The live path no longer calls this (see ``LIVE_SLACK_REASON``): F4 must make
    no network calls. It stays here, correct and exercised by ``--self-check``
    with a stubbed ``slack_call``, for the day Marcel changes the contract. Every
    reason is built from what each call actually answered.
    """
    env = read_env_file(env_path)
    token = env.get("SLACK_BOT_TOKEN") or ""
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
    if listing.get("ok"):
        channels = listing.get("channels") or []
        listing_note = "conversations.list ok (%d channels)" % len(channels)
    else:
        channels = []
        listing_note = "conversations.list failed (%s)" % (
            listing.get("error") or "unknown")
    if not home and channels:
        home = channels[0].get("id") or ""
    if not home:
        return {
            "available": False,
            "unread": None,
            "reason": "auth.test ok, %s, no home channel id to ask "
                      "conversations.info about" % listing_note,
        }

    info = slack_call(token, "conversations.info", channel=home)
    if not info.get("ok"):
        return {
            "available": False,
            "unread": None,
            "reason": "auth.test ok, %s, conversations.info failed (%s)"
                      % (listing_note, info.get("error") or "unknown"),
        }

    channel = info.get("channel") or {}
    if not isinstance(channel, dict):
        channel = {}
    if "unread_count" not in channel:
        return {
            "available": False,
            "unread": None,
            "reason": (
                "auth.test ok, %s, conversations.info ok but the answer carries "
                "no unread_count field at all, so the count is missing rather "
                "than null" % listing_note
            ),
        }
    raw_unread = channel.get("unread_count")
    unread = integer(raw_unread)
    if unread is None and raw_unread is not None:
        return {
            "available": False,
            "unread": None,
            "reason": (
                "auth.test ok, %s, conversations.info ok but unread_count is "
                "not a whole number (%r)" % (listing_note, text(raw_unread, limit=40))
            ),
        }
    if unread is None:
        return {
            "available": False,
            "unread": None,
            "reason": (
                "auth.test ok, %s, conversations.info ok but unread_count is "
                "null for a bot token: Slack returns it only for the calling "
                "user's own membership, so no read-only unread count is "
                "available on this host" % listing_note
            ),
        }
    return {
        "available": True,
        "unread": unread,
        "reason": "auth.test ok, %s, conversations.info unread_count for the "
                  "home channel" % listing_note,
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


# ----------------------------------------------------------------- anchor file
class Brief(dict):
    """The fact object, plus the bookkeeping ``main`` persists. Never JSON."""

    anchor_record: dict | None = None


def anchor_path(out_dir):
    """The anchor file lives beside the brief it belongs to."""
    return os.path.join(out_dir, ANCHOR_NAME)


def pair_key(card):
    """``<task_id>@<completed_at>``: one completion, as the board carries it."""
    return "%s@%d" % (card["id"], card["completed_at"])


def pair_epoch(pair):
    """The ``completed_at`` inside a pair; None when the pair is not ours."""
    _, _, raw = str(pair).rpartition("@")
    return integer(raw)


def read_anchor_file(path):
    """Stored anchor facts as ``(state, problem)``; never raises.

    ``state`` is ``{"anchor": float|None, "anchor_text": str|None,
    "reported": [pair, ...]}``, or None when the file is absent or is not a
    JSON object. ``problem`` is None only when an anchor was actually usable:
    ``missing``, ``unreadable: <Error>``, ``not a JSON object``, or a named
    fault in the anchor field. A file that parses but carries no usable anchor
    still lends its ``reported`` set: what a past brief already said is good
    evidence even when the anchor itself is junk.
    """
    payload, problem = read_json_file(path)
    if problem == "missing":
        return None, "missing"
    if problem:
        return None, problem
    if not isinstance(payload, dict):
        return None, "not a JSON object"
    raw_anchor = payload.get("anchor")
    anchor = parse_epoch(raw_anchor)
    reported = []
    raw_reported = payload.get("reported")
    if isinstance(raw_reported, list):
        for item in raw_reported:
            if isinstance(item, str) and item.strip() and item.strip() not in reported:
                reported.append(item.strip())
    state = {
        "anchor": anchor,
        "anchor_text": raw_anchor if isinstance(raw_anchor, str) else None,
        "reported": reported,
    }
    if anchor is None:
        if raw_anchor is None:
            return state, "anchor field missing"
        return state, "anchor field %r is not a timestamp" % (raw_anchor,)
    return state, None


def merge_reported(previous, pairs):
    """Previous pairs plus ``(completed_at, pair)``, oldest first, newest kept.

    ``REPORTED_CAP`` is a ceiling: on overflow the oldest entries go, so the set
    always holds the most recent completions. A pair already present keeps its
    first position and is never duplicated.
    """
    entries = {}
    position = 0
    for pair in previous:
        if not isinstance(pair, str) or not pair or pair in entries:
            continue
        entries[pair] = (pair_epoch(pair), position)
        position += 1
    for completed_at, pair in pairs:
        if pair in entries:
            continue
        entries[pair] = (completed_at, position)
        position += 1
    ordered = sorted(
        entries.items(),
        key=lambda item: (-1.0 if item[1][0] is None else float(item[1][0]),
                          item[1][1]))
    return [pair for pair, _ in ordered[-REPORTED_CAP:]]


def write_anchor_file(path, anchor_epoch, reported, now_epoch):
    """Atomic write of anchor + reported set. Raises OSError like any write."""
    body = json.dumps({
        "anchor": iso(anchor_epoch),
        "reported": list(reported),
        "written_at": iso(now_epoch),
        "schema": ANCHOR_SCHEMA,
    }, indent=2) + "\n"
    write_atomic(path, body)
    return body


def reset_anchor(path):
    """``--reset-anchor``: drop the stored anchor and reported set, nothing else."""
    shown = display_path(path)
    state, problem = read_anchor_file(path)
    if state is None and problem == "missing":
        print("anchor: nothing to remove at %s" % shown, file=sys.stderr)
        return EXIT_OK
    if state is None:
        print("anchor: removed %s (was %s)" % (shown, problem), file=sys.stderr)
    else:
        print("anchor: removed %s (anchor %s, %d reported pair(s) dropped)"
              % (shown, state["anchor_text"] or "none", len(state["reported"])),
              file=sys.stderr)
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    except OSError as exc:
        print("anchor: could not remove %s (%s: %s)"
              % (shown, type(exc).__name__, exc), file=sys.stderr)
        return EXIT_PROGRAMMING
    return EXIT_OK


def anchor_notes(record):
    """The stderr lines that say where the window came from and what was held back."""
    shown = display_path(record["path"])
    notes = []
    problem = record.get("problem")
    if problem == "missing":
        notes.append("anchor: no stored anchor at %s" % shown)
    elif problem:
        notes.append("anchor: %s unusable (%s)" % (shown, problem))
    if record.get("since") is None:
        notes.append("anchor: none (%s)" % (record.get("reason") or "unknown"))
    else:
        notes.append("anchor: %s %s" % (record["source"], iso(record["since"])))
    already = record.get("already") or []
    if already:
        notes.append("anchor: %d completion(s) previously reported, held back: %s%s"
                     % (len(already), ", ".join(already[:5]),
                        " ..." if len(already) > 5 else ""))
    else:
        notes.append("anchor: 0 completions previously reported")
    return notes


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
        return None, "board db %s missing" % display_path(db_path)
    # ``mode=ro`` needs an existing ``-shm``: with no writer attached the open
    # fails with "unable to open database file" (measured 2026-10-23: 22 of 40
    # and 34 of 60 attempts on the live board, every failure without a -shm).
    # So choose by what the WAL holds: content means a committed row lives
    # there and only a real WAL read sees it; absent or empty means
    # ``immutable=1`` has nothing to miss and does not need the -shm.
    wal_path = db_path + "-wal"
    try:
        wal_size = os.path.getsize(wal_path)
    except FileNotFoundError:
        wal_size = 0
    except OSError:
        # Cannot size an existing -wal: assume it holds something, so the
        # honest WAL read wins over a silent undercount.
        wal_size = 1
    if wal_size > 0:
        uri = "file:%s?mode=ro" % db_path
    else:
        uri = "file:%s?immutable=1" % db_path
    try:
        connection = sqlite3.connect(uri, uri=True, timeout=5)
        try:
            cursor = connection.execute(
                "SELECT id, title, status, assignee, completed_at, created_at,"
                " last_failure_error FROM tasks WHERE status != 'archived'")
            row = cursor.fetchall()
        finally:
            connection.close()
    except sqlite3.Error as exc:
        return None, "board db unreadable (%s: %s)" % (type(exc).__name__, exc)
    cards = []
    for item in row:
        cards.append({
            "id": item[0], "title": item[1], "status": item[2], "assignee": item[3],
            "completed_at": item[4], "created_at": item[5],
            "last_failure_error": item[6],
        })
    return cards, None


def board_from_fixture(path):
    """``(cards, anchor, problem)``: a fixture board and its own anchor field.

    A fixture may be a bare list or ``{"cards": [...], "anchor": "<stamp>"}``.
    The anchor is the fixture's window start; it is never host state, and one
    that does not parse is treated as absent rather than failing the run.
    """
    payload, problem = read_json_file(path)
    if problem:
        return None, None, "board fixture %s" % problem
    fixture_anchor = None
    if isinstance(payload, dict):  # tolerate {"cards": [...]} as well as a bare list
        fixture_anchor = parse_epoch(payload.get("anchor"))
        payload = payload.get("cards")
    if not isinstance(payload, list):
        return None, None, "board fixture is not a list"
    return payload, fixture_anchor, None


# ------------------------------------------------------------------- bucketing
def bucket(cards, since_epoch):
    """Split the board into the four non-overlapping buckets plus lists.

    ``finished`` is ``None`` when ``since_epoch`` is ``None``: a window with no
    start has no measured finished count, and a zero would be a claim the run
    cannot make. A completion counts only when it is *strictly after* the
    window start: the start is the moment the last good brief ended, and that
    brief already spoke for it. The other three buckets are present tense and
    always count.
    """
    finished, blocked, failed, running, needs_me = [], [], [], [], []
    for card in cards:
        status = card["status"]
        if status == "done":
            completed = card["completed_at"]
            if completed is not None and since_epoch is not None and completed > since_epoch:
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
    return (finished if since_epoch is not None else None), blocked, failed, running, needs_me


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

    target = digest_path or DEFAULT_DIGEST
    payload, problem = read_json_file(target)
    if problem:
        if problem != "missing":
            # The file is there and will not parse: name it. Calling that a
            # missing tool would blame a cause this run did not find.
            return {"available": False,
                    "reason": "digest at %s is unreadable (%s)"
                              % (display_path(target),
                                 problem.replace("unreadable: ", ""))}, []
        installed = shutil.which("bridge-digest") or shutil.which("bridge-digest.sh")
        if not installed:
            return {"available": False, "reason": "bridge-digest not on this host"}, []
        return {"available": False,
                "reason": "bridge-digest installed but no digest at %s"
                          % display_path(target)}, []
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
# An absence line names the run, not the host: the JSON reason holds the cause
# (a fixture that supplied no file, a file that did not parse, a probe removed
# by contract), and the text only points there. "not on this host" was a claim
# the fixture and unreadable cases never established.
ABSENT_DIGEST_LINE = "Digest: not available this run (reason in brief.json)."
ABSENT_SLACK_LINE = "Slack: no unread count this run (reason in brief.json)."


def digest_line(digest):
    if digest.get("available"):
        return ("Digest: %d blocked, %d stalled, %d dead events."
                % (digest.get("blocked", 0), digest.get("stalled", 0),
                   digest.get("dead_events", 0)))
    return ABSENT_DIGEST_LINE


def slack_line(slack):
    if slack.get("available"):
        return "Slack: %d unread." % (slack.get("unread") or 0)
    return ABSENT_SLACK_LINE


def render_unreadable_lines(payload):
    """brief.txt when the board could not be read: the reason, never zeros."""
    reason = text(payload.get("reason")
                  or (payload.get("board") or {}).get("reason")
                  or "board not read", limit=160)
    lines = [
        "Board unreadable: %s" % reason,
        "Mac fleet: not measured this run.",
        "Needs you: unknown.",
        digest_line(payload.get("digest") or {}),
        slack_line(payload.get("slack") or {}),
    ]
    return lines


def render_lines(payload):
    """Five short plain lines: the same numbers as brief.json, nothing new."""
    if payload.get("ok") is False:
        return render_unreadable_lines(payload)
    fleet = payload["fleet"]
    if fleet.get("finished") is None:
        # A window with no start has no finished count. Say that, never 0.
        lines = [
            "Mac fleet: finished not measured (window start unknown); "
            "%d blocked, %d failed, %d running."
            % (fleet["blocked"], fleet["failed"], fleet["still_running"]),
        ]
    else:
        lines = [
            "Mac fleet since %s: %d finished, %d blocked, %d failed, %d running."
            % (payload["since"] or "unknown",
               fleet["finished"], fleet["blocked"], fleet["failed"],
               fleet["still_running"]),
        ]

    needs = payload["needs_me"]
    if needs:
        shown = [n["title"] for n in needs[:NEEDS_ME_SHOWN]]
        more = len(needs) - len(shown)
        suffix = " (+%d more)" % more if more > 0 else ""
        lines.append("Needs you: %s%s." % (", ".join(shown), suffix))
    else:
        lines.append("Needs you: nothing.")

    if fleet.get("finished") is None:
        lines.append("Latest done: not measured in an unknown window.")
    elif payload["highlights"]:
        top = payload["highlights"][0]
        who = " (%s)" % top["assignee"] if top.get("assignee") else ""
        lines.append("Latest done: %s%s." % (top["title"], who))
    else:
        lines.append("Nothing finished in this window.")

    lines.append(digest_line(payload["digest"]))
    lines.append(slack_line(payload["slack"]))
    return lines


# ------------------------------------------------------------------ generation
def _resolve_named(path, label):
    """Absolute path for a named file, or ArgError (exit 2) when it is absent."""
    resolved = os.path.abspath(os.path.expanduser(path))
    if not os.path.isfile(resolved):
        raise ArgError("%s not found: %s" % (label, resolved))
    return resolved


def fixture_mode(args):
    """True when the run must not touch the live host at all."""
    return bool(getattr(args, "fixture", None) or getattr(args, "board_fixture", None))


def apply_fixture(args):
    """``--fixture PATH``: the shared feed-contract switch.

    A directory must hold ``board.json`` (``digest.json`` and ``slack.json`` are
    optional); a file is taken as the board. The specific
    ``--board-fixture``/``--digest-fixture``/``--slack-fixture`` flags win over
    whatever the directory supplies. Every named path is validated here, so a
    missing one is exit 2 before any host state is touched. Idempotent.
    """
    path = getattr(args, "fixture", None)
    if path:
        resolved = os.path.abspath(os.path.expanduser(path))
        if os.path.isdir(resolved):
            if not os.path.isfile(os.path.join(resolved, "board.json")):
                raise ArgError("fixture directory has no board.json: %s" % resolved)
            for attribute, name in (("board_fixture", "board.json"),
                                    ("digest_fixture", "digest.json"),
                                    ("slack_fixture", "slack.json")):
                candidate = os.path.join(resolved, name)
                if not getattr(args, attribute, None) and os.path.isfile(candidate):
                    setattr(args, attribute, candidate)
        elif os.path.isfile(resolved):
            if not getattr(args, "board_fixture", None):
                args.board_fixture = resolved
        else:
            raise ArgError("fixture path not found: %s" % resolved)
    for attribute, label in (("board_fixture", "--board-fixture"),
                             ("digest_fixture", "--digest-fixture"),
                             ("slack_fixture", "--slack-fixture")):
        value = getattr(args, attribute, None)
        if value:
            setattr(args, attribute, _resolve_named(value, label))
    if getattr(args, "digest", None):
        args.digest = _resolve_named(args.digest, "--digest")
    return args


def generate(args):
    """Build the brief dict + text. Pure: no writes, no clock beyond ``now``."""
    args = apply_fixture(args)
    fixtures_only = fixture_mode(args)
    source = "fixture" if fixtures_only else "live"
    now = parse_epoch(args.now) if args.now is not None else utc_now()
    if now is None:
        raise ArgError("--now is not a timestamp")

    # Board.
    fixture_anchor = None
    if args.board_fixture:
        raw_cards, fixture_anchor, board_problem = board_from_fixture(args.board_fixture)
        board_source = "fixture"
    else:
        raw_cards, board_problem = board_from_cli()
        board_source = "cli"
        if raw_cards is None:
            raw_cards, db_problem = board_from_db()
            board_source = "db"
            if raw_cards is None:
                board_problem = "%s; %s" % (board_problem, db_problem)
    cards = None
    if raw_cards is not None:
        cards = [card for card in (normalise_card(item) for item in raw_cards)
                 if card is not None]
        if raw_cards and not cards:
            # A non-empty board of rows that are not cards is unreadable, not an
            # empty board: nothing in it can be counted, so say that. A mixed
            # list stays tolerant, because the card rows in it are real.
            cards = None
            board_problem = ("board has %d row(s) and none is a card (no row "
                             "carries an id)" % len(raw_cards))

    # Anchor: where the window starts. Live mode reads the brief's own anchor
    # file and nothing else -- brief.json is the deck's cache, not evidence of
    # time passing. Boot time is the first-run fallback only: once a stored
    # anchor exists, kern.boottime is never consulted, or a run that could not
    # read the board would re-open a window the last good run had closed.
    # Fixture mode never reads or writes that file (fixture purity).
    local_out = os.path.abspath(os.path.expanduser(
        getattr(args, "out", None) or DEFAULT_OUT))
    stored_path = anchor_path(local_out)
    stored = None                 # the parsed anchor file, when there is one
    stored_problem = None         # why it could not supply an anchor
    reported = []                 # pairs already reported, oldest first
    anchor_epoch = None
    since_reason = None

    if args.since is not None:
        since_epoch = parse_epoch(args.since)
        if since_epoch is None:
            raise ArgError("--since is not a timestamp")
        since_source = "override"
    elif fixtures_only:
        boot_hint = parse_epoch(args.boot) if args.boot is not None else None
        if boot_hint is not None:
            anchor_epoch, since_source = boot_hint, "boot"
        elif fixture_anchor is not None:
            anchor_epoch, since_source = fixture_anchor, "fixture"
        else:
            anchor_epoch, since_source = None, "none"
            since_reason = ("fixture mode: no --since, no --boot and no anchor "
                            "field in the board fixture")
        since_epoch = anchor_epoch
    else:
        stored, stored_problem = read_anchor_file(stored_path)
        if stored is not None:
            reported = stored["reported"]
            anchor_epoch = stored["anchor"]
        if anchor_epoch is not None:
            since_source = "stored"
        else:
            boot = parse_epoch(args.boot) if args.boot is not None else boot_epoch()
            if boot is not None:
                anchor_epoch, since_source = boot, "boot"
            else:
                anchor_epoch, since_source = None, "none"
                since_reason = ("no stored anchor at %s, no readable boot time "
                                "and no --since" % display_path(stored_path))
        since_epoch = anchor_epoch

    # Digest: fixture mode never reads the host digest.
    if args.digest_fixture:
        digest, digest_needs_me = build_digest_block(args.digest_fixture, True)
    elif args.digest:
        digest, digest_needs_me = build_digest_block(args.digest, False)
    elif fixtures_only:
        digest, digest_needs_me = ({"available": False,
                                    "reason": "fixture mode: no digest.json fixture "
                                              "supplied"}, [])
    else:
        digest, digest_needs_me = build_digest_block(None, False)

    # Slack: the live path makes no network call (LIVE_SLACK_REASON).
    if args.slack_fixture:
        slack = slack_from_fixture(args.slack_fixture,
                                   "no slack fixture on this host")
    elif fixtures_only:
        slack = {"available": False, "unread": None,
                 "reason": "fixture mode: no slack.json fixture supplied"}
    elif args.no_slack:
        slack = {"available": False, "unread": None,
                 "reason": "slack probe disabled with --no-slack"}
    else:
        slack = {"available": False, "unread": None, "reason": LIVE_SLACK_REASON}

    # An unread board is not an empty board: no counts, just the reason.
    if cards is None:
        problem = text(board_problem, limit=240) or "board not read"
        return {
            "ok": False,
            "generated_at": iso(now),
            "source": source,
            "reason": problem,
            "since": iso(since_epoch),
            "since_source": since_source,
            "fleet": {"finished": None, "blocked": None, "failed": None,
                      "still_running": None},
            "highlights": [],
            "needs_me": [],
            "slack": slack,
            "digest": digest,
            "phrasing": UNREADABLE_PHRASING,
            "board": {"source": board_source, "cards": None, "reason": problem},
        }

    finished, blocked, failed, running, needs_me = bucket(cards, since_epoch)
    for entry in digest_needs_me:
        if not any(existing["id"] == entry["id"] for existing in needs_me):
            needs_me.append(entry)

    # Dedupe against the pairs a past brief already reported. The set is
    # consulted over the whole board, not only over this window: a card the last
    # good brief named stays named after the anchor has moved past it, so a
    # re-anchor can never quietly report it a second time.
    reported_set = set(reported)
    already = []
    if reported_set:
        for card in cards:
            if (card["status"] == "done" and card["completed_at"] is not None
                    and pair_key(card) in reported_set):
                already.append(pair_key(card))
        already.sort(key=lambda pair: (-(pair_epoch(pair) or 0), pair))
    if finished is not None:
        finished = [card for card in finished if pair_key(card) not in reported_set]

    finished_count = None if finished is None else len(finished)
    payload = {
        "ok": True,
        "generated_at": iso(now),
        "source": source,
        "since": iso(since_epoch),
        "since_source": since_source,
    }
    if finished_count is None:
        payload["finished_reason"] = since_reason or "window start unknown"
    payload.update({
        "fleet": {
            "finished": finished_count,
            "blocked": len(blocked),
            "failed": len(failed),
            "still_running": len(running),
        },
        "highlights": build_highlights(finished or []),
        "needs_me": [{"id": card["id"], "title": card["title"], "status": "blocked"}
                     for card in needs_me],
        "slack": slack,
        "digest": digest,
        "phrasing": PHRASING if finished_count is not None else UNKNOWN_WINDOW_PHRASING,
        "board": {"source": board_source, "cards": len(cards)},
    })
    if board_problem:
        payload["board"]["reason"] = text(board_problem, limit=200)

    # What main() persists: the window this brief ended at (the run's own clock,
    # so the next good run never has to ask the boot time again) and the pairs
    # it just reported. A readable board with an unknown window still advances
    # the anchor -- nothing was counted, but the next run then has a start.
    brief = Brief(payload)
    if not fixtures_only:
        fresh = [(card["completed_at"], pair_key(card)) for card in (finished or [])]
        brief.anchor_record = {
            "path": stored_path,
            "anchor": now,
            "since": since_epoch,
            "reported": merge_reported(reported, fresh),
            "new": len(fresh),
            "source": since_source,
            "problem": stored_problem,
            "already": already,
            "reason": since_reason,
        }
    return brief


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

    # 6. Missing digest does not raise and is not invented. In fixture mode the
    #    host digest is off limits, so the absence comes from fixture mode.
    missing_args = argparse.Namespace(
        board_fixture=FIXTURE_BOARD, digest_fixture=None, slack_fixture=FIXTURE_SLACK,
        digest=None, now=str(GOLDEN_NOW),
        boot=str(GOLDEN_BOOT), since=None, out=os.path.join(scratch, "missing-out"),
        no_slack=False, slack_env=DEFAULT_SLACK_ENV)
    missing = generate(missing_args)
    check("missing digest is an honest absence",
          missing["digest"]["available"] is False
          and "fixture mode" in (missing["digest"].get("reason") or ""),
          repr(missing["digest"]), report)
    check("missing digest does not change the board facts",
          missing["fleet"] == payload["fleet"], repr(missing["fleet"]), report)
    named_digest_raised = False
    try:
        generate(argparse.Namespace(
            board_fixture=FIXTURE_BOARD, digest_fixture=None, slack_fixture=None,
            digest=os.path.join(scratch, "no-such-digest.json"), now=str(GOLDEN_NOW),
            boot=str(GOLDEN_BOOT), since=None, out=os.path.join(scratch, "missing-out"),
            no_slack=True, slack_env=DEFAULT_SLACK_ENV))
    except ArgError:
        named_digest_raised = True
    check("a named missing --digest is a bad argument", named_digest_raised, "", report)

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
          and ABSENT_SLACK_LINE in text_body, "", report)
    check("slack absence line does not claim a host fact",
          "not on this host" not in text_body, "", report)

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

    # 11. The live path is exercised once: it must answer, not raise, and an
    #     ok:true answer must carry a board that was actually read (the old
    #     check passed on a fabricated zero brief too).
    live = generate(argparse.Namespace(
        board_fixture=None, digest_fixture=None, slack_fixture=None, digest=None,
        now=None, boot=None, since=None, out=os.path.join(scratch, "live-out"),
        no_slack=True, slack_env=DEFAULT_SLACK_ENV))
    live_numbers = live["fleet"]
    live_ints = all(isinstance(value, int) and not isinstance(value, bool)
                    for value in live_numbers.values())
    # A machine with no readable boot time and no previous live brief reports
    # finished as null with a reason; that is an honest answer too.
    live_unmeasured = (live_numbers.get("finished") is None
                       and bool(live.get("finished_reason"))
                       and all(isinstance(live_numbers.get(key), int)
                               and not isinstance(live_numbers.get(key), bool)
                               for key in ("blocked", "failed", "still_running")))
    live_sum = sum(value for value in live_numbers.values()
                   if isinstance(value, int) and not isinstance(value, bool))
    live_read = (live["ok"] is True
                 and live["board"]["source"] in ("cli", "db")
                 and isinstance(live["board"].get("cards"), int)
                 and not isinstance(live["board"].get("cards"), bool)
                 and (live_ints or live_unmeasured)
                 and live_sum <= live["board"]["cards"]
                 and ((live["board"]["source"] == "cli"
                       and not live["board"].get("reason"))
                      or (live["board"]["source"] == "db"
                          and bool(live["board"].get("reason")))))
    live_absent = (live["ok"] is False and bool(live.get("reason"))
                   and live["board"]["cards"] is None
                   and all(value is None for value in live["fleet"].values()))
    check("live board answers", live_read or live_absent,
          repr(live.get("board")), report)
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

    # 13. Phrasing: a placeholder with spaces inside the braces is caught too.
    spaced = unresolved_placeholders("x {fleet.finished} y { fleet.finishd }", payload)
    check("phrasing catches a spaced placeholder typo",
          spaced == [" fleet.finishd "], repr(spaced), report)

    # 14. The live path makes no network calls, and Slack says why with the
    #     2026-10-23 finding as a fixed reason.
    import urllib.request
    real_urlopen = urllib.request.urlopen
    network_attempts = []

    def recording_urlopen(request, *args, **kwargs):
        network_attempts.append(request)
        raise AssertionError("network call attempted")

    urllib.request.urlopen = recording_urlopen
    try:
        offnet = generate(argparse.Namespace(
            board_fixture=None, digest_fixture=None, slack_fixture=None, digest=None,
            now=str(GOLDEN_NOW), boot=str(GOLDEN_BOOT), since=None,
            out=os.path.join(scratch, "offnet-out"), no_slack=False,
            slack_env=DEFAULT_SLACK_ENV))
    finally:
        urllib.request.urlopen = real_urlopen
    check("live path makes no network calls", not network_attempts,
          repr(network_attempts), report)
    check("live slack reports the 2026-10-23 finding",
          offnet["slack"]["available"] is False
          and offnet["slack"]["reason"] == LIVE_SLACK_REASON,
          repr(offnet["slack"]), report)

    # 15. Fixture mode reads no host state: digest and boot time are off limits.
    board_only_dir = os.path.join(scratch, "board-only-dir")
    os.makedirs(board_only_dir, exist_ok=True)
    with open(FIXTURE_BOARD, "r", encoding="utf-8") as handle:
        write_atomic(os.path.join(board_only_dir, "board.json"), handle.read())

    planted_digest = os.path.join(scratch, "planted-digest.json")
    write_atomic(planted_digest, json.dumps({
        "generated_at": "2026-10-23T00:00:00Z",
        "blocked": [{"id": "t_planted", "title": "planted host digest"}],
        "stalled": 1, "dead_events": 1}) + "\n")
    saved_default_digest = globals()["DEFAULT_DIGEST"]
    globals()["DEFAULT_DIGEST"] = planted_digest
    try:
        planted = generate(argparse.Namespace(
            fixture=board_only_dir, board_fixture=None, digest_fixture=None,
            slack_fixture=None, digest=None, now=str(GOLDEN_NOW),
            boot=None, since=None, out=os.path.join(scratch, "planted-out"),
            no_slack=False, slack_env=DEFAULT_SLACK_ENV))
    finally:
        globals()["DEFAULT_DIGEST"] = saved_default_digest
    check("fixture mode never reads the host digest",
          planted["digest"]["available"] is False
          and all(n["id"] != "t_planted" for n in planted["needs_me"]),
          repr(planted["digest"]), report)
    planted_text = "\n".join(render_lines(planted))
    check("absence text points at brief.json, not at the host",
          ABSENT_DIGEST_LINE in planted_text and ABSENT_SLACK_LINE in planted_text
          and "not on this host" not in planted_text,
          repr(planted_text), report)

    saved_boot_epoch = globals()["boot_epoch"]
    boot_calls = []

    def recording_boot_epoch():
        boot_calls.append(1)
        return GOLDEN_BOOT

    globals()["boot_epoch"] = recording_boot_epoch
    try:
        no_boot = generate(argparse.Namespace(
            fixture=board_only_dir, board_fixture=None, digest_fixture=None,
            slack_fixture=None, digest=None, now=str(GOLDEN_NOW),
            boot=None, since=None, out=os.path.join(scratch, "noboot-out"),
            no_slack=True, slack_env=DEFAULT_SLACK_ENV))
    finally:
        globals()["boot_epoch"] = saved_boot_epoch
    check("fixture mode never asks sysctl for the boot time",
          not boot_calls and no_boot["since"] is None
          and no_boot["since_source"] == "none",
          repr((boot_calls, no_boot["since"])), report)

    # 16. Fixture mode never returns the host cache, even a fresh brief.json.
    import contextlib
    import io

    def quiet_main(argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = main(argv)
        return code, out.getvalue(), err.getvalue()

    cache_out = os.path.join(scratch, "cache-out")
    os.makedirs(cache_out, exist_ok=True)
    planted_brief = {
        "ok": True, "generated_at": iso(utc_now() - 5), "source": "live",
        "since": None, "since_source": "none",
        "fleet": {"finished": 999, "blocked": 0, "failed": 0, "still_running": 0},
        "highlights": [], "needs_me": [],
        "slack": {"available": False, "unread": None, "reason": "planted"},
        "digest": {"available": False, "reason": "planted"},
        "phrasing": PHRASING, "board": {"source": "cli", "cards": 1},
    }
    write_atomic(os.path.join(cache_out, "brief.json"),
                 json.dumps(planted_brief) + "\n")
    cache_rc, cache_stdout, cache_stderr = quiet_main(
        ["--fixture", board_only_dir, "--out", cache_out, "--json"])
    check("fixture mode never returns the host cache",
          cache_rc == EXIT_OK and "brief cached" not in cache_stderr
          and '"finished": 999' not in cache_stdout
          and '"source": "fixture"' in cache_stdout,
          "rc=%r stderr=%r" % (cache_rc, cache_stderr.strip()[:120]), report)

    # 17. Named missing paths and an empty fixture directory are exit 2, and
    #     nothing is written to --out.
    rc_out = os.path.join(scratch, "rc-out")
    named_paths = [
        ("--fixture", ["--fixture", os.path.join(scratch, "no-such-fixture.json")]),
        ("--board-fixture", ["--board-fixture", os.path.join(scratch, "no-such-board.json")]),
        ("--slack-fixture", ["--slack-fixture", os.path.join(scratch, "no-such-slack.json")]),
        ("--digest-fixture", ["--digest-fixture", os.path.join(scratch, "no-such-digest.json")]),
    ]
    empty_fixture_dir = os.path.join(scratch, "empty-fixture-dir")
    os.makedirs(empty_fixture_dir, exist_ok=True)
    named_paths.append(("--fixture empty dir", ["--fixture", empty_fixture_dir]))
    bad_codes = []
    for label, argv in named_paths:
        code, _, _ = quiet_main(argv + ["--out", rc_out])
        if code != EXIT_PROGRAMMING:
            bad_codes.append((label, code))
    check("named missing paths exit 2", not bad_codes, repr(bad_codes), report)
    check("a bad path writes nothing", not os.path.exists(rc_out), rc_out, report)

    # 18. An unreadable board is ok:false with no counts, never fabricated zeros.
    stub_dir = os.path.join(scratch, "stub-bin")
    os.makedirs(stub_dir, exist_ok=True)
    stub_hermes = os.path.join(stub_dir, "hermes")
    write_atomic(stub_hermes, "#!/bin/sh\nexit 1\n")
    os.chmod(stub_hermes, 0o755)
    saved_path = os.environ.get("PATH", "")
    saved_db_env = os.environ.get("HERMES_KANBAN_DB")
    os.environ["PATH"] = stub_dir + os.pathsep + saved_path
    os.environ["HERMES_KANBAN_DB"] = os.path.join(scratch, "no-such-board.db")
    try:
        unreadable_args = argparse.Namespace(
            board_fixture=None, digest_fixture=None, slack_fixture=None, digest=None,
            now=str(GOLDEN_NOW), boot=str(GOLDEN_BOOT), since=None,
            out=os.path.join(scratch, "unreadable-out"), no_slack=True,
            slack_env=DEFAULT_SLACK_ENV)
        unreadable = generate(unreadable_args)
        unreadable_rc, _, _ = quiet_main([
            "--no-slack", "--json", "--now", str(GOLDEN_NOW),
            "--boot", str(GOLDEN_BOOT),
            "--out", os.path.join(scratch, "unreadable-out")])
    finally:
        os.environ["PATH"] = saved_path
        if saved_db_env is None:
            os.environ.pop("HERMES_KANBAN_DB", None)
        else:
            os.environ["HERMES_KANBAN_DB"] = saved_db_env
    unreadable_lines = render_lines(unreadable)
    unreadable_text = "\n".join(unreadable_lines)
    check("unreadable board is ok:false with no counts",
          unreadable["ok"] is False and bool(unreadable.get("reason"))
          and all(value is None for value in unreadable["fleet"].values())
          and unreadable["board"]["cards"] is None
          and unreadable["highlights"] == [] and unreadable["needs_me"] == [],
          repr(unreadable.get("fleet")), report)
    check("unreadable board phrasing resolves",
          not unresolved_placeholders(unreadable["phrasing"], unreadable),
          repr(unreadable["phrasing"]), report)
    check("unreadable board brief.txt leads with Board unreadable",
          unreadable_lines[0].startswith("Board unreadable")
          and "0 finished" not in unreadable_text
          and "Needs you: nothing." not in unreadable_text,
          repr(unreadable_lines[0][:140]), report)
    check("unreadable board is still exit 0", unreadable_rc == EXIT_OK,
          repr(unreadable_rc), report)

    # 19. A malformed board fixture is ok:false too (a missing one is exit 2).
    bad_fixture = os.path.join(scratch, "bad-board.json")
    write_atomic(bad_fixture, "{not json\n")
    bad = generate(argparse.Namespace(
        board_fixture=bad_fixture, digest_fixture=None, slack_fixture=None,
        digest=None, now=str(GOLDEN_NOW), boot=str(GOLDEN_BOOT), since=None,
        out=os.path.join(scratch, "bad-out"), no_slack=True,
        slack_env=DEFAULT_SLACK_ENV))
    check("malformed board fixture is ok:false, not zeros",
          bad["ok"] is False and bad["board"]["source"] == "fixture"
          and bad["board"]["cards"] is None
          and all(value is None for value in bad["fleet"].values()),
          repr(bad.get("fleet")), report)

    # 20. The Slack probe's reason says what each call answered, and it only
    #     reads SLACK_BOT_TOKEN.
    probe_env = os.path.join(scratch, "slack.env")
    write_atomic(probe_env, "SLACK_BOT_TOKEN=xoxb-test\nSLACK_HOME_CHANNEL=C123\n")
    user_env = os.path.join(scratch, "slack-user.env")
    write_atomic(user_env, "SLACK_USER_TOKEN=xoxp-test\nSLACK_HOME_CHANNEL=C123\n")
    real_slack_call = globals()["slack_call"]

    def slack_stub_failed_info(token, method, timeout=6, **params):
        if method == "auth.test":
            return {"ok": True}
        if method == "conversations.list":
            return {"ok": True, "channels": [{"id": "C123"}]}
        return {"ok": False, "error": "channel_not_found"}

    def slack_stub_null_unread(token, method, timeout=6, **params):
        if method == "auth.test":
            return {"ok": True}
        if method == "conversations.list":
            return {"ok": True, "channels": [{"id": "C123"}]}
        return {"ok": True, "channel": {"id": "C123", "unread_count": None}}

    def slack_stub_missing_unread(token, method, timeout=6, **params):
        if method == "auth.test":
            return {"ok": True}
        if method == "conversations.list":
            return {"ok": True, "channels": [{"id": "C123"}]}
        return {"ok": True, "channel": {"id": "C123"}}

    def slack_stub_ok(token, method, timeout=6, **params):
        if method == "auth.test":
            return {"ok": True}
        if method == "conversations.list":
            return {"ok": True, "channels": [{"id": "C123"}]}
        return {"ok": True, "channel": {"id": "C123", "unread_count": 3,
                                        "name": "hq"}}

    try:
        globals()["slack_call"] = slack_stub_failed_info
        failed_info = probe_slack(probe_env)
        globals()["slack_call"] = slack_stub_null_unread
        null_unread = probe_slack(probe_env)
        globals()["slack_call"] = slack_stub_missing_unread
        missing_unread = probe_slack(probe_env)
        globals()["slack_call"] = slack_stub_ok
        user_only = probe_slack(user_env)
        good = probe_slack(probe_env)
    finally:
        globals()["slack_call"] = real_slack_call
    check("slack reason names a failed conversations.info",
          failed_info["available"] is False
          and "channel_not_found" in failed_info["reason"]
          and "unread_count is null" not in failed_info["reason"],
          repr(failed_info["reason"]), report)
    check("slack reason says unread_count null only when it was null",
          null_unread["available"] is False
          and "unread_count is null" in null_unread["reason"],
          repr(null_unread["reason"]), report)
    check("slack reason says a missing field is missing, not null",
          missing_unread["available"] is False
          and "carries no unread_count field" in missing_unread["reason"]
          and "unread_count is null" not in missing_unread["reason"],
          repr(missing_unread["reason"]), report)
    check("slack probe ignores SLACK_USER_TOKEN",
          user_only["available"] is False
          and "SLACK_BOT_TOKEN" in user_only["reason"],
          repr(user_only["reason"]), report)
    check("slack probe still answers when every call is ok",
          good["available"] is True and good["unread"] == 3,
          repr(good), report)

    # 21. Board DB: mode=ro while the WAL holds a committed row (immutable=1
    #     would miss it), and immutable=1 when there is no -wal file, because a
    #     mode=ro open needs a -shm that only a writer creates.
    import sqlite3

    saved_connect = sqlite3.connect
    wal_db = os.path.join(scratch, "wal-board.db")
    writer = sqlite3.connect(wal_db)
    try:
        writer.execute("PRAGMA journal_mode=WAL")
        writer.execute(
            "CREATE TABLE tasks (id TEXT, title TEXT, status TEXT, assignee TEXT,"
            " completed_at INTEGER, created_at INTEGER, last_failure_error TEXT)")
        writer.execute("INSERT INTO tasks VALUES"
                       " ('t_wal1','checkpointed','done','kakashi',1,1,NULL)")
        writer.commit()
        writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        writer.execute("INSERT INTO tasks VALUES"
                       " ('t_wal2','still in wal','blocked','yamato',NULL,2,NULL)")
        writer.commit()
        wal_cards, wal_reason = board_from_db(wal_db)
        wal_ids = sorted(card["id"] for card in (wal_cards or []))
        check("board db sees a committed row still in the WAL",
              wal_cards is not None and wal_ids == ["t_wal1", "t_wal2"],
              repr((wal_ids, wal_reason)), report)

        opened_uris = []

        def failing_readonly(target, *args, **kwargs):
            opened_uris.append(str(target))
            if "mode=ro" in str(target):
                raise sqlite3.OperationalError("simulated refusal")
            return saved_connect(target, *args, **kwargs)

        sqlite3.connect = failing_readonly
        try:
            refused, refused_reason = board_from_db(wal_db)
        finally:
            sqlite3.connect = saved_connect
        check("board db uses mode=ro while the WAL has content",
              refused is None and "simulated refusal" in (refused_reason or "")
              and len(opened_uris) == 1 and "mode=ro" in opened_uris[0],
              repr((refused_reason, opened_uris)), report)
    finally:
        sqlite3.connect = saved_connect
        writer.close()

    # No -wal file is the live failure mode: mode=ro raised "unable to open
    # database file" with no -shm, and immutable=1 read it every time.
    plain_db = os.path.join(scratch, "plain-board.db")
    plain_writer = sqlite3.connect(plain_db)
    try:
        plain_writer.execute("PRAGMA journal_mode=DELETE")
        plain_writer.execute(
            "CREATE TABLE tasks (id TEXT, title TEXT, status TEXT, assignee TEXT,"
            " completed_at INTEGER, created_at INTEGER, last_failure_error TEXT)")
        plain_writer.execute("INSERT INTO tasks VALUES"
                             " ('t_plain1','no wal','done','levi',1,1,NULL)")
        plain_writer.commit()
    finally:
        plain_writer.close()
    check("a closed database leaves no -wal file", not os.path.exists(plain_db + "-wal"),
          plain_db, report)

    opened_uris = []

    def recording_connect(target, *args, **kwargs):
        opened_uris.append(str(target))
        return saved_connect(target, *args, **kwargs)

    sqlite3.connect = recording_connect
    try:
        plain_cards, plain_reason = board_from_db(plain_db)
        with open(plain_db + "-wal", "a", encoding="utf-8"):
            pass  # a zero-byte leftover: nothing in it to miss
        stalled_cards, stalled_reason = board_from_db(plain_db)
    finally:
        sqlite3.connect = saved_connect
    check("board db reads a database with no -wal file",
          plain_cards is not None
          and [card["id"] for card in plain_cards] == ["t_plain1"]
          and len(opened_uris) == 2 and "immutable=1" in opened_uris[0],
          repr((plain_reason, opened_uris)), report)
    check("board db reads a database with an empty -wal file",
          stalled_cards is not None
          and [card["id"] for card in stalled_cards] == ["t_plain1"]
          and "immutable=1" in opened_uris[1],
          repr((stalled_reason, opened_uris)), report)

    # 22. A window with no start has no finished count: null plus a reason,
    #     never a zero (bucket, fleet, brief.txt, phrasing).
    unknown = generate(argparse.Namespace(
        fixture=board_only_dir, board_fixture=None, digest_fixture=None,
        slack_fixture=None, digest=None, now=str(GOLDEN_NOW),
        boot=None, since=None, out=os.path.join(scratch, "unknown-out"),
        no_slack=True, slack_env=DEFAULT_SLACK_ENV))
    unknown_text = "\n".join(render_lines(unknown))
    check("unknown window reports finished as null with a reason",
          unknown["ok"] is True and unknown["since"] is None
          and unknown["since_source"] == "none"
          and unknown["fleet"]["finished"] is None
          and bool(unknown.get("finished_reason"))
          and unknown["fleet"]["blocked"] == 2
          and unknown["fleet"]["failed"] == 1
          and unknown["fleet"]["still_running"] == 2,
          repr((unknown["fleet"], unknown.get("finished_reason"))), report)
    check("unknown window brief.txt says not measured, never 0 finished",
          "finished not measured" in unknown_text
          and "0 finished" not in unknown_text
          and "Nothing finished in this window" not in unknown_text,
          repr(unknown_text), report)
    check("unknown window phrasing resolves",
          not unresolved_placeholders(unknown["phrasing"], unknown),
          repr(unknown["phrasing"]), report)

    # 23. A non-empty board whose rows are not cards is unreadable, not zero.
    noncard_path = os.path.join(scratch, "noncard-board.json")
    write_atomic(noncard_path, json.dumps([
        {"task_id": "t1", "status": "done", "completed_at": 1792709600}]) + "\n")
    noncard = generate(argparse.Namespace(
        board_fixture=noncard_path, digest_fixture=None, slack_fixture=None,
        digest=None, now=str(GOLDEN_NOW), boot=str(GOLDEN_BOOT), since=None,
        out=os.path.join(scratch, "noncard-out"), no_slack=True,
        slack_env=DEFAULT_SLACK_ENV))
    check("a board of rows that are not cards is ok:false, not zeros",
          noncard["ok"] is False and noncard["board"]["cards"] is None
          and noncard["board"]["source"] == "fixture"
          and all(value is None for value in noncard["fleet"].values())
          and "none is a card" in (noncard.get("reason") or ""),
          repr((noncard["board"], noncard.get("reason"))), report)

    # 24. Fixture writes are opt-in, and the live cache and anchor trust only a
    #     live ok brief (defect 1).
    saved_default_out = globals()["DEFAULT_OUT"]
    default_out_dir = os.path.join(scratch, "default-out")
    globals()["DEFAULT_OUT"] = default_out_dir
    try:
        no_out_rc, no_out_stdout, _ = quiet_main(["--fixture", board_only_dir, "--json"])
        no_out_written = os.path.exists(os.path.join(default_out_dir, "brief.json"))
    finally:
        globals()["DEFAULT_OUT"] = saved_default_out
    check("a fixture run with no --out writes nothing",
          no_out_rc == EXIT_OK and '"source": "fixture"' in no_out_stdout
          and not no_out_written, repr((no_out_rc, no_out_written)), report)

    live_out = os.path.join(scratch, "live-cache-out")
    os.makedirs(live_out, exist_ok=True)
    fixture_cache = dict(planted_brief)
    fixture_cache["source"] = "fixture"
    fixture_cache["generated_at"] = iso(utc_now() - 3)
    write_atomic(os.path.join(live_out, "brief.json"),
                 json.dumps(fixture_cache) + "\n")
    saved_cli = globals()["board_from_cli"]
    globals()["board_from_cli"] = lambda: ([], None)
    try:
        live_cache_rc, live_cache_stdout, live_cache_stderr = quiet_main([
            "--out", live_out, "--no-slack", "--json",
            "--now", str(GOLDEN_NOW), "--boot", str(GOLDEN_BOOT)])
    finally:
        globals()["board_from_cli"] = saved_cli
    check("a live run does not serve a fixture brief as its cache",
          live_cache_rc == EXIT_OK and "brief cached" not in live_cache_stderr
          and '"finished": 999' not in live_cache_stdout
          and '"source": "live"' in live_cache_stdout
          and '"since_source": "boot"' in live_cache_stdout,
          "rc=%r stderr=%r" % (live_cache_rc, live_cache_stderr.strip()[:140]),
          report)

    failed_cache = dict(planted_brief)
    failed_cache.update({
        "ok": False, "reason": "board unreadable",
        "generated_at": iso(utc_now() - 3),
        "fleet": {"finished": None, "blocked": None, "failed": None,
                  "still_running": None},
        "board": {"source": "db", "cards": None},
    })
    # Its own directory: the check above advanced the anchor in live_out, and
    # this one must prove a stale unreadable brief.json is not an anchor.
    failed_out = os.path.join(scratch, "failed-cache-out")
    os.makedirs(failed_out, exist_ok=True)
    write_atomic(os.path.join(failed_out, "brief.json"),
                 json.dumps(failed_cache) + "\n")
    globals()["board_from_cli"] = lambda: ([], None)
    try:
        anchor_rc, anchor_stdout, anchor_stderr = quiet_main([
            "--out", failed_out, "--no-slack", "--json",
            "--now", str(GOLDEN_NOW), "--boot", str(GOLDEN_BOOT)])
    finally:
        globals()["board_from_cli"] = saved_cli
    check("a live run does not anchor on an unreadable brief",
          anchor_rc == EXIT_OK and "brief cached" not in anchor_stderr
          and '"since_source": "boot"' in anchor_stdout,
          "rc=%r stderr=%r" % (anchor_rc, anchor_stderr.strip()[:140]), report)

    # 25. The brief's own anchor (brief_anchor.json): the round-3 repro, the
    #     resolution order, dedupe across a re-anchor, --reset-anchor, a corrupt
    #     file, the 200-pair cap, the exclusive window edge and fixture purity.
    def read_bytes(path):
        try:
            with open(path, "rb") as handle:
                return handle.read()
        except OSError:
            return None

    anchor_board = [
        {"id": "t_early", "title": "early finish", "status": "done",
         "assignee": "yamato", "completed_at": 1792650000},
        {"id": "t_run1", "title": "still running card", "status": "running",
         "assignee": "levi", "completed_at": None},
    ]
    saved_db = globals()["board_from_db"]
    anchor_out = os.path.join(scratch, "anchor-out")
    anchor_file = anchor_path(anchor_out)
    boot_stamp, good_one, good_two = 1792600000, 1792700000, 1792707200

    globals()["board_from_cli"] = lambda: (list(anchor_board), None)
    try:
        run1_rc, run1_stdout, run1_stderr = quiet_main([
            "--out", anchor_out, "--no-slack", "--json", "--force",
            "--now", str(good_one), "--boot", str(boot_stamp)])
    finally:
        globals()["board_from_cli"] = saved_cli
    run1 = json.loads(run1_stdout) if run1_stdout.strip() else {}
    run1_raw, run1_problem = read_json_file(anchor_file)
    if not isinstance(run1_raw, dict):
        run1_raw = {}
    check("first live run falls back to the boot time and writes the anchor",
          run1_rc == EXIT_OK and run1.get("ok") is True
          and run1.get("since_source") == "boot"
          and run1.get("since") == iso(boot_stamp)
          and run1.get("fleet", {}).get("finished") == 1
          and run1_problem is None
          and run1_raw.get("anchor") == iso(good_one)
          and run1_raw.get("reported") == ["t_early@1792650000"]
          and parse_epoch(run1_raw.get("written_at")) is not None
          and run1_raw.get("schema") == ANCHOR_SCHEMA,
          "rc=%r since=%r anchor_file=%r" % (
              run1_rc, run1.get("since"), run1_raw), report)

    before_bytes = read_bytes(anchor_file)
    globals()["board_from_cli"] = lambda: (None, "simulated list failure")
    globals()["board_from_db"] = lambda path=None: (None, "no board db")
    try:
        run2_rc, run2_stdout, run2_stderr = quiet_main([
            "--out", anchor_out, "--no-slack", "--json", "--force",
            "--now", str(good_one + 3600), "--boot", str(boot_stamp)])
    finally:
        globals()["board_from_cli"] = saved_cli
        globals()["board_from_db"] = saved_db
    run2 = json.loads(run2_stdout) if run2_stdout.strip() else {}
    check("an unreadable live run writes nothing and moves nothing",
          run2_rc == EXIT_OK and run2.get("ok") is False
          and read_bytes(anchor_file) == before_bytes
          and "not advanced" in run2_stderr,
          "rc=%r changed=%r stderr=%r" % (
              run2_rc, read_bytes(anchor_file) != before_bytes,
              run2_stderr.strip()[:160]), report)

    globals()["board_from_cli"] = lambda: (list(anchor_board), None)
    try:
        run3_rc, run3_stdout, run3_stderr = quiet_main([
            "--out", anchor_out, "--no-slack", "--json", "--force",
            "--now", str(good_two), "--boot", str(boot_stamp)])
    finally:
        globals()["board_from_cli"] = saved_cli
    run3 = json.loads(run3_stdout) if run3_stdout.strip() else {}
    check("the next good run keeps the stored anchor and does not re-count",
          run3_rc == EXIT_OK and run3.get("ok") is True
          and run3.get("since_source") == "stored"
          and run3.get("since") == iso(good_one)
          and run3.get("fleet", {}).get("finished") == 0
          and run3.get("highlights") == []
          and "1 completion(s) previously reported" in run3_stderr
          and "t_early@1792650000" in run3_stderr,
          "rc=%r since=%r fleet=%r stderr=%r" % (
              run3_rc, run3.get("since"), run3.get("fleet"),
              run3_stderr.strip()[:200]), report)
    stored_three, stored_problem = read_anchor_file(anchor_file)
    check("a good run advances the anchor to its own clock",
          stored_problem is None and stored_three is not None
          and stored_three["anchor"] == float(good_two)
          and stored_three["reported"] == ["t_early@1792650000"],
          repr((stored_problem, stored_three)), report)

    # A stored anchor is never overruled by a later boot time.
    precedence_out = os.path.join(scratch, "precedence-out")
    write_anchor_file(anchor_path(precedence_out), good_one,
                      ["t_early@1792650000"], good_one)
    globals()["board_from_cli"] = lambda: (list(anchor_board), None)
    try:
        prec_rc, prec_stdout, _ = quiet_main([
            "--out", precedence_out, "--no-slack", "--json", "--force",
            "--now", str(good_two), "--boot", str(good_one + 100000)])
    finally:
        globals()["board_from_cli"] = saved_cli
    prec = json.loads(prec_stdout) if prec_stdout.strip() else {}
    check("a stored anchor beats a later boot time",
          prec_rc == EXIT_OK and prec.get("since_source") == "stored"
          and prec.get("since") == iso(good_one),
          "rc=%r since=%r source=%r" % (
              prec_rc, prec.get("since"), prec.get("since_source")), report)

    # The window would include t_early again, but the pair is already reported.
    reanchor_out = os.path.join(scratch, "reanchor-out")
    write_anchor_file(anchor_path(reanchor_out), 1792640000,
                      ["t_early@1792650000"], 1792640000)
    globals()["board_from_cli"] = lambda: (list(anchor_board), None)
    try:
        re_rc, re_stdout, re_stderr = quiet_main([
            "--out", reanchor_out, "--no-slack", "--json", "--force",
            "--now", str(good_two)])
    finally:
        globals()["board_from_cli"] = saved_cli
    re_payload = json.loads(re_stdout) if re_stdout.strip() else {}
    check("a pair already reported is not counted in a re-opened window",
          re_rc == EXIT_OK and re_payload.get("since") == iso(1792640000)
          and re_payload.get("fleet", {}).get("finished") == 0
          and "1 completion(s) previously reported" in re_stderr,
          "rc=%r fleet=%r stderr=%r" % (
              re_rc, re_payload.get("fleet"), re_stderr.strip()[:180]), report)

    # --reset-anchor: anchor and set gone, brief.json untouched, and the report
    # says what it removed.
    brief_before = read_bytes(os.path.join(anchor_out, "brief.json"))
    reset_rc, _, reset_stderr = quiet_main(["--out", anchor_out, "--reset-anchor"])
    check("--reset-anchor removes the anchor and the reported set",
          reset_rc == EXIT_OK and not os.path.exists(anchor_file)
          and (iso(good_two) or "?") in reset_stderr
          and "1 reported pair(s) dropped" in reset_stderr
          and read_bytes(os.path.join(anchor_out, "brief.json")) == brief_before,
          "rc=%r exists=%r stderr=%r" % (
              reset_rc, os.path.exists(anchor_file), reset_stderr.strip()[:200]),
          report)
    again_rc, _, again_stderr = quiet_main(["--out", anchor_out, "--reset-anchor"])
    check("--reset-anchor on a missing file says so and exits 0",
          again_rc == EXIT_OK and "nothing to remove" in again_stderr,
          "rc=%r stderr=%r" % (again_rc, again_stderr.strip()[:160]), report)

    # A corrupt anchor file is absent with a reason, never a crash.
    corrupt_out = os.path.join(scratch, "corrupt-out")
    os.makedirs(corrupt_out, exist_ok=True)
    write_atomic(anchor_path(corrupt_out), "{not json\n")
    globals()["board_from_cli"] = lambda: (list(anchor_board), None)
    try:
        corrupt_rc, corrupt_stdout, corrupt_stderr = quiet_main([
            "--out", corrupt_out, "--no-slack", "--json", "--force",
            "--now", str(good_two), "--boot", str(boot_stamp)])
    finally:
        globals()["board_from_cli"] = saved_cli
    corrupt = json.loads(corrupt_stdout) if corrupt_stdout.strip() else {}
    check("a corrupt anchor file is absent with a reason, not a crash",
          corrupt_rc == EXIT_OK and corrupt.get("ok") is True
          and corrupt.get("since_source") == "boot"
          and "unusable" in corrupt_stderr
          and "JSONDecodeError" in corrupt_stderr,
          "rc=%r source=%r stderr=%r" % (
              corrupt_rc, corrupt.get("since_source"),
              corrupt_stderr.strip()[:200]), report)
    corrupt_state, corrupt_problem = read_anchor_file(anchor_path(corrupt_out))
    check("a good run replaces a corrupt anchor file",
          corrupt_problem is None and corrupt_state is not None
          and corrupt_state["anchor"] == float(good_two),
          repr((corrupt_problem, corrupt_state)), report)

    # Fixture mode: the planted anchor is neither read nor written.
    fixture_anchor_out = os.path.join(scratch, "fixture-anchor-out")
    write_anchor_file(anchor_path(fixture_anchor_out), 1792640000,
                      ["t_early@1792650000"], 1792640000)
    planted_bytes = read_bytes(anchor_path(fixture_anchor_out))
    fixture_rc, fixture_stdout, fixture_stderr = quiet_main([
        "--fixture", board_only_dir, "--out", fixture_anchor_out, "--json",
        "--now", str(GOLDEN_NOW)])
    fixture_payload = json.loads(fixture_stdout) if fixture_stdout.strip() else {}
    check("fixture mode neither reads nor writes the anchor file",
          fixture_rc == EXIT_OK and fixture_payload.get("since") is None
          and fixture_payload.get("since_source") == "none"
          and read_bytes(anchor_path(fixture_anchor_out)) == planted_bytes
          and "anchor:" not in fixture_stderr,
          "rc=%r since=%r changed=%r" % (
              fixture_rc, fixture_payload.get("since"),
              read_bytes(anchor_path(fixture_anchor_out)) != planted_bytes),
          report)

    # A fixture may carry its own anchor field.
    anchor_fixture = os.path.join(scratch, "anchor-board.json")
    write_atomic(anchor_fixture, json.dumps({
        "anchor": iso(GOLDEN_BOOT),
        "cards": [{"id": "t_fx", "title": "fixture done", "status": "done",
                   "completed_at": GOLDEN_BOOT + 60}]}) + "\n")
    fixture_field = generate(argparse.Namespace(
        board_fixture=anchor_fixture, digest_fixture=None, slack_fixture=None,
        digest=None, now=str(GOLDEN_NOW), boot=None, since=None,
        out=os.path.join(scratch, "anchor-fixture-out"), no_slack=True,
        slack_env=DEFAULT_SLACK_ENV))
    check("a fixture's own anchor field starts the window",
          fixture_field["since"] == iso(GOLDEN_BOOT)
          and fixture_field["since_source"] == "fixture"
          and fixture_field["fleet"]["finished"] == 1,
          repr((fixture_field["since"], fixture_field["since_source"],
                fixture_field["fleet"])), report)

    # The cap keeps the newest pairs.
    many_pairs = ["t_%03d@%d" % (index, 1792000000 + index) for index in range(250)]
    capped = merge_reported(many_pairs, [])
    check("the reported set keeps the newest 200 pairs",
          len(capped) == REPORTED_CAP and capped[-1] == many_pairs[-1]
          and many_pairs[0] not in capped and capped[0] == many_pairs[50],
          repr((len(capped), capped[0], capped[-1])), report)

    # The window edge is exclusive: a completion exactly at the start is the
    # previous brief's to have reported.
    edge_path = os.path.join(scratch, "edge-board.json")
    write_atomic(edge_path, json.dumps([
        {"id": "t_edge", "title": "at the edge", "status": "done",
         "completed_at": GOLDEN_BOOT},
        {"id": "t_after", "title": "one second after", "status": "done",
         "completed_at": GOLDEN_BOOT + 1}]) + "\n")
    edge = generate(argparse.Namespace(
        board_fixture=edge_path, digest_fixture=None, slack_fixture=None,
        digest=None, now=str(GOLDEN_NOW), boot=str(GOLDEN_BOOT), since=None,
        out=os.path.join(scratch, "edge-out"), no_slack=True,
        slack_env=DEFAULT_SLACK_ENV))
    check("a completion exactly at the window start is not counted",
          edge["fleet"]["finished"] == 1
          and [card["id"] for card in edge["highlights"]] == ["t_after"],
          repr((edge["fleet"], [card["id"] for card in edge["highlights"]])),
          report)

    # 26. A digest file that exists but does not parse is named, not called a
    #     missing tool.
    broken_digest = os.path.join(scratch, "broken-digest.json")
    write_atomic(broken_digest, "{not json\n")
    broken = generate(argparse.Namespace(
        board_fixture=FIXTURE_BOARD, digest_fixture=None, slack_fixture=None,
        digest=broken_digest, now=str(GOLDEN_NOW), boot=str(GOLDEN_BOOT),
        since=None, out=os.path.join(scratch, "broken-out"), no_slack=True,
        slack_env=DEFAULT_SLACK_ENV))
    broken_reason = broken["digest"].get("reason") or ""
    check("an unreadable digest names the file, not a missing tool",
          broken["digest"]["available"] is False
          and "broken-digest.json" in broken_reason
          and "not on this host" not in broken_reason,
          repr(broken["digest"]), report)

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
    parser.add_argument("--out", default=None,
                        help="run directory for brief.json and brief.txt "
                             "(default %s); a fixture run writes only when this "
                             "is given" % display_path(DEFAULT_OUT))
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
                        help="profile .env holding SLACK_BOT_TOKEN (accepted for "
                             "compatibility; the live Slack probe was removed "
                             "2026-10-23 and no longer reads it)")
    parser.add_argument("--no-slack", action="store_true",
                        help="say Slack was not probed (the live path sends no "
                             "network request either way)")
    parser.add_argument("--now", metavar="STAMP", default=None,
                        help="freeze the clock (epoch or ISO) for tests")
    parser.add_argument("--boot", metavar="STAMP", default=None,
                        help="override kern.boottime for tests")
    parser.add_argument("--since", metavar="STAMP", default=None,
                        help="override the since timestamp for tests")
    parser.add_argument("--reset-anchor", action="store_true",
                        help="remove the stored anchor and reported set "
                             "(brief_anchor.json in the run directory), print what "
                             "was removed, and exit; nothing else is touched")
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

        # Settle fixture mode before the cache check: --fixture must never read
        # the host brief, and a named missing path must exit 2 before any work.
        args = apply_fixture(args)
        out_given = args.out is not None
        out_dir = os.path.abspath(os.path.expanduser(args.out or DEFAULT_OUT))
        args.out = out_dir

        if args.reset_anchor:
            # Maintenance, not a brief: this prints and exits without touching
            # brief.json, brief.txt or anything else. A fixture run has no
            # anchor file to reset (it never reads or writes one).
            if fixture_mode(args):
                raise ArgError("--reset-anchor has nothing to reset in fixture "
                               "mode: a fixture run never reads or writes the "
                               "anchor file")
            return reset_anchor(anchor_path(out_dir))

        if not args.force and not fixture_mode(args):
            cached, problem = read_json_file(os.path.join(out_dir, "brief.json"))
            if problem is None and isinstance(cached, dict):
                # Only a live brief the previous run could stand behind is a
                # cache. A fixture brief or a run that failed to read the board
                # is not an answer to the live question, so it is ignored.
                trustable = (cached.get("ok") is True
                             and cached.get("source") == "live")
                cached_at = parse_epoch(cached.get("generated_at"))
                age = utc_now() - cached_at if cached_at is not None else None
                if trustable and age is not None and 0 <= age < CACHE_MIN_SECONDS:
                    print("brief cached: %ds old, nothing re-read" % int(age),
                          file=sys.stderr)
                    if args.json:
                        sys.stdout.write(json.dumps(cached, indent=2) + "\n")
                    else:
                        sys.stdout.write("\n".join(render_lines(cached)) + "\n")
                    return EXIT_OK

        payload = generate(args)
        record = getattr(payload, "anchor_record", None)
        if record is not None:
            for note in anchor_notes(record):
                print(note, file=sys.stderr)
        elif not fixture_mode(args):
            # The board could not be read: this run says so and leaves the
            # stored anchor exactly where the last good run put it.
            print("anchor: not advanced (no readable board this run)",
                  file=sys.stderr)
        if fixture_mode(args) and not out_given:
            # A fixture run writes nothing unless --out names a directory: the
            # live cache is not a fixture's to overwrite.
            json_body = json.dumps(payload, indent=2) + "\n"
            text_body = "\n".join(render_lines(payload)) + "\n"
        else:
            json_body, text_body = write_outputs(payload, out_dir)
            if record is not None:
                # Only a live ok brief gets here: generate() hands back an
                # anchor record only for a readable board, so an unreadable run
                # writes nothing and advances nothing.
                try:
                    write_anchor_file(record["path"], record["anchor"],
                                      record["reported"], utc_now())
                except OSError as exc:
                    print("anchor: NOT written (%s: %s); the next run falls back "
                          "to the boot time" % (type(exc).__name__, exc),
                          file=sys.stderr)
                else:
                    print("anchor: advanced to %s, %d new pair(s), %d in the set"
                          % (iso(record["anchor"]), record["new"],
                             len(record["reported"])), file=sys.stderr)
        sys.stdout.write(json_body if args.json else text_body)
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
