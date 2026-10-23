#!/usr/bin/env python3
"""Hudfix system actions for the v5 HUD (card F8f).

This module is the SYSTEM slice of the maintenance engine. It exports one
table, ``ACTIONS``, and nothing else is required of a caller:

    ACTIONS = {
        "system.failed-jobs": {
            "class": "read",            # read | safe | reversible | destructive
            "doc": "one sentence for the UI",
            "plan": callable,          # ctx -> plan payload (dry run, no changes)
            "run": callable,           # ctx -> result payload (may change state)
            "linux_only": False,
        },
        ...
    }

``plan`` and ``run`` accept ``None``, a dict, or any object with the attributes
of :class:`Ctx`, so the F8a front end can call them with its own context object
as long as it carries the same names. Nothing here imports F8a's module and
nothing outside the standard library is used: ``python3 hudfix_system.py
--self-check`` works on a bare checkout.

Hosts
-----
Every action says where it runs instead of pretending. ``system.units``,
``system.restart-audio`` and the journal branch of ``system.recent-errors`` are
Linux (systemd). ``system.failed-jobs``, the ``log show`` branch of
``system.recent-errors`` and ``system.crash-reports`` are macOS. On the wrong
host a live call answers ``{"ok": false, "reason": "linux_only"|"macos_only"}``
with exit 0 and a detail sentence, never a fabricated empty list.

Safety, in code
---------------
* Every command is an argv list handed to ``subprocess`` with ``shell=False``.
  There is no string interpolation into a shell anywhere in this file.
* The only executables this module can invoke are in ``ALLOWED_EXECUTABLES``:
  ``systemctl``, ``journalctl``, ``launchctl``, ``log``, ``ps``, ``sysctl``,
  ``uptime``. ``sudo``, ``killall`` and ``pkill`` are never executed: they appear
  only in prose, in the refusal list, and in the assertion that keeps them out.
* ``system.restart-shell`` refuses (``{"ok": false, "reason": "protected"}``,
  exit 0) when the target resolves to the gateway, the dispatcher or the bridge
  relay. The guard runs on the live args of the pid at plan time and again at
  run time, before anything is signalled or restarted.
* ``system.restart-shell`` without ``--confirm`` exits 2. State-changing runs in
  fixture mode refuse with exit 0: a fixture is a recording, not a host.
* Every state-changing action has a dry run: ``--plan`` prints the exact argv
  and changes nothing, and ``--dry-run`` is an alias for it.
* The crash quarantine writes each MANIFEST row atomically before it moves the
  file, so a report never leaves the live directory without its row on disk.
* Nothing is restarted or moved by ``--self-check``.

Fixture layout
--------------
``--fixture PATH`` takes a file or a directory. The committed directory is
``fixtures/hudfix/`` (see its README): ``systemctl-failed.json``,
``journalctl-last.json``, ``journalctl-errors.ndjson``, ``launchctl-list.txt``,
``log-show.ndjson``, ``ps.txt``, ``cgroup.txt``, ``uptime.json``, ``crash/*.ips``
and ``meta.json`` (``generated_at``, ``now``, notes). In fixture mode no host
state is read: no ``ps``, no cache, no directories outside the fixture, no
clock-derived age. ``generated_at`` comes from the fixture, and a fixture
without one yields ``null`` plus a reason, so two fixture runs are byte
identical.

Exit codes: 0 for data and for honest absence, 2 only for a caller error
(unknown action, missing ``--fixture`` path, missing ``--confirm`` on a
state-changing run, missing ``--older-than-days`` for the quarantine).
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time

SOURCE = "hudfix_system"
EXIT_OK = 0
EXIT_PROGRAMMING = 2
CLASSES = ("read", "safe", "reversible", "destructive")
HOME = os.path.expanduser("~")
DEFAULT_REPORTS_DIR = "~/Library/Logs/DiagnosticReports"
DEFAULT_STATE_ROOT = "~/.local/state/nexuslink"
LOG_WINDOW = "1h"
CACHE_TTL_S = 10.0
CACHE_TTL_OVERRIDES = {"system.recent-errors": 60.0}
LIMITS = {"senders": 10, "units": 20, "jobs": 200, "reports": 200}
SAMPLE_CHARS = 160
COMMAND_TIMEOUT_S = 30.0
LOG_TIMEOUT_S = 120.0
# A capture nested deeper than this is refused, not walked: JSON nesting is a
# recursion hazard (json itself raises RecursionError past the interpreter's
# stack), and no honest log line, journal row or .ips header is 64 deep.
MAX_JSON_DEPTH = 64

ALLOWED_EXECUTABLES = frozenset(
    {"systemctl", "journalctl", "launchctl", "log", "ps", "sysctl", "uptime"}
)
FORBIDDEN_TOKENS = ("sudo", "killall", "pkill")

# A process is a HUD shell when its command line names quickshell. A nexuslink
# HUD unit or a binary basename counts too, but a path that merely contains
# ``nexuslink.hud`` (this repo, for instance) must not: the token has to end.
HUD_SHELL_RE = re.compile(r"(^|[/\\\s])quickshell(\s|$)", re.IGNORECASE)
HUD_UNIT_RE = re.compile(r"(^|[/\\\s])nexuslink[-_.]hud(\.service|\.scope)?(\s|$)",
                         re.IGNORECASE)


def is_hud_shell(args):
    body = args or ""
    return bool(HUD_SHELL_RE.search(body) or HUD_UNIT_RE.search(body))

# The three things a restart may never touch, matched against the resolved
# process name and its full argument line. Case-insensitive, word bounded.
PROTECTED = (
    ("gateway", re.compile(r"(^|[^a-z0-9])gateway([^a-z0-9]|$)", re.IGNORECASE),
     "it carries the fleet control plane; restarting it drops in-flight turns"),
    ("dispatcher", re.compile(r"(^|[^a-z0-9])dispatch(er)?([^a-z0-9]|$)", re.IGNORECASE),
     "running cards lose their worker and the board stalls mid-dispatch"),
    ("bridge relay", re.compile(r"bridge[\s_.-]*relay|relay[\s_.-]*bridge|codex[\s_.-]*relay",
                                re.IGNORECASE),
     "the Linux box loses its link to the Mac mid-dispatch"),
)


# --------------------------------------------------------------------- errors


class DataProblem(Exception):
    """Missing or malformed input. An answer, not a crash."""

    kind = "data"

    def __init__(self, reason):
        super(DataProblem, self).__init__(reason)
        self.reason = str(reason)


class Missing(DataProblem):
    kind = "missing"


class Malformed(DataProblem):
    kind = "malformed"
    # Set on an instance when the value was refused for nesting, so a caller
    # that skips bad rows can still say why none survived.
    deep = False


class CallerError(Exception):
    """A programming error or a caller error: exit 2."""

    def __init__(self, reason, detail=None):
        super(CallerError, self).__init__(reason)
        self.reason = str(reason)
        self.detail = detail


# ------------------------------------------------------------------- plumbing


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc)


def iso(epoch):
    """Epoch seconds -> ``2026-10-23T01:07:02Z``; anything unusable -> None."""
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
    return iso(utc_now().timestamp())


def epoch_from_iso(value):
    """Tolerant ISO-8601 -> epoch seconds. Naive stamps are read as UTC."""
    if not isinstance(value, str) or not value.strip():
        return None
    raw = value.strip().replace("Z", "+00:00").replace("z", "+00:00")
    # log show and .ips write " 18:40:03.00 +0200": close the gap before the offset,
    # and give fromisoformat the "+02:00" it wants.
    raw = re.sub(r"\s+([+-]\d{2}:?\d{2})$", r"\1", raw)
    raw = re.sub(r"([+-]\d{2})(\d{2})$", r"\1:\2", raw)
    # Python 3.9 fromisoformat only accepts 3 or 6 fractional digits; .ips writes ".00".
    raw = re.sub(r"\.(\d+)", lambda m: "." + (m.group(1) + "000000")[:6], raw)
    try:
        parsed = datetime.datetime.fromisoformat(raw)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.timezone.utc)
    return parsed.timestamp()


def tilde(path):
    if not path:
        return ""
    path = os.path.abspath(os.path.expanduser(str(path)))
    if path == HOME:
        return "~"
    if path.startswith(HOME + os.sep):
        return "~" + path[len(HOME):]
    return path


def tilde_text(message):
    for root in (HOME, os.path.realpath(HOME)):
        if root and root != "/" and root in message:
            message = message.replace(root + os.sep, "~" + os.sep).replace(root, "~")
    return message


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
    """Trimmed one-line string or None."""
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
        value = cut.rstrip(" ,;:-") + "..."
    return value


def first_line(block, limit=200):
    for line in (block or "").splitlines():
        line = line.strip()
        if line:
            return text(line, limit)
    return None


def human_uptime(seconds):
    """Same wording as F1's mac_link feed."""
    if seconds is None or seconds < 0:
        return None
    days, rest = divmod(int(seconds), 86400)
    hours, rest = divmod(rest, 3600)
    mins = rest // 60
    if days:
        return "%dd %dh" % (days, hours)
    if hours:
        return "%dh %dm" % (hours, mins)
    return "%dm" % mins


def reason_nulls(values, prefix, reasons, message):
    for key, value in values.items():
        if value is None:
            reasons.setdefault("%s.%s" % (prefix, key), message)


def failure(mode, problem, action=None, **fields):
    payload = {
        "ok": False,
        "source": SOURCE,
        "mode": mode,
        "generated_at": iso_now() if mode == "live" else fields.pop("generated_at", None),
        "reason": tilde_text(getattr(problem, "reason", None) or str(problem)),
        "kind": getattr(problem, "kind", "data"),
    }
    if action is not None:
        payload["action"] = action
    payload.update(fields)
    return payload


def emit(payload, compact):
    if compact:
        line = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=False)
    else:
        line = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=False)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def _json_depth_ok(value, limit):
    """True when `value` nests no deeper than `limit`. Iterative, not recursive."""
    stack = [(value, 1)]
    while stack:
        item, depth = stack.pop()
        if depth > limit:
            return False
        if isinstance(item, dict):
            stack.extend((child, depth + 1) for child in item.values())
        elif isinstance(item, list):
            stack.extend((child, depth + 1) for child in item)
    return True


def loads_bounded(raw, what, limit=MAX_JSON_DEPTH):
    """json.loads with a depth cap. Hostile nesting is an answer, not a raise.

    ``json`` raises ``RecursionError`` on a capture nested past the C scanner's
    stack (1200 levels is enough), and that is not a ``ValueError``: it would
    escape every ``except ValueError`` in this file and surface as a
    programming error. Both paths become ``Malformed``, and the depth cap is
    checked on the parsed value too, so the answer does not depend on the
    interpreter's recursion limit.
    """
    try:
        value = json.loads(raw)
    except RecursionError:
        problem = Malformed("%s is nested too deeply to read" % what)
        problem.deep = True
        raise problem
    except ValueError as exc:
        raise Malformed("%s is not valid JSON: %s" % (what, exc))
    if not _json_depth_ok(value, limit):
        problem = Malformed("%s is nested deeper than %d levels" % (what, limit))
        problem.deep = True
        raise problem
    return value


def read_json_file(path, what):
    shown = tilde(path)
    target = os.path.expanduser(str(path))
    if not os.path.exists(target):
        raise Missing("no %s at %s" % (what, shown))
    if not os.path.isfile(target):
        raise Missing("%s is not a file: %s" % (what, shown))
    try:
        with open(target, "r", encoding="utf-8") as handle:
            raw = handle.read()
    except OSError as exc:
        raise Missing("cannot read %s at %s: %s" % (what, shown, exc.strerror or exc))
    if not raw.strip():
        raise Missing("%s at %s is empty" % (what, shown))
    return loads_bounded(raw, "%s at %s" % (what, shown))


def write_json_atomic(path, payload):
    target = os.path.expanduser(str(path))
    parent = os.path.dirname(target) or "."
    os.makedirs(parent, exist_ok=True)
    stamp = "%s.%d.tmp" % (target, os.getpid())
    try:
        with open(stamp, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=False)
            handle.write("\n")
        os.replace(stamp, target)
    except BaseException:
        try:
            os.unlink(stamp)
        except OSError:
            pass
        raise


