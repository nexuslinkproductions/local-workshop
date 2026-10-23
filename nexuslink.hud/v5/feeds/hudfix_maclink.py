#!/usr/bin/env python3
"""Mac link maintenance actions for the v5 hudfix CLI (card F8c). Stdlib only.

This module is one half of the shared F8 maintenance engine. It exports the
contract the F8a entry point discovers:

    ACTIONS = {"maclink.<name>": {"class": "read|safe|reversible|destructive",
                                  "doc": str, "plan": callable,
                                  "run": callable, "linux_only": bool}}

``plan(ctx=None)`` returns one dry-run object per action: the exact items, a
count, bytes where countable, what ``run`` would do, what it cannot verify, and
for the state-changing actions a ``blast_radius``. It reads (launchd, ps,
tailscale, the kanban DB) and never signals a process or writes a target file.

``run(ctx=None, confirm=None)`` performs the action. ``reversible`` actions
require ``confirm`` to be the action name (a boolean ``True`` is accepted when
the entry point already validated its own ``--confirm``). A refused run returns
``{"ok": false, "refused": true, "reason": ...}`` and the standalone CLI maps
that to exit 2 with one line on stderr and nothing on stdout.

Actions on this Mac:

    maclink.status         read        relay state, tunnel state, uptime, ssh
    maclink.restart-relay  reversible  launchctl kickstart -k gui/<uid>/<label>
    maclink.restart-tunnel reversible  tailscale down then up, or the launchd unit
    maclink.kick-bot       reversible  SIGTERM one stale worker pid, verified
    maclink.wake           safe        caffeinate -d, pid file recorded
    maclink.wake-off       reversible  SIGTERM only that recorded caffeinate pid
    maclink.screenshot     safe        screencapture -x into a temp file

Safety, in order of what matters most:

  * The gateway and the dispatcher are the fleet's lifeline. ``maclink.kick-bot``
    only ever signals a pid recorded in ``tasks.worker_pid`` for a running card
    whose heartbeat is stale, and only after the live command line proves three
    things: it is a Hermes worker, it carries ``-p <profile>`` for that card's
    assignee, and it names that card id. A command line that mentions
    ``gateway``, ``kanban dispatch``, this module's own process tree, or this
    very card is refused. A row whose ``worker_pid`` cell is not a number, or
    whose ``assignee`` is null or empty, is rejected by name before the host is
    touched: without those two cells the row cannot be tied to a worker at all.
    Every cell read from ``tasks`` is coerced to ``str``, ``int``, ``float`` or
    ``null`` before it enters a payload; a BLOB, a ``memoryview`` or any other
    type (SQLite does not enforce its column types) becomes a placeholder that
    names its type and size and never its contents, the row is refused with
    ``kind: malformed``, and the answer is still one JSON document at exit 0.
    There is no pattern kill anywhere in this file.
  * ``restart-relay`` and ``restart-tunnel`` are the only actions that restart a
    shared service. Both refuse when the named unit or CLI is not present
    instead of reporting a restart that did not happen.
  * Every plan says what it cannot verify. ``restart-relay`` carries its blast
    radius as structured JSON, not only in prose.

Quarantine: no action in this module deletes anything. ``quarantine_file`` is
provided for the shared F8 contract and is exercised by the self-check; a
deletion-less module is the honest reason it has no callers here.

Logging: the standalone CLI appends one JSONL line per plan and per run to
``~/.local/state/nexuslink/hudfix.log`` (``--log PATH`` overrides). When F8a's
entry point imports this module, F8a owns the log and this module writes none,
so a single plan is never logged twice.

Runnable alone, importing nothing from F8a:

    python3 hudfix_maclink.py list
    python3 hudfix_maclink.py plan maclink.restart-relay
    python3 hudfix_maclink.py run maclink.restart-relay --confirm maclink.restart-relay
    python3 hudfix_maclink.py --self-check

Exit codes: 0 data or honest absence, 1 an action ran and failed, 2 a refusal
or a caller error. ``plan`` exits 0 even when it answers ``ok: false`` with a
reason; absence is an answer, not a crash.

Hostile input, same rule: a ``ps`` capture that is not exact UTF-8, a
``caffeinate.pid`` that does not hold a positive pid (text, bytes, empty, JSON
nested past 64 levels), or a ``maclink-status.json`` that is corrupt, a
directory, or that deep answers ``ok: false`` with ``kind: "malformed"``, one
JSON line, exit 0, and no traceback. The ``ps`` capture is refused rather than
read because the command line is the kick-bot identity check; the run path
never signals on that answer. ``--json`` prints exactly one compact JSON object
on one line for every subcommand (``list``, ``plan``, ``run``); without it the
same object is printed indented for a human.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

SOURCE = "hudfix_maclink"
EXIT_OK = 0
EXIT_FAILED = 1
EXIT_REFUSED = 2

RELAY_LABEL = "com.nexuslink.bridge-relay"
TAILSCALE_UNIT_LABELS = ("com.tailscale.tailscaled",)
TAILSCALE_CLI_CANDIDATES = (
    "/usr/local/bin/tailscale",
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    "/opt/homebrew/bin/tailscale",
)
DEFAULT_STALE_AFTER_S = 600
DEFAULT_TIMEOUT_S = 20.0
PAGE_LIMIT = 5
STATUS_CACHE_TTL_S = 10.0
SAFE_LABEL_RE = re.compile(r"^[A-Za-z0-9._:@-]{1,80}$")

ORDER = (
    "maclink.status",
    "maclink.restart-relay",
    "maclink.restart-tunnel",
    "maclink.kick-bot",
    "maclink.wake",
    "maclink.wake-off",
    "maclink.screenshot",
)

CLASS_TABLE = {
    "maclink.status": "read",
    "maclink.restart-relay": "reversible",
    "maclink.restart-tunnel": "reversible",
    "maclink.kick-bot": "reversible",
    "maclink.wake": "safe",
    "maclink.wake-off": "reversible",
    "maclink.screenshot": "safe",
}

DOCS = {
    "maclink.status": (
        "Read launchd relay state, tailscale backend state, boot time and the "
        "configured ssh peer. Changes nothing and signals nothing."
    ),
    "maclink.restart-relay": (
        "Kickstart the com.nexuslink.bridge-relay LaunchAgent. Restarts the relay "
        "process; board events in flight can be lost for a few seconds. Reversible "
        "by running the same kickstart again."
    ),
    "maclink.restart-tunnel": (
        "Restart the tailscale tunnel: the launchd unit when one exists, otherwise "
        "tailscale down then tailscale up. Refuses when neither is present."
    ),
    "maclink.kick-bot": (
        "SIGTERM one worker bot whose card heartbeat is stale, after re-verifying "
        "that the recorded pid command line is that profile and that card. Never a "
        "pattern kill, never the gateway, the dispatcher or this card."
    ),
    "maclink.wake": (
        "Start caffeinate -d and record its pid under "
        "~/.local/state/nexuslink/caffeinate.pid."
    ),
    "maclink.wake-off": (
        "SIGTERM only the caffeinate pid recorded by maclink.wake, after checking "
        "the process is caffeinate. Needs confirm because it signals a process."
    ),
    "maclink.screenshot": (
        "screencapture -x into a fresh file under the system temp directory. "
        "Writes one file and nothing else."
    ),
}


class Refused(Exception):
    """A caller error or a refusal. The CLI turns it into exit 2, one line."""


class DataProblem(Exception):
    """A source is missing or unreadable. An answer for plan, not a crash."""


class Malformed(DataProblem):
    """A capture this reader cannot read exactly: an answer, not a traceback.

    Raised for a lossy byte capture, a pid file that does not hold a pid, a
    status cache that is corrupt or a directory, and JSON nested past the depth
    cap. The CLI turns it into ``ok: false`` with ``kind: "malformed"`` at exit
    0, so a hostile host never crashes the reader.
    """

    def __init__(self, message, deep=False):
        DataProblem.__init__(self, message)
        self.deep = bool(deep)


MAX_JSON_DEPTH = 64


# --------------------------------------------------------------- small helpers


# The self-check drives the Mac action branch on any host (its plans use stubs,
# not the real launchctl). It sets this for its own run; an explicit platform
# argument is still honoured by host_is_mac.
SELF_CHECK_ASSUME_MAC = False
# The self-check also pins the launchd uid. Its fake launchctl table is keyed on
# gui/501, so the fake uid is 501 on any host. None means the real uid (production).
SELF_CHECK_UID = None
SELF_CHECK_FAKE_UID = 501
# The self-check pins the tailscale binary too: a host without tailscale on PATH
# (or with it elsewhere) must not change how many probes a run makes.
SELF_CHECK_TAILSCALE_CLI = None
SELF_CHECK_FAKE_TAILSCALE = "/nonexistent/hudfix-fake-bin/tailscale"
_CLI_BOOT = None  # set by self_check: child loader that pins the fake uid and mac gate


def current_uid():
    return SELF_CHECK_UID if SELF_CHECK_UID is not None else os.getuid()


_CLI_BOOT_SOURCE = (
    "import importlib.util, sys\n"
    "spec = importlib.util.spec_from_file_location('hudfix_maclink_pinned', sys.argv[1])\n"
    "mod = importlib.util.module_from_spec(spec)\n"
    "spec.loader.exec_module(mod)\n"
    "mod.SELF_CHECK_ASSUME_MAC = True\n"
    "mod.SELF_CHECK_TAILSCALE_CLI = '/nonexistent/hudfix-fake-bin/tailscale'\n"
    "mod.SELF_CHECK_UID = %d\n"
    "try:\n"
    "    sys.exit(mod.main(sys.argv[2:]))\n"
    "except mod.Refused as exc:\n"
    "    sys.stderr.write('hudfix_maclink: %%s\\n' %% exc)\n"
    "    sys.exit(mod.EXIT_REFUSED)\n"
) % SELF_CHECK_FAKE_UID


def host_is_mac(platform=None):
    if platform is None and SELF_CHECK_ASSUME_MAC:
        return True
    return (platform if platform is not None else sys.platform) == "darwin"


def home():
    return os.path.expanduser("~")


def utc_now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_from_epoch(epoch):
    try:
        return datetime.datetime.fromtimestamp(float(epoch), datetime.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
    except (TypeError, ValueError, OverflowError, OSError):
        return None


def expand(path):
    return os.path.abspath(os.path.expanduser(str(path)))


def tilde(path):
    if not path:
        return ""
    path = expand(path)
    root = home()
    if path == root:
        return "~"
    if path.startswith(root + os.sep):
        return "~" + path[len(root):]
    return path


def one_line(value, limit=400):
    if value is None:
        return None
    text = " ".join(str(value).split())
    if not text:
        return None
    if limit and len(text) > limit:
        text = text[:limit].rstrip() + "..."
    return text


def ctx_value(ctx, key, default=None):
    if ctx is None:
        return default
    if isinstance(ctx, dict):
        value = ctx.get(key, default)
    else:
        value = getattr(ctx, key, default)
    return default if value is None else value


def positive_int(value, default):
    try:
        number = int(value)
    except (TypeError, ValueError):
        return default
    return number if number > 0 else default


# 2**22 is the Linux pid_max ceiling. macOS pids stay below 99999.
PID_MAX = 4194304


def pid_from_cell(value):
    """The pid as an int, or None when the value is not a pid.

    ``tasks.worker_pid`` is an untyped SQLite cell: a text value, a float or a
    bool can sit there. Only a whole positive number (or its exact decimal
    text) is a pid; everything else is refused instead of coerced, so a float
    is never truncated onto a different process.
    """
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, int):
        number = value
    elif isinstance(value, float):
        if not value.is_integer():
            return None
        number = int(value)
    else:
        text = str(value).strip()
        if not re.fullmatch(r"[0-9]{1,12}", text):
            return None
        number = int(text)
    # 0 is "this process group" and 1 is launchd: neither is ever a worker.
    return number if 1 < number <= PID_MAX else None


def json_cell(value):
    """(safe value, malformed). One board cell -> a JSON-safe scalar.

    SQLite is dynamically typed and the board is writable by every process on
    the host, so a cell the schema calls INTEGER can hold a BLOB, and a stale
    row can carry one in ``id``, ``assignee`` or ``worker_pid``. Only ``str``,
    ``int``, ``float`` and ``None`` cross into a payload. Anything else becomes
    a placeholder that names its type and size and never its contents: a
    ``repr`` of a BLOB would put binary bytes into the answer, and
    ``json.dumps`` would raise on the raw value.
    """
    if value is None or isinstance(value, str):
        return value, False
    if isinstance(value, bool):
        return int(value), False
    if isinstance(value, int):
        return value, False
    if isinstance(value, float):
        if value != value or value in (float("inf"), float("-inf")):
            return "<malformed float>", True
        return value, False
    if isinstance(value, (bytes, bytearray, memoryview)):
        return "<malformed blob of %d bytes>" % len(bytes(value)), True
    return "<malformed %s>" % type(value).__name__, True


def state_paths(ctx):
    root = expand(ctx_value(ctx, "state_dir", os.path.join(home(), ".local", "state", "nexuslink")))
    return {
        "root": root,
        "caffeinate": os.path.join(root, "caffeinate.pid"),
        "log": os.path.join(root, "hudfix.log"),
        "status_cache": os.path.join(root, "maclink-status.json"),
    }


def log_path_for(ctx, override=None):
    if override:
        return expand(override)
    return state_paths(ctx)["log"]


def emit(payload, compact=False):
    # A leading-underscore key is this module's own bookkeeping (for example the
    # marker that a plan failed on a hostile capture, not on a corrupt board
    # row). It never reaches stdout.
    visible = dict((key, value) for key, value in payload.items() if not str(key).startswith("_"))
    if compact:
        line = json.dumps(visible, ensure_ascii=False, separators=(",", ":"))
    else:
        line = json.dumps(visible, ensure_ascii=False, indent=2)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def append_log(path, record):
    """One JSONL line. A logging failure never fails the action."""
    try:
        target = expand(path)
        parent = os.path.dirname(target) or "."
        os.makedirs(parent, exist_ok=True)
        with open(target, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False, sort_keys=False) + "\n")
        return True
    except OSError as exc:
        sys.stderr.write("hudfix_maclink: log write failed: %s\n" % one_line(exc, 200))
        return False


def quarantine_file(path, action, root=None):
    """Move one file under <quarantine>/<date>/ and append one MANIFEST.tsv row.

    Kept for the shared F8 contract. No action in this module deletes anything,
    so nothing here calls it outside the self-check.
    """
    source = expand(path)
    if not os.path.exists(source):
        raise Refused("nothing to quarantine at %s" % tilde(source))
    if not os.path.isfile(source):
        raise Refused("quarantine moves files, not directories: %s" % tilde(source))
    root = expand(root or os.path.join(home(), "NEXUS_AI_CENTER", "_QUARANTINE"))
    day = datetime.date.today().isoformat()
    target_dir = os.path.join(root, day)
    os.makedirs(target_dir, exist_ok=True)
    base = os.path.basename(source)
    target = os.path.join(target_dir, base)
    counter = 1
    while os.path.exists(target):
        target = os.path.join(target_dir, "%s.%d" % (base, counter))
        counter += 1
    size = os.path.getsize(source)
    shutil.move(source, target)
    row = "\t".join([utc_now_iso(), action, source, str(size), target]) + "\n"
    manifest = os.path.join(target_dir, "MANIFEST.tsv")
    with open(manifest, "a", encoding="utf-8") as handle:
        handle.write(row)
    return {"source": source, "destination": target, "bytes": size, "manifest": manifest}


# ------------------------------------------------------------------- runtime


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
    stack (1200 levels reaches it), and that is not a ``ValueError``: it would
    escape every ``except ValueError`` here and surface as a traceback. Both
    paths become ``Malformed``, and the depth cap is checked on the parsed value
    as well, so the answer does not depend on the interpreter's recursion limit.
    """
    try:
        value = json.loads(raw)
    except RecursionError:
        raise Malformed("%s is nested too deeply to read" % what, deep=True)
    except ValueError as exc:
        raise Malformed("%s is not valid JSON: %s" % (what, one_line(exc, 200)))
    if not _json_depth_ok(value, limit):
        raise Malformed("%s is nested deeper than %d levels" % (what, limit), deep=True)
    return value


def _decode_capture(raw):
    """bytes -> (text, bytes replaced). Exact UTF-8 first, then a counted fallback.

    ``surrogateescape`` keeps each invalid byte as one lone surrogate, so the
    count is exact; the returned text is the printable form, one U+FFFD per
    invalid run, and is never written back as bytes.
    """
    try:
        return raw.decode("utf-8"), 0
    except UnicodeDecodeError:
        pass
    text = raw.decode("utf-8", "surrogateescape")
    lost = sum(1 for char in text if "\udc80" <= char <= "\udcff")
    clean = text.encode("utf-8", "surrogateescape").decode("utf-8", "replace")
    return clean, lost


def _kind_of(exc):
    """Payload kind for a DataProblem: malformed only for a hostile capture."""
    return "malformed" if isinstance(exc, Malformed) else None


def _run_command(argv, timeout=DEFAULT_TIMEOUT_S, strict_text=False):
    """Run one command. Returns (stdout, stderr, exit). Never raises OSError.

    The capture is bytes, decoded as UTF-8: exact when the child wrote valid
    UTF-8, otherwise a counted replacement. ``ps`` is the reader's identity
    check, so its callers pass ``strict_text``: a capture that had to replace a
    byte is refused as ``Malformed`` instead of being read as an altered command
    line. A ``UnicodeDecodeError`` out of the subprocess layer would otherwise
    turn a hostile process table into exit 2 ``programming_error``.
    """
    try:
        proc = subprocess.run(
            argv, capture_output=True, timeout=timeout, check=False
        )
        out, lost_out = _decode_capture(proc.stdout or b"")
        err, lost_err = _decode_capture(proc.stderr or b"")
        if strict_text and (lost_out or lost_err):
            raise Malformed(
                "%s output is not valid UTF-8 (%d byte(s) replaced); refusing to "
                "read a lossy capture"
                % (os.path.basename(str(argv[0])), lost_out + lost_err)
            )
        return out, err, proc.returncode
    except subprocess.TimeoutExpired:
        return "", "timed out after %ss" % timeout, 124
    except FileNotFoundError:
        return "", "not installed: %s" % argv[0], 127
    except OSError as exc:
        return "", str(exc), 1


def _spawn_detached(argv):
    proc = subprocess.Popen(
        argv,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )
    return proc.pid


