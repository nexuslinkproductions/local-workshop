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


# --------------------------------------------------------------- small helpers


def host_is_mac(platform=None):
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
        return value if value > 0 else None
    if isinstance(value, float):
        if not value.is_integer():
            return None
        number = int(value)
        return number if number > 0 else None
    text = str(value).strip()
    if not re.fullmatch(r"[0-9]{1,12}", text):
        return None
    number = int(text)
    return number if number > 0 else None


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
    if compact:
        line = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    else:
        line = json.dumps(payload, ensure_ascii=False, indent=2)
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


def _run_command(argv, timeout=DEFAULT_TIMEOUT_S):
    try:
        proc = subprocess.run(
            argv, capture_output=True, text=True, timeout=timeout, check=False
        )
        return proc.stdout or "", proc.stderr or "", proc.returncode
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

    def run(self, argv, timeout=DEFAULT_TIMEOUT_S):
        return _run_command(argv, timeout)

    def spawn(self, argv):
        return _spawn_detached(argv)

    def ps(self, pid):
        """Never raises: a malformed pid is no command line, not a crash."""
        pid_int = pid_from_cell(pid)
        if pid_int is None:
            return ""
        out, _err, code = self.run(
            ["ps", "-ww", "-o", "command=", "-p", str(pid_int)], timeout=5.0
        )
        return out.strip() if code == 0 else ""

    def ps_table(self):
        out, _err, code = self.run(["ps", "-ww", "-Ao", "pid=,ppid=,command="], timeout=8.0)
        if code != 0:
            raise DataProblem("ps -Ao failed with exit %d" % code)
        rows = []
        for line in out.splitlines():
            parts = line.strip().split(None, 2)
            if len(parts) < 2 or not parts[0].isdigit() or not parts[1].isdigit():
                continue
            rows.append((int(parts[0]), int(parts[1]), parts[2] if len(parts) > 2 else ""))
        return rows

    def alive(self, pid):
        try:
            os.kill(int(pid), 0)
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
        elif key == "pid" and value.isdigit():
            info["pid"] = int(value)
        elif key == "program":
            info["program"] = value
        elif key == "path":
            info["plist"] = value
        elif key == "last exit code":
            info["last_exit"] = value
    if info["pid"] is None:
        match = re.search(r"^\tpid = (\d+)$", text or "", re.MULTILINE)
        if match:
            info["pid"] = int(match.group(1))
    return info


def launchd_unit(label, runtime, domain=None):
    uid = os.getuid()
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
            tasks = []
            for row in rows:
                tasks.append(
                    {
                        "id": row[0],
                        "title": one_line(row[1], 80),
                        "assignee": row[2],
                        "status": row[3],
                        "worker_pid": row[4],
                        "last_heartbeat_at": row[5],
                        "current_run_id": row[6],
                        "started_at": row[7],
                    }
                )
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
        return False, "pid %r is not a number" % (pid,)
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


def _plan_unavailable(name, reason, **extra):
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
            "target": "launchctl print gui/%d/%s" % (os.getuid(), RELAY_LABEL),
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
        return _plan_unavailable("maclink.kick-bot", str(exc))
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
    if not os.path.isfile(path):
        return {"present": False, "pid": None, "raw": None}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            raw = handle.read().strip()
    except OSError as exc:
        raise DataProblem("cannot read %s: %s" % (tilde(path), exc.strerror))
    pid = None
    if raw.startswith("{"):
        try:
            pid = json.loads(raw).get("pid")
        except ValueError:
            raise DataProblem("%s is not valid JSON" % tilde(path))
    else:
        pid = raw
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        raise DataProblem("%s does not hold a pid" % tilde(path))
    if pid <= 0:
        raise DataProblem("%s does not hold a pid" % tilde(path))
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
        return _plan_unavailable("maclink.wake-off", str(exc))
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
    """A status payload younger than STATUS_CACHE_TTL_S, marked cached, or None."""
    path = state_paths(ctx)["status_cache"]
    try:
        with open(path, encoding="utf-8") as handle:
            record = json.load(handle)
    except (OSError, ValueError):
        return None
    if not isinstance(record, dict):
        return None
    payload = record.get("payload")
    stamp = record.get("cached_at")
    raw_epoch = record.get("cached_epoch")
    try:
        epoch = float(raw_epoch) if isinstance(raw_epoch, (int, float)) else float(str(raw_epoch))
    except (TypeError, ValueError):
        return None
    age = (time.time() if now is None else now) - epoch
    if not isinstance(payload, dict) or payload.get("action") != "maclink.status":
        return None
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
        return _refused("maclink.restart-relay", plan.get("reason") or "unavailable")
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
        return _refused("maclink.restart-tunnel", plan.get("reason") or "unavailable")
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
        return _refused("maclink.kick-bot", plan.get("reason") or "no stale worker")
    item = plan["items"][0]
    pid = item["pid"]
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
        return _refused("maclink.wake", plan.get("reason") or "unavailable")
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
        return _refused("maclink.wake-off", plan.get("reason") or "no recorded caffeinate")
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
        return _refused("maclink.screenshot", plan.get("reason") or "unavailable")
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

    def run(self, argv, timeout=DEFAULT_TIMEOUT_S):
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
    proc = subprocess.run(
        [sys.executable, os.path.abspath(__file__)] + list(argv),
        capture_output=True,
        text=True,
        env=env,
        timeout=120.0,
    )
    return proc.returncode, proc.stdout, proc.stderr


def self_check():
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
        relay_plan.get("items", [{}])[0].get("unit") == "gui/501/com.nexuslink.bridge-relay",
        str(relay_plan.get("items")),
    )
    check(
        "plan-relay-command",
        relay_plan.get("items", [{}])[0].get("command")
        == "launchctl kickstart -k gui/501/com.nexuslink.bridge-relay",
        str(relay_plan.get("items", [{}])[0].get("command")),
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
        check("cache-first-probes", len(first_runtime.runs) == 3, str(first_runtime.runs))
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
            cache_late.get("cached") is False and len(late_runtime.runs) == 3,
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
            cache_real_late.get("cached") is False and len(real_late_runtime.runs) == 3,
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

    if args.command == "list":
        emit(list_payload(), compact=False)
        return EXIT_OK

    name = args.action
    if name not in ACTIONS:
        sys.stderr.write("hudfix_maclink: unknown action %r (list shows the actions)\n" % name)
        return EXIT_REFUSED

    if args.command == "plan":
        payload = ACTIONS[name]["plan"](ctx)
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
        emit(payload, compact=False)
        return EXIT_OK

    result = ACTIONS[name]["run"](ctx, args.confirm)
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
    if result.get("refused"):
        sys.stderr.write("hudfix_maclink: %s\n" % one_line(result.get("reason"), 400))
        return EXIT_REFUSED
    emit(result, compact=False)
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