def write_manifest(path, rows):
    """Rewrite the quarantine MANIFEST atomically: temp file, fsync, os.replace.

    The caller writes the row before it moves the file, so the manifest is the
    write-ahead record of every move. When the row cannot reach the disk this
    raises OSError and the caller must not move anything.
    """
    target = os.path.expanduser(str(path))
    parent = os.path.dirname(target) or "."
    os.makedirs(parent, exist_ok=True)
    stamp = "%s.%d.tmp" % (target, os.getpid())
    try:
        with open(stamp, "w", encoding="utf-8") as handle:
            for row in rows:
                handle.write(json.dumps(row, ensure_ascii=False, sort_keys=False) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(stamp, target)
    except BaseException:
        try:
            os.unlink(stamp)
        except OSError:
            pass
        raise


def _lossy(*texts):
    """How many bytes the decoder had to replace. Zero means the capture is exact."""
    return sum((piece or "").count("\ufffd") for piece in texts)


def run_cmd(argv, timeout=COMMAND_TIMEOUT_S):
    """Run an argv list with no shell. Returns rc/out/err/timed_out, never raises.

    The child's output is decoded as UTF-8 with ``errors="replace"``. A
    ``launchctl`` or ``log`` child can write a byte that is not part of a UTF-8
    character, and this module's own timeout kills the child mid-character: a
    strict decode would raise ``UnicodeDecodeError`` out of ``communicate`` and
    turn a hostile capture into exit 2 ``programming_error`` instead of
    ``kind: malformed``. ``lossy`` counts the bytes the decoder had to replace,
    so a caller whose answer depends on exact text can refuse the capture
    instead of reading a silently altered one.
    """
    if not argv or argv[0] not in ALLOWED_EXECUTABLES:
        raise CallerError("command_not_allowed", "refusing to run %r" % (argv,))
    try:
        proc = subprocess.Popen(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            shell=False,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
    except FileNotFoundError:
        return {"rc": None, "out": "", "err": "%s not found" % argv[0], "timed_out": False,
                "missing": True, "lossy": 0}
    except OSError as exc:
        return {"rc": None, "out": "", "err": str(exc), "timed_out": False, "missing": False,
                "lossy": 0}
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, err = proc.communicate()
        return {"rc": None, "out": out or "", "err": err or "", "timed_out": True,
                "missing": False, "lossy": _lossy(out, err)}
    return {"rc": proc.returncode, "out": out or "", "err": err or "", "timed_out": False,
            "missing": False, "lossy": _lossy(out, err)}


def sha256_file(path):
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(65536), b""):
                digest.update(chunk)
    except OSError:
        return None
    return digest.hexdigest()


def platform_name():
    name = platform.system().lower()
    if name == "darwin":
        return "macos"
    if name == "linux":
        return "linux"
    return name or "unknown"


# ------------------------------------------------------------------- context


class Ctx(object):
    """What plan/run need to know. F8a may pass its own object with these names."""

    _ATTRS = ("fixture", "confirm", "older_than_days", "target", "reports_dir",
              "state_dir", "window", "now")

    def __init__(self, fixture=None, confirm=False, older_than_days=None, target=None,
                 reports_dir=None, state_dir=None, window=LOG_WINDOW, now=None):
        self.fixture = fixture
        self.confirm = bool(confirm)
        self.older_than_days = older_than_days
        self.target = target
        self.reports_dir = reports_dir
        self.state_dir = state_dir
        self.window = window or LOG_WINDOW
        self.now = now
        self._fixture = None
        self._meta_loaded = False
        self._meta = {}

    @property
    def mode(self):
        return "fixture" if self.fixture else "live"

    def fixture_source(self):
        if self._fixture is None:
            self._fixture = Fixture(self.fixture)
        return self._fixture

    def meta(self):
        if not self._meta_loaded:
            self._meta_loaded = True
            if self.mode == "fixture":
                self._meta = self.fixture_source().meta()
        return self._meta


def coerce_ctx(ctx):
    if ctx is None:
        return Ctx()
    if isinstance(ctx, Ctx):
        return ctx
    if isinstance(ctx, dict):
        return Ctx(**{key: ctx.get(key) for key in Ctx._ATTRS if key in ctx})
    values = {}
    for key in Ctx._ATTRS:
        if hasattr(ctx, key):
            values[key] = getattr(ctx, key)
    return Ctx(**values)


class Fixture(object):
    """A recorded file or directory. Reading it is the only I/O in fixture mode."""

    def __init__(self, path):
        resolved = os.path.expanduser(str(path)) if path else ""
        if not resolved:
            raise CallerError("fixture_missing", "--fixture needs a path")
        if not os.path.exists(resolved):
            raise CallerError("fixture_missing", "no fixture at %s" % tilde(resolved))
        self.path = resolved
        self.is_dir = os.path.isdir(resolved)

    def _inside(self, name):
        if not self.is_dir:
            return None
        return os.path.join(self.path, name)

    def text(self, name, required=True):
        candidate = self._inside(name)
        if candidate is None:
            if required:
                raise Malformed(
                    "fixture %s is a file; %s needs a directory fixture" % (
                        tilde(self.path), name)
                )
            return None
        if not os.path.isfile(candidate):
            if required:
                raise Missing("fixture has no %s at %s" % (name, tilde(candidate)))
            return None
        try:
            with open(candidate, "r", encoding="utf-8", errors="replace") as handle:
                return handle.read()
        except OSError as exc:
            raise Malformed("cannot read fixture %s: %s" % (name, exc.strerror or exc))

    def whole(self):
        """The fixture file itself, when --fixture named a file rather than a directory."""
        if self.is_dir:
            return None
        try:
            with open(self.path, "r", encoding="utf-8", errors="replace") as handle:
                return handle.read()
        except OSError as exc:
            raise Malformed("cannot read fixture %s: %s"
                            % (tilde(self.path), exc.strerror or exc))

    def json(self, name, required=True):
        raw = self.text(name, required=required)
        if raw is None:
            return None
        return loads_bounded(raw, "fixture %s" % name)

    def meta(self):
        if not self.is_dir:
            return {}
        raw = self.text("meta.json", required=False)
        if not raw:
            return {}
        try:
            data = loads_bounded(raw, "fixture meta.json")
        except Malformed:
            return {}
        return data if isinstance(data, dict) else {}

    def generated_at(self):
        value = self.meta().get("generated_at")
        return value if isinstance(value, str) and value.strip() else None

    def now_epoch(self):
        value = self.meta().get("now")
        return epoch_from_iso(value) if isinstance(value, str) else None


def json_shape(data):
    """Human word for a JSON value's type, for malformed-input messages."""
    if isinstance(data, dict):
        return "an object"
    if isinstance(data, list):
        return "an array"
    if isinstance(data, bool):
        return "a boolean"
    if isinstance(data, str):
        return "a string"
    if isinstance(data, (int, float)):
        return "a number"
    if data is None:
        return "null"
    return type(data).__name__


def fixture_object(source, name, required=True):
    """A fixture JSON file that must hold an object. Any other shape -> Malformed.

    A recording is untrusted input like any other. ``[]`` in uptime.json, or
    ``[1]`` in journalctl-last.json, must answer malformed (ok false, exit 0)
    instead of raising AttributeError from a bare ``.get``.
    """
    data = source.json(name, required=required)
    if data is None:
        return {}
    if not isinstance(data, dict):
        raise Malformed("fixture %s must hold a JSON object, got %s"
                        % (name, json_shape(data)))
    return data


def mode_now(ctx):
    """Epoch used for ages. Fixture mode never falls back to the wall clock."""
    if ctx.now is not None:
        return float(ctx.now)
    if ctx.mode == "fixture":
        return ctx.fixture_source().now_epoch()
    return time.time()


# ------------------------------------------------------------------ arguments


def add_ctx_args(parser):
    parser.add_argument("--fixture", metavar="PATH",
                        help="read a recorded file or directory instead of the host")
    parser.add_argument("--json", action="store_true",
                        help="one compact JSON line instead of pretty output")
    parser.add_argument("--confirm", action="store_true",
                        help="required before any action that changes state")
    parser.add_argument("--older-than-days", type=int, metavar="N",
                        help="crash quarantine: only reports older than N days")
    parser.add_argument("--target", type=int, metavar="PID",
                        help="restart-shell: explicit pid instead of lookup")
    parser.add_argument("--reports-dir", metavar="PATH",
                        help="crash reports directory (default ~/Library/Logs/DiagnosticReports)")
    parser.add_argument("--state-dir", metavar="PATH",
                        help="cache and quarantine root (default ~/.local/state/nexuslink)")
    parser.add_argument("--window", default=LOG_WINDOW, metavar="1h",
                        help="recent-errors window (default 1h)")
    return parser


def ctx_from_args(args):
    return Ctx(
        fixture=args.fixture,
        confirm=args.confirm,
        older_than_days=args.older_than_days,
        target=args.target,
        reports_dir=args.reports_dir,
        state_dir=args.state_dir,
        window=args.window,
    )


# ------------------------------------------------------------------- caching


def cache_key(action, ctx):
    """Cache entries are per source, not just per action: two report directories
    or two log windows are different data and must not share a file."""
    if action == "system.crash-reports":
        directory = os.path.abspath(os.path.expanduser(ctx.reports_dir or DEFAULT_REPORTS_DIR))
        return hashlib.sha1(directory.encode("utf-8")).hexdigest()[:10]
    if action == "system.recent-errors":
        return re.sub(r"[^A-Za-z0-9]+", "-", ctx.window or LOG_WINDOW).strip("-")[:24]
    return ""


def cache_path(ctx, action):
    root = ctx.state_dir or DEFAULT_STATE_ROOT
    key = cache_key(action, ctx)
    suffix = ("." + key) if key else ""
    return os.path.join(os.path.expanduser(root),
                        "hudfix_system.%s%s.json" % (action, suffix))


def cache_read(ctx, action, now):
    if ctx.mode != "live":
        return None
    path = cache_path(ctx, action)
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            raw = handle.read()
    except OSError:
        return None
    if not raw.strip():
        return None
    # Every cache read goes through the same bounded loader as the captures.
    # json.load raises RecursionError on a file nested 1200 deep, which is not a
    # ValueError: it escaped as exit 2 programming_error. A cache nested past the
    # cap is hostile, so it answers ok:false kind:malformed at exit 0; a cache
    # that is merely corrupt or empty is still treated as no cache, which is the
    # behaviour the earlier rounds proved.
    try:
        stored = loads_bounded(raw, "cache for %s at %s" % (action, tilde(path)))
    except Malformed as problem:
        if problem.deep:
            raise
        return None
    if not isinstance(stored, dict):
        return None
    collected = integer(stored.get("collected_at"))
    payload = stored.get("payload")
    if collected is None or not isinstance(payload, dict):
        return None
    age = now - collected
    ttl = CACHE_TTL_OVERRIDES.get(action, CACHE_TTL_S)
    if age < 0 or age >= ttl:
        return None
    cached = json.loads(json.dumps(payload))
    cached["cached"] = True
    cached["cache_age_s"] = round(age, 1)
    return cached


def cache_store(ctx, action, payload, now):
    if ctx.mode != "live" or not isinstance(payload, dict) or not payload.get("ok"):
        return
    try:
        write_json_atomic(cache_path(ctx, action), {"collected_at": int(now), "payload": payload})
    except OSError:
        pass


# ------------------------------------------------------------------- parsers


def parse_launchctl_list(raw):
    """``launchctl list`` table -> every job, with pid/status/label."""
    jobs = []
    reasons = {}
    lines = [line for line in (raw or "").splitlines() if line.strip()]
    if not lines:
        raise Missing("launchctl list printed nothing")
    header = lines[0].split("\t")
    if [part.strip() for part in header] != ["PID", "Status", "Label"]:
        reasons["launchctl.header"] = "unexpected header: %s" % text(lines[0], 120)
    for line in lines[1:]:
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        pid_raw, status_raw, label = parts[0].strip(), parts[1].strip(), parts[2].strip()
        job = {
            "label": text(label, 160),
            "pid": None if pid_raw in ("-", "") else integer(pid_raw),
            "last_exit_status": integer(status_raw),
            "signal": None,
            "raw_status": text(status_raw, 20),
        }
        status = job["last_exit_status"]
        if status is not None and status < 0:
            job["signal"] = -status
        jobs.append(job)
    if not jobs:
        raise Malformed("launchctl list had a header but no rows")
    return jobs, reasons


def parse_systemctl_units(data):
    """``systemctl --user --failed --output=json`` -> normalised units."""
    if not isinstance(data, list):
        raise Malformed("systemctl JSON is not an array")
    units = []
    for row in data:
        if not isinstance(row, dict):
            continue
        name = text(row.get("unit") or row.get("id") or row.get("name"), 160)
        if not name:
            continue
        units.append({
            "unit": name,
            "description": text(row.get("description") or row.get("desc"), 200),
            "load": text(row.get("load"), 40),
            "active": text(row.get("active"), 40),
            "sub": text(row.get("sub"), 40),
        })
    return units


def _basename(path):
    if not path:
        return None
    cleaned = str(path).rstrip("/")
    leaf = cleaned.rsplit("/", 1)[-1]
    return text(leaf, 120)


def _journal_message(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        try:
            return bytes(int(part) for part in value).decode("utf-8", "replace")
        except (TypeError, ValueError):
            return None
    return None


def parse_log_row(row):
    """One ``log show`` row, or one ``journalctl -o json`` row, or None."""
    if not isinstance(row, dict):
        return None
    if "eventMessage" in row or "messageType" in row:
        kind = text(row.get("messageType")) or "Error"
        sender = _basename(row.get("senderImagePath")) or _basename(row.get("processImagePath"))
        sender = sender or text(row.get("subsystem"), 120) or "unknown"
        return {
            "kind": kind,
            "sender": sender,
            "message": text(row.get("eventMessage") or row.get("formatString"), SAMPLE_CHARS),
            "at": epoch_from_iso(row.get("timestamp")),
            "process_id": integer(row.get("processID")),
            "subsystem": text(row.get("subsystem"), 120),
        }
    if "MESSAGE" in row or "PRIORITY" in row:
        priority = integer(row.get("PRIORITY"))
        kind = "err" if priority in (0, 1, 2, 3) else "warning"
        sender = (text(row.get("SYSLOG_IDENTIFIER")) or text(row.get("_COMM"))
                  or _basename(text(row.get("_SYSTEMD_UNIT"))) or "unknown")
        at = None
        raw_ts = row.get("__REALTIME_TIMESTAMP")
        if raw_ts is not None:
            micros = integer(raw_ts)
            at = micros / 1000000.0 if micros is not None else None
        return {
            "kind": kind,
            "sender": sender,
            "message": text(_journal_message(row.get("MESSAGE")), SAMPLE_CHARS),
            "at": at,
            "process_id": integer(row.get("_PID")),
            "subsystem": text(row.get("_SYSTEMD_UNIT"), 120),
        }
    return None


def rows_from_text(raw):
    """A recorded capture -> list of dict rows. Accepts a JSON array or ndjson."""
    body = (raw or "").strip()
    if not body:
        raise Missing("log capture is empty")
    if body.startswith("["):
        data = loads_bounded(body, "log capture")
        if not isinstance(data, list):
            raise Malformed("log capture is not a JSON array")
        return [row for row in data if isinstance(row, dict)], 0
    rows = []
    skipped = 0
    too_deep = 0
    for line in body.splitlines():
        line = line.strip().rstrip(",")
        if not line or line in ("[", "]"):
            skipped += 1
            continue
        try:
            row = loads_bounded(line, "log capture row")
        except Malformed as problem:
            # One unreadable line is skipped and counted; a nesting bomb in one
            # row must not take the whole capture down.
            if getattr(problem, "deep", False):
                too_deep += 1
            skipped += 1
            continue
        if isinstance(row, dict):
            rows.append(row)
        else:
            skipped += 1
    if not rows:
        if too_deep:
            raise Malformed(
                "log capture rows are nested deeper than %d levels (%d row(s))"
                % (MAX_JSON_DEPTH, too_deep)
            )
        raise Malformed("no JSON rows in the log capture")
    return rows, skipped


def iter_json_rows(lines, stats):
    """Live stream -> dict rows. Counts what it scans without keeping the text."""
    for line in lines:
        stats["scanned"] += 1
        line = (line or "").strip()
        if not line or line.startswith("[") or line == "]":
            stats["skipped"] += 1
            continue
        if line.endswith(","):
            line = line[:-1]
        try:
            row = loads_bounded(line, "log row")
        except Malformed:
            stats["skipped"] += 1
            continue
        if not isinstance(row, dict):
            stats["skipped"] += 1
            continue
        yield row


def parse_log_stream(rows, stats, want=("Error", "Fault", "err", "warning")):
    """Iterable of JSON rows -> ranked sender summary. Bounded memory, full counts."""
    counts = {}
    kinds = {}
    first_ts = None
    last_ts = None
    for row in rows:
        stats["parsed"] += 1
        item = parse_log_row(row)
        if item is None:
            stats["skipped"] += 1
            continue
        if item["kind"] not in want:
            continue
        kinds[item["kind"]] = kinds.get(item["kind"], 0) + 1
        bucket = counts.get(item["sender"])
        if bucket is None:
            bucket = {"sender": item["sender"], "count": 0, "errors": 0, "faults": 0,
                      "first": None, "last": None, "sample": None, "subsystem": None}
            counts[item["sender"]] = bucket
        bucket["count"] += 1
        if item["kind"].lower() == "fault":
            bucket["faults"] += 1
        else:
            bucket["errors"] += 1
        if item["kind"].lower() in ("fault", "error"):
            bucket["subsystem"] = bucket["subsystem"] or item["subsystem"]
        if bucket["sample"] is None and item["message"]:
            bucket["sample"] = item["message"]
        at = item["at"]
        if at is not None:
            stamp = iso(at)
            if stamp:
                if bucket["first"] is None or stamp < bucket["first"]:
                    bucket["first"] = stamp
                if bucket["last"] is None or stamp > bucket["last"]:
                    bucket["last"] = stamp
                if first_ts is None or stamp < first_ts:
                    first_ts = stamp
                if last_ts is None or stamp > last_ts:
                    last_ts = stamp
    ranked = sorted(counts.values(), key=lambda row: (-row["count"], row["sender"] or ""))
    return {
        "ranked": ranked,
        "scanned": stats["scanned"],
        "parsed": stats["parsed"],
        "skipped": stats["skipped"],
        "kinds": kinds,
        "first": first_ts,
        "last": last_ts,
    }


def parse_ps(raw):
    """``ps -Ao pid=,ppid=,args=`` -> [{pid, ppid, args}]."""
    table = []
    for line in (raw or "").splitlines():
        match = re.match(r"^\s*(\d+)\s+(\d+)\s+(.*\S)\s*$", line)
        if not match:
            continue
        table.append({"pid": int(match.group(1)), "ppid": int(match.group(2)),
                      "args": match.group(3)})
    if not table:
        raise Malformed("ps table had no readable rows")
    return table


def process_name(args):
    first = (args or "").split(" ", 1)[0]
    if not first:
        return None
    return text(os.path.basename(first), 80)


def process_row(pid, table):
    for row in table:
        if row["pid"] == pid:
            return row
    return None


def parse_cgroup_unit(raw):
    """``/proc/<pid>/cgroup`` -> (unit, user_manager, scope)."""
    body = raw or ""
    for line in body.splitlines():
        parts = line.split(":", 2)
        path = parts[2] if len(parts) == 3 else line
        match = re.search(r"([^/]+\.(?:service|scope))$", path.strip())
        if not match:
            continue
        unit = match.group(1)
        return unit, "/user@" in path or "/user.slice/" in path, "user" if "/user@" in path else "system"
    return None, False, None


def parse_boottime(raw):
    if not isinstance(raw, str):
        return None
    match = re.search(r"sec\s*=\s*(\d+)", raw)
    return int(match.group(1)) if match else None


def parse_uptime_text(raw):
    if not isinstance(raw, str):
        return None
    body = raw
    match = re.search(r"up\s+(\d+)\s+days?,\s*(\d+):(\d+)", body)
    if match:
        return int(match.group(1)) * 86400 + int(match.group(2)) * 3600 + int(match.group(3)) * 60
    match = re.search(r"up\s+(\d+):(\d+)", body)
    if match:
        return int(match.group(1)) * 3600 + int(match.group(2)) * 60
    match = re.search(r"up\s+(\d+)\s+mins?", body)
    if match:
        return int(match.group(1)) * 60
    return None


def parse_loadavg(raw):
    if not isinstance(raw, str):
        return None
    match = re.search(r"\{?\s*([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s*\}?", raw)
    if not match:
        return None
    try:
        return [round(float(match.group(i)), 2) for i in (1, 2, 3)]
    except ValueError:
        return None


def parse_ips_header(raw):
    """A .ips file starts with one JSON header line. Tolerant of a bad line."""
    if not raw:
        return None
    line = raw.splitlines()[0].strip() if raw.splitlines() else ""
    if not line.startswith("{"):
        return None
    try:
        header = loads_bounded(line, ".ips header")
    except Malformed:
        return None
    return header if isinstance(header, dict) else None


def filename_date(name):
    match = re.search(r"(\d{4})-(\d{2})-(\d{2})[-_ ](\d{2})[-_]?(\d{2})[-_]?(\d{2})", name or "")
    if not match:
        match = re.search(r"(\d{4})-(\d{2})-(\d{2})", name or "")
        if not match:
            return None
        try:
            stamp = datetime.datetime(int(match.group(1)), int(match.group(2)),
                                      int(match.group(3)), tzinfo=datetime.timezone.utc)
        except ValueError:
            return None
        return stamp.timestamp()
    try:
        stamp = datetime.datetime(*(int(match.group(i)) for i in range(1, 7)),
                                  tzinfo=datetime.timezone.utc)
    except ValueError:
        return None
    return stamp.timestamp()


# -------------------------------------------------------------------- readers


def launchctl_jobs(ctx):
    now = time.time()
    cached = cache_read(ctx, "system.failed-jobs", now)
    if cached:
        return cached
    if ctx.mode == "fixture":
        source = ctx.fixture_source()
        raw = source.text("launchctl-list.txt", required=False) if source.is_dir \
            else source.whole()
        if raw is None:
            raise Missing("fixture has no launchctl-list.txt")
        jobs, reasons = parse_launchctl_list(raw)
        failed = [job for job in jobs if job["last_exit_status"] not in (0, None)]
        payload = {
            "ok": True,
            "source": SOURCE,
            "mode": "fixture",
            "generated_at": ctx.fixture_source().generated_at(),
            "action": "system.failed-jobs",
            "jobs_total": len(jobs),
            "failed_count": len(failed),
            "jobs": failed[:LIMITS["jobs"]],
            "truncated": len(failed) > LIMITS["jobs"],
            "reasons": reasons,
        }
        return payload
    if platform_name() != "macos":
        return refusal_payload(
            ctx, "system.failed-jobs", "read", "macos_only",
            "launchctl is macOS-only; this host is %s. Record a capture and use --fixture."
            % platform_name())
    result = run_cmd(["launchctl", "list"], timeout=15.0)
    if result.get("missing"):
        raise Missing("launchctl not found on this Mac")
    if result["timed_out"]:
        raise Missing("launchctl list timed out after 15 s")
    if result["rc"] not in (0, None):
        raise Malformed("launchctl list exited %s: %s" % (result["rc"], first_line(result["err"], 160)))
    if result.get("lossy"):
        raise Malformed(
            "launchctl list output is not valid UTF-8 (%d byte(s) replaced); "
            "refusing to read a lossy capture" % result["lossy"])
    jobs, reasons = parse_launchctl_list(result["out"])
    failed = [job for job in jobs if job["last_exit_status"] not in (0, None)]
    failed.sort(key=lambda job: (job["last_exit_status"] if job["last_exit_status"] is not None else 0,
                                 job["label"] or ""))
    if not failed:
        reasons["jobs"] = "no launchctl job has a non-zero last exit status"
    payload = {
        "ok": True,
        "source": SOURCE,
        "mode": "live",
        "generated_at": iso_now(),
        "action": "system.failed-jobs",
        "host": platform_name(),
        "jobs_total": len(jobs),
        "failed_count": len(failed),
        "jobs": failed[:LIMITS["jobs"]],
        "truncated": len(failed) > LIMITS["jobs"],
        "reasons": reasons,
    }
    cache_store(ctx, "system.failed-jobs", payload, now)
    return payload


def systemctl_units(ctx):
    now = time.time()
    cached = cache_read(ctx, "system.units", now)
    if cached:
        return cached
    if ctx.mode == "live" and platform_name() != "linux":
        return refusal_payload(
            ctx, "system.units", "read", "linux_only",
            "systemctl is Linux-only; this host is %s. Record a capture and use --fixture."
            % platform_name())
    if ctx.mode == "fixture":
        source = ctx.fixture_source()
        data = source.json("systemctl-failed.json")
        last_log = fixture_object(source, "journalctl-last.json", required=False)
        units = parse_systemctl_units(data)
        reasons = {}
    else:
        result = run_cmd(["systemctl", "--user", "--failed", "--output=json"], timeout=20.0)
        if result.get("missing"):
            raise Missing("systemctl not found")
        if result["rc"] not in (0, None):
            raise Malformed("systemctl --user --failed exited %s: %s"
                            % (result["rc"], first_line(result["err"], 160)))
        if result.get("lossy"):
            raise Malformed(
                "systemctl --output=json is not valid UTF-8 (%d byte(s) replaced); "
                "refusing to read a lossy capture" % result["lossy"])
        data = loads_bounded(result["out"] or "[]", "systemctl --output=json")
        units = parse_systemctl_units(data)
        last_log = {}
        reasons = {}
        for unit in units[:LIMITS["units"]]:
            entry = run_cmd(["journalctl", "--user", "-u", unit["unit"], "-n", "1",
                             "--no-pager", "-o", "cat"], timeout=6.0)
            line = first_line(entry["out"], 200) if entry["rc"] == 0 else None
            if line:
                last_log[unit["unit"]] = line
            else:
                reasons["units.%s.last_log" % unit["unit"]] = (
                    first_line(entry["err"], 140) or "journalctl printed no line"
                )
    for unit in units:
        unit["last_log"] = text(last_log.get(unit["unit"]), 200)
        if unit["last_log"] is None:
            reasons.setdefault("units.%s.last_log" % unit["unit"],
                               "no journal line recorded for this unit")
    if not units:
        reasons["units"] = "systemctl reports no failed user units"
    payload = {
        "ok": True,
        "source": SOURCE,
        "mode": ctx.mode,
        "generated_at": ctx.fixture_source().generated_at() if ctx.mode == "fixture" else iso_now(),
        "action": "system.units",
        "host": platform_name() if ctx.mode == "live" else "linux",
        "units": units[:LIMITS["units"]],
        "count": len(units),
        "truncated": len(units) > LIMITS["units"],
        "reasons": reasons,
    }
    cache_store(ctx, "system.units", payload, now)
    return payload


def log_lines_from_cmd(argv, timeout):
    """Stream a command's stdout line by line, memory bounded, with a hard timeout."""
    if argv[0] not in ALLOWED_EXECUTABLES:
        raise CallerError("command_not_allowed", "refusing to run %r" % (argv,))
    try:
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                stdin=subprocess.DEVNULL, shell=False, text=True,
                                encoding="utf-8", errors="replace")
    except FileNotFoundError:
        raise Missing("%s not found on this host" % argv[0])
    except OSError as exc:
        raise Missing("cannot run %s: %s" % (argv[0], exc))
    deadline = time.time() + timeout
    timed_out = False
    finished = False
    yielded = 0
    err_text = ""
    try:
        for line in proc.stdout:
            if time.time() > deadline:
                timed_out = True
                break
            yielded += 1
            yield line
        finished = True
    finally:
        if timed_out or not finished:
            proc.kill()
        try:
            _out, err_text = proc.communicate(timeout=5.0)
        except subprocess.TimeoutExpired:
            proc.kill()
            _out, err_text = proc.communicate()
    if timed_out:
        raise Missing("read timed out after %.0f s" % timeout)
    if proc.returncode not in (0, None) and yielded == 0:
        raise Missing("%s exited %s: %s" % (
            argv[0], proc.returncode, first_line(err_text, 160) or "no output"))


def recent_errors(ctx):
    now = time.time()
    cached = cache_read(ctx, "system.recent-errors", now)
    if cached:
        return cached
    if ctx.mode == "fixture":
        source = ctx.fixture_source()
        if source.is_dir:
            raw = source.text("log-show.ndjson")
            framework = "log-show"
        else:
            try:
                with open(source.path, "r", encoding="utf-8", errors="replace") as handle:
                    raw = handle.read()
            except OSError as exc:
                raise Missing("cannot read fixture %s: %s"
                              % (tilde(source.path), exc.strerror or exc))
            framework = "log-show-file"
        rows, skipped = rows_from_text(raw)
        stats = {"scanned": len(rows) + skipped, "parsed": 0, "skipped": skipped}
        summary = parse_log_stream(rows, stats)
        payload = {
            "ok": True,
            "source": SOURCE,
            "mode": "fixture",
            "generated_at": ctx.fixture_source().generated_at(),
            "action": "system.recent-errors",
            "window": ctx.window,
            "framework": framework,
            "scanned": summary["scanned"],
            "parsed": summary["parsed"],
            "skipped": summary["skipped"],
            "kinds": summary["kinds"],
            "senders_total": len(summary["ranked"]),
            "senders": summary["ranked"][:LIMITS["senders"]],
            "capped": LIMITS["senders"],
            "truncated": len(summary["ranked"]) > LIMITS["senders"],
            "first": summary["first"],
            "last": summary["last"],
        }
        if not summary["ranked"]:
            payload["reasons"] = {"senders": "no Error or Fault rows in %s" % ctx.window}
        return payload
    if platform_name() == "macos":
        window = ctx.window or LOG_WINDOW
        argv = ["log", "show", "--last", window, "--style", "ndjson",
                "--predicate", 'messageType == "Error" OR messageType == "Fault"']
        framework = "log-show"
        lines = log_lines_from_cmd(argv, LOG_TIMEOUT_S)
    elif platform_name() == "linux":
        window = ctx.window or LOG_WINDOW
        argv = ["journalctl", "-p", "err", "--since", "-%s" % window, "-o", "json",
                "--no-pager"]
        framework = "journalctl"
        lines = log_lines_from_cmd(argv, LOG_TIMEOUT_S)
    else:
        return failure(ctx.mode, DataProblem("no log source on %s" % platform_name()),
                       action="system.recent-errors")
    stats = {"scanned": 0, "parsed": 0, "skipped": 0}
    summary = parse_log_stream(iter_json_rows(lines, stats), stats)
    payload = {
        "ok": True,
        "source": SOURCE,
        "mode": "live",
        "generated_at": iso_now(),
        "action": "system.recent-errors",
        "host": platform_name(),
        "window": ctx.window,
        "framework": framework,
        "command": argv,
        "scanned": summary["scanned"],
        "parsed": summary["parsed"],
        "skipped": summary["skipped"],
        "kinds": summary["kinds"],
        "senders_total": len(summary["ranked"]),
        "senders": summary["ranked"][:LIMITS["senders"]],
        "capped": LIMITS["senders"],
        "truncated": len(summary["ranked"]) > LIMITS["senders"],
        "first": summary["first"],
        "last": summary["last"],
        "notes": [
            "log show --style json builds one 340 MB array per hour on this Mac; "
            "ndjson is the same rows streamed, so memory stays bounded",
        ],
    }
    if not summary["ranked"]:
        payload["reasons"] = {"senders": "no Error or Fault rows in %s" % ctx.window}
    cache_store(ctx, "system.recent-errors", payload, now)
    return payload


def reports_source(ctx):
    """(directory, display) for crash reports. Fixture -> its crash/ directory."""
    if ctx.mode == "fixture":
        source = ctx.fixture_source()
        if source.is_dir:
            crash_dir = os.path.join(source.path, "crash")
            if not os.path.isdir(crash_dir):
                raise Missing("fixture has no crash/ directory")
            return crash_dir, "crash/"
        if source.path.lower().endswith(".ips"):
            return os.path.dirname(source.path), os.path.basename(source.path)
        raise Malformed("a file fixture for crash-reports must be a .ips file")
    directory = os.path.expanduser(ctx.reports_dir or DEFAULT_REPORTS_DIR)
    if not os.path.isdir(directory):
        raise Missing("no crash reports directory at %s" % tilde(directory))
    return directory, tilde(directory)


def within_root(path, root):
    """True when ``path`` resolves inside ``root``, both through realpath.

    A report entry is untrusted input: a symlink under the reports directory can
    point at ``../outside/secret.ips``, at an absolute path elsewhere, or at
    ``/etc/hosts``. The resolved path has to stay under the resolved reports
    root, or the entry is refused before it is sized, hashed or moved.
    """
    try:
        target = os.path.realpath(path)
        boundary = os.path.realpath(root)
        return os.path.commonpath([target, boundary]) == boundary
    except (OSError, ValueError):
        return False


def crash_report(path, ctx):
    name = os.path.basename(path)
    try:
        size = os.path.getsize(path)
    except OSError:
        size = None
    header = None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            header = parse_ips_header(handle.read(8192))
    except OSError:
        header = None
    app = None
    stamp = None
    bug_type = None
    if header:
        app = text(header.get("app_name") or header.get("name") or header.get("procName"), 120)
        stamp = epoch_from_iso(header.get("timestamp"))
        bug_type = text(header.get("bug_type"), 40)
    if stamp is None:
        stamp = filename_date(name)
    if app is None:
        app = text(name.split("-2026")[0].split("-2025")[0], 120)
    report = {
        "name": name,
        "app": app,
        "date": iso(stamp),
        "age_days": None,
        "bug_type": bug_type,
        "bytes": size,
        "path": name if ctx.mode == "fixture" else tilde(path),
        "header_ok": bool(header),
    }
    now = mode_now(ctx)
    if stamp is not None and now is not None:
        report["age_days"] = round((now - stamp) / 86400.0, 1)
    if ctx.mode == "live":
        try:
            report["modified_at"] = iso(os.path.getmtime(path))
        except OSError:
            report["modified_at"] = None
    return report


def crash_reports(ctx, fresh=False):
    now = time.time()
    if not fresh:
        cached = cache_read(ctx, "system.crash-reports", now)
        if cached:
            return cached
    directory, display = reports_source(ctx)
    reasons = {}
    refused = []
    names = []
    if ctx.mode == "fixture" and not ctx.fixture_source().is_dir:
        single = os.path.basename(ctx.fixture_source().path)
        if not single.lower().endswith(".ips"):
            raise Malformed("a file fixture for crash-reports must be a .ips file")
        names = [single]
    else:
        try:
            for entry in os.listdir(directory):
                if not entry.lower().endswith(".ips"):
                    continue
                full = os.path.join(directory, entry)
                if not os.path.isfile(full):
                    continue
                if not within_root(full, directory):
                    reason = "entry resolves outside %s; refused" % display
                    reasons["reports.%s.scope" % entry] = reason
                    refused.append({"name": entry, "reason": reason})
                    continue
                names.append(entry)
        except OSError as exc:
            raise Missing("cannot list %s: %s" % (display, exc.strerror or exc))
    if not names:
        if not reasons:
            reasons["reports"] = "no .ips files in %s" % display
        payload = {
            "ok": True,
            "source": SOURCE,
            "mode": ctx.mode,
            "generated_at": ctx.fixture_source().generated_at() if ctx.mode == "fixture" else iso_now(),
            "action": "system.crash-reports",
            "dir": display,
            "count": 0,
            "reports": [],
            "refused": refused,
            "total_bytes": 0,
            "reasons": reasons,
        }
        if not fresh:
            cache_store(ctx, "system.crash-reports", payload, now)
        return payload
    reports = []
    for name in names:
        report = crash_report(os.path.join(directory, name), ctx)
        if report["date"] is None:
            reasons.setdefault("reports.%s.date" % name, "no timestamp in the .ips header or its name")
        reports.append(report)
    reports.sort(key=lambda item: (item["date"] or ""), reverse=True)
    payload = {
        "ok": True,
        "source": SOURCE,
        "mode": ctx.mode,
        "generated_at": ctx.fixture_source().generated_at() if ctx.mode == "fixture" else iso_now(),
        "action": "system.crash-reports",
        "dir": display,
        "count": len(reports),
        "reports": reports[:LIMITS["reports"]],
        "refused": refused,
        "total_bytes": sum(item["bytes"] or 0 for item in reports),
        "truncated": len(reports) > LIMITS["reports"],
        "reasons": reasons,
    }
    if not fresh:
        cache_store(ctx, "system.crash-reports", payload, now)
    return payload


def uptime_read(ctx):
    now = time.time()
    cached = cache_read(ctx, "system.uptime", now)
    if cached:
        return cached
    reasons = {}
    uptime_s = None
    boot_at = None
    source = None
    if ctx.mode == "fixture":
        data = fixture_object(ctx.fixture_source(), "uptime.json")
        boot = parse_boottime(data.get("kern_boottime"))
        cold_start = mode_now(ctx)
        source = "kern.boottime" if boot else None
        boot_at = iso(boot)
        mode = "fixture"
        generated = ctx.fixture_source().generated_at()
        if cold_start is None:
            # No fixture clock: uptime is clock-derived, and fixture mode reads
            # no wall clock. The uptime text would be a second-hand reading of
            # the recorder's clock, so it stays null too. Same rule as F1.
            reasons["uptime_s"] = (
                "the fixture carries no clock (meta.json now); uptime is clock-derived "
                "and fixture mode reads no wall clock")
        elif boot is not None and cold_start < boot:
            reasons["uptime_s"] = (
                "the fixture clock is earlier than kern.boottime; no uptime can be derived")
        elif boot is not None:
            uptime_s = int(cold_start - boot)
        else:
            uptime_s = parse_uptime_text(data.get("uptime_text"))
            source = "uptime" if uptime_s is not None else None
    else:
        mode = "live"
        generated = iso_now()
        source = None
        boot = None
        if platform_name() == "macos":
            result = run_cmd(["sysctl", "-n", "kern.boottime"], timeout=6.0)
            if result["rc"] == 0:
                boot = parse_boottime(result["out"])
            if boot:
                source = "kern.boottime"
            else:
                text_result = run_cmd(["uptime"], timeout=6.0)
                uptime_s = parse_uptime_text(text_result["out"])
                if uptime_s is not None:
                    source = "uptime"
        elif platform_name() == "linux":
            try:
                with open("/proc/uptime", "r", encoding="utf-8") as handle:
                    uptime_s = integer(handle.read().split()[0])
                source = "/proc/uptime"
            except (OSError, IndexError, ValueError):
                uptime_s = None
        if boot:
            uptime_s = int(time.time() - boot)
            boot_at = iso(boot)
        else:
            boot_at = iso(time.time() - uptime_s) if uptime_s is not None else None
    if uptime_s is None:
        reasons.setdefault("uptime_s", "no boot time or uptime text on this host")
    payload = {
        "ok": True,
        "source": SOURCE,
        "mode": mode,
        "generated_at": generated,
        "action": "system.uptime",
        "uptime_s": uptime_s,
        "uptime_human": human_uptime(uptime_s),
        "boot_at": boot_at,
        "read_from": source,
        "reasons": reasons,
        "note": "leaf names match F1 mac_link (uptime_s, uptime_human); F1 nests them under mac, "
                "this payload keeps them at the top level",
    }
    if uptime_s is None:
        payload["ok"] = False
        payload["reason"] = reasons["uptime_s"]
    cache_store(ctx, "system.uptime", payload, now)
    return payload


def load_read(ctx):
    now = time.time()
    cached = cache_read(ctx, "system.load", now)
    if cached:
        return cached
    reasons = {}
    if ctx.mode == "fixture":
        data = fixture_object(ctx.fixture_source(), "uptime.json")
        avg = parse_loadavg(data.get("vm_loadavg"))
        cores = integer(data.get("ncpu"))
        source = "vm.loadavg"
        mode = "fixture"
        generated = ctx.fixture_source().generated_at()
    else:
        mode = "live"
        generated = iso_now()
        if platform_name() == "macos":
            result = run_cmd(["sysctl", "-n", "vm.loadavg"], timeout=6.0)
            avg = parse_loadavg(result["out"])
            cores_result = run_cmd(["sysctl", "-n", "hw.ncpu"], timeout=6.0)
            cores = integer(cores_result["out"].strip()) if cores_result["rc"] == 0 else None
            source = "vm.loadavg"
        elif platform_name() == "linux":
            try:
                with open("/proc/loadavg", "r", encoding="utf-8") as handle:
                    avg = parse_loadavg(handle.read())
                cores = os.cpu_count()
                source = "/proc/loadavg"
            except OSError:
                avg = None
                cores = os.cpu_count()
                source = None
        else:
            avg = None
            cores = os.cpu_count()
            source = None
    load1_frac = None
    if avg and cores:
        load1_frac = round(avg[0] / float(cores), 3)
    else:
        reasons["load1_frac"] = "load average or core count unavailable"
    if avg is None:
        reasons["avg"] = "no load average on this host"
    if cores is None:
        reasons["cores"] = "core count unavailable"
    payload = {
        "ok": True,
        "source": SOURCE,
        "mode": mode,
        "generated_at": generated,
        "action": "system.load",
        "avg": avg,
        "load1_frac": load1_frac,
        "cores": cores,
        "read_from": source,
        "reasons": reasons,
        "note": "leaf names match F1 mac_link (avg, load1_frac, cores); F1 nests them under "
                "mac.load, this payload keeps them at the top level",
    }
    if avg is None:
        payload["ok"] = False
        payload["reason"] = reasons["avg"]
    cache_store(ctx, "system.load", payload, now)
    return payload


# -------------------------------------------------------------- shell restart


def process_table(ctx):
    if ctx.mode == "fixture":
        return parse_ps(ctx.fixture_source().text("ps.txt"))
    result = run_cmd(["ps", "-Ao", "pid=,ppid=,args="], timeout=10.0)
    if result["rc"] not in (0, None):
        raise Missing("ps failed: %s" % (first_line(result["err"], 160) or result["rc"]))
    return parse_ps(result["out"])


def protected_hit(target):
    """The hard refusal. Returns (label, why) or None. Pure, no I/O."""
    haystack = "%s %s" % (target.get("name") or "", target.get("args") or "")
    for label, pattern, why in PROTECTED:
        if pattern.search(haystack):
            return label, why
    return None


def protected_refusal(ctx, target, label, why):
    plan = {
        "changes": True,
        "confirm_required": True,
        "command": None,
        "target": target,
        "blank_gap_s": [2, 4],
        "effect": "refused: nothing was signalled",
        "refusals": refusal_list(),
        "protected_check": {"verdict": "protected", "rule": label, "why": why},
        "notes": ["the guard runs on the live argument line and on the supervisor label "
                  "or unit, at plan and at run time"],
    }
    return refusal_payload(ctx, "system.restart-shell", "reversible", "protected",
                           "the target resolves to the %s" % label, plan=plan)


def refusal_list():
    return [
        {"target": "hermes gateway", "matches": ["gateway"],
         "why": "it carries the fleet control plane; restarting it drops in-flight turns"},
        {"target": "kanban dispatcher", "matches": ["dispatcher", "kanban dispatch"],
         "why": "running cards lose their worker and the board stalls mid-dispatch"},
        {"target": "bridge relay", "matches": ["bridge relay", "bridge-relay", "codex-relay"],
         "why": "the Linux box loses its link to the Mac mid-dispatch"},
    ]


def refusal_payload(ctx, action, cls, reason, detail, plan=None):
    payload = {
        "ok": False,
        "source": SOURCE,
        "mode": ctx.mode,
        "generated_at": ctx.fixture_source().generated_at() if ctx.mode == "fixture" else iso_now(),
        "action": action,
        "class": cls,
        "reason": reason,
        "detail": detail,
    }
    if plan is not None:
        payload["plan"] = plan
    return payload


def resolve_shell_target(ctx, table=None):
    """-> (target, None) or (None, refusal payload). Guard runs before the name check."""
    table = table if table is not None else process_table(ctx)
    if ctx.target is not None:
        row = process_row(int(ctx.target), table)
        if row is None:
            return None, refusal_payload(
                ctx, "system.restart-shell", "reversible", "no_such_pid",
                "pid %s is not in the process table" % ctx.target)
        target = {"name": process_name(row["args"]), "pid": row["pid"], "ppid": row["ppid"],
                  "args": text(row["args"], 300)}
        # Match against the whole argument line. A long interpreter invocation
        # can carry the token past the 300 characters kept for display.
        hit = protected_hit({"name": target["name"], "args": row["args"]})
        if hit:
            return None, protected_refusal(ctx, target, hit[0], hit[1])
        if not is_hud_shell(target["args"] or ""):
            return None, refusal_payload(
                ctx, "system.restart-shell", "reversible", "not_hud_shell",
                "pid %s (%s) is not a HUD shell process" % (row["pid"], target["name"]))
        return target, None
    matches = []
    for row in table:
        if is_hud_shell(row["args"] or ""):
            matches.append(row)
    if not matches:
        return None, refusal_payload(
            ctx, "system.restart-shell", "reversible", "no_hud_shell",
            "no quickshell or nexuslink-hud process on this host")
    if len(matches) > 1:
        return None, refusal_payload(
            ctx, "system.restart-shell", "reversible", "ambiguous_target",
            "several HUD shell processes: %s; name one with --target"
            % ", ".join(str(row["pid"]) for row in matches))
    row = matches[0]
    target = {"name": process_name(row["args"]), "pid": row["pid"], "ppid": row["ppid"],
              "args": text(row["args"], 300)}
    hit = protected_hit({"name": target["name"], "args": row["args"]})
    if hit:
        return None, protected_refusal(ctx, target, hit[0], hit[1])
    return target, None


def supervise(ctx, target, kind, name):
    """Build the supervisor record, but only after its own name passes the guard.

    A launchd label or a systemd unit is the name the restart command carries,
    so the label can hold a protected rule even when the target's argv looks
    like a plain shell (for example ai.hermes.gateway-keeper). The guard runs
    here, before the command is built, and both plan and run reach the
    supervisor through this function, so both check it.
    """
    hit = protected_hit({"name": name, "args": name})
    if hit:
        annotated = dict(target)
        annotated["supervisor"] = kind
        annotated["supervisor_name"] = name
        return None, protected_refusal(ctx, annotated, hit[0], hit[1])
    if kind == "systemd-user":
        record = {"kind": kind, "unit": name,
                  "command": ["systemctl", "--user", "restart", name]}
    else:
        record = {"kind": kind, "label": name,
                  "command": ["launchctl", "kickstart", "-k",
                              "gui/%d/%s" % (os.getuid(), name)]}
    return record, None


def supervisor_for(target, ctx):
    """-> (supervisor dict, refusal payload or None)."""
    if ctx.mode == "fixture":
        cgroup = ctx.fixture_source().text("cgroup.txt", required=False)
        if cgroup:
            unit, user_manager, scope = parse_cgroup_unit(cgroup)
            if not unit:
                return None, None
            if not user_manager:
                return None, refusal_payload(
                    ctx, "system.restart-shell", "reversible", "no_supervisor",
                    "unit %s runs in the system slice; restarting it would need root" % unit)
            return supervise(ctx, target, "systemd-user", unit)
        raw = ctx.fixture_source().text("launchctl-list.txt", required=False)
        if raw:
            jobs, _ = parse_launchctl_list(raw)
            for job in jobs:
                if job.get("pid") == target["pid"] and job.get("label"):
                    label = job["label"]
                    return supervise(ctx, target, "launchd", label)
        return None, None
    if platform_name() == "linux":
        path = "/proc/%d/cgroup" % target["pid"]
        try:
            with open(path, "r", encoding="utf-8") as handle:
                unit, user_manager, scope = parse_cgroup_unit(handle.read())
        except OSError:
            return None, None
        if not unit or not unit.endswith(".service"):
            return None, None
        if not user_manager:
            return None, refusal_payload(
                ctx, "system.restart-shell", "reversible", "no_supervisor",
                "unit %s runs in the system slice; restarting it would need root, which "
                "the HUD does not get" % unit)
        return supervise(ctx, target, "systemd-user", unit)
    if platform_name() == "macos":
        result = run_cmd(["launchctl", "list"], timeout=10.0)
        if result["rc"] != 0:
            return None, None
        try:
            jobs, _ = parse_launchctl_list(result["out"])
        except DataProblem:
            return None, None
        for job in jobs:
            if job.get("pid") == target["pid"] and job.get("label"):
                label = job["label"]
                return supervise(ctx, target, "launchd", label)
    return None, None


def restart_shell_plan(ctx):
    target, refusal = resolve_shell_target(ctx)
    if refusal:
        return refusal
    if target is None:
        return refusal_payload(ctx, "system.restart-shell", "reversible", "no_hud_shell",
                               "target resolution returned nothing")
    supervisor, refusal = supervisor_for(target, ctx)
    if refusal:
        return refusal
    if supervisor is None:
        plan = {
            "changes": False,
            "confirm_required": True,
            "restartable": False,
            "command": None,
            "target": target,
            "blank_gap_s": [2, 4],
            "effect": "nothing would happen: no supervisor owns this process, so a "
                      "signal would leave the deck down until it is started by hand",
            "refusals": refusal_list(),
            "protected_check": {"verdict": "clear"},
            "notes": ["restarting needs launchd or systemd --user to respawn the shell; "
                      "the engine does not kill and hope"],
        }
        return refusal_payload(ctx, "system.restart-shell", "reversible", "no_supervisor",
                               "no launchd label or systemd user unit owns pid %s"
                               % target["pid"], plan=plan)
    target.update({"supervisor": supervisor["kind"]})
    if "unit" in supervisor:
        target["unit"] = supervisor["unit"]
    if "label" in supervisor:
        target["label"] = supervisor["label"]
    return {
        "ok": True,
        "source": SOURCE,
        "mode": ctx.mode,
        "generated_at": ctx.fixture_source().generated_at() if ctx.mode == "fixture" else iso_now(),
        "action": "system.restart-shell",
        "class": "reversible",
        "linux_only": False,
        "plan": {
            "changes": True,
            "confirm_required": True,
            "restartable": True,
            "command": supervisor["command"],
            "target": target,
            "blank_gap_s": [2, 4],
            "effect": "the deck is blank for 2 to 4 s while the shell respawns",
            "refusals": refusal_list(),
            "protected_check": {"verdict": "clear"},
            "notes": [
                "the target is re-read and the guard re-run immediately before the restart",
                "no killall, no pkill, no sudo: the supervisor does the restart",
            ],
        },
    }


def restart_shell_run(ctx):
    if ctx.mode == "fixture":
        return refusal_payload(ctx, "system.restart-shell", "reversible", "fixture_read_only",
                               "a fixture is a recording; restart the real shell on its host")
    if not ctx.confirm:
        # Still resolve the target: a protected pid must answer "protected" even when the
        # caller forgot --confirm, so the refusal is about the target, not just the flag.
        attempt, refusal = resolve_shell_target(ctx)
        if refusal and refusal.get("reason") == "protected":
            return refusal
        raise CallerError("confirm_required",
                          "system.restart-shell needs --confirm; nothing was changed")
    planned = restart_shell_plan(ctx)
    if not planned.get("ok"):
        return planned
    # Re-resolve from the live table so a pid recycled since plan time cannot slip through.
    target, refusal = resolve_shell_target(ctx, table=process_table(ctx))
    if refusal:
        return refusal
    if target is None:
        return refusal_payload(ctx, "system.restart-shell", "reversible", "no_hud_shell",
                               "target resolution returned nothing")
    hit = protected_hit(target)
    if hit:
        return protected_refusal(ctx, target, hit[0], hit[1])
    supervisor, refusal = supervisor_for(target, ctx)
    if refusal:
        return refusal
    if supervisor is None:
        return refusal_payload(ctx, "system.restart-shell", "reversible", "no_supervisor",
                               "no supervisor owns pid %s" % target["pid"])
    result = run_cmd(supervisor["command"], timeout=20.0)
    payload = {
        "ok": result["rc"] in (0, None) and not result.get("missing"),
        "source": SOURCE,
        "mode": ctx.mode,
        "generated_at": iso_now(),
        "action": "system.restart-shell",
        "class": "reversible",
        "applied": result["rc"] == 0,
        "command": supervisor["command"],
        "target": target,
        "blank_gap_s": [2, 4],
        "returncode": result["rc"],
        "stderr": first_line(result["err"], 200),
        "note": "the deck is blank for 2 to 4 s; the feed is valid again once quickshell repaints",
    }
    if not payload["ok"]:
        payload["reason"] = "restart command failed: %s" % (
            first_line(result["err"], 160) or "exit %s" % result["rc"])
    return payload


# ------------------------------------------------------------------- actions


def units_plan(ctx):
    return {
        "ok": True,
        "source": SOURCE,
        "mode": ctx.mode,
        "generated_at": ctx.fixture_source().generated_at() if ctx.mode == "fixture" else iso_now(),
        "action": "system.units",
        "class": "read",
        "linux_only": True,
        "plan": {
            "changes": False,
            "confirm_required": False,
            "command": ["systemctl", "--user", "--failed", "--output=json"],
            "follow_up": "one journalctl --user -u <unit> -n 1 per failed unit",
            "items": [],
            "bytes": 0,
            "effect": "reads only; nothing changes",
            "notes": ["Linux only: systemctl has no macOS equivalent"],
        },
    }


def units_run(ctx):
    return systemctl_units(ctx)


def jobs_plan(ctx):
    return {
        "ok": True,
        "source": SOURCE,
        "mode": ctx.mode,
        "generated_at": ctx.fixture_source().generated_at() if ctx.mode == "fixture" else iso_now(),
        "action": "system.failed-jobs",
        "class": "read",
        "linux_only": False,
        "plan": {
            "changes": False,
            "confirm_required": False,
            "command": ["launchctl", "list"],
            "filter": "last exit status != 0",
            "items": [],
            "bytes": 0,
            "effect": "reads only; nothing changes",
            "notes": ["macOS only: launchctl has no Linux equivalent"],
        },
    }


def jobs_run(ctx):
    return launchctl_jobs(ctx)


def errors_plan(ctx):
    if ctx.mode == "live" and platform_name() == "macos":
        command = ["log", "show", "--last", ctx.window, "--style", "ndjson",
                   "--predicate", 'messageType == "Error" OR messageType == "Fault"']
        framework = "log-show"
    elif ctx.mode == "live":
        command = ["journalctl", "-p", "err", "--since", "-%s" % ctx.window, "-o", "json",
                   "--no-pager"]
        framework = "journalctl"
    else:
        command = None
        framework = "fixture"
    return {
        "ok": True,
        "source": SOURCE,
        "mode": ctx.mode,
        "generated_at": ctx.fixture_source().generated_at() if ctx.mode == "fixture" else iso_now(),
        "action": "system.recent-errors",
        "class": "read",
        "linux_only": False,
        "plan": {
            "changes": False,
            "confirm_required": False,
            "command": command,
            "framework": framework,
            "window": ctx.window,
            "rank_by": "count per sender, capped at %d senders" % LIMITS["senders"],
            "items": [],
            "bytes": 0,
            "effect": "reads only; nothing changes",
            "notes": [
                "macOS reads log show; Linux reads journalctl -p err (the Linux branch is "
                "the one that needs the Linux host)",
            ],
        },
    }


def errors_run(ctx):
    return recent_errors(ctx)


def crash_reports_plan(ctx):
    directory, display = reports_source(ctx)
    return {
        "ok": True,
        "source": SOURCE,
        "mode": ctx.mode,
        "generated_at": ctx.fixture_source().generated_at() if ctx.mode == "fixture" else iso_now(),
        "action": "system.crash-reports",
        "class": "read",
        "linux_only": False,
        "plan": {
            "changes": False,
            "confirm_required": False,
            "command": None,
            "reads": display,
            "glob": "*.ips",
            "items": [],
            "bytes": 0,
            "effect": "reads only; nothing changes",
            "notes": ["newest first by the .ips header timestamp"],
        },
    }


def crash_reports_run(ctx):
    return crash_reports(ctx)


def quarantine_plan(ctx):
    if ctx.older_than_days is None:
        raise CallerError("missing_argument",
                          "system.crash-quarantine needs --older-than-days N")
    if ctx.older_than_days < 0:
        raise CallerError("bad_argument",
                          "--older-than-days must be zero or more, got %d"
                          % ctx.older_than_days)
    listing = crash_reports(ctx, fresh=True)
    if not listing.get("ok"):
        return listing
    eligible = [report for report in listing.get("reports", [])
                if report.get("age_days") is not None
                and report["age_days"] > ctx.older_than_days]
    if ctx.mode == "fixture":
        reference = mode_now(ctx)
        stamp = (datetime.datetime.fromtimestamp(reference, datetime.timezone.utc)
                 .strftime("%Y%m%dT%H%M%SZ") if reference is not None else "fixture")
    else:
        stamp = utc_now().strftime("%Y%m%dT%H%M%SZ")
    root = os.path.expanduser(ctx.state_dir or DEFAULT_STATE_ROOT)
    destination = os.path.join(root, "quarantine", "crash-reports", stamp)
    total = sum(report.get("bytes") or 0 for report in eligible)
    refused = listing.get("refused") or []
    return {
        "ok": True,
        "source": SOURCE,
        "mode": ctx.mode,
        "generated_at": ctx.fixture_source().generated_at() if ctx.mode == "fixture" else iso_now(),
        "action": "system.crash-quarantine",
        "class": "reversible",
        "linux_only": False,
        "refused": refused,
        "reasons": listing.get("reasons") or {},
        "plan": {
            "changes": True,
            "confirm_required": True,
            "command": None,
            "destination": tilde(destination),
            "manifest": tilde(os.path.join(destination, "MANIFEST.jsonl")),
            "older_than_days": ctx.older_than_days,
            "items": eligible,
            "count": len(eligible),
            "refused": refused,
            "bytes": total,
            "effect": "moves %d report(s), %d bytes, out of the live crash directory; "
                      "each move writes a MANIFEST row and can be moved back"
                      % (len(eligible), total),
            "undo": "every row in MANIFEST.jsonl carries src and dst; move dst back to src to undo",
            "notes": [
                "a report with no readable date is never moved",
                "an entry that resolves outside the reports directory is refused and never moved",
                "the live directory is read first; nothing is deleted",
            ],
        },
    }


def quarantine_run(ctx):
    if ctx.mode == "fixture":
        return refusal_payload(ctx, "system.crash-quarantine", "reversible", "fixture_read_only",
                               "a fixture is a recording; quarantine the real reports on the host")
    planned = quarantine_plan(ctx)
    if not planned.get("ok"):
        return planned
    if not ctx.confirm:
        raise CallerError("confirm_required",
                          "system.crash-quarantine needs --confirm; nothing was moved")
    plan = planned["plan"]
    if not plan["items"]:
        return {
            "ok": True,
            "source": SOURCE,
            "mode": ctx.mode,
            "generated_at": iso_now(),
            "action": "system.crash-quarantine",
            "class": "reversible",
            "applied": False,
            "moved": 0,
            "bytes": 0,
            "refused": plan.get("refused") or [],
            "reasons": planned.get("reasons") or {},
            "reason": "no crash report older than %d days" % ctx.older_than_days,
            "destination": plan["destination"],
        }
    directory, _display = reports_source(ctx)
    destination = os.path.expanduser(plan["destination"])
    manifest = os.path.join(destination, "MANIFEST.jsonl")
    os.makedirs(destination, exist_ok=True)
    rows = []
    log = []
    moved_bytes = 0
    manifest_errors = 0
    for report in plan["items"]:
        src = os.path.join(directory, report["name"])
        dst = os.path.join(destination, report["name"])
        size = report.get("bytes")
        # The plan already dropped entries that resolve outside the reports
        # root; check again here so a target swapped in after the plan is
        # still refused before it is hashed or moved.
        if not within_root(src, directory):
            rows.append({"name": report["name"], "moved": False,
                         "reason": "resolves outside the reports directory; refused"})
            continue
        digest = sha256_file(src)
        row = {
            "ts": iso_now(),
            "action": "system.crash-quarantine",
            "class": "reversible",
            "name": report["name"],
            "src": tilde(src),
            "dst": tilde(dst),
            "bytes": size,
            "sha256": digest,
            "crash_date": report.get("date"),
            "age_days": report.get("age_days"),
            "older_than_days": ctx.older_than_days,
            "moved": False,
            "state": "pending",
        }
        # Write-ahead: the row reaches the disk before the file leaves the
        # reports directory, and a row that cannot be written blocks the move.
        log.append(row)
        try:
            write_manifest(manifest, log)
        except OSError as exc:
            log.pop()
            manifest_errors += 1
            rows.append({"name": report["name"], "moved": False,
                         "reason": "MANIFEST row was not written: %s"
                                   % (exc.strerror or str(exc))})
            continue
        try:
            os.replace(src, dst)
        except OSError:
            try:
                shutil.move(src, dst)
            except OSError as exc:
                row["state"] = "failed"
                row["reason"] = exc.strerror or str(exc)
                try:
                    write_manifest(manifest, log)
                except OSError:
                    manifest_errors += 1
                rows.append({"name": report["name"], "moved": False,
                             "reason": row["reason"]})
                continue
        row["moved"] = True
        row["state"] = "moved"
        try:
            write_manifest(manifest, log)
        except OSError as exc:
            manifest_errors += 1
            row["reason"] = ("the report moved but its MANIFEST state update failed: %s"
                             % (exc.strerror or str(exc)))
        rows.append(row)
        moved_bytes += size or 0
    moved = [row for row in rows if row.get("moved")]
    ok = len(moved) == len(rows) and manifest_errors == 0
    if ok:
        reason = None
    elif manifest_errors and not moved:
        reason = "no report was moved: its MANIFEST row could not be written"
    elif manifest_errors:
        reason = "some files could not be moved or their MANIFEST rows could not be written"
    else:
        reason = "some files could not be moved"
    return {
        "ok": ok,
        "source": SOURCE,
        "mode": ctx.mode,
        "generated_at": iso_now(),
        "action": "system.crash-quarantine",
        "class": "reversible",
        "applied": True,
        "moved": len(moved),
        "failed": len(rows) - len(moved),
        "manifest_errors": manifest_errors,
        "bytes": moved_bytes,
        "refused": plan.get("refused") or [],
        "reasons": planned.get("reasons") or {},
        "destination": tilde(destination),
        "manifest": tilde(manifest),
        "rows": rows,
        "undo": "move each row's dst back to src",
        "reason": reason,
    }


def restart_audio_plan(ctx):
    if ctx.mode == "live" and platform_name() != "linux":
        return refusal_payload(
            ctx, "system.restart-audio", "reversible", "linux_only",
            "coreaudiod is a root daemon: restarting it needs sudo, which the HUD does "
            "not get. Use the Sound menu or log out.")
    return {
        "ok": True,
        "source": SOURCE,
        "mode": ctx.mode,
        "generated_at": ctx.fixture_source().generated_at() if ctx.mode == "fixture" else iso_now(),
        "action": "system.restart-audio",
        "class": "reversible",
        "linux_only": True,
        "plan": {
            "changes": True,
            "confirm_required": True,
            "command": ["systemctl", "--user", "restart", "pipewire", "wireplumber"],
            "effect": "audio drops for about a second while PipeWire and WirePlumber respawn",
            "refusals": [],
            "notes": [
                "Linux only: the macOS equivalent is coreaudiod, which needs sudo",
                "apps holding a stream may need their output device re-selected",
            ],
        },
    }


def restart_audio_run(ctx):
    planned = restart_audio_plan(ctx)
    if not planned.get("ok"):
        return planned
    if ctx.mode == "fixture":
        return refusal_payload(ctx, "system.restart-audio", "reversible", "fixture_read_only",
                               "a fixture is a recording; restart audio on the real host")
    if not ctx.confirm:
        raise CallerError("confirm_required",
                          "system.restart-audio needs --confirm; nothing was changed")
    command = planned["plan"]["command"]
    result = run_cmd(command, timeout=30.0)
    return {
        "ok": result["rc"] == 0,
        "source": SOURCE,
        "mode": ctx.mode,
        "generated_at": iso_now(),
        "action": "system.restart-audio",
        "class": "reversible",
        "applied": result["rc"] == 0,
        "command": command,
        "returncode": result["rc"],
        "stderr": first_line(result["err"], 200),
        "reason": None if result["rc"] == 0 else (
            "systemctl restart failed: %s" % (first_line(result["err"], 160) or result["rc"])),
    }


def uptime_plan(ctx):
    return {
        "ok": True,
        "source": SOURCE,
        "mode": ctx.mode,
        "generated_at": ctx.fixture_source().generated_at() if ctx.mode == "fixture" else iso_now(),
        "action": "system.uptime",
        "class": "read",
        "linux_only": False,
        "plan": {
            "changes": False,
            "confirm_required": False,
            "command": ["sysctl", "-n", "kern.boottime"] if platform_name() == "macos" else None,
            "items": [],
            "bytes": 0,
            "effect": "reads only; nothing changes",
            "notes": ["leaf names reuse F1 mac_link (uptime_s, uptime_human); F1 nests them "
                      "under mac, this plan keeps them at the top level"],
        },
    }


def uptime_run(ctx):
    return uptime_read(ctx)


def load_plan(ctx):
    return {
        "ok": True,
        "source": SOURCE,
        "mode": ctx.mode,
        "generated_at": ctx.fixture_source().generated_at() if ctx.mode == "fixture" else iso_now(),
        "action": "system.load",
        "class": "read",
        "linux_only": False,
        "plan": {
            "changes": False,
            "confirm_required": False,
            "command": ["sysctl", "-n", "vm.loadavg"] if platform_name() == "macos" else None,
            "items": [],
            "bytes": 0,
            "effect": "reads only; nothing changes",
            "notes": ["leaf names reuse F1 mac_link (avg, load1_frac, cores); F1 nests them "
                      "under mac.load, this plan keeps them at the top level"],
        },
    }


def load_run(ctx):
    return load_read(ctx)


_SPECS = (
    ("system.units", "read", True,
     "Failed systemd user units with name, description and last log line.",
     units_plan, units_run),
    ("system.failed-jobs", "read", False,
     "launchctl jobs whose last exit status is non-zero, with label, pid and exit code.",
     jobs_plan, jobs_run),
    ("system.recent-errors", "read", False,
     "Errors and faults from the last hour, ranked by count per sender.",
     errors_plan, errors_run),
    ("system.crash-reports", "read", False,
     "Crash reports in ~/Library/Logs/DiagnosticReports, newest first.",
     crash_reports_plan, crash_reports_run),
    ("system.crash-quarantine", "reversible", False,
     "Move crash reports older than N days into quarantine, one MANIFEST row per file.",
     quarantine_plan, quarantine_run),
    ("system.restart-shell", "reversible", False,
     "Restart the HUD shell through its supervisor; never the gateway, dispatcher or relay.",
     restart_shell_plan, restart_shell_run),
    ("system.restart-audio", "reversible", True,
     "Restart PipeWire and WirePlumber (Linux); the Mac has no non-root equivalent.",
     restart_audio_plan, restart_audio_run),
    ("system.uptime", "read", False,
     "Host uptime; the leaf key names match F1 mac_link.",
     uptime_plan, uptime_run),
    ("system.load", "read", False,
     "Load average and cores; the leaf key names match F1 mac_link.",
     load_plan, load_run),
)

def _wrap(fn):
    """ACTIONS entries accept None, a dict or a Ctx: F8a's calling convention is ours too."""

    def call(ctx=None):
        return fn(coerce_ctx(ctx))

    call.__name__ = getattr(fn, "__name__", "call")
    return call


ACTIONS = {
    name: {"class": cls, "doc": doc, "plan": _wrap(plan), "run": _wrap(run),
           "linux_only": bool(linux_only)}
    for name, cls, linux_only, doc, plan, run in _SPECS
}

CLASS_TABLE = [(name, spec["class"], spec["linux_only"]) for name, spec in ACTIONS.items()]


# --------------------------------------------------------------------- CLI


def _cli(argv):
    """Parse and dispatch. Returns (payload, exit_code); prints nothing."""
    parser = argparse.ArgumentParser(
        prog="hudfix_system.py",
        description="HUD maintenance engine: system actions (F8f).")
    parser.add_argument("--action", metavar="NAME", help="one key from ACTIONS")
    parser.add_argument("--plan", "--dry-run", action="store_true", dest="plan",
                        help="print the dry-run plan; never changes state "
                             "(--dry-run is an alias for --plan)")
    parser.add_argument("--list", action="store_true", help="list actions and their classes")
    parser.add_argument("--self-check", action="store_true", help="run the proof suite")
    add_ctx_args(parser)
    args = parser.parse_args(argv)

    if args.self_check:
        return None, self_check()
    if args.list:
        lines = ["%-26s %-11s %s" % ("action", "class", "host") for _ in range(1)]
        for name, cls, linux_only in CLASS_TABLE:
            lines.append("%-26s %-11s %s" % (name, cls, "linux" if linux_only else "any"))
        print("\n".join(lines))
        return None, EXIT_OK
    if not args.action:
        parser.error("--action NAME, --list or --self-check is required")
    name = args.action
    spec = ACTIONS.get(name)
    if spec is None:
        payload = {
            "ok": False,
            "source": SOURCE,
            "mode": "fixture" if args.fixture else "live",
            "generated_at": iso_now(),
            "action": name,
            "reason": "unknown_action",
            "detail": "known actions: %s" % ", ".join(sorted(ACTIONS)),
        }
        return payload, EXIT_PROGRAMMING
    ctx = ctx_from_args(args)

    def fixture_stamp():
        if ctx.mode != "fixture":
            return iso_now()
        try:
            return ctx.fixture_source().generated_at()
        except CallerError:
            return None

    try:
        payload = (spec["plan"] if args.plan else spec["run"])(ctx)
    except CallerError as exc:
        payload = {
            "ok": False,
            "source": SOURCE,
            "mode": ctx.mode,
            "generated_at": fixture_stamp(),
            "action": name,
            "class": spec["class"],
            "reason": exc.reason,
            "detail": exc.detail,
        }
        return payload, EXIT_PROGRAMMING
    except DataProblem as exc:
        payload = failure(ctx.mode, exc, action=name, **{"class": spec["class"]})
        if ctx.mode == "fixture":
            payload["generated_at"] = fixture_stamp()
        return payload, EXIT_OK
    except (KeyboardInterrupt, SystemExit):
        raise
    except BaseException as exc:  # a bug is a bug: report it and exit 2
        payload = {
            "ok": False,
            "source": SOURCE,
            "mode": ctx.mode,
            "generated_at": iso_now(),
            "action": name,
            "class": spec["class"],
            "reason": "programming_error",
            "detail": tilde_text("%s: %s" % (type(exc).__name__, exc)),
        }
        return payload, EXIT_PROGRAMMING
    if isinstance(payload, dict):
        payload.setdefault("class", spec["class"])
    if ctx.mode == "fixture" and isinstance(payload, dict) and payload.get("generated_at") is None:
        payload["generated_at"] = ctx.fixture_source().generated_at()
        if payload["generated_at"] is None:
            reasons = payload.get("reasons")
            if not isinstance(reasons, dict):
                reasons = {}
                payload["reasons"] = reasons
            reasons.setdefault("generated_at", "fixture carries no generated_at")
    return payload, EXIT_OK


def main(argv=None):
    payload, code = _cli(argv)
    if payload is not None:
        compact = False
        for arg in (argv if argv is not None else sys.argv[1:]):
            if arg == "--json":
                compact = True
        emit(payload, compact)
    return code


# --------------------------------------------------------------- self-check


class Checker(object):
    def __init__(self):
        self.failures = []
        self.count = 0

    def ok(self, condition, label, detail=""):
        self.count += 1
        if condition:
            print("ok   %s" % label)
        else:
            print("FAIL %s%s" % (label, (": " + detail) if detail else ""))
            self.failures.append(label)
        return bool(condition)

    def equal(self, actual, expected, label):
        return self.ok(actual == expected, label, "expected %r, got %r" % (expected, actual))


def _fixture_dir():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        os.pardir, "fixtures", "hudfix")