class Runtime(object):
    """The only place that touches the host. Plans use reads only."""

    def run(self, argv, timeout=DEFAULT_TIMEOUT_S, strict_text=False):
        return _run_command(argv, timeout, strict_text)

    def spawn(self, argv):
        return _spawn_detached(argv)

    def ps(self, pid):
        """Never raises on a bad pid: a malformed pid is no command line.

        A lossy capture does raise ``Malformed``: the command line is compared
        against a digest and a profile, so a byte the decoder had to replace
        could change the identity. That is refused, not read.
        """
        pid_int = pid_from_cell(pid)
        if pid_int is None:
            return ""
        out, _err, code = self.run(
            ["ps", "-ww", "-o", "command=", "-p", str(pid_int)], timeout=5.0,
            strict_text=True,
        )
        return out.strip() if code == 0 else ""

    def ps_table(self):
        out, _err, code = self.run(
            ["ps", "-ww", "-Ao", "pid=,ppid=,command="], timeout=8.0, strict_text=True
        )
        if code != 0:
            raise DataProblem("ps -Ao failed with exit %d" % code)
        rows = []
        for line in out.splitlines():
            parts = line.strip().split(None, 2)
            # ASCII digits only. str.isdigit() also accepts superscript two, which
            # int() refuses, so such a row used to crash the reader.
            if len(parts) < 2 or not re.fullmatch(r"[0-9]{1,12}", parts[0]) \
                    or not re.fullmatch(r"[0-9]{1,12}", parts[1]):
                continue
            rows.append((int(parts[0]), int(parts[1]), parts[2] if len(parts) > 2 else ""))
        return rows

    def alive(self, pid):
        # Only a strict pid reaches os.kill: 0, 1, negatives and text stop here.
        pid_int = pid_from_cell(pid)
        if pid_int is None:
            return False
        try:
            os.kill(pid_int, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        except (ValueError, OSError):
            return False
        return True

    def now(self):
        return time.time()


# ------------------------------------------------------------------- parsing


def parse_launchctl(text):
    """Parse `launchctl print` into top-level keys; arguments block included."""
    info = {
        "present": True,
        "state": None,
        "pid": None,
        "program": None,
        "plist": None,
        "arguments": [],
        "last_exit": None,
    }
    lines = (text or "").splitlines()
    in_arguments = False
    for line in lines:
        if in_arguments:
            stripped = line.strip()
            if stripped == "}":
                in_arguments = False
            elif stripped:
                info["arguments"].append(stripped)
            continue
        if not line.startswith("\t") or line.startswith("\t\t"):
            continue
        match = re.match(r"^\t([a-z][a-z0-9 ]*) = (.*)$", line)
        if not match:
            continue
        key, value = match.group(1), match.group(2).strip()
        if key == "arguments":
            in_arguments = True
        elif key == "state":
            info["state"] = value
        elif key == "pid" and re.fullmatch(r"[0-9]{1,12}", value):
            # isdigit() accepts superscript two, which int() refuses: a strict
            # ASCII match plus pid_from_cell keeps 0, 1 and huge values out too.
            info["pid"] = pid_from_cell(value)
        elif key == "program":
            info["program"] = value
        elif key == "path":
            info["plist"] = value
        elif key == "last exit code":
            info["last_exit"] = value
    if info["pid"] is None:
        match = re.search(r"^\tpid = ([0-9]{1,12})$", text or "", re.MULTILINE)
        if match:
            info["pid"] = pid_from_cell(match.group(1))
    return info


def launchd_unit(label, runtime, domain=None):
    uid = current_uid()
    domain = domain or "gui/%d" % uid
    unit = "%s/%s" % (domain, label)
    out, err, code = runtime.run(["launchctl", "print", unit], timeout=10.0)
    if code != 0:
        reason = one_line(err) or one_line(out) or "launchctl print exited %d" % code
        raise DataProblem("launchd does not know %s: %s" % (unit, reason))
    parsed = parse_launchctl(out)
    if parsed["state"] is None and parsed["pid"] is None:
        raise DataProblem("launchctl print %s returned no state and no pid" % unit)
    parsed.update({"label": label, "domain": domain, "unit": unit})
    return parsed


def tailscale_cli():
    if SELF_CHECK_TAILSCALE_CLI is not None:
        return SELF_CHECK_TAILSCALE_CLI
    for candidate in TAILSCALE_CLI_CANDIDATES:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    found = shutil.which("tailscale")
    if found:
        return found
    return None


def tailscale_status(cli, runtime):
    out, err, code = runtime.run([cli, "status", "--json"], timeout=8.0)
    if code != 0:
        raise DataProblem(
            "tailscale status exited %d: %s" % (code, one_line(err) or one_line(out))
        )
    try:
        payload = json.loads(out)
    except ValueError:
        raise DataProblem("tailscale status returned no JSON")
    if not isinstance(payload, dict):
        raise DataProblem("tailscale status returned %s, not an object" % type(payload).__name__)
    return payload


def boot_seconds(runtime):
    out, err, code = runtime.run(["sysctl", "-n", "kern.boottime"], timeout=5.0)
    if code != 0:
        raise DataProblem("sysctl kern.boottime exited %d: %s" % (code, one_line(err)))
    match = re.search(r"sec\s*=\s*(\d+)", out)
    if not match:
        raise DataProblem("sysctl kern.boottime printed no sec field")
    return int(match.group(1))


def uptime_human(seconds):
    if seconds is None:
        return None
    seconds = max(0, int(seconds))
    days, rest = divmod(seconds, 86400)
    hours, rest = divmod(rest, 3600)
    minutes, _ = divmod(rest, 60)
    if days:
        return "%dd %02dh %02dm" % (days, hours, minutes)
    return "%dh %02dm" % (hours, minutes)


def read_ssh_config():
    path = os.path.join(home(), ".ssh", "config")
    if not os.path.isfile(path):
        return "", "no ~/.ssh/config"
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read(), None
    except OSError as exc:
        return "", "cannot read ~/.ssh/config: %s" % exc.strerror


def ssh_peer_from_config(text, override=None):
    """A named peer: the override, a Host omarchylink block, or a 100.x / ts.net HostName."""
    if override:
        return override, "override"
    blocks = []
    current = None
    for raw in (text or "").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if not parts:
            continue
        key = parts[0].lower()
        if key == "host":
            current = {"patterns": parts[1:], "hostname": None}
            blocks.append(current)
        elif key == "hostname" and current is not None and len(parts) > 1:
            current["hostname"] = parts[1]
    for block in blocks:
        if "omarchylink" in [pattern.lower() for pattern in block["patterns"]]:
            return "omarchylink", "ssh config"
    for block in blocks:
        hostname = (block.get("hostname") or "").strip()
        if not hostname:
            continue
        first = hostname.split(".")[0]
        if re.match(r"^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.", hostname):
            return first if block["patterns"] else hostname, "ssh config 100.64/10"
        if hostname.endswith(".ts.net"):
            return first, "ssh config tailscale dns"
    return None, "no tailscale peer in ~/.ssh/config"


def ssh_reachable(peer, runtime):
    argv = [
        "ssh",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=3",
        "-o", "StrictHostKeyChecking=yes",
        peer,
        "true",
    ]
    out, err, code = runtime.run(argv, timeout=6.0)
    return {
        "peer": peer,
        "reachable": code == 0,
        "exit": code,
        "stderr": one_line(err, 200),
        "stdout": one_line(out, 120),
    }


# -------------------------------------------------------------------- kanban


def kanban_db_path(ctx):
    explicit = ctx_value(ctx, "db_path", None)
    if explicit:
        return expand(explicit)
    env = os.environ.get("HERMES_KANBAN_DB")
    if env:
        return expand(env)
    return os.path.join(home(), ".hermes", "kanban.db")


def quote_sqlite_path(path):
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


def read_running_tasks(db_path):
    """Read running cards read-only. Returns (tasks, readonly_mode).

    ``mode=ro`` first. A WAL-marked board with no ``-shm`` beside it refuses a
    read-only open, so the second attempt reads it ``immutable=1``: no WAL
    replay, which can make a heartbeat a few seconds stale. Both paths SELECT.
    """
    if not os.path.isfile(db_path):
        raise DataProblem("no kanban database at %s" % tilde(db_path))
    quoted = quote_sqlite_path(os.path.abspath(db_path))
    attempts = (("ro", "?mode=ro"), ("immutable", "?mode=ro&immutable=1"))
    last_error = None
    for readonly, query in attempts:
        connection = None
        try:
            connection = sqlite3.connect(
                "file:%s%s" % (quoted, query), uri=True, timeout=2.0
            )
            connection.execute("PRAGMA query_only = ON")
            rows = connection.execute(
                "SELECT id, title, assignee, status, worker_pid, last_heartbeat_at, "
                "current_run_id, started_at FROM tasks "
                "WHERE status = 'running' AND worker_pid IS NOT NULL"
            ).fetchall()
            columns = (
                ("id", 0),
                ("title", 1),
                ("assignee", 2),
                ("status", 3),
                ("worker_pid", 4),
                ("last_heartbeat_at", 5),
                ("current_run_id", 6),
                ("started_at", 7),
            )
            tasks = []
            for row in rows:
                task = {}
                malformed = []
                for name, index in columns:
                    value, bad = json_cell(row[index])
                    task[name] = value
                    if bad:
                        malformed.append(name)
                task["title"] = one_line(task["title"], 80)
                if malformed:
                    # Named on the row, so no caller has to guess which cell a
                    # placeholder replaced. It never reaches the host boundary:
                    # stale_workers refuses the row on this field alone.
                    task["malformed"] = malformed
                tasks.append(task)
            return tasks, readonly
        except sqlite3.Error as exc:
            last_error = exc
        finally:
            if connection is not None:
                connection.close()
    raise DataProblem("cannot read kanban db %s: %s" % (tilde(db_path), last_error))


def self_process_chain(runtime):
    pids = {os.getpid(), os.getppid(), 1}
    try:
        table = runtime.ps_table()
    except Malformed:
        # A ps table this reader cannot read exactly is not "no table": the
        # chain it would prove is the protection against signalling this very
        # process or its ancestors, so the read is refused, not guessed.
        raise
    except DataProblem:
        return pids
    parents = {}
    for pid, ppid, _cmd in table:
        parents[pid] = ppid
    cursor = os.getpid()
    seen = set()
    while cursor and cursor not in seen:
        seen.add(cursor)
        pids.add(cursor)
        cursor = parents.get(cursor, 0)
    return pids


def tokens_of(cmdline):
    try:
        return shlex.split(cmdline or "")
    except ValueError:
        return (cmdline or "").split()


def command_digest(cmdline):
    """sha256 over the whitespace-normalized command line. Exact, not truncated."""
    normalized = " ".join((cmdline or "").split())
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


def profile_from_command(cmdline):
    tokens = tokens_of(cmdline)
    for index, token in enumerate(tokens):
        if token in ("-p", "--profile") and index + 1 < len(tokens):
            return tokens[index + 1]
        if token.startswith("--profile="):
            return token.split("=", 1)[1]
    return None


def card_from_command(cmdline):
    tokens = tokens_of(cmdline)
    for index, token in enumerate(tokens):
        if token == "--kanban-task" and index + 1 < len(tokens):
            return tokens[index + 1]
        if token.startswith("--kanban-task="):
            return token.split("=", 1)[1]
    for index in range(len(tokens) - 2):
        if tokens[index] == "kanban" and tokens[index + 1] == "task":
            return tokens[index + 2]
    return None


def argv0_name(cmdline):
    """The basename of argv[0], and nothing else, when it is a plain token."""
    tokens = tokens_of(cmdline)
    if not tokens:
        return None
    base = os.path.basename(str(tokens[0]))
    return base if SAFE_LABEL_RE.match(base) else None


def safe_argv_label(value):
    """An argv-derived value safe to print. Never a command line, never a secret."""
    if not value:
        return "<none>"
    text = str(value)
    return text if SAFE_LABEL_RE.match(text) else "<redacted>"


def classify_worker(cmdline, profile, card_id, pid, self_pids, self_card=None):
    """Return (True, None) when the pid provably is that profile on that card.

    Never echoes argv text: a reason carries the pid and at most basename(argv[0]).
    """
    body = (cmdline or "").strip()
    if not body:
        return False, "pid %s has no command line, so it is gone or unreadable" % pid
    pid_int = pid_from_cell(pid)
    if pid_int is None:
        return False, "pid %r is not a number or a usable pid (2 to %d)" % (pid, PID_MAX)
    if pid_int <= 1:
        return False, "pid %d is launchd or invalid" % pid_int
    assignee = "" if profile is None else str(profile).strip()
    if not assignee:
        # Without an assignee the profile half of the identity check is vacuous:
        # a hermes process with no -p at all would pass. The row cannot be tied
        # to a worker, so refuse it.
        return False, "the row carries no assignee, so pid %d cannot be tied to a worker" % pid_int
    tokens = tokens_of(body)
    lower = [token.lower() for token in tokens]
    if "gateway" in lower:
        return False, "pid %d is the gateway" % pid_int
    if "kanban" in lower and ("dispatch" in lower or "dispatcher" in lower):
        return False, "pid %d is the kanban dispatcher" % pid_int
    if self_card and card_id == self_card:
        return False, "card %s is this very worker's card" % card_id
    if pid_int in self_pids:
        return False, "pid %d is this process or one of its ancestors" % pid_int
    hermes_runtime = "hermes_cli.main" in body or any(
        os.path.basename(token) in ("hermes", "devin") for token in tokens[:3]
    )
    if not hermes_runtime:
        name = argv0_name(body)
        if name:
            return False, "pid %d is not a Hermes or Devin worker (argv0: %s)" % (pid_int, name)
        return False, "pid %d is not a Hermes or Devin worker" % pid_int
    found_profile = profile_from_command(body)
    if found_profile != assignee:
        return False, "pid %d carries profile %r, not %r" % (
            pid_int,
            safe_argv_label(found_profile),
            assignee,
        )
    found_card = card_from_command(body)
    if not found_card:
        return False, "pid %d does not name a card, so it cannot be tied to %s" % (
            pid_int,
            card_id,
        )
    if found_card != card_id:
        return False, "pid %d names card %s, not %s" % (
            pid_int,
            safe_argv_label(found_card),
            card_id,
        )
    return True, None


def stale_workers(ctx, runtime):
    """Return (candidate, rejected, scanned, threshold, now, readonly). No signals."""
    db_path = kanban_db_path(ctx)
    threshold = positive_int(ctx_value(ctx, "stale_after_s", None), DEFAULT_STALE_AFTER_S)
    now = runtime.now()
    self_pids = self_process_chain(runtime)
    self_card = os.environ.get("HERMES_KANBAN_TASK")
    tasks, readonly = read_running_tasks(db_path)
    stale = []
    rejected = []
    for task in tasks:
        stamp = task.get("last_heartbeat_at")
        source = "last_heartbeat_at"
        if stamp is None:
            stamp = task.get("started_at")
            source = "started_at"
        if stamp is None:
            rejected.append(
                {"card": task["id"], "pid": task["worker_pid"], "reason": "no heartbeat or start time"}
            )
            continue
        try:
            age = max(0, int(now - float(stamp)))
        except (TypeError, ValueError):
            rejected.append(
                {"card": task["id"], "pid": task["worker_pid"], "reason": "unreadable timestamp"}
            )
            continue
        if age < threshold:
            continue
        malformed = task.get("malformed") or []
        if malformed:
            # The row is corrupt in the cell itself: a BLOB id, assignee or
            # worker_pid cannot name a worker, so the row is refused by name
            # before the host boundary. The placeholder says what replaced it
            # and the row never raises on the way into a payload.
            rejected.append(
                {
                    "card": task["id"],
                    "profile": task.get("assignee"),
                    "pid": task["worker_pid"],
                    "heartbeat_age_s": age,
                    "reason": "board row has a malformed %s cell (%s), so it cannot "
                    "name a worker" % (" and ".join(malformed), task[malformed[0]]),
                    "kind": "malformed",
                    "malformed_fields": list(malformed),
                }
            )
            continue
        pid = task["worker_pid"]
        pid_int = pid_from_cell(pid)
        if pid_int is None:
            # SQLite is dynamically typed: a text cell is not a pid. Refuse the
            # row before the host boundary, so a corrupt board never raises.
            rejected.append(
                {
                    "card": task["id"],
                    "profile": task.get("assignee"),
                    "pid": pid,
                    "heartbeat_age_s": age,
                    "reason": "worker_pid %r is not a number" % (pid,),
                }
            )
            continue
        cmdline = runtime.ps(pid_int)
        ok, reason = classify_worker(
            cmdline, task.get("assignee"), task["id"], pid_int, self_pids, self_card
        )
        if not ok:
            rejected.append(
                {
                    "card": task["id"],
                    "profile": task.get("assignee"),
                    "pid": pid,
                    "heartbeat_age_s": age,
                    "reason": reason,
                }
            )
            continue
        stale.append(
            {
                "card": task["id"],
                "title": task.get("title"),
                "profile": task.get("assignee"),
                "pid": pid_int,
                "heartbeat_age_s": age,
                "heartbeat_source": source,
                "heartbeat_iso": iso_from_epoch(stamp),
                "argv0": argv0_name(cmdline),
                "command_sha256": command_digest(cmdline),
            }
        )
    stale.sort(key=lambda item: (-item["heartbeat_age_s"], item["card"]))
    return stale, rejected, len(tasks), threshold, now, readonly


# ---------------------------------------------------------------------- plans


def _plan_base(name, items, total_bytes, would, cannot_verify, **extra):
    payload = {
        "ok": True,
        "source": SOURCE,
        "generated_at": utc_now_iso(),
        "action": name,
        "class": CLASS_TABLE[name],
        "linux_only": False,
        "dry_run": True,
        "items": items,
        "total": {
            "items": len(items),
            "bytes": total_bytes,
            "bytes_reason": None
            if total_bytes is not None
            else "size is known only after the action runs",
        },
        "would": would,
        "cannot_verify": list(cannot_verify),
        "reasons": {},
    }
    payload.update(extra)
    return payload


def _plan_unavailable(name, reason, kind=None, **extra):
    payload = {
        "ok": False,
        "source": SOURCE,
        "generated_at": utc_now_iso(),
        "action": name,
        "class": CLASS_TABLE[name],
        "linux_only": False,
        "dry_run": True,
        "available": False,
        "reason": reason,
        "items": [],
        "total": {"items": 0, "bytes": 0, "bytes_reason": None},
        "cannot_verify": [
            "this is a read at plan time; the missing source may come back before a later run",
            "the reason describes this one probe, not the service's permanent state",
        ],
        "reasons": {"available": reason},
    }
    if kind is not None:
        payload["kind"] = kind
    payload.update(extra)
    return payload


def plan_status(ctx=None, runtime=None):
    runtime = runtime or Runtime()
    if not host_is_mac():
        return _plan_unavailable("maclink.status", "not this host (mac only)")
    config_text, config_reason = read_ssh_config()
    peer, peer_reason = ssh_peer_from_config(config_text, ctx_value(ctx, "peer", None))
    items = [
        {
            "kind": "read",
            "target": "launchctl print gui/%d/%s" % (current_uid(), RELAY_LABEL),
            "changes": False,
        },
        {
            "kind": "read",
            "target": "tailscale status --json",
            "changes": False,
            "cli": tilde(tailscale_cli()) if tailscale_cli() else None,
        },
        {"kind": "read", "target": "sysctl -n kern.boottime", "changes": False},
    ]
    if peer:
        items.append(
            {
                "kind": "read",
                "target": "ssh -o BatchMode=yes -o ConnectTimeout=3 %s true" % peer,
                "changes": False,
                "skipped": False,
            }
        )
    else:
        items.append(
            {
                "kind": "read",
                "target": "ssh reachability",
                "changes": False,
                "skipped": True,
                "skip_reason": "%s (%s)" % (peer_reason, config_reason or "no peer"),
            }
        )
    return _plan_base(
        "maclink.status",
        items,
        None,
        "read launchd relay state, the tailscale backend, boot time and the configured "
        "ssh peer, then return them; signal and write nothing",
        [
            "launchd state is what launchd reports; it does not prove the relay's tunnel "
            "session is healthy",
            "BackendState Running does not prove the Linux triage peer is reachable",
            "an ssh probe answers only that a shell replied, not that bridge-triage is "
            "processing events",
            "no peer configured means the ssh row is null with a reason, not a guess",
        ],
    )


def plan_restart_relay(ctx=None, runtime=None):
    runtime = runtime or Runtime()
    if not host_is_mac():
        return _plan_unavailable("maclink.restart-relay", "not this host (mac only)")
    try:
        unit = launchd_unit(RELAY_LABEL, runtime)
    except DataProblem as exc:
        return _plan_unavailable("maclink.restart-relay", str(exc))
    domain = unit["domain"]
    command = "launchctl kickstart -k %s" % unit["unit"]
    item = {
        "kind": "launchd-unit",
        "label": RELAY_LABEL,
        "domain": domain,
        "unit": unit["unit"],
        "plist": unit["plist"],
        "program": unit["program"],
        "arguments": unit["arguments"],
        "state_before": unit["state"],
        "pid_before": unit["pid"],
        "command": command,
        "argv": ["launchctl", "kickstart", "-k", unit["unit"]],
    }
    return _plan_base(
        "maclink.restart-relay",
        [item],
        0,
        "send launchctl kickstart -k to %s, which terminates the relay and starts it "
        "again, then poll launchctl print for a new pid for up to 6 s" % unit["unit"],
        [
            "how many board events are in flight at this moment; the relay's own queue is "
            "not readable from here",
            "whether the relay process is wedged now; launchd says %r, which only means it "
            "has a pid" % unit["state"],
            "that Linux triage receives the events that were in flight",
            "the exact downtime of this unit; measuring it would mean restarting it, which "
            "this plan does not do",
        ],
        blast_radius=(
            "in-flight board events can be lost for a few seconds; nothing else stops"
        ),
        blast_radius_detail={
            "lost": [
                "board events in transit between a bot and Linux triage while the relay is "
                "down (the Mac kanban database keeps every event it already holds)"
            ],
            "kept": [
                "worker bots",
                "the kanban database",
                "the tailscale tunnel",
                "the local HUD",
            ],
            "duration": "until launchd starts the unit again; this unit's restart time is "
            "not measured by the plan",
            "undo": command,
            "rollback": "run the same kickstart again; the plan stays valid after a restart",
        },
        rollback=command,
    )


def plan_restart_tunnel(ctx=None, runtime=None):
    runtime = runtime or Runtime()
    if not host_is_mac():
        return _plan_unavailable("maclink.restart-tunnel", "not this host (mac only)")
    reasons = {}
    unit = None
    for label in TAILSCALE_UNIT_LABELS:
        try:
            unit = launchd_unit(label, runtime)
            break
        except DataProblem as exc:
            reasons[label] = str(exc)
    if unit is not None:
        command = "launchctl kickstart -k %s" % unit["unit"]
        items = [
            {
                "kind": "launchd-unit",
                "label": unit["label"],
                "domain": unit["domain"],
                "unit": unit["unit"],
                "state_before": unit["state"],
                "pid_before": unit["pid"],
                "command": command,
                "argv": ["launchctl", "kickstart", "-k", unit["unit"]],
            }
        ]
        mechanism = "launchd"
        argv_list = [["launchctl", "kickstart", "-k", unit["unit"]]]
    else:
        cli = tailscale_cli()
        if not cli:
            reason = "no tailscaled launchd unit (%s) and no tailscale CLI at %s or on PATH" % (
                ", ".join(TAILSCALE_UNIT_LABELS),
                ", ".join(TAILSCALE_CLI_CANDIDATES),
            )
            payload = _plan_unavailable("maclink.restart-tunnel", reason)
            payload["reasons"].update(reasons)
            return payload
        items = [
            {
                "kind": "command",
                "command": "%s down" % tilde(cli),
                "argv": [cli, "down"],
                "changes": True,
            },
            {
                "kind": "command",
                "command": "%s up" % tilde(cli),
                "argv": [cli, "up"],
                "changes": True,
            },
        ]
        mechanism = "tailscale-cli"
        argv_list = [[cli, "down"], [cli, "up"]]
    backend = None
    cli_path = tailscale_cli()
    if cli_path:
        try:
            status = tailscale_status(cli_path, runtime)
            backend = {
                "backend_state": status.get("BackendState"),
                "version": status.get("Version"),
                "ips": status.get("TailscaleIPs") or [],
            }
        except DataProblem as exc:
            reasons["backend"] = str(exc)
    return _plan_base(
        "maclink.restart-tunnel",
        items,
        0,
        "take the tunnel down and bring it back up through %s, then read "
        "tailscale status for BackendState" % mechanism,
        [
            "whether tailscale up succeeds non-interactively on this macsys build; the "
            "App Store variant can require the GUI app, and run reports the exact exit",
            "how long the tunnel stays down",
            "whether the relay reconnects on its own; the relay is not read here",
        ],
        mechanism=mechanism,
        backend_before=backend,
        unit_probe_reasons=reasons,
        commands=[" ".join(shlex.quote(part) for part in argv) for argv in argv_list],
        blast_radius=(
            "the tailscale tunnel drops for a few seconds, so anything routed over it "
            "stalls or fails during the restart"
        ),
        blast_radius_detail={
            "lost": [
                "relay traffic to Linux during the gap (the Mac keeps the board events it "
                "already has)"
            ],
            "kept": ["the Mac itself", "launchd units", "the kanban database"],
            "duration": "until tailscale reports Running again; not measured by the plan",
            "undo": "tailscale up, or the kickstart command when the unit exists",
        },
        rollback="tailscale up (or the same kickstart when the unit exists)",
    )


def plan_kick_bot(ctx=None, runtime=None):
    runtime = runtime or Runtime()
    if not host_is_mac():
        return _plan_unavailable("maclink.kick-bot", "not this host (mac only)")
    try:
        stale, rejected, scanned, threshold, now, readonly = stale_workers(ctx, runtime)
    except DataProblem as exc:
        return _plan_unavailable(
            "maclink.kick-bot", str(exc), kind=_kind_of(exc),
            _capture_malformed=isinstance(exc, Malformed),
        )
    if not stale:
        if rejected:
            reason = (
                "no stale worker passed the pid identity check; %d stale row(s) rejected, "
                "nothing safe to kick" % len(rejected)
            )
        elif scanned:
            reason = "no running card with a worker pid is stale; %d scanned at %ds threshold" % (
                scanned,
                threshold,
            )
        else:
            reason = "no running card carries a worker pid"
        payload = _plan_unavailable("maclink.kick-bot", reason)
        payload["rejected"] = rejected[:PAGE_LIMIT]
        if any(item.get("kind") == "malformed" for item in rejected):
            # Nothing safe was found and at least one board row had to be
            # coerced: say so at the top level as well as on the row.
            payload["kind"] = "malformed"
        payload["threshold_s"] = threshold
        payload["now"] = int(now)
        payload["db_readonly"] = readonly
        return payload
    chosen = stale[0]
    command = "kill -TERM %d" % chosen["pid"]
    cannot = [
        "whether the worker is wedged or merely slow inside a long tool call; a stale "
        "heartbeat is evidence, not proof",
        "whether the dispatcher will requeue the card promptly after the process exits",
        "whether the worker had unsaved work in flight",
        "if the pid is reused between plan and run; run re-checks the command line and "
        "refuses when it changed",
    ]
    if readonly != "ro":
        cannot.append(
            "the board was read with immutable=1 (a WAL-marked file with no -shm), so "
            "heartbeat ages skip WAL replay and can lag the live board"
        )
    item = {
        "kind": "process-signal",
        "profile": chosen["profile"],
        "pid": chosen["pid"],
        "card": chosen["card"],
        "title": chosen["title"],
        "heartbeat_age_s": chosen["heartbeat_age_s"],
        "heartbeat_source": chosen["heartbeat_source"],
        "heartbeat_iso": chosen["heartbeat_iso"],
        "command": command,
        "command_sha256": chosen["command_sha256"],
        "argv0": chosen["argv0"],
        "argv": ["kill", "-TERM", str(chosen["pid"])],
    }
    return _plan_base(
        "maclink.kick-bot",
        [item],
        0,
        "re-verify pid %d against the live command line, then send SIGTERM to that pid "
        "only and poll up to 3 s for it to exit" % chosen["pid"],
        cannot,
        threshold_s=threshold,
        db_readonly=readonly,
        others=stale[1:PAGE_LIMIT],
        rejected=rejected[:PAGE_LIMIT],
        blast_radius=(
            "one stale worker process ends; its card stays running until the dispatcher's "
            "stale timeout requeues it"
        ),
        blast_radius_detail={
            "lost": ["that worker's in-flight tool call and any unsaved reasoning"],
            "kept": ["every other worker", "the gateway", "the dispatcher", "the board"],
            "duration": "the process exit is immediate; the card returns to the queue on "
            "the dispatcher's schedule",
            "undo": "the dispatcher respawns the card; no manual undo exists",
        },
        rollback="none; the dispatcher respawns the card",
    )


def pid_file_state(path):
    """Read a pid file. Anything that is not a positive pid is ``Malformed``.

    Bytes are decoded exactly: a file holding a byte that is not UTF-8 is
    refused instead of being read as a replacement character, which would make
    the answer depend on the decoder. A JSON body goes through ``loads_bounded``,
    so 1200 levels of nesting (which ``json`` cannot parse without a
    ``RecursionError``) is an answer, not a traceback.
    """
    if not os.path.isfile(path):
        return {"present": False, "pid": None, "raw": None}
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError as exc:
        raise Malformed("cannot read %s: %s" % (tilde(path), exc.strerror or exc))
    raw, lost = _decode_capture(data)
    if lost:
        raise Malformed(
            "%s is not valid UTF-8 (%d byte(s) replaced), so it is not a pid file"
            % (tilde(path), lost)
        )
    raw = raw.strip()
    if not raw:
        raise Malformed("%s is empty, so it holds no pid" % tilde(path))
    if raw.startswith("{"):
        record = loads_bounded(raw, tilde(path))
        if not isinstance(record, dict):
            raise Malformed("%s does not hold a pid" % tilde(path))
        pid = record.get("pid")
    else:
        pid = raw
    # Strict: a whole pid as text or a JSON integer. A bool, a float (12.7 must
    # not become 12), 0, 1 or a negative value is not a pid.
    pid = pid_from_cell(pid)
    if pid is None:
        raise Malformed("%s does not hold a pid" % tilde(path))
    return {"present": True, "pid": pid, "raw": raw}


def write_pid_file(path, pid, action, command):
    target = expand(path)
    os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
    payload = {
        "pid": int(pid),
        "action": action,
        "command": command,
        "started_at": utc_now_iso(),
    }
    handle = tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=os.path.dirname(target) or ".",
        prefix=".tmp-", suffix=".pid", delete=False,
    )
    try:
        with handle:
            json.dump(payload, handle, indent=2)
            handle.write("\n")
        os.replace(handle.name, target)
    except BaseException:
        try:
            os.unlink(handle.name)
        except OSError:
            pass
        raise


