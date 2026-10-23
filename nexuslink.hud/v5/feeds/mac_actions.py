#!/usr/bin/env python3
"""Typed Mac actions for the v5 Mac Link Explorer. Stdlib only.

Every action carries a class:

  safe    open-app, screenshot, list-dir, status
  unsafe  lock, sleep, wake, wakeoff, start-bot, stop-bot

Rules this file enforces:

  * ``--list`` prints the typed table as one JSON object (name, class, usage,
    exact command, what it needs, whether it needs a confirm).
  * ``--dry-run`` prints the exact command and exits 0.
  * An unsafe action given neither ``--confirm`` nor ``--dry-run`` refuses with
    exit 2 and one line on stderr, and runs nothing. Running it needs
    ``--confirm <action-name>`` with the name equal to the action; a mismatched
    name refuses the same way.
  * ``stop-bot`` never signals a pattern. It reads the recorded PID from
    ``~/.local/state/nexuslink/bots/<profile>.pid``, asks ``ps`` for that PID's
    command line, and refuses unless the line carries that profile's
    ``-p/--profile``. Only then does it run ``kill -TERM <pid>``.
  * Nothing here writes to Marcel's config or the live HUD tree. The only
    files written are PID files under ``~/.local/state/nexuslink/`` (and the
    screenshot the caller asked for).
  * ``--self-check`` never executes an unsafe action. It plans, refuses and
    parses only, with a recording runtime that fails loudly if it is asked to
    run anything destructive, and asserts afterwards that no action command
    was run. Every subprocess it calls runs with a stub PATH, so even a
    regression cannot reach the real ``pmset``, ``kill`` or ``hermes``.

Exit codes: 0 success or dry run, 1 the action ran and failed, 2 refused or a
caller error.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

SOURCE = "mac_actions"
HOME = os.path.expanduser("~")
DEFAULT_STATE_DIR = "~/.local/state/nexuslink"
EXIT_OK = 0
EXIT_FAILED = 1
EXIT_REFUSED = 2
PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")


class Refusal(Exception):
    """A caller error or a safety check that said no. Exit 2, one line."""


# ------------------------------------------------------------------ plumbing


def iso_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def tilde(path):
    if not path:
        return ""
    path = os.path.abspath(os.path.expanduser(str(path)))
    if path == HOME:
        return "~"
    if path.startswith(HOME + os.sep):
        return "~" + path[len(HOME):]
    return path


def text(value, limit=None):
    if value is None:
        return None
    if not isinstance(value, str):
        value = str(value)
    value = " ".join(value.split())
    if not value:
        return None
    if limit is not None and len(value) > limit:
        value = value[:limit].rstrip() + "..."
    return value


def emit(payload, compact):
    if compact:
        line = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=False)
    else:
        line = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=False)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def write_json(path, payload):
    target = os.path.expanduser(str(path))
    parent = os.path.dirname(target) or "."
    os.makedirs(parent, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=parent, prefix=".tmp-", suffix=".json", delete=False
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


def read_pid_file(path):
    """Plain integer or JSON object. Missing or unusable -> Refusal."""
    shown = tilde(path)
    if not os.path.isfile(os.path.expanduser(path)):
        raise Refusal("no PID file at %s" % shown)
    try:
        with open(os.path.expanduser(path), "r", encoding="utf-8") as handle:
            raw = handle.read().strip()
    except OSError as exc:
        raise Refusal("cannot read %s: %s" % (shown, exc.strerror or exc))
    if not raw:
        raise Refusal("%s is empty" % shown)
    if raw.startswith("{"):
        try:
            pid = json.loads(raw).get("pid")
        except ValueError:
            raise Refusal("%s is not valid JSON" % shown)
    else:
        pid = raw
    try:
        value = int(pid)
    except (TypeError, ValueError):
        raise Refusal("%s does not hold a PID" % shown)
    if value <= 0:
        raise Refusal("%s does not hold a PID" % shown)
    return value


def write_pid_file(path, pid, action, command, profile=None):
    write_json(
        path,
        {
            "pid": int(pid),
            "action": action,
            "profile": profile,
            "command": command,
            "started_at": iso_now(),
        },
    )


def command_matches_profile(cmdline, profile):
    """True only when the live command line is a bot runtime for this profile."""
    body = (cmdline or "").strip()
    if not body:
        return False
    if not re.search(r"(^|/)(hermes|devin)(\s|$)", body):
        return False
    try:
        tokens = shlex.split(body)
    except ValueError:
        tokens = body.split()
    for index, token in enumerate(tokens):
        if token in ("-p", "--profile"):
            if index + 1 < len(tokens) and tokens[index + 1] == profile:
                return True
        elif token.startswith("--profile=") and token.split("=", 1)[1] == profile:
            return True
    return False


def command_matches_name(cmdline, name):
    body = (cmdline or "").strip()
    if not body:
        return False
    try:
        tokens = shlex.split(body)
    except ValueError:
        tokens = body.split()
    if not tokens:
        return False
    return os.path.basename(tokens[0]) == name


def command_name(cmdline):
    """The program a foreign command line runs; never the whole line.

    A refusal has to name what it found, but another process's full argv can
    carry paths, flags and arguments that are not this tool's business to
    print. The basename is enough evidence for a human.
    """
    body = (cmdline or "").strip()
    if not body:
        return "nothing"
    try:
        tokens = shlex.split(body)
    except ValueError:
        tokens = body.split()
    if not tokens:
        return "nothing"
    return os.path.basename(tokens[0]) or "nothing"


def display_line(argv):
    """The command as a reader should see it: a program under $HOME shows as ~.

    The argv that runs keeps the absolute path a non-interactive shell needs
    (a gateway spawned without a login shell has no useful PATH); only this
    printed and dry-run line is shortened, so output carries no absolute home
    path (feeds brief).
    """
    parts = list(argv or [])
    if parts and parts[0].startswith(HOME + os.sep):
        head = "~" + parts[0][len(HOME):]
        return " ".join([head] + [shlex.quote(part) for part in parts[1:]])
    return shlex.join(parts)


def hermes_bin():
    candidates = [os.path.join(HOME, ".local", "bin", "hermes"), shutil.which("hermes")]
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    raise Refusal("hermes binary not found at ~/.local/bin/hermes or on PATH")


def default_screenshot_path():
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    return os.path.join(HOME, "Desktop", "nexus-%s.jpg" % stamp)


# ------------------------------------------------------------------- runtime


def run_command(argv, timeout=20.0):
    try:
        proc = subprocess.run(
            argv, capture_output=True, text=True, timeout=timeout, check=False
        )
        return proc.stdout or "", proc.stderr or "", proc.returncode
    except subprocess.TimeoutExpired:
        return "", "timed out after %ss" % timeout, 124
    except FileNotFoundError:
        return "", "not installed", 127
    except OSError as exc:
        return "", str(exc), 1


def spawn_background(argv):
    proc = subprocess.Popen(
        argv,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )
    return proc.pid


def inspect_process(pid):
    out, _err, code = run_command(["ps", "-o", "command=", "-p", str(pid)], timeout=5.0)
    return out.strip() if code == 0 else ""


def process_alive(pid):
    try:
        os.kill(int(pid), 0)
    except (ProcessLookupError, ValueError):
        return False
    except PermissionError:
        return True
    return True


class Runtime(object):
    """The seams the self-check replaces. Nothing here decides policy."""

    def run(self, argv, timeout=20.0):
        return run_command(argv, timeout)

    def spawn(self, argv):
        return spawn_background(argv)

    def ps(self, pid):
        return inspect_process(pid)

    def alive(self, pid):
        return process_alive(pid)


# -------------------------------------------------------------------- action


class Action(object):
    def __init__(self, name, klass, usage, command, needs, confirm=False):
        self.name = name
        self.klass = klass
        self.usage = usage
        self.command = command
        self.needs = needs
        self.confirm = confirm

    def as_dict(self):
        return {
            "name": self.name,
            "class": self.klass,
            "usage": self.usage,
            "command": self.command,
            "needs": self.needs,
            "confirm": self.confirm,
        }


ACTIONS = (
    Action("open-app", "safe", "open-app <name>", "open -a <name>", "an installed app name"),
    Action("screenshot", "safe", "screenshot [--path FILE]", "screencapture -x -t jpg <path>", "Screen Recording permission for the calling process; default path ~/Desktop"),
    Action("list-dir", "safe", "list-dir <path>", "ls -la -- <path>", "a path readable by the Mac user"),
    Action("status", "safe", "status", "sw_vers -productVersion; uptime; pmset -g batt; pgrep -fl '[c]affeinate' || true", "nothing"),
    Action("lock", "unsafe", "lock", "pmset displaysleepnow", "nothing; the screen locks when the Mac requires a password after display sleep", confirm=True),
    Action("sleep", "unsafe", "sleep", "pmset sleepnow", "nothing", confirm=True),
    Action("wake", "unsafe", "wake", "caffeinate -dims", "nothing; records the PID at ~/.local/state/nexuslink/caffeinate.pid", confirm=True),
    Action("wakeoff", "unsafe", "wakeoff", "kill -TERM <recorded caffeinate pid>", "a caffeinate PID recorded by wake", confirm=True),
    Action("start-bot", "unsafe", "start-bot <profile>", "hermes -p <profile> gateway run", "a Hermes profile name; records the PID at ~/.local/state/nexuslink/bots/<profile>.pid", confirm=True),
    Action("stop-bot", "unsafe", "stop-bot <profile>", "kill -TERM <recorded pid>", "a live PID file for that profile whose command line carries -p <profile>", confirm=True),
)
ACTION_MAP = {action.name: action for action in ACTIONS}

STATUS_SCRIPT = "\n".join(
    [
        "echo '@@OS'",
        "sw_vers -productVersion 2>&1",
        "echo '@@UPTIME'",
        "uptime 2>&1",
        "echo '@@BATT'",
        "pmset -g batt 2>&1",
        "echo '@@CAFFEINATE'",
        # pgrep exits 1 when nothing matches, which is the normal state here.
        # Without the "|| true" the whole script exits non-zero, execute()
        # parses no status object, and status reports a failure when it worked.
        "pgrep -fl '[c]affeinate' 2>&1 || true",
    ]
) + "\n"


# ---------------------------------------------------------------------- plan


def require_value(args):
    value = text(args.value)
    if not value:
        raise Refusal("%s needs a value (%s)" % (args.action, ACTION_MAP[args.action].usage))
    return value


def state_paths(state_dir):
    root = os.path.expanduser(state_dir or DEFAULT_STATE_DIR)
    return {
        "root": root,
        "bots": os.path.join(root, "bots"),
        "caffeinate": os.path.join(root, "caffeinate.pid"),
    }


def build_plan(args, runtime):
    """Pure-ish: reads PID files and ps, never executes or signals.

    Returns {argv, display, background, pid_path, pid, note}.
    """
    name = args.action
    paths = state_paths(args.state_dir)
    plan = {"argv": None, "background": False, "pid_path": None, "pid": None, "note": None}

    if name == "open-app":
        plan["argv"] = ["open", "-a", require_value(args)]
    elif name == "screenshot":
        target = text(args.path) or default_screenshot_path()
        plan["argv"] = ["screencapture", "-x", "-t", "jpg", os.path.expanduser(target)]
    elif name == "list-dir":
        plan["argv"] = ["ls", "-la", "--", os.path.expanduser(require_value(args))]
    elif name == "status":
        plan["argv"] = ["/bin/sh", "-c", STATUS_SCRIPT]
    elif name == "lock":
        plan["argv"] = ["pmset", "displaysleepnow"]
    elif name == "sleep":
        plan["argv"] = ["pmset", "sleepnow"]
    elif name == "wake":
        pid_path = paths["caffeinate"]
        if os.path.isfile(pid_path):
            pid = read_pid_file(pid_path)
            if runtime.alive(pid):
                raise Refusal("caffeinate already running as pid %d" % pid)
        plan["argv"] = ["caffeinate", "-dims"]
        plan["background"] = True
        plan["pid_path"] = pid_path
    elif name == "wakeoff":
        pid = read_pid_file(paths["caffeinate"])
        cmdline = runtime.ps(pid)
        if not cmdline:
            raise Refusal("pid %d is gone; run wake again" % pid)
        if not command_matches_name(cmdline, "caffeinate"):
            raise Refusal("pid %d is not caffeinate (command: %s)" % (pid, command_name(cmdline)))
        plan["argv"] = ["kill", "-TERM", str(pid)]
        plan["pid"] = pid
    elif name == "start-bot":
        profile = require_value(args)
        if not PROFILE_RE.match(profile):
            raise Refusal("not a Hermes profile name: %r" % profile)
        pid_path = os.path.join(paths["bots"], "%s.pid" % profile)
        if os.path.isfile(pid_path):
            pid = read_pid_file(pid_path)
            if runtime.alive(pid):
                raise Refusal("%s bot already running as pid %d" % (profile, pid))
        plan["argv"] = [hermes_bin(), "-p", profile, "gateway", "run"]
        plan["background"] = True
        plan["pid_path"] = pid_path
        plan["profile"] = profile
    elif name == "stop-bot":
        profile = require_value(args)
        if not PROFILE_RE.match(profile):
            raise Refusal("not a Hermes profile name: %r" % profile)
        pid_path = os.path.join(paths["bots"], "%s.pid" % profile)
        pid = read_pid_file(pid_path)
        cmdline = runtime.ps(pid)
        if not cmdline:
            raise Refusal("pid %d for %s is gone" % (pid, profile))
        if not command_matches_profile(cmdline, profile):
            raise Refusal(
                "pid %d does not look like the %s bot: %s"
                % (pid, profile, command_name(cmdline))
            )
        plan["argv"] = ["kill", "-TERM", str(pid)]
        plan["pid"] = pid
        plan["profile"] = profile
    else:  # pragma: no cover - guarded by argparse choices
        raise Refusal("unknown action %r" % name)

    plan["display"] = display_line(plan["argv"])
    return plan


# ------------------------------------------------------------------- execute


def parse_status(payload):
    """Collector text with @@ markers -> the status object, nulls where unread."""
    sections = {}
    current = None
    for line in (payload or "").splitlines():
        match = re.match(r"^@@([A-Z][A-Z0-9_]*)$", line.strip())
        if match:
            current = match.group(1)
            sections.setdefault(current, [])
            continue
        if current:
            sections[current].append(line)
    blocks = {name: "\n".join(lines).strip() for name, lines in sections.items()}

    os_version = text(blocks.get("OS", "").splitlines()[0]) if blocks.get("OS") else None
    uptime = text(blocks.get("UPTIME"), 160)
    battery = {"percent": None, "state": None}
    match = re.search(r"(\d{1,3})%;\s*([^;]+);", blocks.get("BATT", ""))
    if match:
        battery["percent"] = int(match.group(1))
        battery["state"] = text(match.group(2).lower())
    pids = []
    for line in (blocks.get("CAFFEINATE", "") or "").splitlines():
        match = re.match(r"^(\d+)\s+", line.strip())
        if match:
            pids.append(int(match.group(1)))
    return {
        "os_version": os_version,
        "uptime": uptime,
        "battery": battery,
        "caffeinate": {"on": bool(pids), "pids": pids},
    }


def bot_pid_files(state_dir):
    root = state_paths(state_dir)["bots"]
    found = []
    if not os.path.isdir(root):
        return found
    for entry in sorted(os.listdir(root)):
        if not entry.endswith(".pid"):
            continue
        path = os.path.join(root, entry)
        try:
            pid = read_pid_file(path)
        except Refusal:
            continue
        found.append({"profile": entry[:-4], "pid": pid, "path": tilde(path)})
    return found


def ensure_allowed(action, args):
    """Refuse an unsafe action that was not explicitly confirmed.

    ``--dry-run`` is the one safe way to see the command; it never reaches a
    runtime. A bare unsafe call is a refusal (exit 2, one line on stderr), not
    a silent dry run, so a caller that forgot the flag learns about it.
    """
    if action.klass != "unsafe":
        return
    if args.confirm is not None and args.confirm != action.name:
        raise Refusal(
            "%s needs --confirm %s, got --confirm %s" % (action.name, action.name, args.confirm)
        )
    if args.dry_run:
        return
    if args.confirm is None:
        raise Refusal(
            "%s is unsafe: pass --confirm %s to run it, or --dry-run to print the command"
            % (action.name, action.name)
        )


def execute(args, runtime):
    action = ACTION_MAP[args.action]
    ensure_allowed(action, args)
    plan = build_plan(args, runtime)
    unsafe = action.klass == "unsafe"

    result: dict = {
        "ok": True,
        "source": SOURCE,
        "generated_at": iso_now(),
        "action": action.name,
        "class": action.klass,
        "command": plan["display"],
        "dry_run": False,
        "ran": False,
    }

    if args.dry_run:
        result["dry_run"] = True
        if unsafe:
            result["reason"] = "dry run; pass --confirm %s to run" % action.name
        return result

    if plan["background"]:
        pid = runtime.spawn(plan["argv"])
        write_pid_file(
            plan["pid_path"], pid, action.name, plan["display"], profile=plan.get("profile")
        )
        result.update({"ran": True, "pid": pid, "pid_file": tilde(plan["pid_path"])})
    else:
        out, err, code = runtime.run(plan["argv"], timeout=args.timeout)
        result.update(
            {
                "ran": True,
                "exit": code,
                "stdout": text(out, 4000),
                "stderr": text(err, 2000),
            }
        )
        if action.name == "status" and code == 0:
            result["status"] = parse_status(out)
            result["status"]["bots"] = bot_pid_files(args.state_dir)
        if code != 0:
            result["ok"] = False
            result["reason"] = "command exit %d" % code
    result["ok"] = result.get("ok", True)
    return result


# ----------------------------------------------------------------- self-check


def _cli(argv, env=None):
    proc = subprocess.run(
        [sys.executable, os.path.abspath(__file__)] + argv,
        capture_output=True,
        text=True,
        env=env,
    )
    return proc.returncode, proc.stdout, proc.stderr


def make_shim_dir(root, log_path, names, bodies=None):
    """A PATH holding one logging stub per command this tool could call.

    Each stub records its argv and then exits 1, so an accidental real
    invocation is caught by an assertion instead of touching the Mac. The
    self-check runs every CLI subprocess with this as its whole PATH.
    ``bodies`` overrides a stub with recorded output (used to feed the status
    script a caffeinate-off machine without running a probe for real).
    """
    os.makedirs(root, exist_ok=True)
    bodies = bodies or {}
    for name in names:
        path = os.path.join(root, name)
        with open(path, "w", encoding="utf-8") as handle:
            if name in bodies:
                handle.write(
                    "#!/bin/sh\n"
                    "printf '%%s\\n' \"${0##*/} $*\" >> %s\n" % shlex.quote(log_path)
                    + bodies[name]
                )
            else:
                handle.write(
                    "#!/bin/sh\n"
                    "printf '%%s\\n' \"${0##*/} $*\" >> %s\n" % shlex.quote(log_path)
                    + "exit 1\n"
                )
        os.chmod(path, 0o755)
    return root


def shim_calls(log_path):
    if not os.path.exists(log_path):
        return []
    with open(log_path, "r", encoding="utf-8") as handle:
        return [line.strip() for line in handle if line.strip()]


class RecordingRuntime(Runtime):
    """Records every seam call and refuses to be a real process executor."""

    def __init__(self, ps_text="", run_stdout=""):
        self.runs = []
        self.spawns = []
        self.ps_calls = []
        self.ps_text = ps_text
        self.run_stdout = run_stdout
        self.alive_map = {}

    def run(self, argv, timeout=20.0):
        self.runs.append(list(argv))
        return self.run_stdout, "", 0

    def spawn(self, argv):
        self.spawns.append(list(argv))
        return 4242

    def ps(self, pid):
        self.ps_calls.append(int(pid))
        return self.ps_text

    def alive(self, pid):
        return bool(self.alive_map.get(int(pid), False))


def self_check(args):
    import types

    ok, bad = [], []

    def check(name, condition, detail=""):
        if condition:
            ok.append(name)
            print("PASS %s" % name)
        else:
            bad.append(name)
            print("FAIL %s %s" % (name, detail))

    # --- a PATH the self-check cannot escape --------------------------------
    shim_root = tempfile.mkdtemp(prefix="f1-mac-actions-shim-", dir=os.environ.get("TMPDIR"))
    shim_log = os.path.join(shim_root, "commands.log")
    shim_dir = make_shim_dir(
        os.path.join(shim_root, "bin"),
        shim_log,
        (
            "pmset", "kill", "caffeinate", "open", "screencapture", "ls",
            "sw_vers", "uptime", "pgrep", "hermes", "ps", "devin", "tailscale",
        ),
    )
    cli_env = dict(os.environ)
    cli_env["PATH"] = shim_dir

    # --- the typed table ----------------------------------------------------
    code, stdout, stderr = _cli(["--list", "--json"], env=cli_env)
    check("list-exit-0", code == 0, "exit=%s %s" % (code, stderr[:200]))
    try:
        listed = json.loads(stdout)
    except ValueError:
        listed = None
    check("list-one-object", isinstance(listed, dict), stdout[:120])
    names = [item["name"] for item in (listed or {}).get("actions", [])]
    check(
        "list-ten-actions",
        names == [action.name for action in ACTIONS],
        str(names),
    )
    classes = {item["name"]: item["class"] for item in (listed or {}).get("actions", [])}
    for name in ("open-app", "screenshot", "list-dir", "status"):
        check("class-safe:%s" % name, classes.get(name) == "safe", str(classes.get(name)))
    for name in ("lock", "sleep", "wake", "wakeoff", "start-bot", "stop-bot"):
        check("class-unsafe:%s" % name, classes.get(name) == "unsafe", str(classes.get(name)))
    check(
        "list-every-command",
        all(item.get("command") for item in (listed or {}).get("actions", [])),
        "an action has no exact command",
    )

    # --- dry run through the CLI -------------------------------------------
    code, stdout, stderr = _cli(["sleep", "--dry-run"], env=cli_env)
    check("dry-sleep-exit-0", code == 0, "exit=%s %s" % (code, stderr[:200]))
    check("dry-sleep-line", stdout.strip() == "pmset sleepnow", repr(stdout))

    # --- a bare unsafe call refuses instead of running ----------------------
    # The stub PATH above means even a regression cannot reach the real pmset.
    # These calls carry no --dry-run on purpose: the refusal is what is under
    # test, and a dry run would not exercise it.
    for name, extra in (("sleep", []), ("lock", []), ("wake", []), ("start-bot", ["kakashi"])):
        code, stdout, stderr = _cli([name] + extra, env=cli_env)
        check("unsafe-bare-exit-2:%s" % name, code == 2, "exit=%s %s" % (code, stderr.strip()[:160]))
        check("unsafe-bare-one-line:%s" % name, len(stderr.strip().splitlines()) == 1, repr(stderr[:200]))
        check("unsafe-bare-no-stdout:%s" % name, stdout.strip() == "", repr(stdout[:120]))

    # --- refusal: --confirm with a name that is not the action -------------
    # --dry-run is added so the call is safe even if the name check regressed;
    # a mismatched confirm still refuses with it.
    code, stdout, stderr = _cli(["sleep", "--confirm", "lock", "--dry-run"], env=cli_env)
    check("wrong-confirm-exit-2", code == 2, "exit=%s" % code)
    check("wrong-confirm-one-line", len(stderr.strip().splitlines()) == 1, repr(stderr))
    check("wrong-confirm-nothing-on-stdout", stdout.strip() == "", repr(stdout[:120]))

    # --- no PID file: stop-bot refuses before any command -------------------
    tmp = tempfile.mkdtemp(prefix="f1-mac-actions-", dir=os.environ.get("TMPDIR"))
    code, stdout, stderr = _cli(
        ["stop-bot", "kakashi", "--confirm", "stop-bot", "--state-dir", tmp, "--dry-run"],
        env=cli_env,
    )
    check("stop-bot-no-pid-exit-2", code == 2, "exit=%s" % code)
    check("stop-bot-no-pid-one-line", len(stderr.strip().splitlines()) == 1, repr(stderr))
    check("stop-bot-no-pid-nothing-run", stdout.strip() == "", repr(stdout[:120]))

    # --- plan() is pure: every unsafe action builds its exact command -------
    state = os.path.join(tmp, "state")
    os.makedirs(os.path.join(state, "bots"))
    base = types.SimpleNamespace(
        action=None, value=None, path=None, state_dir=state, confirm=None, timeout=5.0
    )

    def plan_for(name, value=None):
        local = types.SimpleNamespace(**vars(base))
        local.action = name
        local.value = value
        return build_plan(local, RecordingRuntime())

    check("plan-sleep", plan_for("sleep")["argv"] == ["pmset", "sleepnow"], str(plan_for("sleep")["argv"]))
    check("plan-lock", plan_for("lock")["argv"] == ["pmset", "displaysleepnow"], str(plan_for("lock")["argv"]))
    wake = plan_for("wake")
    check("plan-wake", wake["argv"] == ["caffeinate", "-dims"] and wake["background"] is True, str(wake))
    check("plan-open-app", plan_for("open-app", "Safari")["argv"] == ["open", "-a", "Safari"], str(plan_for("open-app", "Safari")["argv"]))
    check(
        "plan-screenshot",
        plan_for("screenshot")["argv"][:4] == ["screencapture", "-x", "-t", "jpg"],
        str(plan_for("screenshot")["argv"]),
    )
    check(
        "plan-list-dir",
        plan_for("list-dir", tmp)["argv"] == ["ls", "-la", "--", tmp],
        str(plan_for("list-dir", tmp)["argv"]),
    )
    bot = plan_for("start-bot", "kakashi")
    check(
        "plan-start-bot",
        bot["argv"][1:] == ["-p", "kakashi", "gateway", "run"] and bot["background"] is True,
        str(bot["argv"]),
    )
    check(
        "plan-start-bot-pid-file",
        bot["pid_path"].endswith(os.path.join("bots", "kakashi.pid")),
        bot["pid_path"],
    )
    # The printed line is reader-facing: a program under the home directory is
    # shown as ~ while the argv keeps the absolute path (observation O3).
    check(
        "plan-start-bot-display-no-home-path",
        HOME not in bot["display"] and bot["display"].endswith("-p kakashi gateway run"),
        bot["display"],
    )
    check(
        "plan-start-bot-argv-keeps-absolute-path",
        os.path.isabs(bot["argv"][0]),
        bot["argv"][0],
    )
    for bad_profile in ("../evil", "Kakashi", "", "a b"):
        try:
            plan_for("start-bot", bad_profile)
            refused = False
        except Refusal:
            refused = True
        check("plan-profile-refused:%r" % bad_profile, refused, bad_profile)

    # --- stop-bot verification: only the recorded PID, only its own profile -
    pid_path = os.path.join(state, "bots", "kakashi.pid")
    write_pid_file(pid_path, 4242, "start-bot", "hermes -p kakashi gateway run", profile="kakashi")
    match_rt = RecordingRuntime(ps_text="/Users/marcelspatz/.local/bin/hermes -p kakashi gateway run")
    match_rt.alive_map[4242] = True
    local = types.SimpleNamespace(**vars(base))
    local.action = "stop-bot"
    local.value = "kakashi"
    stop_plan = build_plan(local, match_rt)
    check("stop-bot-kill-by-pid", stop_plan["argv"] == ["kill", "-TERM", "4242"], str(stop_plan["argv"]))
    check("stop-bot-no-pattern", all("pkill" not in part for part in stop_plan["argv"]), str(stop_plan["argv"]))

    mismatch = RecordingRuntime(
        ps_text="/usr/bin/python3 /tmp/other-job.py --token sk-not-for-output"
    )
    mismatch.alive_map[4242] = True
    mismatch_text = ""
    try:
        build_plan(local, mismatch)
    except Refusal as exc:
        mismatch_text = str(exc)
    check(
        "stop-bot-refuses-other-process",
        "does not look like the kakashi bot" in mismatch_text,
        "mismatched command line was accepted",
    )
    # A refusal names the program, never another process's whole argv (O4).
    check(
        "stop-bot-refusal-names-program-only",
        "python3" in mismatch_text
        and "sk-not-for-output" not in mismatch_text
        and "/tmp/other-job.py" not in mismatch_text,
        mismatch_text,
    )

    gone = RecordingRuntime(ps_text="")
    try:
        build_plan(local, gone)
        refused = False
    except Refusal as exc:
        refused = "is gone" in str(exc)
    check("stop-bot-refuses-dead-pid", refused, "dead pid was accepted")

    check(
        "stop-bot-profile-matching",
        command_matches_profile("hermes -p kakashi gateway run", "kakashi")
        and command_matches_profile("hermes --profile=kakashi gateway run", "kakashi")
        and not command_matches_profile("hermes -p kakashi gateway run", "yamato")
        and not command_matches_profile("python3 -p kakashi", "kakashi"),
        "profile matching is loose or wrong",
    )

    try:
        plan_for("wakeoff")
        refused = False
    except Refusal as exc:
        refused = "no PID file" in str(exc)
    check("wakeoff-needs-recorded-pid", refused, "wakeoff planned without a recorded caffeinate PID")

    # A recorded PID that now belongs to something else: refused, and the
    # message names only the program (observation O4).
    write_pid_file(os.path.join(state, "caffeinate.pid"), 5150, "wake", "caffeinate -dims")
    foreign = RecordingRuntime(
        ps_text="/usr/bin/python3 /tmp/other-job.py --token sk-not-for-output"
    )
    foreign.alive_map[5150] = True
    foreign_args = types.SimpleNamespace(**vars(base))
    foreign_args.action = "wakeoff"
    foreign_args.value = None
    foreign_text = ""
    try:
        build_plan(foreign_args, foreign)
    except Refusal as exc:
        foreign_text = str(exc)
    check(
        "wakeoff-refuses-foreign-pid",
        "is not caffeinate" in foreign_text,
        foreign_text or "a foreign PID was accepted as caffeinate",
    )
    check(
        "wakeoff-refusal-names-program-only",
        "python3" in foreign_text
        and "sk-not-for-output" not in foreign_text
        and "/tmp/other-job.py" not in foreign_text,
        foreign_text,
    )

    # --- safe action execution goes through the seam, not the real runner ---
    list_rt = RecordingRuntime(run_stdout="total 0\n")
    local = types.SimpleNamespace(**vars(base))
    local.action = "list-dir"
    local.value = tmp
    local.dry_run = False
    local.confirm = None
    result = execute(local, list_rt)
    check("safe-action-runs", result["ran"] is True and list_rt.runs == [["ls", "-la", "--", tmp]], str(list_rt.runs))
    check("safe-action-ok", result["ok"] is True and result["exit"] == 0, str(result))

    # --- status parsing from a recorded block ------------------------------
    recorded = (
        "@@OS\n26.4.1\n@@UPTIME\n 1:20  up 13 days,  4:50, 1 user, load averages: 12.0 9.0 7.0\n"
        "@@BATT\nNow drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t72%; charging; 2:14 remaining present: true\n"
        "@@CAFFEINATE\n"
    )
    status = parse_status(recorded)
    check("status-os", status["os_version"] == "26.4.1", str(status["os_version"]))
    check("status-batt", status["battery"] == {"percent": 72, "state": "charging"}, str(status["battery"]))
    check("status-caffeinate-off", status["caffeinate"]["on"] is False, str(status["caffeinate"]))
    check("status-uptime", "up 13 days" in (status["uptime"] or ""), str(status["uptime"]))

    # --- the destructive proof: nothing unsafe reached a runner ------------
    destructive = RecordingRuntime()
    for name, value in (("sleep", None), ("lock", None), ("wake", None), ("start-bot", "kakashi")):
        local = types.SimpleNamespace(**vars(base))
        local.action = name
        local.value = value
        local.dry_run = False
        local.confirm = None
        try:
            execute(local, destructive)
            refused = False
        except Refusal:
            refused = True
        check("unsafe-bare-refused-in-process:%s" % name, refused, "a bare unsafe call was not refused")
    check(
        "self-check-no-destructive-exec",
        destructive.runs == [] and destructive.spawns == [],
        "a runner was called: %s %s" % (destructive.runs, destructive.spawns),
    )

    # --- status with caffeinate off exits 0 and returns the object ----------
    # The real STATUS_SCRIPT runs against a stub PATH: pmset, uptime and
    # sw_vers answer from the recorded values, and pgrep exits 1 exactly as it
    # does when no caffeinate is running. Nothing here touches the Mac.
    status_log = os.path.join(shim_root, "status.log")
    status_dir = make_shim_dir(
        os.path.join(shim_root, "status-bin"),
        status_log,
        ("sw_vers", "uptime", "pmset", "pgrep"),
        {
            "sw_vers": "printf '%s\\n' '26.4.1'\nexit 0\n",
            "uptime": "printf '%s\\n' ' 1:20  up 13 days,  4:50, 1 user, load averages: 12.0 9.0 7.0'\nexit 0\n",
            "pmset": (
                "printf '%s\\n' \"Now drawing from 'AC Power'\"\n"
                "printf ' -InternalBattery-0 (id=1)\\t72%%; charging; 2:14 remaining present: true\\n'\n"
                "exit 0\n"
            ),
        },
    )
    status_env = dict(os.environ)
    status_env["PATH"] = status_dir
    proc = subprocess.run(
        ["/bin/sh", "-c", STATUS_SCRIPT], capture_output=True, text=True, timeout=10.0, env=status_env
    )
    check("status-script-exit-0-caffeinate-off", proc.returncode == 0, "exit=%s" % proc.returncode)
    check("status-script-caffeinate-not-on", proc.stdout.strip().split("@@CAFFEINATE")[-1].strip() == "", repr(proc.stdout[-80:]))

    class StatusRuntime(Runtime):
        def run(self, argv, timeout=20.0):
            self.argv = argv
            return proc.stdout, proc.stderr, proc.returncode

    status_args = types.SimpleNamespace(**vars(base))
    status_args.action = "status"
    status_args.value = None
    status_args.dry_run = False
    status_args.confirm = None
    status_runtime = StatusRuntime()
    status_result = execute(status_args, status_runtime)
    check("status-action-ok-true", status_result["ok"] is True, str(status_result.get("reason")))
    check("status-action-ran", status_result["ran"] is True and status_result["exit"] == 0, str(status_result))
    parsed_status = status_result.get("status") or {}
    check("status-action-object", parsed_status.get("os_version") == "26.4.1", str(parsed_status))
    check(
        "status-action-caffeinate-off",
        parsed_status.get("caffeinate") == {"on": False, "pids": []},
        str(parsed_status.get("caffeinate")),
    )
    check(
        "status-action-battery",
        parsed_status.get("battery") == {"percent": 72, "state": "charging"},
        str(parsed_status.get("battery")),
    )

    # --- the whole run: no state-changing command reached a stub -----------
    banned = ("pmset sleepnow", "pmset displaysleepnow", "kill ", "caffeinate -", "open -a", "screencapture", "hermes -p")
    all_calls = shim_calls(shim_log) + shim_calls(status_log)
    caught = [line for line in all_calls if any(token in line for token in banned)]
    check("self-check-no-state-changing-command", caught == [], str(caught)[:300])
    check("self-check-no-command-via-cli-path", shim_calls(shim_log) == [], str(shim_calls(shim_log))[:200])

    print("\nself-check %s: %d passed, %d failed" % ("ok" if not bad else "FAILED", len(ok), len(bad)))
    if bad:
        print("failed: %s" % ", ".join(bad))
    return 0 if not bad else 1


# ----------------------------------------------------------------------- cli


def parse(argv):
    parser = argparse.ArgumentParser(
        description="Typed Mac actions for the v5 HUD Mac Link Explorer."
    )
    parser.add_argument("action", nargs="?", help="one of: %s" % ", ".join(a.name for a in ACTIONS))
    parser.add_argument("value", nargs="?", help="app name, path or profile for the action")
    parser.add_argument("--list", dest="list_actions", action="store_true", help="print the typed table as JSON")
    parser.add_argument("--dry-run", action="store_true", help="print the exact command and exit 0")
    parser.add_argument("--confirm", metavar="ACTION", help="required to run an unsafe action")
    parser.add_argument("--path", help="screenshot output path")
    parser.add_argument("--state-dir", default=DEFAULT_STATE_DIR, help="PID file root (default %s)" % DEFAULT_STATE_DIR)
    parser.add_argument("--timeout", type=float, default=20.0, help="command timeout seconds (default 20)")
    parser.add_argument("--json", action="store_true", help="one compact JSON line")
    parser.add_argument("--self-check", action="store_true", help="run the built-in checks and exit")
    args = parser.parse_args(argv)

    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if not args.self_check and not args.list_actions:
        if not args.action:
            parser.error("give an action or --list")
        if args.action not in ACTION_MAP:
            parser.error("unknown action %r (use --list)" % args.action)
    return args


def main(argv=None):
    args = parse(argv)
    if args.self_check:
        return self_check(args)
    if args.list_actions:
        emit(
            {
                "ok": True,
                "source": SOURCE,
                "generated_at": iso_now(),
                "actions": [action.as_dict() for action in ACTIONS],
            },
            bool(args.json),
        )
        return EXIT_OK

    try:
        result = execute(args, Runtime())
    except Refusal as exc:
        sys.stderr.write("%s: refused: %s\n" % (args.action, exc))
        return EXIT_REFUSED
    except KeyboardInterrupt:
        raise
    except BaseException as exc:
        sys.stderr.write("%s: error: %s: %s\n" % (args.action, type(exc).__name__, exc))
        return EXIT_REFUSED

    if result.get("dry_run") and not args.json:
        sys.stdout.write(result["command"] + "\n")
        sys.stdout.flush()
        return EXIT_OK
    emit(result, bool(args.json))
    return EXIT_OK if result.get("ok") else EXIT_FAILED


if __name__ == "__main__":
    sys.exit(main())