def _run_json(argv):
    """Run _cli and serialise its payload so two fixture runs can be compared."""
    payload, code = _cli(argv)
    if payload is None:
        raise AssertionError("_cli returned no payload for %r" % (argv,))
    return payload, code, json.dumps(payload, sort_keys=True, ensure_ascii=False)


def _spawn_decoy(extra_arg):
    """A harmless child whose argv carries ``extra_arg``. Killed by the caller."""
    return subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(30)", extra_arg],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)


def self_check():
    check = Checker()
    fixture = _fixture_dir()
    temp_root = None
    decoys = []
    try:
        temp_root = tempfile.mkdtemp(prefix="hudfix-selftest-")
        # 1. the table itself
        print("-- table")
        check.equal(len(ACTIONS), 9, "nine actions are registered")
        for name, spec in ACTIONS.items():
            check.ok(spec["class"] in CLASSES, "%s has a known class" % name, spec["class"])
            check.ok(isinstance(spec["doc"], str) and len(spec["doc"]) > 10,
                     "%s has a one-line doc" % name)
            check.ok(callable(spec["plan"]) and callable(spec["run"]),
                     "%s plan and run are callable" % name)
            check.ok(isinstance(spec["linux_only"], bool), "%s linux_only is a bool" % name)
        check.equal([name for name, spec in ACTIONS.items() if spec["class"] == "read"],
                    ["system.units", "system.failed-jobs", "system.recent-errors",
                     "system.crash-reports", "system.uptime", "system.load"],
                    "read actions are exactly the six readers")

        # 2. read actions parse their recorded fixtures
        print("-- fixtures")
        payload, code, _ = _run_json(["--action", "system.failed-jobs",
                                      "--fixture", fixture, "--json"])
        check.equal(code, 0, "failed-jobs fixture exits 0")
        check.ok(payload.get("ok") is True, "failed-jobs fixture is ok")
        jobs = payload.get("jobs") or []
        check.ok(len(jobs) >= 1, "failed-jobs fixture lists failed jobs", str(len(jobs)))
        check.ok(all(job.get("last_exit_status") not in (0, None) for job in jobs),
                 "every listed job has a non-zero exit status")
        check.ok(any(job.get("signal") == 9 for job in jobs),
                 "a SIGKILL job is described as signal 9")
        check.ok(all(job.get("label") for job in jobs), "every job has a label")

        payload, code, _ = _run_json(["--action", "system.units",
                                      "--fixture", fixture, "--json"])
        check.equal(code, 0, "units fixture exits 0")
        units = payload.get("units") or []
        check.equal(len(units), 2, "units fixture lists two failed units")
        check.ok(all(unit.get("description") for unit in units),
                 "every unit has a description")
        check.ok(all(unit.get("last_log") for unit in units),
                 "every unit has its last log line")

        payload, code, _ = _run_json(["--action", "system.recent-errors",
                                      "--fixture", fixture, "--json"])
        check.equal(code, 0, "recent-errors fixture exits 0")
        senders = payload.get("senders") or []
        counts = [row["count"] for row in senders]
        check.ok(counts == sorted(counts, reverse=True), "senders are ranked by count")
        check.ok(payload.get("kinds", {}).get("Fault") == 2,
                 "the two Fault rows are counted", payload.get("kinds"))
        check.ok(payload.get("senders_total") >= 3, "several senders are ranked")
        check.ok(sum(counts) <= payload.get("parsed", 0),
                 "ranked counts never exceed the parsed rows")

        journal_fixture = os.path.join(fixture, "journalctl-errors.ndjson")
        payload, code, _ = _run_json(["--action", "system.recent-errors",
                                      "--fixture", journal_fixture, "--json"])
        check.equal(code, 0, "journal fixture file exits 0")
        check.ok(payload.get("ok") is True and payload.get("parsed") == 3,
                 "the journal capture parses three rows",
                 payload.get("parsed"))

        single_capture = os.path.join(fixture, "launchctl-list.txt")
        payload, code, _ = _run_json(["--action", "system.failed-jobs",
                                      "--fixture", single_capture, "--json"])
        check.equal(code, 0, "a single launchctl capture file exits 0")
        check.ok(payload.get("ok") is True and payload.get("failed_count", 0) >= 1,
                 "a single launchctl capture file is read",
                 str(payload.get("failed_count")))

        single_ips = os.path.join(fixture, "crash", "HudCrash-2026-10-20-090000.ips")
        payload, code, _ = _run_json(["--action", "system.crash-reports",
                                      "--fixture", single_ips, "--json"])
        check.equal(code, 0, "a single .ips file fixture exits 0")
        check.equal(len(payload.get("reports") or []), 1,
                    "a single .ips file fixture lists exactly that report")

        payload, code, _ = _run_json(["--action", "system.crash-reports",
                                      "--fixture", fixture, "--json"])
        check.equal(code, 0, "crash-reports fixture exits 0")
        reports = payload.get("reports") or []
        check.equal(len(reports), 2, "two .ips fixtures are listed")
        check.ok(reports[0]["app"] == "nexuslink-hud", "newest report is first",
                 reports[0]["app"] if reports else "none")
        check.ok(all(report.get("date") for report in reports),
                 "every report has a header date")

        payload, code, _ = _run_json(["--action", "system.uptime",
                                      "--fixture", fixture, "--json"])
        check.ok(payload.get("ok") is True and isinstance(payload.get("uptime_s"), int),
                 "uptime fixture parses to whole seconds", payload.get("uptime_s"))
        check.ok(payload.get("uptime_human"), "uptime has the human form")
        # the uptime fixture has to agree with itself (R2-3): one boot epoch, one
        # ctime text, one uptime text and one fixture clock
        with open(os.path.join(fixture, "uptime.json"), "r", encoding="utf-8") as handle:
            uptime_fixture = json.load(handle)
        with open(os.path.join(fixture, "meta.json"), "r", encoding="utf-8") as handle:
            fixture_meta = json.load(handle)
        fixture_boot = parse_boottime(uptime_fixture.get("kern_boottime"))
        fixture_text_s = parse_uptime_text(uptime_fixture.get("uptime_text"))
        fixture_now = epoch_from_iso(fixture_meta.get("now"))
        check.ok(fixture_boot is not None and fixture_text_s is not None
                 and fixture_now == fixture_boot + fixture_text_s,
                 "the uptime fixture text agrees with its boot epoch and meta.now",
                 "%r + %r != %r" % (fixture_boot, fixture_text_s, fixture_now))
        if fixture_boot is not None:
            boot_moment = datetime.datetime.fromtimestamp(fixture_boot, datetime.timezone.utc)
            months = ("Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
            boot_words = "%s %02d %02d:%02d:%02d %04d" % (
                months[boot_moment.month - 1], boot_moment.day, boot_moment.hour,
                boot_moment.minute, boot_moment.second, boot_moment.year)
            check.ok(boot_words in (uptime_fixture.get("kern_boottime") or ""),
                     "the kern_boottime ctime text names its own epoch", boot_words)

        payload, code, _ = _run_json(["--action", "system.load",
                                      "--fixture", fixture, "--json"])
        check.ok(payload.get("avg") == [3.42, 3.1, 2.87], "load triple parses",
                 payload.get("avg"))
        check.equal(payload.get("cores"), 12, "core count parses")
        check.ok(isinstance(payload.get("load1_frac"), float),
                 "load1_frac is computed")

        # 3. fixture purity: no clock, no host, byte-identical repeat
        print("-- purity")
        first = _run_json(["--action", "system.failed-jobs", "--fixture", fixture, "--json"])
        second = _run_json(["--action", "system.failed-jobs", "--fixture", fixture, "--json"])
        check.equal(first[2], second[2], "two fixture runs are byte-identical")
        check.equal(first[0].get("generated_at"), "2026-10-23T00:00:00Z",
                    "fixture generated_at comes from the fixture")
        before = os.listdir(os.path.expanduser(DEFAULT_STATE_ROOT)) \
            if os.path.isdir(os.path.expanduser(DEFAULT_STATE_ROOT)) else []
        _run_json(["--action", "system.crash-reports", "--fixture", fixture, "--json"])
        after = os.listdir(os.path.expanduser(DEFAULT_STATE_ROOT)) \
            if os.path.isdir(os.path.expanduser(DEFAULT_STATE_ROOT)) else []
        check.equal(sorted(after), sorted(before), "a fixture run writes no cache file")

        # 4. a missing fixture path is a caller error, never a live fallback
        missing_payload, missing_code = _cli(["--action", "system.failed-jobs",
                                              "--fixture", "/nope/hudfix", "--json"])
        check.equal(missing_code, 2, "missing fixture path exits 2")
        check.equal(missing_payload.get("reason"), "fixture_missing",
                    "missing fixture path says fixture_missing")

        # 4b. the cache entry lives exactly 10 s; recent-errors has a 60 s override
        # (D4a). cache_read and cache_store take a clock, so no host call is needed.
        print("-- cache interval")
        cache_ctx = Ctx(state_dir=os.path.join(temp_root, "cache"), now=1000000.0)
        cache_store(cache_ctx, "system.failed-jobs",
                    {"ok": True, "source": SOURCE, "action": "system.failed-jobs"}, 1000000.0)
        inside = cache_read(cache_ctx, "system.failed-jobs", 1000009.9)
        check.ok(isinstance(inside, dict) and inside.get("cached") is True,
                 "an entry 9.9 s old is a cache hit", inside)
        check.equal(inside.get("cache_age_s") if isinstance(inside, dict) else None, 9.9,
                    "the hit reports cache_age_s 9.9")
        check.equal(cache_read(cache_ctx, "system.failed-jobs", 1000010.0), None,
                    "an entry at exactly 10.0 s is a cache miss")
        cache_store(cache_ctx, "system.recent-errors",
                    {"ok": True, "source": SOURCE, "action": "system.recent-errors"}, 1000000.0)
        check.ok(isinstance(cache_read(cache_ctx, "system.recent-errors", 1000059.9), dict),
                 "recent-errors is still a hit at 59.9 s (60 s override)")
        check.equal(cache_read(cache_ctx, "system.recent-errors", 1000060.0), None,
                    "recent-errors expires at exactly 60.0 s")

        # 4c. malformed or empty fixture input is an answer (ok false, exit 0),
        # never a crash. This is the case D1 slipped through.
        print("-- malformed input")
        empty_dir = os.path.join(temp_root, "empty-fixture")
        os.makedirs(empty_dir)
        for name in ("system.units", "system.failed-jobs", "system.recent-errors",
                     "system.crash-reports", "system.uptime", "system.load"):
            payload, code = _cli(["--action", name, "--fixture", empty_dir, "--json"])
            check.equal(code, 0, "%s on an empty fixture directory exits 0" % name)
            check.ok(payload.get("ok") is False and bool(payload.get("reason")),
                     "%s on an empty fixture directory says ok false with a reason" % name,
                     payload.get("reason"))

        bad_json = os.path.join(temp_root, "bad-json")
        shutil.copytree(fixture, bad_json)
        with open(os.path.join(bad_json, "uptime.json"), "w", encoding="utf-8") as handle:
            handle.write('{"kern_boottime": ')
        for name in ("system.uptime", "system.load"):
            payload, code = _cli(["--action", name, "--fixture", bad_json, "--json"])
            check.equal(code, 0, "%s on malformed JSON exits 0" % name)
            check.ok(payload.get("ok") is False and payload.get("kind") == "malformed",
                     "%s on malformed JSON says malformed" % name, payload.get("kind"))

        array_json = os.path.join(temp_root, "array-json")
        shutil.copytree(fixture, array_json)
        with open(os.path.join(array_json, "uptime.json"), "w", encoding="utf-8") as handle:
            handle.write("[]\n")
        for name in ("system.uptime", "system.load"):
            payload, code = _cli(["--action", name, "--fixture", array_json, "--json"])
            check.equal(code, 0, "%s on an array-shaped uptime.json exits 0" % name)
            check.ok(payload.get("ok") is False and payload.get("kind") == "malformed",
                     "%s on an array-shaped uptime.json says malformed" % name,
                     payload.get("kind"))

        units_array = os.path.join(temp_root, "units-array")
        shutil.copytree(fixture, units_array)
        with open(os.path.join(units_array, "journalctl-last.json"), "w",
                  encoding="utf-8") as handle:
            handle.write("[1]\n")
        payload, code = _cli(["--action", "system.units", "--fixture", units_array, "--json"])
        check.equal(code, 0, "units with an array-shaped journalctl-last.json exits 0")
        check.ok(payload.get("ok") is False and payload.get("kind") == "malformed",
                 "units with an array-shaped journalctl-last.json says malformed",
                 payload.get("kind"))

        units_object = os.path.join(temp_root, "units-object")
        shutil.copytree(fixture, units_object)
        with open(os.path.join(units_object, "systemctl-failed.json"), "w",
                  encoding="utf-8") as handle:
            handle.write("{}\n")
        payload, code = _cli(["--action", "system.units", "--fixture", units_object, "--json"])
        check.equal(code, 0, "units with an object-shaped systemctl-failed.json exits 0")
        check.ok(payload.get("ok") is False and payload.get("kind") == "malformed",
                 "units with an object-shaped systemctl-failed.json says malformed",
                 payload.get("kind"))

        # 4d. a fixture with no clock has no uptime: no epoch-0 fallback, no
        # negative seconds, ok false with a reason (R2-2)
        print("-- no-clock uptime")
        no_clock = os.path.join(temp_root, "no-clock")
        shutil.copytree(fixture, no_clock)
        with open(os.path.join(no_clock, "meta.json"), "r", encoding="utf-8") as handle:
            no_clock_meta = json.load(handle)
        no_clock_meta.pop("now", None)
        with open(os.path.join(no_clock, "meta.json"), "w", encoding="utf-8") as handle:
            json.dump(no_clock_meta, handle, indent=2)
        payload, code = _cli(["--action", "system.uptime", "--fixture", no_clock, "--json"])
        payload = payload or {}
        check.equal(code, 0, "a fixture with no clock exits 0")
        check.ok(payload.get("ok") is False, "a fixture with no clock says ok false",
                 repr(payload.get("ok")))
        check.ok(payload.get("uptime_s") is None,
                 "a fixture with no clock reports no uptime_s", repr(payload.get("uptime_s")))
        check.ok(payload.get("uptime_human") is None,
                 "a fixture with no clock reports no uptime_human")
        check.ok("no clock" in (payload.get("reason") or ""),
                 "a fixture with no clock gives a reason", str(payload.get("reason")))
        corrupt_meta = os.path.join(temp_root, "corrupt-meta")
        shutil.copytree(fixture, corrupt_meta)
        with open(os.path.join(corrupt_meta, "meta.json"), "w", encoding="utf-8") as handle:
            handle.write('{"generated_at": ')
        payload, code = _cli(["--action", "system.uptime", "--fixture", corrupt_meta, "--json"])
        payload = payload or {}
        check.equal(code, 0, "a corrupt meta.json exits 0")
        check.ok(payload.get("ok") is False and payload.get("uptime_s") is None,
                 "a corrupt meta.json answers ok false with no uptime",
                 str(payload.get("reason")))

        # 4e. hostile output: bytes that are not UTF-8 out of launchctl (the
        # module's own timeout can cut a character in half), and a capture
        # nested past the reader's depth cap. Both answer, neither raises.
        print("-- hostile output")
        stub_dir = os.path.join(temp_root, "bin")
        os.makedirs(stub_dir)
        launchctl_stub = os.path.join(stub_dir, "launchctl")
        with open(launchctl_stub, "w", encoding="utf-8") as handle:
            handle.write("#!/bin/sh\nprintf 'PID\\tStatus\\tLabel\\n'; "
                         "printf -- '-\\t0\\tcom.example.hud.\\377\\n'\n")
        os.chmod(launchctl_stub, 0o755)
        saved_path = os.environ.get("PATH", "")
        try:
            os.environ["PATH"] = stub_dir + os.pathsep + saved_path
            payload, code = _cli(["--action", "system.failed-jobs", "--json",
                                  "--state-dir", os.path.join(temp_root, "hostile-state-a")])
        finally:
            os.environ["PATH"] = saved_path
        payload = payload or {}
        check.equal(code, 0, "non-UTF-8 launchctl output exits 0")
        check.ok(payload.get("ok") is False and payload.get("kind") == "malformed",
                 "non-UTF-8 launchctl output says ok false and malformed",
                 str(payload.get("reason")))
        check.ok("not valid UTF-8" in (payload.get("reason") or ""),
                 "the lossy launchctl refusal names the encoding",
                 str(payload.get("reason")))

        deep_capture = os.path.join(temp_root, "deep.ndjson")
        depth = 1200
        with open(deep_capture, "w", encoding="utf-8") as handle:
            handle.write("{" + '"a":{' * depth + "}" + "}" * depth + "\n")
        payload, code = _cli(["--action", "system.recent-errors", "--json",
                              "--fixture", deep_capture,
                              "--state-dir", os.path.join(temp_root, "hostile-state-b")])
        payload = payload or {}
        check.equal(code, 0, "a log capture nested 1200 deep exits 0")
        check.ok(payload.get("ok") is False and payload.get("kind") == "malformed",
                 "a log capture nested 1200 deep says ok false and malformed",
                 str(payload.get("reason")))
        check.ok("nested" in (payload.get("reason") or ""),
                 "the nesting refusal names the depth", str(payload.get("reason")))

        # 4g. a live cache file nested past the depth cap. json.load raised
        # RecursionError there (exit 2); the bounded loader answers malformed.
        print("-- hostile cache")
        cache_state = os.path.join(temp_root, "deep-cache-state")
        os.makedirs(cache_state)
        cache_file = os.path.join(cache_state, "hudfix_system.system.failed-jobs.json")
        for label, levels in (("1200", 1200), ("100", 100)):
            with open(cache_file, "w", encoding="utf-8") as handle:
                handle.write("[" * levels + "]" * levels)
            payload, code = _cli(["--action", "system.failed-jobs", "--json",
                                  "--state-dir", cache_state])
            payload = payload or {}
            check.equal(code, 0, "a cache nested %s deep exits 0" % label)
            check.ok(payload.get("ok") is False and payload.get("kind") == "malformed",
                     "a cache nested %s deep says ok false and malformed" % label,
                     str(payload.get("reason")))
            check.ok("nested" in (payload.get("reason") or ""),
                     "the cache refusal %s names the nesting" % label,
                     str(payload.get("reason")))
        with open(cache_file, "w", encoding="utf-8") as handle:
            handle.write("{not json at all")
        clean_bin = os.path.join(temp_root, "bin-clean")
        os.makedirs(clean_bin)
        clean_launchctl = os.path.join(clean_bin, "launchctl")
        with open(clean_launchctl, "w", encoding="utf-8") as handle:
            handle.write("#!/bin/sh\nprintf 'PID\\tStatus\\tLabel\\n'; "
                         "printf -- '-\\t0\\tcom.example.ok\\n'\n")
        os.chmod(clean_launchctl, 0o755)
        saved_path = os.environ.get("PATH", "")
        try:
            os.environ["PATH"] = clean_bin + os.pathsep + saved_path
            payload, code = _cli(["--action", "system.failed-jobs", "--json",
                                  "--state-dir", cache_state])
        finally:
            os.environ["PATH"] = saved_path
        payload = payload or {}
        check.equal(code, 0, "a corrupt cache still falls through to a probe")
        check.ok(payload.get("ok") is True and payload.get("cached") is not True,
                 "a corrupt cache is treated as no cache, not as hostile nesting",
                 str(payload.get("reason")))

        # 5. quarantine: fake report -> MANIFEST row, original gone
        print("-- quarantine")
        reports_dir = os.path.join(temp_root, "reports")
        state_dir = os.path.join(temp_root, "state")
        os.makedirs(reports_dir)
        stamp = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=90)
        fake_name = "FakeCrash-%s.ips" % stamp.strftime("%Y-%m-%d-%H%M%S")
        fake_path = os.path.join(reports_dir, fake_name)
        with open(fake_path, "w", encoding="utf-8") as handle:
            handle.write(json.dumps({
                "app_name": "fake", "timestamp": stamp.strftime("%Y-%m-%d %H:%M:%S.00 +0000"),
                "bug_type": "309", "os_version": "macOS 26.4.1 (25E253)",
                "incident_id": "selftest"}) + "\n")
            handle.write("{\"selftest\": true}\n")
        before_listing, _, _ = _run_json(["--action", "system.crash-reports",
                                          "--reports-dir", reports_dir,
                                          "--state-dir", state_dir, "--json"])
        check.equal(len(before_listing.get("reports") or []), 1,
                    "the fake report is listed")
        other_reports = os.path.join(temp_root, "other-reports")
        os.makedirs(other_reports)
        other_name = "OtherCrash-2026-01-01-000000.ips"
        with open(os.path.join(other_reports, other_name), "w", encoding="utf-8") as handle:
            handle.write(json.dumps({"app_name": "other",
                                     "timestamp": "2026-01-01 00:00:00.00 +0000",
                                     "bug_type": "309"}) + "\n")
        other_listing, _, _ = _run_json(["--action", "system.crash-reports",
                                         "--reports-dir", other_reports,
                                         "--state-dir", state_dir, "--json"])
        check.equal(len(other_listing.get("reports") or []), 1,
                    "the second report directory is listed")
        check.ok((other_listing.get("reports") or [{}])[0].get("name") == other_name,
                 "two report directories never share a cache entry",
                 (other_listing.get("reports") or [{}])[0].get("name"))
        plan_payload, plan_code, _ = _run_json([
            "--action", "system.crash-quarantine", "--plan", "--older-than-days", "30",
            "--reports-dir", reports_dir, "--state-dir", state_dir, "--json"])
        check.equal(plan_code, 0, "quarantine plan exits 0")
        check.equal(plan_payload["plan"]["count"], 1, "quarantine plan selects the old report")
        check.ok(plan_payload["plan"]["bytes"] > 0, "quarantine plan carries exact bytes")
        moved_payload, moved_code, _ = _run_json([
            "--action", "system.crash-quarantine", "--confirm", "--older-than-days", "30",
            "--reports-dir", reports_dir, "--state-dir", state_dir, "--json"])
        check.equal(moved_code, 0, "quarantine run exits 0")
        check.equal(moved_payload.get("moved"), 1, "quarantine moved one report")
        check.ok(not os.path.exists(fake_path), "the original report is gone")
        manifest = os.path.join(state_dir, "quarantine", "crash-reports")
        manifests = []
        for root, _dirs, files in os.walk(manifest):
            manifests.extend(os.path.join(root, name) for name in files
                             if name == "MANIFEST.jsonl")
        check.equal(len(manifests), 1, "one MANIFEST.jsonl was written")
        rows = []
        if manifests:
            with open(manifests[0], "r", encoding="utf-8") as handle:
                rows = [json.loads(line) for line in handle if line.strip()]
        check.equal(len(rows), 1, "the MANIFEST holds one row")
        check.ok(rows and rows[0]["name"] == fake_name, "the MANIFEST row names the report")
        check.ok(rows and rows[0]["sha256"] and len(rows[0]["sha256"]) == 64,
                 "the MANIFEST row records a sha256")
        check.ok(rows and rows[0]["moved"] is True, "the MANIFEST row says moved")
        missing_days_payload, missing_days_code = _cli([
            "--action", "system.crash-quarantine", "--confirm",
            "--reports-dir", reports_dir, "--state-dir", state_dir, "--json"])
        check.equal(missing_days_code, 2, "quarantine without --older-than-days exits 2")

        # 5b. write-ahead: when the MANIFEST row cannot land, the report does not move (D2)
        print("-- quarantine write-ahead")
        fail_root = os.path.join(temp_root, "manifest-failure")
        fail_reports = os.path.join(fail_root, "reports")
        fail_state = os.path.join(fail_root, "state")
        os.makedirs(fail_reports)
        os.makedirs(fail_state)
        fail_stamp = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=90)
        fail_name = "FakeCrash-%s.ips" % fail_stamp.strftime("%Y-%m-%d-%H%M%S")
        fail_path = os.path.join(fail_reports, fail_name)
        with open(fail_path, "w", encoding="utf-8") as handle:
            handle.write(json.dumps({"app_name": "fake", "bug_type": "309",
                                     "timestamp": fail_stamp.strftime(
                                         "%Y-%m-%d %H:%M:%S.00 +0000")}) + "\n")
        real_write_manifest = globals()["write_manifest"]

        def failing_write_manifest(path, rows_snapshot):
            raise OSError(28, "No space left on device (injected)")

        globals()["write_manifest"] = failing_write_manifest
        try:
            payload, code = _cli(["--action", "system.crash-quarantine", "--confirm",
                                  "--older-than-days", "30", "--reports-dir", fail_reports,
                                  "--state-dir", fail_state, "--json"])
        finally:
            globals()["write_manifest"] = real_write_manifest
        check.equal(code, 0, "an unwritable MANIFEST is an answer, not a crash")
        check.ok(payload.get("ok") is False, "an unwritable MANIFEST says ok false",
                 payload.get("ok"))
        check.equal(payload.get("moved"), 0, "no report moves without its MANIFEST row")
        check.ok(payload.get("manifest_errors") == 1,
                 "the answer counts the MANIFEST failure", payload.get("manifest_errors"))
        check.ok(os.path.exists(fail_path), "the report is still in the reports directory")
        failed_manifests = []
        for fail_dir, _dirs, files in os.walk(os.path.join(fail_state, "quarantine")):
            failed_manifests.extend(name for name in files if name == "MANIFEST.jsonl")
        check.equal(len(failed_manifests), 0, "no MANIFEST file was left behind")

        # 5c. an entry that resolves outside the reports root is refused before
        # it is sized, hashed or moved, and no row claims it (R2-1)
        print("-- quarantine scope")
        scope_root = os.path.join(temp_root, "scope")
        scope_reports = os.path.join(scope_root, "reports")
        scope_state = os.path.join(scope_root, "state")
        scope_outside = os.path.join(scope_root, "outside")
        for path in (scope_reports, scope_state, scope_outside):
            os.makedirs(path)
        secret_path = os.path.join(scope_outside, "secret.ips")
        with open(secret_path, "w", encoding="utf-8") as handle:
            handle.write(json.dumps({"app_name": "secret",
                                     "timestamp": "2020-01-01 00:00:00.00 +0000"}) + "\n")
            handle.write("outside body that must never be read\n")
        scope_name = "ScopeCrash-2020-01-01-000000.ips"
        scope_path = os.path.join(scope_reports, scope_name)
        with open(scope_path, "w", encoding="utf-8") as handle:
            handle.write(json.dumps({"app_name": "real",
                                     "timestamp": "2020-01-01 00:00:00.00 +0000"}) + "\n")
            handle.write("real body\n")
        escape_links = {
            "RelOut-2020-01-01-000000.ips": os.path.join(os.pardir, "outside", "secret.ips"),
            "AbsOut-2020-01-01-000000.ips": secret_path,
            "SysOut-2020-01-01-000000.ips": "/etc/hosts",
        }
        for link_name, target in escape_links.items():
            os.symlink(target, os.path.join(scope_reports, link_name))
        scope_listing, scope_list_code, _ = _run_json([
            "--action", "system.crash-reports", "--reports-dir", scope_reports,
            "--state-dir", scope_state, "--json"])
        check.equal(scope_list_code, 0, "a listing with an escaping entry exits 0")
        check.equal(scope_listing.get("count"), 1,
                    "only the contained report is listed")
        check.equal([item.get("name") for item in scope_listing.get("reports") or []],
                    [scope_name], "the escaping entries are not listed")
        check.equal(scope_listing.get("total_bytes"), os.path.getsize(scope_path),
                    "the escaping entries add no bytes")
        scope_reasons = scope_listing.get("reasons") or {}
        check.equal(sorted(name for name in escape_links
                           if ("reports.%s.scope" % name) in scope_reasons),
                    sorted(escape_links), "every escaping entry carries a scope reason")
        scope_plan, scope_plan_code, _ = _run_json([
            "--action", "system.crash-quarantine", "--plan", "--older-than-days", "30",
            "--reports-dir", scope_reports, "--state-dir", scope_state, "--json"])
        check.equal(scope_plan_code, 0, "the quarantine plan with an escaping entry exits 0")
        check.equal(scope_plan.get("plan", {}).get("count"), 1,
                    "the quarantine plan selects only the contained report")
        check.equal(scope_plan.get("plan", {}).get("bytes"), os.path.getsize(scope_path),
                    "the quarantine plan counts only the contained bytes")
        check.equal(len(scope_plan.get("refused") or []), 3,
                    "the quarantine plan carries the three refusals")
        real_sha256_file = globals()["sha256_file"]
        hashed = []

        def recording_sha256_file(path):
            hashed.append(os.path.basename(path))
            return real_sha256_file(path)

        globals()["sha256_file"] = recording_sha256_file
        try:
            scope_run, scope_run_code, _ = _run_json([
                "--action", "system.crash-quarantine", "--confirm", "--older-than-days", "30",
                "--reports-dir", scope_reports, "--state-dir", scope_state, "--json"])
        finally:
            globals()["sha256_file"] = real_sha256_file
        check.equal(scope_run_code, 0, "the quarantine run with an escaping entry exits 0")
        check.equal(scope_run.get("moved"), 1, "only the contained report moves")
        check.equal(len(scope_run.get("refused") or []), 3,
                    "the quarantine run carries the three refusals")
        check.ok(not any(name in hashed for name in escape_links),
                 "no escaping entry is hashed", ", ".join(hashed) or "nothing hashed")
        check.ok(all(os.path.islink(os.path.join(scope_reports, name)) for name in escape_links),
                 "the escaping entries are still in the reports directory")
        check.ok(os.path.isfile(secret_path) and os.path.getsize(secret_path) > 0,
                 "the outside file is untouched")
        scope_rows = []
        for scope_dir, _dirs, files in os.walk(os.path.join(scope_state, "quarantine")):
            for name in files:
                if name != "MANIFEST.jsonl":
                    continue
                with open(os.path.join(scope_dir, name), "r", encoding="utf-8") as handle:
                    scope_rows.extend(json.loads(line) for line in handle if line.strip())
        check.equal([row.get("name") for row in scope_rows], [scope_name],
                    "the MANIFEST holds one row for the contained report only")
        check.ok(scope_rows and scope_rows[0].get("sha256") != real_sha256_file(secret_path),
                 "the MANIFEST row carries no hash of the outside file")

        # 6. restart-shell: no confirm -> exit 2; protected pid -> refusal
        print("-- restart guards")
        decoy = _spawn_decoy("quickshell")
        decoys.append(decoy)
        time.sleep(0.3)
        no_confirm, no_confirm_code = _cli([
            "--action", "system.restart-shell", "--target", str(decoy.pid), "--json"])
        check.equal(no_confirm_code, 2, "restart-shell without --confirm exits 2")
        check.equal(no_confirm.get("reason"), "confirm_required",
                    "the no-confirm answer says confirm_required")
        check.ok(decoy.poll() is None, "the decoy process was not signalled")
        protected, protected_code = _cli([
            "--action", "system.restart-shell", "--target", str(decoy.pid), "--plan", "--json"])
        check.equal(protected_code, 0, "a quickshell decoy exits 0 (a refusal, not a crash)")
        check.ok(protected.get("reason") != "protected",
                 "a quickshell-named decoy is not protected by itself",
                 protected.get("reason"))

        gateway = _spawn_decoy("hermes-gateway")
        decoys.append(gateway)
        time.sleep(0.3)
        gateway_payload, gateway_code = _cli([
            "--action", "system.restart-shell", "--target", str(gateway.pid), "--plan", "--json"])
        check.equal(gateway_code, 0, "the gateway refusal exits 0")
        check.equal(gateway_payload.get("reason"), "protected",
                    "a fake gateway pid is refused as protected")
        check.equal(gateway_payload.get("plan", {}).get("protected_check", {}).get("rule"),
                    "gateway", "the plan names the gateway rule")
        dispatcher = _spawn_decoy("kanban-dispatcher")
        decoys.append(dispatcher)
        bridge = _spawn_decoy("bridge-relay")
        decoys.append(bridge)
        time.sleep(0.3)
        for decoy_row, label in ((dispatcher, "dispatcher"), (bridge, "bridge relay")):
            payload, code = _cli(["--action", "system.restart-shell", "--target",
                                  str(decoy_row.pid), "--plan", "--json"])
            check.equal(payload.get("reason"), "protected",
                        "a fake %s pid is refused as protected" % label)
        check.equal(protected_hit({"name": "quickshell", "args": "quickshell -n -p /x"}), None,
                    "a plain shell is not protected")
        check.ok(is_hud_shell("quickshell -n -p /usr/share/omarchy/shell"),
                 "the live quickshell command line is a HUD shell")
        check.ok(not is_hud_shell("/repo/nexuslink.hud/v5/feeds/hudfix_system.py --action x"),
                 "a path containing nexuslink.hud is not a HUD shell")

        # 6b. the supervisor's own name is guarded too, not just the process (D3)
        print("-- supervisor guard")
        label_gap = os.path.join(temp_root, "label-gap")
        shutil.copytree(fixture, label_gap)
        os.unlink(os.path.join(label_gap, "cgroup.txt"))
        with open(os.path.join(label_gap, "launchctl-list.txt"), "w",
                  encoding="utf-8") as handle:
            handle.write("PID\tStatus\tLabel\n2506443\t0\tai.hermes.gateway-keeper\n")
        payload, code = _cli(["--action", "system.restart-shell", "--plan",
                              "--fixture", label_gap, "--json"])
        check.equal(code, 0, "a protected launchd label refuses with exit 0")
        check.equal(payload.get("reason"), "protected",
                    "a launchd label naming the gateway is refused as protected")
        check.equal(payload.get("plan", {}).get("protected_check", {}).get("rule"), "gateway",
                    "the label refusal names the gateway rule")
        check.equal(payload.get("plan", {}).get("command"), None,
                    "the label refusal builds no kickstart command")
        benign_label = os.path.join(temp_root, "label-benign")
        shutil.copytree(fixture, benign_label)
        os.unlink(os.path.join(benign_label, "cgroup.txt"))
        with open(os.path.join(benign_label, "launchctl-list.txt"), "w",
                  encoding="utf-8") as handle:
            handle.write("PID\tStatus\tLabel\n2506443\t0\tcom.nexuslink.hud.shell\n")
        payload, code = _cli(["--action", "system.restart-shell", "--plan",
                              "--fixture", benign_label, "--json"])
        check.equal(code, 0, "a plain launchd label plans with exit 0")
        check.ok(payload.get("ok") is True and payload.get("plan", {}).get("command"),
                 "a plain launchd label produces the kickstart command",
                 payload.get("reason"))
        benign_command = ((payload.get("plan") or {}).get("command") or [])
        check.equal(benign_command[-1:], ["gui/%d/com.nexuslink.hud.shell" % os.getuid()],
                    "the kickstart command names the label")
        unit_gap = os.path.join(temp_root, "unit-gap")
        shutil.copytree(fixture, unit_gap)
        with open(os.path.join(unit_gap, "cgroup.txt"), "w", encoding="utf-8") as handle:
            handle.write("0::/user.slice/user-1000.slice/user@1000.service/app.slice/"
                         "hermes-gateway.service\n")
        payload, code = _cli(["--action", "system.restart-shell", "--plan",
                              "--fixture", unit_gap, "--json"])
        check.equal(code, 0, "a protected systemd unit name refuses with exit 0")
        check.equal(payload.get("reason"), "protected",
                    "a systemd unit naming the gateway is refused as protected")

        # 7. plans exist for every action, are read-only where they claim to be
        print("-- plans")
        for name, spec in ACTIONS.items():
            plan_payload, plan_code, _ = _run_json([
                "--action", name, "--plan", "--fixture", fixture,
                "--older-than-days", "30", "--json"])
            check.equal(plan_code, 0, "%s --plan exits 0 on the fixture" % name)
            check.ok(plan_payload.get("ok") is True, "%s --plan is ok" % name)
            plan = plan_payload.get("plan", {})
            check.ok(isinstance(plan.get("changes"), bool),
                     "%s plan states whether it changes anything" % name)
            check.equal(plan.get("confirm_required"), spec["class"] != "read",
                        "%s confirm_required matches its class" % name)
            if spec["class"] == "read":
                check.equal(plan.get("changes"), False, "%s plan is read-only" % name)
            command = plan.get("command")
            if command:
                check.ok(command[0] in ALLOWED_EXECUTABLES,
                         "%s plan names an allowed executable" % name, command[0])
                check.ok(not any(token in " ".join(command) for token in FORBIDDEN_TOKENS),
                         "%s plan carries no sudo/killall/pkill" % name)
        shell_plan, _, _ = _run_json(["--action", "system.restart-shell", "--plan",
                                      "--fixture", fixture, "--json"])
        shell_plan = shell_plan["plan"]
        check.equal(shell_plan["blank_gap_s"], [2, 4], "restart-shell declares the 2-4 s gap")
        check.equal(len(shell_plan["refusals"]), 3, "restart-shell carries three exclusions")
        check.equal(shell_plan["target"]["unit"], "nexuslink-hud.service",
                    "restart-shell names the systemd unit from the cgroup fixture")
        check.equal(shell_plan["command"][:3], ["systemctl", "--user", "restart"],
                    "restart-shell restarts through the supervisor")
        plan_text = _run_json(["--action", "system.restart-shell", "--plan",
                               "--fixture", fixture, "--json"])[2]
        dry_text = _run_json(["--action", "system.restart-shell", "--dry-run",
                              "--fixture", fixture, "--json"])[2]
        check.equal(dry_text, plan_text, "--dry-run prints the same plan as --plan")

        # 8. platform honesty
        print("-- host honesty")
        if platform_name() == "macos":
            audio, audio_code = _cli(["--action", "system.restart-audio", "--plan", "--json"])
            check.equal(audio_code, 0, "restart-audio on the Mac exits 0")
            check.equal(audio.get("reason"), "linux_only",
                        "restart-audio on the Mac refuses as linux_only")
            check.ok("sudo" in (audio.get("detail") or ""),
                     "the refusal says why (coreaudiod needs sudo)")
            units_live, units_code = _cli(["--action", "system.units", "--json"])
            check.equal(units_code, 0, "live units on the Mac exits 0")
            check.equal(units_live.get("reason"), "linux_only",
                        "live units on the Mac refuses as linux_only")

        # 9. no forbidden token is ever executed
        print("-- source")
        with open(os.path.abspath(__file__), "r", encoding="utf-8") as handle:
            source = handle.read()
        check.ok("shell=False" in source, "subprocess is called with shell=False")
        check.ok(re.search(r"shell\s*=\s*True", source) is None,
                 "no subprocess shell is used")
        check.ok(("os.system" + "(") not in source, "no os.system call")
        check.ok(re.search(r"\[\s*['\"](sudo|killall|pkill)['\"]", source) is None,
                 "no command list starts with sudo, killall or pkill")
    finally:
        for decoy in decoys:
            if decoy.poll() is None:
                decoy.terminate()
                try:
                    decoy.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    decoy.kill()
        if temp_root and os.path.isdir(temp_root):
            shutil.rmtree(temp_root, ignore_errors=True)

    print("")
    if check.failures:
        print("SELF-CHECK FAILED: %d of %d checks" % (len(check.failures), check.count))
        for label in check.failures:
            print("  - %s" % label)
        return EXIT_PROGRAMMING
    print("SELF-CHECK OK: %d checks, 0 failures" % check.count)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