def process_is_caffeinate(cmdline):
    tokens = tokens_of(cmdline)
    if not tokens:
        return False
    return os.path.basename(tokens[0]) == "caffeinate"


def plan_wake(ctx=None, runtime=None):
    runtime = runtime or Runtime()
    if not host_is_mac():
        return _plan_unavailable("maclink.wake", "not this host (mac only)")
    paths = state_paths(ctx)
    try:
        recorded = pid_file_state(paths["caffeinate"])
    except Malformed as exc:
        # A pid file this reader cannot read exactly is not "no caffeinate
        # running": it is a hostile file, and starting a second display helper
        # on top of it would be a guess.
        return _plan_unavailable(
            "maclink.wake", str(exc), kind="malformed", _capture_malformed=True
        )
    except DataProblem as exc:
        recorded = {"present": True, "pid": None, "reason": str(exc)}
    if recorded.get("pid") and runtime.alive(recorded["pid"]):
        payload = _plan_unavailable(
            "maclink.wake",
            "caffeinate already running as pid %d; not starting a second one"
            % recorded["pid"],
        )
        payload["pid_file"] = tilde(paths["caffeinate"])
        payload["pid"] = recorded["pid"]
        return payload
    return _plan_base(
        "maclink.wake",
        [
            {
                "kind": "process-start",
                "command": "caffeinate -d",
                "argv": ["caffeinate", "-d"],
                "pid_file": tilde(paths["caffeinate"]),
                "detached": True,
            }
        ],
        0,
        "start caffeinate -d detached, write its pid to %s, and check it is alive"
        % tilde(paths["caffeinate"]),
        [
            "how long the display stays awake; caffeinate holds it until wake-off, the "
            "process dies, or the Mac sleeps",
            "whether the system policy allows the assertion; run reads the exit",
        ],
        pid_file=tilde(paths["caffeinate"]),
        pid_file_reason=recorded.get("reason"),
        already_running=False,
    )


def plan_wake_off(ctx=None, runtime=None):
    runtime = runtime or Runtime()
    if not host_is_mac():
        return _plan_unavailable("maclink.wake-off", "not this host (mac only)")
    paths = state_paths(ctx)
    try:
        recorded = pid_file_state(paths["caffeinate"])
    except DataProblem as exc:
        return _plan_unavailable(
            "maclink.wake-off", str(exc), kind=_kind_of(exc),
            _capture_malformed=isinstance(exc, Malformed),
        )
    if not recorded["pid"]:
        return _plan_unavailable(
            "maclink.wake-off",
            "no recorded caffeinate pid at %s" % tilde(paths["caffeinate"]),
        )
    pid = recorded["pid"]
    command_line = runtime.ps(pid)
    if not command_line:
        return _plan_unavailable(
            "maclink.wake-off",
            "pid %d from %s is gone; nothing to stop" % (pid, tilde(paths["caffeinate"])),
        )
    if not process_is_caffeinate(command_line):
        return _plan_unavailable(
            "maclink.wake-off",
            "pid %d is not caffeinate (argv0: %s); refusing to signal it"
            % (pid, argv0_name(command_line) or "unknown"),
        )
    if not runtime.alive(pid):
        return _plan_unavailable(
            "maclink.wake-off", "pid %d is not alive" % pid
        )
    return _plan_base(
        "maclink.wake-off",
        [
            {
                "kind": "process-signal",
                "pid": pid,
                "command": "kill -TERM %d" % pid,
                "argv": ["kill", "-TERM", str(pid)],
                "recorded_in": tilde(paths["caffeinate"]),
                "argv0": argv0_name(command_line),
            }
        ],
        0,
        "send SIGTERM to recorded pid %d only, after checking the process is caffeinate, "
        "then poll up to 3 s" % pid,
        [
            "whether the display assertion drops immediately; that is macOS policy, not "
            "this module",
            "whether another caffeinate process exists; this action does not look for or "
            "signal one",
        ],
        pid_file=tilde(paths["caffeinate"]),
        blast_radius="one caffeinate process ends; the display may sleep per system settings",
        rollback="maclink.wake starts a new caffeinate",
    )


def screenshot_path(ctx):
    explicit = ctx_value(ctx, "screenshot_path", None)
    if explicit:
        return expand(explicit)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    return os.path.join(tempfile.gettempdir(), "nexuslink", "screenshot-%s.png" % stamp)


def plan_screenshot(ctx=None, runtime=None):
    runtime = runtime or Runtime()
    if not host_is_mac():
        return _plan_unavailable("maclink.screenshot", "not this host (mac only)")
    target = screenshot_path(ctx)
    exists = os.path.exists(target)
    return _plan_base(
        "maclink.screenshot",
        [
            {
                "kind": "file-create",
                "command": "screencapture -x %s" % target,
                "argv": ["screencapture", "-x", target],
                "path": target,
                "path_display": tilde(target),
                "in_temp_dir": os.path.abspath(target).startswith(os.path.abspath(tempfile.gettempdir()) + os.sep),
                "exists_already": exists,
            }
        ],
        None,
        "run screencapture -x once into %s and report its size" % tilde(target),
        [
            "whether Screen Recording permission is granted; without it screencapture can "
            "fail or write a desktop-only image",
            "what the screen shows at capture time",
            "that the file is cleaned up; this action does not delete it",
        ],
        path=target,
        path_display=tilde(target),
        blast_radius="one new file under the system temp directory",
    )


# ----------------------------------------------------------------------- runs


def _run_base(name, result, summary):
    return {
        "ok": bool(result.get("ok", True)),
        "source": SOURCE,
        "generated_at": utc_now_iso(),
        "action": name,
        "class": CLASS_TABLE[name],
        "linux_only": False,
        "ran": True,
        "summary": summary,
        "result": result,
    }


def _refused(name, reason, **extra):
    payload = {
        "ok": False,
        "source": SOURCE,
        "generated_at": utc_now_iso(),
        "action": name,
        "class": CLASS_TABLE[name],
        "linux_only": False,
        "ran": False,
        "refused": True,
        "reason": reason,
    }
    payload.update(extra)
    return payload


def _plan_failure(name, plan, fallback="unavailable"):
    """A plan that could not read hostile input is the answer, not a refusal.

    A marker set by a ``Malformed`` catch (a lossy ``ps`` capture or a pid file
    that is not a pid) returns the plan unchanged, so the run answers
    ``kind: "malformed"`` at exit 0 without touching the host. A plan that
    refused a corrupt *board row* carries ``kind: "malformed"`` without that
    marker and keeps the existing exit 2 refusal, which is the surface the
    verifier already proved.
    """
    if plan.get("_capture_malformed"):
        return _malformed_run(name, plan.get("reason") or "unreadable input")
    return _refused(name, plan.get("reason") or fallback)


def _malformed_run(name, reason):
    """A run that never reached the host because its input was hostile."""
    return {
        "ok": False,
        "source": SOURCE,
        "generated_at": utc_now_iso(),
        "action": name,
        "class": CLASS_TABLE[name],
        "linux_only": False,
        "ran": False,
        "refused": False,
        "kind": "malformed",
        "reason": reason,
        "items": [],
        "total": {"items": 0, "bytes": 0, "bytes_reason": None},
    }


def _confirmed(confirm, name):
    if confirm is True:
        return True
    if isinstance(confirm, str) and confirm.strip() == name:
        return True
    return False


def _guard_run(name, ctx, confirm, runtime):
    """Shared run preamble: host, class confirmation, plan availability."""
    if not host_is_mac():
        return _refused(name, "not this host (mac only): sys.platform is %r" % sys.platform)
    if CLASS_TABLE[name] in ("reversible", "destructive") and not _confirmed(confirm, name):
        return _refused(
            name,
            "%s is %s: pass --confirm %s to run it"
            % (name, CLASS_TABLE[name], name),
        )
    return None


def status_cache_read(ctx, now=None):
    """A status payload younger than STATUS_CACHE_TTL_S, marked cached, or None.

    A cache file this reader cannot read exactly - a directory, a byte that is
    not UTF-8, text that is not JSON, JSON nested past the depth cap - raises
    ``Malformed`` instead of crashing with a traceback. A missing file is not a
    problem: it means the next probe is the first one.
    """
    path = state_paths(ctx)["status_cache"]
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except FileNotFoundError:
        return None
    except IsADirectoryError:
        raise Malformed("%s is a directory, not a status cache" % tilde(path))
    except OSError as exc:
        raise Malformed("cannot read %s: %s" % (tilde(path), exc.strerror or exc))
    raw, lost = _decode_capture(data)
    if lost:
        raise Malformed(
            "%s is not valid UTF-8 (%d byte(s) replaced)" % (tilde(path), lost)
        )
    if not raw.strip():
        raise Malformed("%s is empty" % tilde(path))
    record = loads_bounded(raw, tilde(path))
    if not isinstance(record, dict):
        raise Malformed("%s does not hold a status record" % tilde(path))
    payload = record.get("payload")
    stamp = record.get("cached_at")
    raw_epoch = record.get("cached_epoch")
    # A bool, a huge JSON integer (OverflowError), 1e400 or NaN is not a time:
    # NaN would pass both the age tests and be served as fresh.
    if isinstance(raw_epoch, bool) or not isinstance(raw_epoch, (int, float, str)):
        raise Malformed("%s carries no readable cache timestamp" % tilde(path))
    try:
        epoch = float(raw_epoch)
    except (TypeError, ValueError, OverflowError):
        raise Malformed("%s carries no readable cache timestamp" % tilde(path))
    if epoch != epoch or epoch in (float("inf"), float("-inf")):
        raise Malformed("%s carries no readable cache timestamp" % tilde(path))
    age = (time.time() if now is None else now) - epoch
    if not isinstance(payload, dict) or payload.get("action") != "maclink.status":
        raise Malformed("%s does not hold a status payload" % tilde(path))
    if not isinstance(stamp, str) or age < 0 or age >= STATUS_CACHE_TTL_S:
        return None
    served = dict(payload)
    served["cached"] = True
    served["cached_at"] = stamp
    served["cache_age_s"] = round(age, 3)
    return served


def status_cache_write(ctx, payload):
    """Atomically keep one status payload for STATUS_CACHE_TTL_S. Never fails the read."""
    path = state_paths(ctx)["status_cache"]
    parent = os.path.dirname(path) or "."
    record = {
        "source": SOURCE,
        "action": "maclink.status",
        "cached_at": utc_now_iso(),
        "cached_epoch": time.time(),
        "payload": payload,
    }
    temp_name = None
    try:
        os.makedirs(parent, exist_ok=True)
        handle = tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", prefix=".maclink-status-", suffix=".tmp",
            dir=parent, delete=False,
        )
        temp_name = handle.name
        with handle:
            json.dump(record, handle, ensure_ascii=False, sort_keys=False)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
        return True
    except OSError:
        if temp_name and os.path.exists(temp_name):
            try:
                os.unlink(temp_name)
            except OSError:
                pass
        return False


def run_status(ctx=None, confirm=None, runtime=None):
    runtime = runtime or Runtime()
    guard = _guard_run("maclink.status", ctx, confirm, runtime)
    if guard:
        return guard
    cached = status_cache_read(ctx)
    if cached:
        return cached
    reasons = {}
    relay = {"label": RELAY_LABEL, "present": False}
    relay_ok = False
    try:
        relay = launchd_unit(RELAY_LABEL, runtime)
        relay_ok = True
    except DataProblem as exc:
        reasons["relay"] = str(exc)
    tunnel = {"mechanism": None, "backend_state": None, "up": None, "reasons": {}}
    tunnel_ok = False
    launchd_tunnel = None
    for label in TAILSCALE_UNIT_LABELS:
        try:
            launchd_tunnel = launchd_unit(label, runtime)
            break
        except DataProblem as exc:
            tunnel["reasons"][label] = str(exc)
    cli = tailscale_cli()
    if launchd_tunnel is not None:
        tunnel["mechanism"] = "launchd"
        tunnel["launchd"] = launchd_tunnel
    if cli:
        try:
            status = tailscale_status(cli, runtime)
            tunnel.update(
                {
                    "mechanism": tunnel["mechanism"] or "tailscale-cli",
                    "cli": tilde(cli),
                    "backend_state": status.get("BackendState"),
                    "version": status.get("Version"),
                    "ips": status.get("TailscaleIPs") or [],
                    "dns_name": (status.get("Self") or {}).get("DNSName"),
                }
            )
            tunnel["up"] = status.get("BackendState") == "Running"
            tunnel_ok = True
        except DataProblem as exc:
            tunnel["reasons"]["status"] = str(exc)
    uptime_s = None
    uptime_text = None
    try:
        boot = boot_seconds(runtime)
        uptime_s = max(0, int(runtime.now() - boot))
        uptime_text = uptime_human(uptime_s)
    except DataProblem as exc:
        reasons["uptime"] = str(exc)
    config_text, config_reason = read_ssh_config()
    peer, peer_reason = ssh_peer_from_config(config_text, ctx_value(ctx, "peer", None))
    if peer:
        ssh = ssh_reachable(peer, runtime)
        ssh["source"] = peer_reason
    else:
        ssh = {
            "peer": None,
            "reachable": None,
            "reason": "%s (%s)" % (peer_reason, config_reason or "no peer"),
        }
    ok = relay_ok or tunnel_ok
    result = {
        "ok": ok,
        "relay": relay,
        "tunnel": tunnel,
        "uptime_s": uptime_s,
        "uptime_human": uptime_text,
        "ssh": ssh,
        "reasons": reasons,
    }
    if not ok:
        result["reason"] = "neither launchd nor tailscale answered; the link state is unknown"
    summary = "relay %s, tunnel %s, uptime %s" % (
        relay.get("state") if relay_ok else "unreadable",
        tunnel.get("backend_state") if tunnel_ok else "unreadable",
        uptime_text or "unreadable",
    )
    payload = _run_base("maclink.status", result, summary)
    payload["cached"] = False
    payload["cached_at"] = None
    status_cache_write(ctx, payload)
    return payload


def run_restart_relay(ctx=None, confirm=None, runtime=None):
    runtime = runtime or Runtime()
    guard = _guard_run("maclink.restart-relay", ctx, confirm, runtime)
    if guard:
        return guard
    plan = plan_restart_relay(ctx, runtime)
    if not plan.get("ok"):
        return _plan_failure("maclink.restart-relay", plan)
    item = plan["items"][0]
    pid_before = item.get("pid_before")
    argv = item["argv"]
    out, err, code = runtime.run(argv, timeout=15.0)
    result = {
        "ok": False,
        "unit": item["unit"],
        "command": item["command"],
        "exit": code,
        "stdout": one_line(out, 400),
        "stderr": one_line(err, 400),
        "pid_before": pid_before,
        "pid_after": None,
        "restarted": False,
        "waited_s": 0.0,
        "blast_radius": plan.get("blast_radius"),
        "rollback": item["command"],
    }
    if code != 0:
        result["reason"] = "launchctl kickstart exited %d" % code
        return _run_base("maclink.restart-relay", result, "kickstart failed, relay state unchanged or unknown")
    started = runtime.now()
    deadline = started + 6.0
    pid_after = None
    while runtime.now() < deadline:
        time.sleep(0.25)
        try:
            unit = launchd_unit(RELAY_LABEL, runtime)
        except DataProblem:
            continue
        pid_after = unit.get("pid")
        if pid_after is not None and pid_after != pid_before:
            break
        if pid_before is None and pid_after is not None:
            break
    result["waited_s"] = round(runtime.now() - started, 2)
    result["pid_after"] = pid_after
    result["restarted"] = pid_after is not None and pid_after != pid_before
    if pid_before is None and pid_after is not None:
        result["restarted"] = True
    if result["restarted"]:
        result["ok"] = True
        summary = "relay restarted, pid %s -> %s in %.2fs" % (
            pid_before,
            pid_after,
            result["waited_s"],
        )
    else:
        result["reason"] = (
            "kickstart exited 0 but launchd reported no new pid within %.1fs; check the "
            "relay log" % result["waited_s"]
        )
        summary = "kickstart exited 0 but no new pid was observed"
    return _run_base("maclink.restart-relay", result, summary)


def run_restart_tunnel(ctx=None, confirm=None, runtime=None):
    runtime = runtime or Runtime()
    guard = _guard_run("maclink.restart-tunnel", ctx, confirm, runtime)
    if guard:
        return guard
    plan = plan_restart_tunnel(ctx, runtime)
    if not plan.get("ok"):
        return _plan_failure("maclink.restart-tunnel", plan)
    steps = []
    ok = True
    for item in plan["items"]:
        out, err, code = runtime.run(item["argv"], timeout=30.0)
        steps.append(
            {
                "command": item["command"],
                "exit": code,
                "stdout": one_line(out, 300),
                "stderr": one_line(err, 300),
            }
        )
        if code != 0:
            ok = False
            break
    after = None
    cli = tailscale_cli()
    if cli:
        try:
            status = tailscale_status(cli, runtime)
            after = {
                "backend_state": status.get("BackendState"),
                "ips": status.get("TailscaleIPs") or [],
            }
        except DataProblem as exc:
            after = {"backend_state": None, "reason": str(exc)}
    if ok and after and after.get("backend_state") == "Running":
        result_ok = True
        summary = "tunnel restarted via %s, BackendState Running" % plan.get("mechanism")
    elif ok:
        result_ok = False
        summary = "commands exited 0 but BackendState is %r" % (
            (after or {}).get("backend_state"),
        )
    else:
        result_ok = False
        summary = "tunnel restart failed at %s; the tunnel may be DOWN" % (
            steps[-1]["command"] if steps else "the first command"
        )
    result = {
        "ok": result_ok,
        "mechanism": plan.get("mechanism"),
        "steps": steps,
        "backend_after": after,
        "blast_radius": plan.get("blast_radius"),
        "rollback": plan.get("rollback"),
    }
    if not result_ok:
        result["reason"] = summary
    return _run_base("maclink.restart-tunnel", result, summary)


def run_kick_bot(ctx=None, confirm=None, runtime=None):
    runtime = runtime or Runtime()
    guard = _guard_run("maclink.kick-bot", ctx, confirm, runtime)
    if guard:
        return guard
    plan = plan_kick_bot(ctx, runtime)
    if not plan.get("ok"):
        return _plan_failure("maclink.kick-bot", plan, "no stale worker")
    item = plan["items"][0]
    pid = item["pid"]
    # Strict gate before any ps, signal or wait: only a plain int that
    # pid_from_cell accepts (no bool, float, text, 0, 1 or negative) gets through.
    if type(pid) is not int or pid_from_cell(pid) != pid:
        return _refused(
            "maclink.kick-bot",
            "pid %r was not parsed as a strict pid; refusing to signal" % (pid,),
        )
    fresh = runtime.ps(pid)
    self_pids = self_process_chain(runtime)
    ok, reason = classify_worker(
        fresh,
        item["profile"],
        item["card"],
        pid,
        self_pids,
        os.environ.get("HERMES_KANBAN_TASK"),
    )
    if not ok:
        return _refused("maclink.kick-bot", "pid %d changed or no longer matches: %s" % (pid, reason))
    if not item.get("command_sha256"):
        return _refused("maclink.kick-bot", "plan carried no command digest; refusing to signal pid %d" % pid)
    if command_digest(fresh) != item["command_sha256"]:
        return _refused(
            "maclink.kick-bot",
            "pid %d command line changed since the plan; refusing to signal it" % pid,
        )
    out, err, code = runtime.run(item["argv"], timeout=10.0)
    result = {
        "ok": False,
        "profile": item["profile"],
        "pid": pid,
        "card": item["card"],
        "command": item["command"],
        "exit": code,
        "stdout": one_line(out, 200),
        "stderr": one_line(err, 200),
        "gone": False,
        "waited_s": 0.0,
        "blast_radius": plan.get("blast_radius"),
    }
    if code != 0:
        result["reason"] = "kill exited %d" % code
        return _run_base("maclink.kick-bot", result, "kill failed, worker untouched")
    started = runtime.now()
    deadline = started + 3.0
    gone = False
    while runtime.now() < deadline:
        time.sleep(0.1)
        if not runtime.alive(pid):
            gone = True
            break
    result["waited_s"] = round(runtime.now() - started, 2)
    result["gone"] = gone
    if gone:
        result["ok"] = True
        summary = "SIGTERM to %s pid %d, exited in %.2fs" % (
            item["profile"],
            pid,
            result["waited_s"],
        )
    else:
        result["reason"] = "pid %d is still alive %.1fs after SIGTERM" % (pid, result["waited_s"])
        summary = "SIGTERM sent to pid %d, still alive" % pid
    return _run_base("maclink.kick-bot", result, summary)


def run_wake(ctx=None, confirm=None, runtime=None):
    runtime = runtime or Runtime()
    guard = _guard_run("maclink.wake", ctx, confirm, runtime)
    if guard:
        return guard
    plan = plan_wake(ctx, runtime)
    if not plan.get("ok"):
        return _plan_failure("maclink.wake", plan)
    item = plan["items"][0]
    paths = state_paths(ctx)
    try:
        again = pid_file_state(paths["caffeinate"])
        if again.get("pid") and runtime.alive(again["pid"]):
            return _refused(
                "maclink.wake",
                "caffeinate is already running as pid %d; not starting a second one"
                % again["pid"],
            )
    except Malformed:
        # The pid file was readable at plan time and is hostile now: refuse the
        # run rather than start a second helper over a file we cannot read.
        raise
    except DataProblem:
        pass
    try:
        pid = runtime.spawn(item["argv"])
    except OSError as exc:
        return _run_base(
            "maclink.wake",
            {"ok": False, "reason": "could not start caffeinate: %s" % exc},
            "caffeinate did not start",
        )
    deadline = runtime.now() + 1.0
    alive = False
    while runtime.now() < deadline:
        time.sleep(0.05)
        if runtime.alive(pid):
            alive = True
            break
    result = {"ok": alive, "pid": pid, "command": "caffeinate -d", "pid_file": tilde(paths["caffeinate"])}
    if not alive:
        result["reason"] = "caffeinate exited immediately; no pid file written"
        return _run_base("maclink.wake", result, "caffeinate did not stay up")
    try:
        write_pid_file(paths["caffeinate"], pid, "maclink.wake", "caffeinate -d")
    except OSError as exc:
        _out, _err, cleanup_code = runtime.run(["kill", "-TERM", str(pid)], timeout=5.0)
        result["ok"] = False
        result["cleanup_exit"] = cleanup_code
        result["reason"] = (
            "caffeinate was pid %d but the pid file could not be written (%s); the "
            "process was stopped again so no unrecorded helper is left running"
            % (pid, exc)
        )
        return _run_base("maclink.wake", result, "caffeinate up, pid file failed, process stopped")
    return _run_base("maclink.wake", result, "caffeinate running as pid %d" % pid)


def run_wake_off(ctx=None, confirm=None, runtime=None):
    runtime = runtime or Runtime()
    guard = _guard_run("maclink.wake-off", ctx, confirm, runtime)
    if guard:
        return guard
    plan = plan_wake_off(ctx, runtime)
    if not plan.get("ok"):
        return _plan_failure("maclink.wake-off", plan, "no recorded caffeinate")
    item = plan["items"][0]
    pid = item["pid"]
    fresh = runtime.ps(pid)
    if not fresh or not process_is_caffeinate(fresh):
        return _refused(
            "maclink.wake-off",
            "pid %d no longer looks like caffeinate (argv0: %s); refusing to signal it"
            % (pid, argv0_name(fresh) or "gone"),
        )
    out, err, code = runtime.run(item["argv"], timeout=10.0)
    result = {
        "ok": False,
        "pid": pid,
        "command": item["command"],
        "exit": code,
        "stdout": one_line(out, 200),
        "stderr": one_line(err, 200),
        "gone": False,
        "waited_s": 0.0,
    }
    if code != 0:
        result["reason"] = "kill exited %d" % code
        return _run_base("maclink.wake-off", result, "kill failed, caffeinate untouched")
    started = runtime.now()
    deadline = started + 3.0
    gone = False
    while runtime.now() < deadline:
        time.sleep(0.1)
        if not runtime.alive(pid):
            gone = True
            break
    result["waited_s"] = round(runtime.now() - started, 2)
    result["gone"] = gone
    if gone:
        result["ok"] = True
        summary = "caffeinate pid %d stopped in %.2fs" % (pid, result["waited_s"])
    else:
        result["reason"] = "pid %d is still alive %.1fs after SIGTERM" % (pid, result["waited_s"])
        summary = "SIGTERM sent to caffeinate pid %d, still alive" % pid
    return _run_base("maclink.wake-off", result, summary)


def run_screenshot(ctx=None, confirm=None, runtime=None):
    runtime = runtime or Runtime()
    guard = _guard_run("maclink.screenshot", ctx, confirm, runtime)
    if guard:
        return guard
    plan = plan_screenshot(ctx, runtime)
    if not plan.get("ok"):
        return _plan_failure("maclink.screenshot", plan)
    item = plan["items"][0]
    target = item["path"]
    if os.path.exists(target):
        return _refused(
            "maclink.screenshot",
            "%s already exists; remove it or pass --screenshot-path" % tilde(target),
        )
    try:
        os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
    except OSError as exc:
        return _run_base(
            "maclink.screenshot",
            {"ok": False, "reason": "cannot create %s: %s" % (tilde(os.path.dirname(target)), exc)},
            "no temp directory",
        )
    out, err, code = runtime.run(item["argv"], timeout=20.0)
    size = None
    exists = os.path.isfile(target)
    if exists:
        try:
            size = os.path.getsize(target)
        except OSError:
            size = None
    result = {
        "ok": bool(code == 0 and exists and size),
        "command": item["command"],
        "path": target,
        "path_display": tilde(target),
        "exit": code,
        "bytes": size,
        "stdout": one_line(out, 200),
        "stderr": one_line(err, 200),
    }
    if not result["ok"]:
        if code != 0:
            result["reason"] = "screencapture exited %d" % code
        elif not exists:
            result["reason"] = "screencapture exited 0 but wrote no file"
        else:
            result["reason"] = "screencapture wrote an empty file"
        return _run_base("maclink.screenshot", result, "screenshot failed or empty")
    return _run_base(
        "maclink.screenshot",
        result,
        "screenshot at %s (%d bytes)" % (result["path_display"], size),
    )


_PLAN_FUNCS = {
    "maclink.status": plan_status,
    "maclink.restart-relay": plan_restart_relay,
    "maclink.restart-tunnel": plan_restart_tunnel,
    "maclink.kick-bot": plan_kick_bot,
    "maclink.wake": plan_wake,
    "maclink.wake-off": plan_wake_off,
    "maclink.screenshot": plan_screenshot,
}

_RUN_FUNCS = {
    "maclink.status": run_status,
    "maclink.restart-relay": run_restart_relay,
    "maclink.restart-tunnel": run_restart_tunnel,
    "maclink.kick-bot": run_kick_bot,
    "maclink.wake": run_wake,
    "maclink.wake-off": run_wake_off,
    "maclink.screenshot": run_screenshot,
}

ACTIONS = {}
for _name in ORDER:
    ACTIONS[_name] = {
        "class": CLASS_TABLE[_name],
        "doc": DOCS[_name],
        "plan": _PLAN_FUNCS[_name],
        "run": _RUN_FUNCS[_name],
        "linux_only": False,
    }


def list_payload():
    return {
        "ok": True,
        "source": SOURCE,
        "generated_at": utc_now_iso(),
        "actions": [
            {
                "name": name,
                "class": ACTIONS[name]["class"],
                "doc": ACTIONS[name]["doc"],
                "linux_only": ACTIONS[name]["linux_only"],
            }
            for name in ORDER
        ],
    }


# ------------------------------------------------------------------ self-check


def _state_changing(argv):
    if not argv:
        return False
    first = os.path.basename(str(argv[0]))
    rest = [str(part) for part in argv[1:]]
    if first in ("kill", "pkill", "killall", "shutdown", "reboot"):
        return True
    if first == "launchctl" and any(part in ("kickstart", "bootout", "bootstrap", "kill") for part in rest):
        return True
    if first == "tailscale" and rest[:1] and rest[0] in ("down", "up", "restart", "set"):
        return True
    if first in ("caffeinate", "screencapture"):
        return True
    return False


class RecordingRuntime(object):
    """Records every seam call. Never touches a real process."""

    def __init__(self, outputs=None, ps_map=None, ps_table_text="", now=None, alive_map=None,
                 ps_sequence=None):
        self.outputs = outputs or {}
        self.ps_map = ps_map or {}
        self.ps_sequence = ps_sequence or {}
        self.ps_table_text = ps_table_text
        self.fixed_now = time.time() if now is None else now
        self.alive_map = alive_map or {}
        self.runs = []
        self.changes = []
        self.spawns = []
        self.ps_calls = []
        self.ps_table_calls = 0
        self.table = []

    def run(self, argv, timeout=DEFAULT_TIMEOUT_S, strict_text=False):
        argv = [str(part) for part in argv]
        self.runs.append(argv)
        if _state_changing(argv):
            self.changes.append(argv)
        key = argv[0]
        if argv[:2] == ["sysctl", "-n"]:
            key = "sysctl"
        elif argv[:1] == ["ps"] and "-Ao" in argv:
            key = "ps_table"
        return self.outputs.get(key, ("", "", 0))

    def spawn(self, argv):
        argv = [str(part) for part in argv]
        self.spawns.append(argv)
        if _state_changing(argv):
            self.changes.append(argv)
        return 5150

    def ps(self, pid):
        key = int(pid)
        self.ps_calls.append(key)
        queue = self.ps_sequence.get(key)
        if queue:
            if len(queue) > 1:
                return queue.pop(0)
            return queue[0]
        return self.ps_map.get(key, "")

    def ps_table(self):
        self.ps_table_calls += 1
        if self.ps_table_text == "__FAIL__":
            raise DataProblem("ps -Ao failed")
        rows = []
        for line in self.ps_table_text.splitlines():
            parts = line.strip().split(None, 2)
            if len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit():
                rows.append((int(parts[0]), int(parts[1]), parts[2] if len(parts) > 2 else ""))
        self.table = rows
        return rows

    def alive(self, pid):
        try:
            key = int(pid)
        except (TypeError, ValueError):
            return False
        return bool(self.alive_map.get(key, False))

    def now(self):
        return self.fixed_now


def _sha_tree(root, ignore=()):
    """sha256 over sorted relative paths and file bytes. Used to prove purity."""
    import hashlib

    digest = hashlib.sha256()
    ignored = {os.path.abspath(path) for path in ignore}
    for base, dirs, files in os.walk(root):
        dirs[:] = [
            name
            for name in sorted(dirs)
            if not any(
                os.path.abspath(os.path.join(base, name)) == item
                or os.path.abspath(os.path.join(base, name)).startswith(item + os.sep)
                for item in ignored
            )
        ]
        for name in sorted(files):
            path = os.path.abspath(os.path.join(base, name))
            if any(path == item or path.startswith(item + os.sep) for item in ignored):
                continue
            rel = os.path.relpath(path, root)
            digest.update(rel.encode("utf-8"))
            try:
                with open(path, "rb") as handle:
                    digest.update(handle.read())
            except OSError:
                digest.update(b"<unreadable>")
    return digest.hexdigest()


def _write_stub(directory, name, body):
    path = os.path.join(directory, name)
    header = (
        "#!" + sys.executable + "\n"
        "import json, os, sys\n"
        "LOG = os.environ['MACLINK_SC_LOG']\n"
        "FIX = os.environ['MACLINK_SC_FIX']\n"
        "def log(line):\n"
        "    with open(LOG, 'a', encoding='utf-8') as handle:\n"
        "        handle.write(line + '\\n')\n"
        "ARGS = sys.argv[1:]\n"
        "log('%s ' % os.path.basename(sys.argv[0]) + ' '.join(ARGS))\n"
    )
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(header)
        handle.write(body)
    os.chmod(path, 0o755)
    return path


def _cli(argv, env):
    # Self-check children load the module through the boot file, which pins the
    # fake uid and the mac gate for that child only. Production never sees it.
    target = [sys.executable, os.path.abspath(__file__)]
    if _CLI_BOOT:
        target = [sys.executable, _CLI_BOOT, os.path.abspath(__file__)]
    proc = subprocess.run(
        target + list(argv),
        capture_output=True,
        text=True,
        env=env,
        timeout=120.0,
    )
    return proc.returncode, proc.stdout, proc.stderr


class _FakeRuntime(Runtime):
    """In-process fake for the F8c cases: records every call, runs nothing.

    run() answers only the ps table from a canned string and fails every other
    command with 127. ps() records and returns no command line. No ps, kill,
    launchctl or ssh ever executes.
    """

    def __init__(self, table_text=""):
        self.table_text = table_text
        self.calls = []

    def run(self, argv, timeout=DEFAULT_TIMEOUT_S, strict_text=False):
        self.calls.append(list(argv))
        if list(argv[:2]) == ["ps", "-ww"] and "-Ao" in argv:
            return self.table_text, "", 0
        return "", "fake runtime: %s not run" % argv[0], 127

    def ps(self, pid):
        self.calls.append(["ps", pid])
        return ""

    def alive(self, pid):
        self.calls.append(["alive", pid])
        return False


def _f8c_try(fn):
    """(value, None), or (None, "ErrorName: text") so a crash is a failed case."""
    try:
        return fn(), None
    except Exception as exc:
        return None, "%s: %s" % (type(exc).__name__, exc)


def _f8c_kick(pid):
    """Run the real run_kick_bot with a canned plan carrying `pid`. Returns (result, calls)."""
    runtime = _FakeRuntime()
    plan = {
        "ok": True,
        "items": [{
            "pid": pid, "profile": "kakashi", "card": "t_f8c",
            "command": "kill -TERM %s" % (pid,), "argv": ["kill", "-TERM", str(pid)],
            "command_sha256": "0" * 64,
        }],
        "blast_radius": "fake",
    }
    saved = globals()["plan_kick_bot"]
    globals()["plan_kick_bot"] = lambda ctx=None, runtime=None: plan
    try:
        result = run_kick_bot({}, confirm="maclink.kick-bot", runtime=runtime)
    finally:
        globals()["plan_kick_bot"] = saved
    return result, runtime.calls


def f8c_cases(check):
    """Named F8c cases: strict pid parse, ps rows, pid file, status cache, kick gate."""
    bad_pids = [
        ("f8c-pid-zero-refused", 0),
        ("f8c-pid-one-refused", 1),
        ("f8c-pid-negative-refused", -5),
        ("f8c-pid-text-refused", "abc"),
        ("f8c-pid-text-tail-refused", "12x"),
        ("f8c-pid-empty-refused", ""),
        ("f8c-pid-float-fraction-refused", 12.5),
        ("f8c-pid-bool-refused", True),
        ("f8c-pid-huge-refused", 10 ** 12),
        ("f8c-pid-above-ceiling-refused", PID_MAX + 1),
        ("f8c-pid-none-refused", None),
    ]
    for name, value in bad_pids:
        check(name, pid_from_cell(value) is None, "accepted %r" % (value,))
    value, error = _f8c_try(lambda: (pid_from_cell("4242"), pid_from_cell(PID_MAX)))
    check("f8c-pid-good-accepted", error is None and value == (4242, PID_MAX), "%r %r" % (value, error))

    ps_cases = [
        ("f8c-ps-row-missing-columns-skipped", "7\n", []),
        ("f8c-ps-row-nonnumeric-pid-skipped", "abc 1 cmd\n-5 1 cmd\n", []),
        ("f8c-ps-row-superscript-pid-skipped", "\u00b2 1 cmd\n", []),
        ("f8c-ps-row-good-kept-after-bad", "abc 1 x\n4242 1 /usr/bin/hermes\n", [(4242, 1, "/usr/bin/hermes")]),
    ]
    for name, table, expected in ps_cases:
        value, error = _f8c_try(lambda: _FakeRuntime(table).ps_table())
        check(name, error is None and value == expected, "%r %r" % (value, error))

    tmp = tempfile.mkdtemp(prefix="hudfix-f8c-", dir=os.environ.get("TMPDIR"))
    pid_files = [
        ("f8c-pidfile-zero-malformed", "0\n"),
        ("f8c-pidfile-one-malformed", "1\n"),
        ("f8c-pidfile-negative-malformed", "-7\n"),
        ("f8c-pidfile-text-malformed", "abc\n"),
        ("f8c-pidfile-empty-malformed", ""),
        ("f8c-pidfile-json-float-malformed", '{"pid": 12.7}'),
        ("f8c-pidfile-json-bool-malformed", '{"pid": true}'),
        ("f8c-pidfile-json-truncated-malformed", '{"pid": 42'),
    ]
    for name, text in pid_files:
        path = os.path.join(tmp, name + ".pid")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        value, error = _f8c_try(lambda: pid_file_state(path))
        check(name, error is not None and error.startswith("Malformed"), "%r %r" % (value, error))
    good = os.path.join(tmp, "good.pid")
    with open(good, "w", encoding="utf-8") as handle:
        handle.write("4242\n")
    value, error = _f8c_try(lambda: pid_file_state(good))
    check("f8c-pidfile-good-accepted", error is None and (value or {}).get("pid") == 4242, "%r %r" % (value, error))

    state = os.path.join(tmp, "state")
    os.makedirs(state, exist_ok=True)
    cache = os.path.join(state, "maclink-status.json")
    cache_cases = [
        ("f8c-status-cache-truncated-malformed", '{"source": "hudfix_maclink", "payload": {"ok": tr'),
        ("f8c-status-cache-non-json-malformed", "relay is up, not json\n"),
        ("f8c-status-cache-empty-malformed", ""),
        ("f8c-status-cache-wrong-types-malformed", '{"payload": "ok", "cached_epoch": "soon"}'),
    ]
    for name, text in cache_cases:
        with open(cache, "w", encoding="utf-8") as handle:
            handle.write(text)
        value, error = _f8c_try(lambda: status_cache_read({"state_dir": state}))
        check(name, error is not None and error.startswith("Malformed"), "%r %r" % (value, error))
    # The kick path never reads the status cache: with a truncated cache on disk
    # and no board, the plan refuses and no kill is ever recorded.
    runtime = _FakeRuntime()
    with open(cache, "w", encoding="utf-8") as handle:
        handle.write('{"payload": {"ok": tr')
    value, error = _f8c_try(lambda: plan_kick_bot(
        {"state_dir": state, "db_path": os.path.join(tmp, "absent.db")}, runtime=runtime))
    kills = [call for call in runtime.calls if call and call[0] == "kill"]
    check(
        "f8c-status-cache-never-kicks",
        error is None and (value or {}).get("ok") is False and kills == [],
        "%r %r kills=%r" % ((value or {}).get("ok"), error, kills),
    )

    # Parse-level cases: each breaking input is a named check, no ps/kill/launchctl run.
    for name, text in [
        ("f8c-launchctl-superscript-pid-no-crash", "\tpid = \u00b2\n"),
        ("f8c-launchctl-pid-zero-refused", "\tpid = 0\n"),
        ("f8c-launchctl-pid-one-refused", "\tpid = 1\n"),
        ("f8c-launchctl-pid-huge-refused", "\tpid = 99999999999999\n"),
    ]:
        value, error = _f8c_try(lambda: parse_launchctl("\tstate = running\n" + text)["pid"])
        check(name, error is None and value is None, "pid=%r error=%r" % (value, error))
    value, error = _f8c_try(lambda: parse_launchctl("\tstate = running\n\tpid = 4242\n")["pid"])
    check("f8c-launchctl-pid-good-accepted", error is None and value == 4242, "pid=%r error=%r" % (value, error))
    class _CannedPs(Runtime):
        """The real Runtime.ps_table parser, fed a canned table (no ps runs)."""

        def __init__(self, text):
            self.text = text

        def run(self, argv, timeout=DEFAULT_TIMEOUT_S, strict_text=False):
            return self.text, "", 0

    rows, error = _f8c_try(lambda: _CannedPs("123 456\n\u00b2 5 bad\n\u0661\u0662 5 x\n").ps_table())
    check(
        "f8c-ps-row-missing-command-empty",
        error is None and rows == [(123, 456, "")]
        and classify_worker("", "kakashi", "t_f8c", 123, set())[0] is False,
        "rows=%r error=%r" % (rows, error),
    )
    for name, epoch_text in [
        ("f8c-status-cache-nan-epoch-malformed", "NaN"),
        ("f8c-status-cache-inf-epoch-malformed", "1e400"),
        ("f8c-status-cache-bigint-epoch-malformed", "1" + "0" * 400),
        ("f8c-status-cache-bool-epoch-malformed", "true"),
    ]:
        text = ('{"source": "hudfix_maclink", "action": "maclink.status", "cached_at": "2026-10-23T12:00:00Z",'
                ' "cached_epoch": %s, "payload": {"action": "maclink.status", "ok": true}}') % epoch_text
        with open(cache, "w", encoding="utf-8") as handle:
            handle.write(text)
        value, error = _f8c_try(lambda: status_cache_read({"state_dir": state}))
        check(name, error is not None and error.startswith("Malformed"), "%r %r" % (value, error))
    for name, pid in [
        ("f8c-kick-pid-zero-no-signal", 0),
        ("f8c-kick-pid-one-no-signal", 1),
        ("f8c-kick-pid-negative-no-signal", -1),
        ("f8c-kick-pid-text-no-signal", "4242"),
        ("f8c-kick-pid-float-no-signal", 4242.0),
        ("f8c-kick-pid-bool-no-signal", True),
        ("f8c-kick-pid-none-no-signal", None),
    ]:
        result, calls = _f8c_kick(pid)
        check(name, result.get("ok") is False and calls == [], "ok=%r calls=%r" % (result.get("ok"), calls))
    result, calls = _f8c_kick(4242)
    check(
        "f8c-kick-strict-pid-reaches-ps-only",
        result.get("ok") is False and ["ps", 4242] in calls and not any(c[:1] == ["kill"] for c in calls),
        "ok=%r calls=%r" % (result.get("ok"), calls),
    )
    for name, pid in [("f8c-alive-zero-refused", 0), ("f8c-alive-one-refused", 1), ("f8c-alive-negative-refused", -1)]:
        check(name, Runtime().alive(pid) is False, "alive(%r) not refused" % (pid,))


def self_check():
    """Run the suite with a private HOME that holds a fixed ssh config.

    The probes read ~/.ssh/config (the ssh peer decides whether an ssh run is
    recorded), so the suite pins HOME to a temp dir with one fixed omarchylink host.
    The real HOME, the real PATH and the real ps/launchctl/tailscale are never
    read by the cases; HOME is restored and the temp dir removed on exit.
    """
    home_dir = tempfile.mkdtemp(prefix="hudfix-selfcheck-home-", dir=os.environ.get("TMPDIR"))
    ssh_dir = os.path.join(home_dir, ".ssh")
    os.makedirs(ssh_dir, exist_ok=True)
    with open(os.path.join(ssh_dir, "config"), "w", encoding="utf-8") as handle:
        handle.write("Host omarchylink\n    HostName omarchylink.example.invalid\n")
    saved_home = os.environ.get("HOME")
    os.environ["HOME"] = home_dir
    try:
        return _self_check_run()
    finally:
        if saved_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = saved_home
        shutil.rmtree(home_dir, ignore_errors=True)


def _self_check_run():
    global SELF_CHECK_ASSUME_MAC, SELF_CHECK_UID, SELF_CHECK_TAILSCALE_CLI, _CLI_BOOT
    SELF_CHECK_ASSUME_MAC = True
    SELF_CHECK_UID = SELF_CHECK_FAKE_UID
    SELF_CHECK_TAILSCALE_CLI = SELF_CHECK_FAKE_TAILSCALE
    print("hudfix_maclink self-check (python %s on %s)" % (sys.version.split()[0], sys.platform))
    passed = []
    failed = []

    def check(name, condition, detail=""):
        if condition:
            passed.append(name)
            print("PASS %s" % name)
        else:
            failed.append(name)
            print("FAIL %s %s" % (name, detail))

    root = tempfile.mkdtemp(prefix="hudfix-maclink-selfcheck-", dir=os.environ.get("TMPDIR"))
    stub_dir = os.path.join(root, "bin")
    fix_dir = os.path.join(root, "fixtures")
    temp_home = os.path.join(root, "home")
    temp_tmp = os.path.join(root, "tmp")
    work_dir = os.path.join(root, "work")
    for path in (stub_dir, fix_dir, temp_home, temp_tmp, work_dir):
        os.makedirs(path, exist_ok=True)
    log_file = os.path.join(root, "stub-commands.log")
    _CLI_BOOT = os.path.join(root, "boot.py")
    with open(_CLI_BOOT, "w", encoding="utf-8") as handle:
        handle.write(_CLI_BOOT_SOURCE)

    relay_text = (
        "gui/501/com.nexuslink.bridge-relay = {\n"
        "\tactive count = 1\n"
        "\tpath = /Users/marcel/Library/LaunchAgents/com.nexuslink.bridge-relay.plist\n"
        "\ttype = LaunchAgent\n"
        "\tstate = running\n"
        "\n"
        "\tprogram = /usr/bin/python3\n"
        "\targuments = {\n"
        "\t\t/usr/bin/python3\n"
        "\t\t/Users/marcel/NEXUS_AI_CENTER/04_PROJECTS/BRIDGE/mac/bridge-relay.py\n"
        "\t}\n"
        "\n"
        "\tpid = 70854\n"
        "\tlast exit code = (never exited)\n"
        "}\n"
    )
    launchctl_fixture = {"gui/501/com.nexuslink.bridge-relay": relay_text}
    with open(os.path.join(fix_dir, "launchctl.json"), "w", encoding="utf-8") as handle:
        json.dump(launchctl_fixture, handle)
    with open(os.path.join(fix_dir, "tailscale.json"), "w", encoding="utf-8") as handle:
        json.dump(
            {
                "Version": "1.102.2",
                "BackendState": "Running",
                "TailscaleIPs": ["100.104.123.2"],
                "Self": {"DNSName": "mac.example.ts.net."},
            },
            handle,
        )
    stale_pid = 4242
    worker_cmd = (
        "/Users/marcel/.hermes/tools/python3/bin/python3 -m hermes_cli.main -p kakashi "
        "--cli chat -q work kanban task t_selfcheck_stale"
    )
    null_assignee_pid = 4344
    null_assignee_cmd = (
        "/Users/marcel/.hermes/tools/python3/bin/python3 -m hermes_cli.main "
        "--cli chat -q work kanban task t_selfcheck_corrupt"
    )
    with open(os.path.join(fix_dir, "ps.json"), "w", encoding="utf-8") as handle:
        json.dump(
            {str(stale_pid): worker_cmd, str(null_assignee_pid): null_assignee_cmd},
            handle,
        )
    with open(os.path.join(fix_dir, "ps_table.txt"), "w", encoding="utf-8") as handle:
        handle.write("1 0 /sbin/launchd\n")
        handle.write("%d 1 %s\n" % (stale_pid, worker_cmd))
        handle.write("88494 1 python3 -m hermes_cli.main --profile atlas gateway run\n")

    _write_stub(
        stub_dir,
        "launchctl",
        (
            "unit = ARGS[1] if len(ARGS) > 1 else ''\n"
            "table = json.load(open(os.path.join(FIX, 'launchctl.json'), encoding='utf-8'))\n"
            "if ARGS[:1] == ['print'] and unit in table:\n"
            "    sys.stdout.write(table[unit])\n"
            "    sys.exit(0)\n"
            "sys.stderr.write('Could not find service \"%s\" in domain for user gui: 501\\n' % unit)\n"
            "sys.exit(113)\n"
        ),
    )
    _write_stub(
        stub_dir,
        "tailscale",
        (
            "if ARGS[:1] == ['status']:\n"
            "    sys.stdout.write(open(os.path.join(FIX, 'tailscale.json'), encoding='utf-8').read())\n"
            "    sys.exit(0)\n"
            "sys.exit(0)\n"
        ),
    )
    _write_stub(
        stub_dir,
        "ps",
        (
            "if os.environ.get('MACLINK_SC_PS_LOSSY') == '1':\n"
            "    sys.stdout.buffer.write(b'4242 1 worker \\xff\\n')\n"
            "    sys.exit(0)\n"
            "if any(part.startswith('-Ao') for part in ARGS):\n"
            "    sys.stdout.write(open(os.path.join(FIX, 'ps_table.txt'), encoding='utf-8').read())\n"
            "    sys.exit(0)\n"
            "if '-p' in ARGS:\n"
            "    pid = ARGS[ARGS.index('-p') + 1]\n"
            "    table = json.load(open(os.path.join(FIX, 'ps.json'), encoding='utf-8'))\n"
            "    if pid in table:\n"
            "        sys.stdout.write(table[pid] + '\\n')\n"
            "        sys.exit(0)\n"
            "    sys.exit(1)\n"
            "sys.exit(1)\n"
        ),
    )
    _write_stub(
        stub_dir,
        "sysctl",
        "sys.stdout.write('{ sec = 1791570618, usec = 738093 } Fri Oct  9 20:30:18 2026\\n')\nsys.exit(0)\n",
    )
    _write_stub(
        stub_dir,
        "ssh",
        "sys.stderr.write('ssh: Could not resolve hostname\\n')\nsys.exit(255)\n",
    )
    for name in ("screencapture", "caffeinate", "kill", "pkill"):
        _write_stub(stub_dir, name, "sys.exit(1)\n")

    env = dict(os.environ)
    env["PATH"] = stub_dir
    env["HOME"] = temp_home
    env["TMPDIR"] = temp_tmp
    env["MACLINK_SC_LOG"] = log_file
    env["MACLINK_SC_FIX"] = fix_dir

    db_path = os.path.join(root, "kanban.db")
    connection = sqlite3.connect(db_path)
    connection.execute(
        "CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT, assignee TEXT, status TEXT, "
        "worker_pid INTEGER, last_heartbeat_at INTEGER, current_run_id INTEGER, started_at INTEGER)"
    )
    connection.execute(
        "INSERT INTO tasks VALUES (?,?,?,?,?,?,?,?)",
        (
            "t_selfcheck_stale",
            "self-check stale worker",
            "kakashi",
            "running",
            stale_pid,
            int(time.time()) - 900,
            1,
            int(time.time()) - 1200,
        ),
    )
    connection.execute(
        "INSERT INTO tasks VALUES (?,?,?,?,?,?,?,?)",
        (
            "t_selfcheck_fresh",
            "self-check fresh worker",
            "yamato",
            "running",
            4343,
            int(time.time()) - 5,
            2,
            int(time.time()) - 60,
        ),
    )
    connection.commit()
    connection.close()

    # --- list -------------------------------------------------------------
    code, stdout, stderr = _cli(["list", "--json"], env)
    check("list-exit-0", code == 0, "exit=%s %s" % (code, one_line(stderr)))
    try:
        listed = json.loads(stdout)
    except ValueError:
        listed = None
    check("list-one-object", isinstance(listed, dict), stdout[:120])
    names = [item["name"] for item in (listed or {}).get("actions", [])]
    check("list-every-action-in-order", names == list(ORDER), str(names))
    classes = {item["name"]: item["class"] for item in (listed or {}).get("actions", [])}
    check(
        "list-classes",
        classes == CLASS_TABLE,
        str(classes),
    )
    check(
        "list-docs",
        all(item.get("doc") for item in (listed or {}).get("actions", [])),
        "an action has no doc",
    )
    check(
        "list-linux-only",
        all(item.get("linux_only") is False for item in (listed or {}).get("actions", [])),
        "a mac action claims linux_only",
    )

    # --- plan, every action, hermetic -------------------------------------
    baseline_home = _sha_tree(temp_home, ignore=(os.path.join(temp_home, ".local"),))
    baseline_tmp = _sha_tree(temp_tmp)
    plans = {}
    for name in ORDER:
        code, stdout, stderr = _cli(
            ["plan", name, "--db", db_path, "--state-dir", os.path.join(temp_home, ".local", "state", "nexuslink")],
            env,
        )
        check("plan-exit-0:%s" % name, code == 0, "exit=%s %s" % (code, one_line(stderr)))
        try:
            payload = json.loads(stdout)
        except ValueError:
            payload = None
        plans[name] = payload
        check("plan-object:%s" % name, isinstance(payload, dict), str(stdout[:120]))
        if not isinstance(payload, dict):
            continue
        check("plan-dry-run:%s" % name, payload.get("dry_run") is True, str(payload.get("dry_run")))
        check(
            "plan-class:%s" % name,
            payload.get("class") == CLASS_TABLE[name],
            str(payload.get("class")),
        )
        check(
            "plan-cannot-verify:%s" % name,
            isinstance(payload.get("cannot_verify"), list) and payload["cannot_verify"],
            str(payload.get("cannot_verify")),
        )
        check(
            "plan-total:%s" % name,
            isinstance(payload.get("total"), dict) and "items" in payload["total"],
            str(payload.get("total")),
        )
        if payload.get("ok"):
            check(
                "plan-would:%s" % name,
                isinstance(payload.get("would"), str) and len(payload["would"]) > 20,
                str(payload.get("would")),
            )
            check(
                "plan-items:%s" % name,
                isinstance(payload.get("items"), list) and len(payload["items"]) >= 1,
                str(payload.get("items")),
            )
        else:
            check(
                "plan-reason:%s" % name,
                bool(payload.get("reason")),
                "ok:false with no reason",
            )

    relay_plan = plans.get("maclink.restart-relay") or {}
    check(
        "plan-relay-unit",
        (relay_plan.get("items") or [{}])[0].get("unit") == "gui/501/com.nexuslink.bridge-relay",
        str(relay_plan.get("items")),
    )
    check(
        "plan-relay-command",
        ((relay_plan.get("items")) or [{}])[0].get("command")
        == "launchctl kickstart -k gui/501/com.nexuslink.bridge-relay",
        str(((relay_plan.get("items")) or [{}])[0].get("command")),
    )
    check(
        "plan-relay-blast-radius",
        isinstance(relay_plan.get("blast_radius"), str) and "events" in relay_plan["blast_radius"],
        str(relay_plan.get("blast_radius")),
    )
    check(
        "plan-relay-blast-detail",
        isinstance(relay_plan.get("blast_radius_detail"), dict)
        and relay_plan["blast_radius_detail"].get("undo"),
        str(relay_plan.get("blast_radius_detail")),
    )
    tunnel_plan = plans.get("maclink.restart-tunnel") or {}
    check(
        "plan-tunnel-mechanism",
        tunnel_plan.get("ok") is True and tunnel_plan.get("mechanism") in ("launchd", "tailscale-cli"),
        str(tunnel_plan.get("mechanism")),
    )
    check(
        "plan-tunnel-commands",
        (tunnel_plan.get("commands") or [""])[0].endswith("tailscale down")
        and (tunnel_plan.get("commands") or ["", ""])[-1].endswith("tailscale up"),
        str(tunnel_plan.get("commands")),
    )
    missing = RecordingRuntime(outputs={"launchctl": ("", "Could not find service", 113)})
    missing_relay = plan_restart_relay(None, missing)
    check(
        "plan-relay-refuses-missing-unit",
        missing_relay.get("ok") is False
        and "launchd does not know" in (missing_relay.get("reason") or ""),
        str(missing_relay.get("reason")),
    )
    original_cli = globals()["tailscale_cli"]
    try:
        globals()["tailscale_cli"] = lambda: None
        missing_tunnel = plan_restart_tunnel(None, missing)
    finally:
        globals()["tailscale_cli"] = original_cli
    check(
        "plan-tunnel-refuses-without-unit-or-cli",
        missing_tunnel.get("ok") is False
        and "no tailscaled launchd unit" in (missing_tunnel.get("reason") or ""),
        str(missing_tunnel.get("reason")),
    )
    kick_plan = plans.get("maclink.kick-bot") or {}
    kick_item = (kick_plan.get("items") or [{}])[0]
    check(
        "plan-kick-fields",
        kick_item.get("profile") == "kakashi"
        and kick_item.get("pid") == stale_pid
        and kick_item.get("card") == "t_selfcheck_stale"
        and isinstance(kick_item.get("heartbeat_age_s"), int)
        and kick_item["heartbeat_age_s"] >= 600,
        str(kick_item),
    )
    check(
        "plan-kick-command",
        kick_item.get("command") == "kill -TERM %d" % stale_pid,
        str(kick_item.get("command")),
    )
    check(
        "plan-kick-digest",
        kick_item.get("command_sha256") == command_digest(worker_cmd),
        str(kick_item.get("command_sha256")),
    )
    check(
        "plan-kick-db-mode",
        (kick_plan.get("db_readonly") in ("ro", "immutable")),
        str(kick_plan.get("db_readonly")),
    )
    wake_plan = plans.get("maclink.wake") or {}
    screenshot_plan = plans.get("maclink.screenshot") or {}
    shot_path = (screenshot_plan.get("items") or [{}])[0].get("path")
    check(
        "plan-screenshot-path",
        isinstance(shot_path, str) and os.path.abspath(shot_path).startswith(os.path.abspath(temp_tmp)),
        str(shot_path),
    )
    check(
        "plan-wake-pid-file",
        (wake_plan.get("items") or [{}])[0].get("pid_file", "").endswith("caffeinate.pid"),
        str(wake_plan.get("items")),
    )
    check(
        "plan-wake-off-unavailable",
        (plans.get("maclink.wake-off") or {}).get("ok") is False
        and "no recorded caffeinate" in ((plans.get("maclink.wake-off") or {}).get("reason") or ""),
        str(plans.get("maclink.wake-off")),
    )

    # --- plan purity -------------------------------------------------------
    after_home = _sha_tree(temp_home, ignore=(os.path.join(temp_home, ".local"),))
    after_tmp = _sha_tree(temp_tmp)
    check("plan-no-home-writes", baseline_home == after_home, "temp home changed")
    check("plan-no-tmp-writes", baseline_tmp == after_tmp, "temp dir changed")
    check(
        "plan-no-screenshot-file",
        not shot_path or not os.path.exists(shot_path),
        str(shot_path),
    )
    stub_lines = []
    if os.path.exists(log_file):
        with open(log_file, encoding="utf-8") as handle:
            stub_lines = [line.strip() for line in handle if line.strip()]
    forbidden = [line for line in stub_lines if _state_changing(line.split())]
    check("plan-no-state-changing-command", forbidden == [], str(forbidden)[:300])
    allowed_prefixes = ("launchctl print", "tailscale status", "ps ", "sysctl ")
    check(
        "plan-only-read-commands",
        all(line.startswith(allowed_prefixes) for line in stub_lines),
        str([line for line in stub_lines if not line.startswith(allowed_prefixes)])[:300],
    )

    # --- log --------------------------------------------------------------
    log_path = os.path.join(temp_home, ".local", "state", "nexuslink", "hudfix.log")
    check("log-exists", os.path.isfile(log_path), log_path)
    log_rows = []
    if os.path.isfile(log_path):
        with open(log_path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line:
                    try:
                        log_rows.append(json.loads(line))
                    except ValueError:
                        log_rows.append({"bad": line})
    plan_rows = [row for row in log_rows if row.get("phase") == "plan"]
    check("log-one-line-per-plan", len(plan_rows) == len(ORDER), "%d rows" % len(plan_rows))
    check(
        "log-jsonl-fields",
        all(row.get("action") and row.get("class") and row.get("ts") for row in plan_rows),
        str(log_rows[:1]),
    )

    # --- caller errors: a named file that does not exist is exit 2 --------
    named_missing_db = os.path.join(root, "kanban-missing.db")
    code, stdout, stderr = _cli(
        ["plan", "maclink.kick-bot", "--db", named_missing_db, "--state-dir",
         os.path.join(temp_home, ".local", "state", "nexuslink")],
        env,
    )
    check("named-missing-db-exit-2", code == 2, "exit=%s %s" % (code, one_line(stderr)))
    check("named-missing-db-no-stdout", stdout.strip() == "", repr(stdout[:120]))
    check(
        "named-missing-db-one-stderr-line",
        len(stderr.strip().splitlines()) == 1 and "does not exist" in stderr,
        repr(stderr[:200]),
    )
    empty_db = os.path.join(root, "kanban-empty.db")
    with open(empty_db, "w", encoding="utf-8"):
        pass
    code, stdout, stderr = _cli(
        ["plan", "maclink.kick-bot", "--db", empty_db, "--state-dir",
         os.path.join(temp_home, ".local", "state", "nexuslink")],
        env,
    )
    empty_payload = json.loads(stdout) if stdout.strip().startswith("{") else {}
    check(
        "existing-empty-db-exit-0",
        code == 0 and empty_payload.get("ok") is False and bool(empty_payload.get("reason")),
        "exit=%s %s" % (code, one_line(stderr)),
    )
    garbage_db = os.path.join(root, "kanban-garbage.db")
    with open(garbage_db, "w", encoding="utf-8") as handle:
        handle.write("this is not a sqlite database\n")
    code, stdout, stderr = _cli(
        ["plan", "maclink.kick-bot", "--db", garbage_db, "--state-dir",
         os.path.join(temp_home, ".local", "state", "nexuslink")],
        env,
    )
    garbage_payload = json.loads(stdout) if stdout.strip().startswith("{") else {}
    check(
        "existing-garbage-db-exit-0",
        code == 0 and garbage_payload.get("ok") is False and bool(garbage_payload.get("reason")),
        "exit=%s %s" % (code, one_line(stderr)),
    )

    # --- corrupt board rows: no traceback, no candidate, no signal --------
    def corrupt_board(worker_pid, assignee, filename, card_id):
        path = os.path.join(root, filename)
        connection = sqlite3.connect(path)
        connection.execute(
            "CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT, assignee TEXT, status TEXT, "
            "worker_pid INTEGER, last_heartbeat_at INTEGER, current_run_id INTEGER, started_at INTEGER)"
        )
        connection.execute(
            "INSERT INTO tasks VALUES (?,?,?,?,?,?,?,?)",
            (
                card_id,
                "corrupt board row",
                assignee,
                "running",
                worker_pid,
                int(time.time()) - 900,
                9,
                int(time.time()) - 1200,
            ),
        )
        connection.commit()
        connection.close()
        return path

    def stub_log():
        if not os.path.exists(log_file):
            return []
        with open(log_file, encoding="utf-8") as handle:
            return [line.strip() for line in handle if line.strip()]

    corrupt_state_dir = os.path.join(temp_home, ".local", "state", "nexuslink")
    corrupt_pid_db = corrupt_board("not-a-pid", "kakashi", "kanban-corrupt-pid.db",
                                   "t_selfcheck_corrupt")
    code, stdout, stderr = _cli(
        ["plan", "maclink.kick-bot", "--db", corrupt_pid_db, "--state-dir", corrupt_state_dir],
        env,
    )
    try:
        corrupt_pid_plan = json.loads(stdout)
    except ValueError:
        corrupt_pid_plan = {}
    corrupt_pid_rejected = corrupt_pid_plan.get("rejected") or []
    check(
        "corrupt-worker-pid-plan-refused",
        code == 0
        and corrupt_pid_plan.get("ok") is False
        and bool(corrupt_pid_plan.get("reason"))
        and corrupt_pid_plan.get("items") == []
        and len(corrupt_pid_rejected) == 1
        and "is not a number" in (corrupt_pid_rejected[0].get("reason") or "")
        and stderr.strip() == "",
        "exit=%s out=%s err=%s" % (code, one_line(stdout, 200), one_line(stderr, 200)),
    )
    corrupt_pid_before = len(stub_log())
    code, stdout, stderr = _cli(
        ["run", "maclink.kick-bot", "--confirm", "maclink.kick-bot",
         "--db", corrupt_pid_db, "--state-dir", corrupt_state_dir],
        env,
    )
    corrupt_pid_run_stderr = stderr.strip().splitlines()
    corrupt_pid_calls = stub_log()[corrupt_pid_before:]
    check(
        "corrupt-worker-pid-run-refused",
        code == 2
        and stdout.strip() == ""
        and len(corrupt_pid_run_stderr) == 1
        and "no stale worker" in corrupt_pid_run_stderr[0]
        and not any(line.startswith(("kill", "pkill", "kickstart")) for line in corrupt_pid_calls),
        "exit=%s out=%s err=%s calls=%s"
        % (code, one_line(stdout, 200), one_line(stderr, 200), str(corrupt_pid_calls)[:200]),
    )

    null_assignee_db = corrupt_board(null_assignee_pid, None, "kanban-null-assignee.db",
                                     "t_selfcheck_corrupt")
    code, stdout, stderr = _cli(
        ["plan", "maclink.kick-bot", "--db", null_assignee_db, "--state-dir", corrupt_state_dir],
        env,
    )
    try:
        null_assignee_plan = json.loads(stdout)
    except ValueError:
        null_assignee_plan = {}
    null_assignee_rejected = null_assignee_plan.get("rejected") or []
    check(
        "null-assignee-plan-refused",
        code == 0
        and null_assignee_plan.get("ok") is False
        and null_assignee_plan.get("items") == []
        and (null_assignee_plan.get("total") or {}).get("items") == 0
        and len(null_assignee_rejected) == 1
        and null_assignee_rejected[0].get("profile") is None
        and "no assignee" in (null_assignee_rejected[0].get("reason") or "")
        and stderr.strip() == "",
        "exit=%s out=%s err=%s" % (code, one_line(stdout, 200), one_line(stderr, 200)),
    )
    null_assignee_before = len(stub_log())
    code, stdout, stderr = _cli(
        ["run", "maclink.kick-bot", "--confirm", "maclink.kick-bot",
         "--db", null_assignee_db, "--state-dir", corrupt_state_dir],
        env,
    )
    null_assignee_run_stderr = stderr.strip().splitlines()
    null_assignee_calls = stub_log()[null_assignee_before:]
    check(
        "null-assignee-run-refused",
        code == 2
        and stdout.strip() == ""
        and len(null_assignee_run_stderr) == 1
        and "no stale worker" in null_assignee_run_stderr[0]
        and not any(line.startswith(("kill", "pkill", "kickstart")) for line in null_assignee_calls),
        "exit=%s out=%s err=%s calls=%s"
        % (code, one_line(stdout, 200), one_line(stderr, 200), str(null_assignee_calls)[:200]),
    )

    def blob_board(label, card_id, assignee, worker_pid, filename):
        path = corrupt_board(worker_pid, assignee, filename, card_id)
        code, stdout, stderr = _cli(
            ["plan", "maclink.kick-bot", "--db", path, "--state-dir", corrupt_state_dir], env
        )
        try:
            payload = json.loads(stdout)
        except ValueError:
            payload = {}
        rejected = payload.get("rejected") or []
        shown = json.dumps(rejected, ensure_ascii=False)
        check(
            label,
            code == 0
            and payload.get("ok") is False
            and payload.get("kind") == "malformed"
            and payload.get("items") == []
            and len(rejected) == 1
            and rejected[0].get("kind") == "malformed"
            and "<malformed blob" in shown
            and "b'" not in stdout
            and "\\u0000" not in stdout
            and stderr.strip() == "",
            "exit=%s out=%s err=%s" % (code, one_line(stdout, 240), one_line(stderr, 200)),
        )
        return path

    # SQLite is dynamically typed: a BLOB can sit in a TEXT or INTEGER cell.
    blob_pid_db = blob_board(
        "blob-worker-pid-plan-malformed",
        "t_selfcheck_blob_pid",
        "kakashi",
        b"\x00\x01\x02\x03",
        "kanban-blob-pid.db",
    )
    blob_board(
        "blob-assignee-plan-malformed",
        "t_selfcheck_blob_assignee",
        b"\xfe\xff\x00",
        null_assignee_pid,
        "kanban-blob-assignee.db",
    )
    blob_board(
        "blob-id-plan-malformed",
        b"\x00\xff\x01",
        "kakashi",
        null_assignee_pid,
        "kanban-blob-id.db",
    )
    blob_board(
        "memoryview-worker-pid-plan-malformed",
        "t_selfcheck_memoryview_pid",
        "kakashi",
        memoryview(b"\x00\x02\x03"),
        "kanban-memoryview-pid.db",
    )
    corrupt_pid_before = len(stub_log())
    code, stdout, stderr = _cli(
        ["run", "maclink.kick-bot", "--confirm", "maclink.kick-bot",
         "--db", blob_pid_db, "--state-dir", corrupt_state_dir],
        env,
    )
    blob_run_stderr = stderr.strip().splitlines()
    blob_calls = stub_log()[corrupt_pid_before:]
    check(
        "blob-worker-pid-run-refused",
        code == 2
        and stdout.strip() == ""
        and len(blob_run_stderr) == 1
        and "no stale worker" in blob_run_stderr[0]
        and not any(line.startswith(("kill", "pkill", "kickstart")) for line in blob_calls),
        "exit=%s out=%s err=%s calls=%s"
        % (code, one_line(stdout, 200), one_line(stderr, 200), str(blob_calls)[:200]),
    )

    # --- status cache: 10 s, atomic, and never probes on a hit -------------
    cache_dir = os.path.join(temp_home, ".local", "state", "nexuslink")
    cache_file = os.path.join(cache_dir, "maclink-status.json")
    cache_now = time.time()
    cache_outputs = {
        "launchctl": (relay_text, "", 0),
        "sysctl": ("{ sec = %d, usec = 0 }" % (int(cache_now) - 5000), "", 0),
    }
    utc_stamp_re = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

    def read_cache():
        with open(cache_file, encoding="utf-8") as handle:
            return json.load(handle)

    def write_cache(record):
        with open(cache_file, "w", encoding="utf-8") as handle:
            json.dump(record, handle)

    cache_cli_original = globals()["tailscale_cli"]
    try:
        globals()["tailscale_cli"] = lambda: None
        first_runtime = RecordingRuntime(outputs=cache_outputs, now=cache_now)
        cache_first = run_status({"state_dir": cache_dir}, None, first_runtime)
        check(
            "cache-first-not-cached",
            cache_first.get("cached") is False and cache_first.get("cached_at") is None,
            str(cache_first.get("cached")),
        )
        check("cache-first-probes", len(first_runtime.runs) == 4, str(first_runtime.runs))
        check("cache-file-written", os.path.isfile(cache_file), cache_file)
        second_runtime = RecordingRuntime(outputs=cache_outputs, now=cache_now)
        cache_second = run_status({"state_dir": cache_dir}, None, second_runtime)
        check(
            "cache-second-hit",
            cache_second.get("cached") is True
            and bool(utc_stamp_re.match(cache_second.get("cached_at") or "")),
            str(cache_second.get("cached_at")),
        )
        check(
            "cache-second-no-probe",
            second_runtime.runs == [] and second_runtime.ps_calls == [],
            str(second_runtime.runs),
        )
        check(
            "cache-second-keeps-generated-at",
            cache_second.get("generated_at") == cache_first.get("generated_at"),
            "%s vs %s" % (cache_second.get("generated_at"), cache_first.get("generated_at")),
        )
        check(
            "cache-second-age-under-limit",
            isinstance(cache_second.get("cache_age_s"), float)
            and 0 <= cache_second["cache_age_s"] < STATUS_CACHE_TTL_S,
            str(cache_second.get("cache_age_s")),
        )
        record = read_cache()
        record["cached_epoch"] = time.time() - 9.5
        write_cache(record)
        near_runtime = RecordingRuntime(outputs=cache_outputs, now=cache_now)
        cache_near = run_status({"state_dir": cache_dir}, None, near_runtime)
        check(
            "cache-9.5s-still-served",
            cache_near.get("cached") is True and near_runtime.runs == [],
            "cached=%s runs=%s" % (cache_near.get("cached"), near_runtime.runs),
        )
        record = read_cache()
        record["cached_epoch"] = time.time() - 10.5
        write_cache(record)
        late_runtime = RecordingRuntime(outputs=cache_outputs, now=cache_now)
        cache_late = run_status({"state_dir": cache_dir}, None, late_runtime)
        check(
            "cache-10.5s-expired",
            cache_late.get("cached") is False and len(late_runtime.runs) == 4,
            "cached=%s runs=%s" % (cache_late.get("cached"), len(late_runtime.runs)),
        )
        real_runtime = RecordingRuntime(outputs=cache_outputs, now=cache_now)
        run_status({"state_dir": cache_dir}, None, real_runtime)
        time.sleep(3.0)
        real_hit_runtime = RecordingRuntime(outputs=cache_outputs, now=cache_now)
        cache_real_hit = run_status({"state_dir": cache_dir}, None, real_hit_runtime)
        check(
            "cache-real-3s-hit",
            cache_real_hit.get("cached") is True and real_hit_runtime.runs == [],
            "cached=%s runs=%s" % (cache_real_hit.get("cached"), real_hit_runtime.runs),
        )
        time.sleep(7.3)
        real_late_runtime = RecordingRuntime(outputs=cache_outputs, now=cache_now)
        cache_real_late = run_status({"state_dir": cache_dir}, None, real_late_runtime)
        check(
            "cache-real-10.3s-miss",
            cache_real_late.get("cached") is False and len(real_late_runtime.runs) == 4,
            "cached=%s runs=%s" % (cache_real_late.get("cached"), len(real_late_runtime.runs)),
        )
    finally:
        globals()["tailscale_cli"] = cache_cli_original
    check(
        "cache-no-temp-file-left",
        [name for name in os.listdir(cache_dir) if name.startswith(".maclink-status-")] == [],
        str(os.listdir(cache_dir)),
    )
    check(
        "cache-file-atomic-shape",
        isinstance(read_cache().get("payload"), dict)
        and read_cache()["payload"].get("action") == "maclink.status",
        "cache record does not carry the status payload",
    )

    # --- --json is one compact line, for every subcommand -------------------
    json_state = os.path.join(temp_home, ".local", "state", "nexuslink-json")
    for name in ("maclink.kick-bot", "maclink.status", "maclink.wake-off"):
        code, stdout, stderr = _cli(
            ["plan", name, "--json", "--db", db_path, "--state-dir", json_state],
            env,
        )
        json_lines = stdout.strip().splitlines()
        try:
            json_payload = json.loads(stdout)
        except ValueError:
            json_payload = None
        check(
            "plan-json-one-line:%s" % name,
            code == 0 and len(json_lines) == 1,
            "exit=%s lines=%s %s" % (code, len(json_lines), one_line(stderr)),
        )
        check(
            "plan-json-object:%s" % name,
            isinstance(json_payload, dict) and json_payload.get("action") == name,
            stdout[:120],
        )
    code, stdout, stderr = _cli(
        ["run", "maclink.status", "--json", "--state-dir", os.path.join(json_state, "status")],
        env,
    )
    status_lines = stdout.strip().splitlines()
    check(
        "run-status-json-one-line",
        code == 0 and len(status_lines) == 1,
        "exit=%s lines=%s %s" % (code, len(status_lines), one_line(stderr)),
    )

    # --- hostile ps: a lossy capture is malformed, never a traceback --------
    lossy_env = dict(env)
    lossy_env["MACLINK_SC_PS_LOSSY"] = "1"
    lossy_state = os.path.join(temp_home, ".local", "state", "nexuslink-lossy")
    log_before = len(stub_log())
    code, stdout, stderr = _cli(
        ["plan", "maclink.kick-bot", "--json", "--db", db_path, "--state-dir", lossy_state],
        lossy_env,
    )
    lossy_lines = stdout.strip().splitlines()
    try:
        lossy_plan = json.loads(stdout)
    except ValueError:
        lossy_plan = None
    check(
        "lossy-ps-plan-exit-0",
        code == 0 and len(lossy_lines) == 1 and "Traceback" not in stderr,
        "exit=%s lines=%s %s" % (code, len(lossy_lines), one_line(stderr)),
    )
    check(
        "lossy-ps-plan-malformed",
        isinstance(lossy_plan, dict)
        and lossy_plan.get("ok") is False
        and lossy_plan.get("kind") == "malformed"
        and "not valid UTF-8" in (lossy_plan.get("reason") or ""),
        one_line(stdout, 240),
    )
    # Even with no card to examine: the ps chain is part of the safety proof, so
    # an unreadable table is refused instead of quietly falling back.
    empty_db = os.path.join(root, "kanban-empty.db")
    empty_conn = sqlite3.connect(empty_db)
    empty_conn.execute(
        "CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT, assignee TEXT, status TEXT, "
        "worker_pid INTEGER, last_heartbeat_at INTEGER, current_run_id INTEGER, started_at INTEGER)"
    )
    empty_conn.commit()
    empty_conn.close()
    code, stdout, stderr = _cli(
        ["plan", "maclink.kick-bot", "--json", "--db", empty_db, "--state-dir", lossy_state],
        lossy_env,
    )
    try:
        lossy_empty = json.loads(stdout)
    except ValueError:
        lossy_empty = None
    check(
        "lossy-ps-malformed-with-empty-board",
        code == 0
        and len(stdout.strip().splitlines()) == 1
        and isinstance(lossy_empty, dict)
        and lossy_empty.get("kind") == "malformed"
        and "Traceback" not in stderr,
        "exit=%s out=%s err=%s" % (code, one_line(stdout, 200), one_line(stderr, 160)),
    )
    code, stdout, stderr = _cli(
        ["run", "maclink.kick-bot", "--confirm", "maclink.kick-bot", "--json",
         "--db", db_path, "--state-dir", lossy_state],
        lossy_env,
    )
    try:
        lossy_run = json.loads(stdout)
    except ValueError:
        lossy_run = None
    lossy_calls = stub_log()[log_before:]
    check(
        "lossy-ps-run-malformed-no-signal",
        code == 0
        and isinstance(lossy_run, dict)
        and lossy_run.get("ok") is False
        and lossy_run.get("kind") == "malformed"
        and "Traceback" not in stderr
        and not any(line.startswith(("kill", "pkill", "killall")) for line in lossy_calls),
        "exit=%s out=%s err=%s calls=%s"
        % (code, one_line(stdout, 200), one_line(stderr, 200), str(lossy_calls)[:160]),
    )

    # --- hostile pid file: text, bytes, empty, 1200-deep JSON ---------------
    pid_state = os.path.join(temp_home, ".local", "state", "nexuslink-pid")
    os.makedirs(pid_state, exist_ok=True)
    pid_file = os.path.join(pid_state, "caffeinate.pid")
    pid_cases = (
        ("text", b"not-a-pid\n"),
        ("blob", b"\\x00\\x01\\xff\\xfe"),
        ("empty", b""),
        ("deep", b"[" * 1200 + b"]" * 1200),
        ("object", b'{"pid": null}'),
    )
    for label, payload_bytes in pid_cases:
        with open(pid_file, "wb") as handle:
            handle.write(payload_bytes)
        for action in ("maclink.wake-off", "maclink.wake"):
            code, stdout, stderr = _cli(
                ["plan", action, "--json", "--state-dir", pid_state],
                env,
            )
            try:
                pid_plan = json.loads(stdout)
            except ValueError:
                pid_plan = None
            check(
                "pid-%s-%s-malformed" % (label, action.split(".", 1)[1]),
                code == 0
                and len(stdout.strip().splitlines()) == 1
                and isinstance(pid_plan, dict)
                and pid_plan.get("ok") is False
                and pid_plan.get("kind") == "malformed"
                and "Traceback" not in stderr,
                "exit=%s out=%s err=%s" % (code, one_line(stdout, 200), one_line(stderr, 160)),
            )
    os.unlink(pid_file)

    # --- status cache: corrupt bytes, a directory, 1200-deep JSON ----------
    cache_state = os.path.join(temp_home, ".local", "state", "nexuslink-cache")
    os.makedirs(cache_state, exist_ok=True)
    cache_path = os.path.join(cache_state, "maclink-status.json")
    cache_cases = (
        ("corrupt", b"{not json at all"),
        ("empty", b""),
        ("blob", b"\\xff\\xfe\\x00"),
        ("deep", b"[" * 1200 + b"]" * 1200),
    )
    for label, payload_bytes in cache_cases:
        with open(cache_path, "wb") as handle:
            handle.write(payload_bytes)
        code, stdout, stderr = _cli(
            ["run", "maclink.status", "--json", "--state-dir", cache_state],
            env,
        )
        try:
            cache_payload = json.loads(stdout)
        except ValueError:
            cache_payload = None
        check(
            "status-cache-%s-malformed" % label,
            code == 0
            and len(stdout.strip().splitlines()) == 1
            and isinstance(cache_payload, dict)
            and cache_payload.get("ok") is False
            and cache_payload.get("kind") == "malformed"
            and "Traceback" not in stderr,
            "exit=%s out=%s err=%s" % (code, one_line(stdout, 200), one_line(stderr, 160)),
        )
    os.unlink(cache_path)
    os.makedirs(cache_path, exist_ok=True)
    code, stdout, stderr = _cli(
        ["run", "maclink.status", "--json", "--state-dir", cache_state],
        env,
    )
    try:
        cache_dir_payload = json.loads(stdout)
    except ValueError:
        cache_dir_payload = None
    check(
        "status-cache-directory-malformed",
        code == 0
        and len(stdout.strip().splitlines()) == 1
        and isinstance(cache_dir_payload, dict)
        and cache_dir_payload.get("ok") is False
        and cache_dir_payload.get("kind") == "malformed"
        and "Traceback" not in stderr,
        "exit=%s out=%s err=%s" % (code, one_line(stdout, 200), one_line(stderr, 160)),
    )

    # --- no argv text, no token, in classify_worker or the kick-bot plan --
    secret = "FAKE-SECRET-f8c-selfcheck"
    token_pid = 4245
    token_worker_pid = 4246
    token_nonworker_cmd = "python3 -m http.server 8000 --token=%s" % secret
    token_worker_cmd = worker_cmd + " --token=%s" % secret
    ok, reason = classify_worker(token_nonworker_cmd, "kakashi", "t_selfcheck_stale", token_pid, set(), None)
    check(
        "classify-reason-has-no-argv-text",
        ok is False
        and secret not in (reason or "")
        and "http.server" not in (reason or "")
        and "4245" in (reason or "")
        and "argv0: python3" in (reason or ""),
        str(reason),
    )
    token_state = os.path.join(root, "state-token-wakeoff")
    os.makedirs(token_state, exist_ok=True)
    with open(os.path.join(token_state, "caffeinate.pid"), "w", encoding="utf-8") as handle:
        json.dump({"pid": token_pid, "action": "fixture", "command": "caffeinate -d"}, handle)
    token_caffeinate_cmd = "caffeinate -d -t 3600 --token=%s" % secret
    token_wake_plan = plan_wake_off(
        {"state_dir": token_state},
        RecordingRuntime(ps_map={token_pid: token_caffeinate_cmd}, alive_map={token_pid: True}),
    )
    token_wake_text = json.dumps(token_wake_plan)
    check(
        "wake-off-plan-has-no-argv-text",
        token_wake_plan.get("ok") is True
        and secret not in token_wake_text
        and "command_line" not in token_wake_text
        and (token_wake_plan.get("items") or [{}])[0].get("argv0") == "caffeinate",
        token_wake_text[:200],
    )
    token_wake_refusal = plan_wake_off(
        {"state_dir": token_state},
        RecordingRuntime(ps_map={token_pid: token_nonworker_cmd}, alive_map={token_pid: True}),
    )
    check(
        "wake-off-refusal-has-no-argv-text",
        token_wake_refusal.get("ok") is False
        and secret not in json.dumps(token_wake_refusal)
        and "argv0: python3" in (token_wake_refusal.get("reason") or ""),
        str(token_wake_refusal.get("reason"))[:200],
    )
    token_run_runtime = RecordingRuntime(
        ps_sequence={token_pid: [token_caffeinate_cmd, token_nonworker_cmd]},
        alive_map={token_pid: True},
    )
    token_wake_run = ACTIONS["maclink.wake-off"]["run"](
        {"state_dir": token_state}, "maclink.wake-off", token_run_runtime
    )
    check(
        "wake-off-run-refusal-has-no-argv-text",
        token_wake_run.get("refused") is True
        and secret not in json.dumps(token_wake_run)
        and token_run_runtime.changes == [],
        str(token_wake_run)[:200],
    )
    with open(os.path.join(fix_dir, "ps.json"), "w", encoding="utf-8") as handle:
        json.dump(
            {
                str(stale_pid): worker_cmd,
                str(token_pid): token_nonworker_cmd,
                str(token_worker_pid): token_worker_cmd,
            },
            handle,
        )
    token_db = os.path.join(root, "kanban-token.db")
    token_connection = sqlite3.connect(token_db)
    token_connection.execute(
        "CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT, assignee TEXT, status TEXT, "
        "worker_pid INTEGER, last_heartbeat_at INTEGER, current_run_id INTEGER, started_at INTEGER)"
    )
    token_connection.executemany(
        "INSERT INTO tasks VALUES (?,?,?,?,?,?,?,?)",
        [
            ("t_selfcheck_nonworker", "non-worker with a token", "kakashi", "running",
             token_pid, int(time.time()) - 3000, 1, int(time.time()) - 3200),
            ("t_selfcheck_stale", "worker with a token", "kakashi", "running",
             token_worker_pid, int(time.time()) - 2000, 2, int(time.time()) - 2200),
        ],
    )
    token_connection.commit()
    token_connection.close()
    code, stdout, stderr = _cli(
        ["plan", "maclink.kick-bot", "--db", token_db, "--state-dir",
         os.path.join(temp_home, ".local", "state", "nexuslink")],
        env,
    )
    try:
        token_plan = json.loads(stdout)
    except ValueError:
        token_plan = {}
    token_item = (token_plan.get("items") or [{}])[0]
    token_rejected = (token_plan.get("rejected") or [])
    check("token-plan-exit-0", code == 0, "exit=%s %s" % (code, one_line(stderr)))
    check("token-not-in-plan-stdout", secret not in stdout, "the token reached stdout")
    check("token-not-in-plan-stderr", secret not in stderr, "the token reached stderr")
    check(
        "token-plan-prints-no-argv-text",
        "http.server" not in stdout and "hermes_cli.main" not in stdout,
        "argv text reached the plan",
    )
    check(
        "token-plan-candidate-identity-only",
        token_item.get("pid") == token_worker_pid
        and token_item.get("argv0") == "python3"
        and token_item.get("command") == "kill -TERM %d" % token_worker_pid
        and bool(token_item.get("command_sha256")),
        str(token_item),
    )
    check(
        "token-plan-rejected-names-pid-only",
        len(token_rejected) == 1
        and token_rejected[0].get("pid") == token_pid
        and "4245" in (token_rejected[0].get("reason") or "")
        and "argv0: python3" in (token_rejected[0].get("reason") or ""),
        str(token_rejected),
    )

    # --- confirm refusals through the CLI ---------------------------------
    if os.path.exists(log_file):
        with open(log_file, encoding="utf-8") as handle:
            stub_lines = [line.strip() for line in handle if line.strip()]
    relay_refusal_before = len(stub_lines)
    code, stdout, stderr = _cli(
        ["run", "maclink.restart-relay", "--db", db_path, "--state-dir", os.path.join(temp_home, ".local", "state", "nexuslink")],
        env,
    )
    check("relay-run-without-confirm-exit-2", code == 2, "exit=%s %s" % (code, one_line(stderr)))
    check("relay-run-without-confirm-one-line", len(stderr.strip().splitlines()) == 1, repr(stderr[:200]))
    check("relay-run-without-confirm-no-stdout", stdout.strip() == "", repr(stdout[:120]))
    code, stdout, stderr = _cli(
        ["run", "maclink.restart-relay", "--confirm", "maclink.wake", "--db", db_path, "--state-dir", os.path.join(temp_home, ".local", "state", "nexuslink")],
        env,
    )
    check("relay-run-wrong-confirm-exit-2", code == 2, "exit=%s" % code)
    if os.path.exists(log_file):
        with open(log_file, encoding="utf-8") as handle:
            new_lines = [line.strip() for line in handle if line.strip()]
    else:
        new_lines = []
    check(
        "relay-run-no-kickstart",
        not any("kickstart" in line for line in new_lines),
        str([line for line in new_lines if "kickstart" in line])[:200],
    )
    check(
        "relay-run-no-stub-call",
        len(new_lines) == relay_refusal_before,
        "%d new stub calls" % (len(new_lines) - relay_refusal_before),
    )

    # --- in-process refusal and matcher proofs ----------------------------
    fixed_now = time.time()
    self_pid = os.getpid()
    recorder = RecordingRuntime(
        outputs={
            "launchctl": (relay_text, "", 0),
            "tailscale": (json.dumps({"BackendState": "Running"}), "", 0),
            "sysctl": ("{ sec = %d, usec = 0 }" % (int(fixed_now) - 5000), "", 0),
        },
        ps_map={stale_pid: worker_cmd},
        ps_table_text=(
            "1 0 /sbin/launchd\n"
            "%d 1 %s\n"
            "88494 1 python3 -m hermes_cli.main --profile atlas gateway run\n"
            % (stale_pid, worker_cmd)
        ),
        now=fixed_now,
        alive_map={stale_pid: True},
    )
    refusal_ctx = {"db_path": db_path, "state_dir": os.path.join(temp_home, ".local", "state", "nexuslink")}
    for name in ("maclink.restart-relay", "maclink.restart-tunnel", "maclink.kick-bot", "maclink.wake-off"):
        payload = ACTIONS[name]["run"](refusal_ctx, None, recorder)
        check(
            "reversible-refused-in-process:%s" % name,
            isinstance(payload, dict)
            and payload.get("refused") is True
            and payload.get("ran") is False,
            str(payload)[:200],
        )
    check(
        "refusal-no-runner-call",
        recorder.changes == [] and recorder.spawns == [],
        "a state changing seam was called: %s" % (recorder.changes + recorder.spawns),
    )

    self_pids = {self_pid, os.getppid(), 1}
    cases = [
        (
            "kick-refuses-other-process",
            "/usr/bin/python3 /tmp/other-job.py",
            "kakashi",
            "t_selfcheck_stale",
            stale_pid,
            False,
        ),
        (
            "kick-refuses-gateway",
            "python3 -m hermes_cli.main -p kakashi gateway run",
            "kakashi",
            "t_selfcheck_stale",
            stale_pid,
            False,
        ),
        (
            "kick-refuses-dispatcher",
            "python3 -m hermes_cli.main kanban dispatch",
            "kakashi",
            "t_selfcheck_stale",
            stale_pid,
            False,
        ),
        (
            "kick-refuses-wrong-profile",
            worker_cmd.replace("-p kakashi", "-p yamato"),
            "kakashi",
            "t_selfcheck_stale",
            stale_pid,
            False,
        ),
        (
            "kick-refuses-other-card",
            worker_cmd.replace("t_selfcheck_stale", "t_some_other_card"),
            "kakashi",
            "t_selfcheck_stale",
            stale_pid,
            False,
        ),
        (
            "kick-refuses-no-card",
            "python3 -m hermes_cli.main -p kakashi --cli chat -q work",
            "kakashi",
            "t_selfcheck_stale",
            stale_pid,
            False,
        ),
        (
            "kick-refuses-self-pid",
            worker_cmd,
            "kakashi",
            "t_selfcheck_stale",
            self_pid,
            False,
        ),
        (
            "kick-accepts-match",
            worker_cmd,
            "kakashi",
            "t_selfcheck_stale",
            stale_pid,
            True,
        ),
    ]
    for label, cmdline, profile, card, pid, expected in cases:
        ok, reason = classify_worker(cmdline, profile, card, pid, self_pids, None)
        check(label, ok is expected, "ok=%s reason=%s" % (ok, reason))
    ok, reason = classify_worker(
        worker_cmd, "kakashi", "t_selfcheck_stale", stale_pid, self_pids, "t_selfcheck_stale"
    )
    check("kick-refuses-this-card", ok is False and "this very worker" in (reason or ""), str(reason))

    changed_runtime = RecordingRuntime(
        outputs={
            "launchctl": (relay_text, "", 0),
            "tailscale": (json.dumps({"BackendState": "Running"}), "", 0),
            "sysctl": ("{ sec = %d, usec = 0 }" % (int(fixed_now) - 5000), "", 0),
        },
        ps_sequence={stale_pid: [worker_cmd, worker_cmd + " --late-flag"]},
        ps_table_text=(
            "1 0 /sbin/launchd\n"
            "%d 1 %s\n"
            "88494 1 python3 -m hermes_cli.main --profile atlas gateway run\n"
            % (stale_pid, worker_cmd)
        ),
        now=fixed_now,
        alive_map={stale_pid: True},
    )
    changed = ACTIONS["maclink.kick-bot"]["run"](refusal_ctx, "maclink.kick-bot", changed_runtime)
    check(
        "kick-run-refuses-changed-cmdline",
        changed.get("refused") is True and "changed since the plan" in (changed.get("reason") or ""),
        str(changed)[:240],
    )
    check(
        "kick-run-changed-no-signal",
        changed_runtime.changes == [] and changed_runtime.spawns == [],
        str(changed_runtime.changes + changed_runtime.spawns),
    )

    # --- quarantine parity ------------------------------------------------
    victim = os.path.join(root, "victim.txt")
    with open(victim, "w", encoding="utf-8") as handle:
        handle.write("quarantine me\n")
    qroot = os.path.join(root, "quarantine")
    moved = quarantine_file(victim, "maclink.self-check", root=qroot)
    check("quarantine-moves-file", not os.path.exists(victim) and os.path.isfile(moved["destination"]))
    manifest = moved["manifest"]
    rows = []
    if os.path.isfile(manifest):
        with open(manifest, encoding="utf-8") as handle:
            rows = [line.rstrip("\n") for line in handle if line.strip()]
    check("quarantine-manifest-row", len(rows) == 1, str(rows))
    check(
        "quarantine-manifest-five-fields",
        len(rows) == 1 and len(rows[0].split("\t")) == 5,
        str(rows[-1] if rows else ""),
    )

    # --- host refusal -----------------------------------------------------
    check("host-refusal-helper", host_is_mac("linux") is False and host_is_mac("darwin") is True)
    original_host = globals()["host_is_mac"]
    try:
        globals()["host_is_mac"] = lambda platform=None: False
        linux_plan = plan_wake(None, RecordingRuntime())
        linux_run = ACTIONS["maclink.wake"]["run"](None, None, RecordingRuntime())
    finally:
        globals()["host_is_mac"] = original_host
    check(
        "host-refusal-plan",
        linux_plan.get("ok") is False and "not this host" in (linux_plan.get("reason") or ""),
        str(linux_plan.get("reason")),
    )
    check(
        "host-refusal-run",
        linux_run.get("refused") is True and linux_run.get("ran") is False,
        str(linux_run.get("reason")),
    )
    code, stdout, stderr = _cli(["list"], env)
    check("list-without-json-flag", code == 0 and json.loads(stdout).get("ok") is True, repr(stdout[:80]))

    f8c_cases(check)
    print("")
    print("%d passed, %d failed" % (len(passed), len(failed)))
    if failed:
        print("FAILED: %s" % ", ".join(failed))
        return EXIT_FAILED
    return EXIT_OK


# ------------------------------------------------------------------------- CLI


def _common_options(parser):
    parser.add_argument("--json", action="store_true", default=argparse.SUPPRESS,
                        help="accepted for the shared feed contract; output is always one JSON object")
    parser.add_argument("--state-dir", default=argparse.SUPPRESS)
    parser.add_argument("--log", default=argparse.SUPPRESS)
    parser.add_argument("--db", default=argparse.SUPPRESS)
    parser.add_argument("--stale-after", type=int, default=argparse.SUPPRESS)
    parser.add_argument("--peer", default=argparse.SUPPRESS)
    parser.add_argument("--screenshot-path", default=argparse.SUPPRESS)


def build_ctx(args):
    ctx = {}
    if getattr(args, "state_dir", None):
        ctx["state_dir"] = args.state_dir
    if getattr(args, "db", None):
        ctx["db_path"] = args.db
    if getattr(args, "peer", None):
        ctx["peer"] = args.peer
    if getattr(args, "screenshot_path", None):
        ctx["screenshot_path"] = args.screenshot_path
    if getattr(args, "stale_after", None):
        ctx["stale_after_s"] = args.stale_after
    return ctx


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="hudfix_maclink.py",
        description="Mac link maintenance actions for the v5 hudfix engine.",
    )
    parser.add_argument("--self-check", action="store_true", help="hermetic proof, no host action")
    parser.add_argument("--json", action="store_true", default=argparse.SUPPRESS)
    sub = parser.add_subparsers(dest="command")
    list_parser = sub.add_parser("list", help="every action with its class")
    _common_options(list_parser)
    plan_parser = sub.add_parser("plan", help="dry run for one action")
    plan_parser.add_argument("action")
    _common_options(plan_parser)
    run_parser = sub.add_parser("run", help="perform one action")
    run_parser.add_argument("action")
    run_parser.add_argument("--confirm", default=None)
    _common_options(run_parser)
    args = parser.parse_args(argv)

    if args.self_check:
        return self_check()
    if not args.command:
        parser.print_usage(sys.stderr)
        return EXIT_REFUSED

    ctx = build_ctx(args)
    if ctx.get("db_path") and not os.path.exists(expand(ctx["db_path"])):
        sys.stderr.write(
            "hudfix_maclink: --db names a file that does not exist: %s\n"
            % tilde(ctx["db_path"])
        )
        return EXIT_REFUSED
    log_override = getattr(args, "log", None)
    log_target = log_path_for(ctx, log_override)
    # --json is the shared feed contract: exactly one JSON object on stdout.
    # Without the flag the same object is printed for a human, indented.
    compact = bool(getattr(args, "json", False))

    if args.command == "list":
        emit(list_payload(), compact=compact)
        return EXIT_OK

    name = args.action
    if name not in ACTIONS:
        sys.stderr.write("hudfix_maclink: unknown action %r (list shows the actions)\n" % name)
        return EXIT_REFUSED

    if args.command == "plan":
        try:
            payload = ACTIONS[name]["plan"](ctx)
        except DataProblem as exc:
            # A hostile capture or a pid file that is not a pid is an answer
            # here, not a traceback: one JSON document, ok false, exit 0.
            payload = _plan_unavailable(
                name, str(exc), kind=_kind_of(exc),
                _capture_malformed=isinstance(exc, Malformed),
            )
        append_log(
            log_target,
            {
                "ts": utc_now_iso(),
                "source": SOURCE,
                "phase": "plan",
                "action": name,
                "class": CLASS_TABLE[name],
                "ok": bool(payload.get("ok")),
                "dry_run": True,
                "items": (payload.get("total") or {}).get("items"),
                "bytes": (payload.get("total") or {}).get("bytes"),
                "reason": payload.get("reason"),
            },
        )
        emit(payload, compact=compact)
        return EXIT_OK

    try:
        result = ACTIONS[name]["run"](ctx, args.confirm)
    except DataProblem as exc:
        result = (
            _malformed_run(name, str(exc))
            if isinstance(exc, Malformed)
            else _refused(name, str(exc))
        )
    append_log(
        log_target,
        {
            "ts": utc_now_iso(),
            "source": SOURCE,
            "phase": "run",
            "action": name,
            "class": CLASS_TABLE[name],
            "ok": bool(result.get("ok")),
            "refused": bool(result.get("refused")),
            "ran": bool(result.get("ran")),
            "summary": one_line(result.get("summary") or result.get("reason"), 200),
        },
    )
    if result.get("kind") == "malformed":
        # Nothing was signalled or started: the input could not be read exactly.
        emit(result, compact=compact)
        return EXIT_OK
    if result.get("refused"):
        sys.stderr.write("hudfix_maclink: %s\n" % one_line(result.get("reason"), 400))
        return EXIT_REFUSED
    emit(result, compact=compact)
    if result.get("ok"):
        return EXIT_OK
    if CLASS_TABLE[name] == "read":
        return EXIT_OK
    return EXIT_FAILED


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Refused as exc:
        sys.stderr.write("hudfix_maclink: %s\n" % exc)
        sys.exit(EXIT_REFUSED)
