#!/usr/bin/env python3
"""Call-capture bridge: report whether a call is being recorded, start, stop.

Thin wrapper around Marcel's ``callcap`` on the Linux box
(``~/.local/bin/callcap``, canonical copy ``scripts/callcap``; see the
``linux-microphone-processing`` skill, ``references/call-capture.md``):

    callcap start <label>   -> ~/calls/<YYYYmmdd-HHMM>-<label>/call.wav + meta.txt
    callcap stop            -> closes the file, prints duration and size
    callcap status          -> REC or idle per directory

It records s16le 48 kHz **stereo**, channel 1 the microphone and channel 2 the
far end. That is where ``channels: 2`` and the 192000 bytes/second figure below
come from: they are the wrapper's own format, not a guess.

This reader never re-implements the recorder. It reports the state the tool
leaves on disk, and it runs the tool's own verbs for the two actions.

Payload (``--status``)::

    {"ok": true, "source": "fixture|live", "generated_at": "<UTC ISO>",
     "running": true, "elapsed_s": 42.5, "channels": 2,
     "target": "~/calls/20261023-2140-standup",
     "last": [{"file": "~/calls/20261022-1812-review/call.wav",
               "started_at": "2026-10-22T16:12:03Z", "duration_s": 1812.4}]}

Actions (``--start [LABEL]``, ``--stop``) call the real binary when it is on
this host. When it is not, they print
``{"ok": false, "reason": "callcap not on this host"}`` and exit 2, having
changed nothing. Stopping while a recording is live is destructive -- it ends a
call capture mid-sentence -- so ``--stop`` refuses without ``--confirm stop``.

Exit codes follow the feed contract: 0 for data and for honest absence
(``ok: false`` with a reason), 2 for a caller error (bad arguments, a missing
file the caller named) and for an action that was refused or failed.

Host reality: ``callcap`` and PipeWire are Linux-only. On the Mac this file is
fixture-only, and ``--self-check`` proves that without either.
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
import time

EXIT_OK = 0
EXIT_PROGRAMMING = 2

HOME = os.path.expanduser("~")
SOURCE = "callcap"
DEFAULT_BIN = "callcap"
DEFAULT_CALLS = "~/calls"
DEFAULT_CACHE = "~/.local/state/nexuslink/callcap.json"
CACHE_TTL_S = 10.0

# callcap's fixed format: s16le, 48 kHz, stereo (ch1 mic, ch2 far end).
CHANNELS = 2
SAMPLE_RATE = 48000
BYTES_PER_SEC = SAMPLE_RATE * CHANNELS * 2  # 192000
WAV_HEADER = 44

CONFIRM_TOKEN = "stop"
PROBE_TIMEOUT = 4.0
ACTION_TIMEOUT = 20.0
LABEL_RE = re.compile(r"^[A-Za-z0-9._-]{1,32}$")
DIR_RE = re.compile(r"^(\d{8}-\d{4})(?:-(.+))?$")
WAV_RE = re.compile(r"(/[^\s'\"]*/calls/[^\s'\"]*/call[^\s'\"]*\.wav)")
PID_RE = re.compile(r"^\s*pid\s*[=:]\s*(\d+)\s*$", re.MULTILINE | re.IGNORECASE)


# --------------------------------------------------------------- shared plumbing
# The generic half of this file is the same in callcap.py, chief.py and level.py
# (and in feeds/_common.py once W8 lands) so each reader runs on its own from a
# bare checkout. Consolidation is a separate, mechanical change.


class DataProblem(Exception):
    """A source is missing, empty or malformed. Always an answer, never a crash."""

    kind = "data"

    def __init__(self, reason):
        super(DataProblem, self).__init__(reason)
        self.reason = str(reason)


class Missing(DataProblem):
    kind = "missing"


class Malformed(DataProblem):
    kind = "malformed"


class Caller(DataProblem):
    """The caller named a file that is not there. Exit 2, per the feed contract."""

    kind = "caller"


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


def iso_now():
    return iso(time.time())


def tilde(path):
    """Home-relative display form. Output never carries an absolute home path."""
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
    """Finite float or None. Accepts numeric strings, rejects bools and NaN."""
    if value is None or isinstance(value, bool):
        return None
    try:
        out = float(value)
    except (TypeError, ValueError):
        return None
    if out != out or out in (float("inf"), float("-inf")):
        return None
    return out


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
        value = value[:limit].rstrip() + "\u2026"
    return value


def envelope(source, **fields):
    payload = {"ok": True, "source": source, "generated_at": iso_now()}
    payload.update(fields)
    return payload


def failure(problem, source=SOURCE):
    reason = getattr(problem, "reason", None) or str(problem)
    return {
        "ok": False,
        "source": source,
        "generated_at": iso_now(),
        "reason": tilde_text(reason),
        "kind": getattr(problem, "kind", "data"),
    }


def emit(payload, compact):
    if compact:
        line = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    else:
        line = json.dumps(payload, ensure_ascii=False, indent=2)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def read_json(path, what):
    shown = tilde(path)
    if not path:
        raise Missing("no %s path given" % what)
    target = os.path.expanduser(str(path))
    if not os.path.exists(target):
        raise Missing("no %s at %s" % (what, shown))
    if not os.path.isfile(target):
        raise Missing("%s is not a file: %s" % (what, shown))
    try:
        with open(target, "r", encoding="utf-8") as handle:
            raw = handle.read()
    except OSError as exc:
        raise Missing("cannot read %s at %s: %s" % (what, shown, exc))
    if not raw.strip():
        raise Missing("%s at %s is empty" % (what, shown))
    try:
        return json.loads(raw)
    except ValueError as exc:
        raise Malformed("%s at %s is not valid JSON: %s" % (what, shown, exc))


def write_json(path, payload):
    """Atomic write: temp file in the same directory, then os.replace."""
    target = os.path.expanduser(str(path))
    parent = os.path.dirname(target) or "."
    os.makedirs(parent, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=parent, prefix=".tmp-", suffix=".json", delete=False
    )
    try:
        with handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(handle.name, target)
    except BaseException:
        try:
            os.unlink(handle.name)
        except OSError:
            pass
        raise


def cache_get(path, key, now=None):
    """Return (payload, age_s) for a live entry younger than CACHE_TTL_S."""
    try:
        with open(os.path.expanduser(path), "r", encoding="utf-8") as handle:
            blob = json.load(handle)
    except (OSError, ValueError):
        return None
    if not isinstance(blob, dict) or blob.get("key") != key:
        return None
    payload = blob.get("payload")
    if not isinstance(payload, dict):
        return None
    stamp = number(blob.get("at"))
    if stamp is None:
        return None
    age = (time.time() if now is None else float(now)) - stamp
    if 0 <= age < CACHE_TTL_S:
        return payload, age
    return None


def cache_put(path, key, payload):
    try:
        write_json(path, {"key": key, "at": time.time(), "payload": payload})
    except OSError:
        pass  # a cache we cannot write is a cache we do without


def shell(argv, timeout):
    """Run a command. Returns (returncode, stdout, stderr). Never raises."""
    try:
        proc = subprocess.run(
            argv, capture_output=True, text=True, timeout=timeout, check=False
        )
        return proc.returncode, proc.stdout or "", proc.stderr or ""
    except FileNotFoundError:
        return 127, "", "not found: %s" % argv[0]
    except subprocess.TimeoutExpired:
        return 124, "", "timed out after %.1fs: %s" % (timeout, " ".join(argv))
    except OSError as exc:
        return 126, "", str(exc)


# ------------------------------------------------------------------------ callcap


def resolve_bin(args):
    """The callcap executable, or None. ``--bin`` wins; ``""`` forces absence."""
    explicit = getattr(args, "bin", None)
    if explicit is not None:
        if not explicit:
            return None
        path = os.path.expanduser(explicit)
        return path if os.path.isfile(path) and os.access(path, os.X_OK) else None
    found = shutil.which(DEFAULT_BIN)
    if found:
        return found
    local = os.path.expanduser("~/.local/bin/%s" % DEFAULT_BIN)
    if os.path.isfile(local) and os.access(local, os.X_OK):
        return local
    return None


def calls_root(args):
    return os.path.abspath(os.path.expanduser(getattr(args, "calls_dir", None) or DEFAULT_CALLS))


def pid_alive(pid):
    if pid is None or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def dir_pid(path):
    meta = os.path.join(path, "meta.txt")
    try:
        with open(meta, "r", encoding="utf-8", errors="replace") as handle:
            raw = handle.read()
    except OSError:
        return None
    match = PID_RE.search(raw)
    if not match:
        return None
    try:
        return int(match.group(1))
    except ValueError:
        return None


def wav_bytes(path):
    try:
        return max(0, os.path.getsize(path) - WAV_HEADER)
    except OSError:
        return 0


def wav_seconds(path):
    size = wav_bytes(path)
    return (size / float(BYTES_PER_SEC)) if size else 0.0


def stamp_epoch(stamp):
    """``YYYYmmdd-HHMM`` in local time -> epoch, or None."""
    try:
        return time.mktime(time.strptime(stamp, "%Y%m%d-%H%M"))
    except (ValueError, OverflowError):
        return None


def recording_dirs(root):
    """Recording directories under ``root``, oldest first."""
    out = []
    if not os.path.isdir(root):
        return out
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return out
    for name in names:
        match = DIR_RE.match(name)
        if not match:
            continue
        path = os.path.join(root, name)
        if not os.path.isdir(path):
            continue
        out.append(
            {
                "name": name,
                "path": path,
                "wav": os.path.join(path, "call.wav"),
                "stamp": match.group(1),
                "label": match.group(2) or "",
            }
        )
    return out


def probe_running(args, dirs, bin_path):
    """Find the recording that is live right now.

    Three independent probes, cheapest and most reliable first: the pid the
    wrapper writes into ``meta.txt``, the ffmpeg process the skill itself uses as
    the truth check, then ``callcap status``. Returns (dir or None, probe name).
    """
    for item in reversed(dirs):
        if pid_alive(dir_pid(item["path"])):
            return item, "meta-pid"

    if not getattr(args, "no_process_probe", False):
        rc, out, _ = shell(["pgrep", "-af", "ffmpeg .*calls/"], PROBE_TIMEOUT)
        if rc == 0 and out.strip():
            for line in out.splitlines():
                match = WAV_RE.search(line)
                if not match:
                    continue
                wav = os.path.realpath(match.group(1))
                for item in reversed(dirs):
                    if os.path.realpath(item["wav"]) == wav:
                        return item, "pgrep"
                return {"name": os.path.basename(os.path.dirname(wav)), "path": os.path.dirname(wav),
                        "wav": wav, "stamp": "", "label": ""}, "pgrep"

    if bin_path:
        rc, out, _ = shell([bin_path, "status"], PROBE_TIMEOUT)
        if rc == 0 and out.strip():
            rec_lines = [line for line in out.splitlines() if re.search(r"\bREC\b", line)]
            for line in rec_lines:
                for item in reversed(dirs):
                    if item["name"] in line:
                        return item, "status"
            if rec_lines:
                return None, "status-rec-unnamed"
    return None, None


def describe(item, running):
    """One recording -> the ``last`` entry shape."""
    wav = item.get("wav") or ""
    seconds = wav_seconds(wav) if wav else 0.0
    try:
        mtime = os.path.getmtime(wav) if wav and os.path.exists(wav) else None
    except OSError:
        mtime = None
    started = None
    if mtime is not None and seconds:
        started = iso(mtime - seconds)
    elif item.get("stamp"):
        started = iso(stamp_epoch(item["stamp"]))
    entry = {
        "file": tilde(wav) if wav else None,
        "started_at": started,
        "duration_s": round(seconds, 1) if seconds else None,
    }
    if running:
        entry["running"] = True
    return entry


def live_status(args):
    root = calls_root(args)
    bin_path = resolve_bin(args)
    dirs = recording_dirs(root)
    running, probe = probe_running(args, dirs, bin_path)

    if running is None and not dirs and bin_path is None:
        raise Missing("no callcap binary and no recordings under %s" % tilde(root))

    elapsed = None
    source_of_elapsed = None
    target = None
    if running is not None:
        target = tilde(running["path"])
        seconds = wav_seconds(running["wav"]) if running.get("wav") else 0.0
        if seconds > 0:
            elapsed, source_of_elapsed = round(seconds, 1), "wav-size"
        elif running.get("stamp"):
            started = stamp_epoch(running["stamp"])
            if started:
                elapsed, source_of_elapsed = round(max(0.0, time.time() - started), 1), "dir-stamp"

    last = []
    for item in reversed(dirs):
        if running is not None and item["path"] == running["path"]:
            continue
        last.append(describe(item, running=False))
        if len(last) >= max(1, int(getattr(args, "last", 3) or 3)):
            break

    payload = envelope(
        "live",
        running=running is not None or probe == "status-rec-unnamed",
        elapsed_s=elapsed,
        channels=CHANNELS,
        target=target,
        last=last,
    )
    if probe:
        payload["probe"] = probe
    if source_of_elapsed:
        payload["elapsed_source"] = source_of_elapsed
    return payload


def fixture_status(args):
    target = os.path.expanduser(str(args.fixture))
    if not os.path.isfile(target):
        raise Caller("no callcap fixture at %s" % tilde(args.fixture))
    data = read_json(args.fixture, "callcap fixture")
    if not isinstance(data, dict):
        raise Malformed("callcap fixture at %s is not a JSON object" % tilde(args.fixture))
    running = data.get("running")
    if not isinstance(running, bool):
        raise Malformed("callcap fixture at %s has no boolean 'running'" % tilde(args.fixture))
    channels = data.get("channels")
    channels_value = number(channels)
    last = data.get("last") or []
    if not isinstance(last, list):
        raise Malformed("callcap fixture at %s has a non-list 'last'" % tilde(args.fixture))
    entries = []
    for item in last:
        if not isinstance(item, dict):
            continue
        entries.append(
            {
                "file": text(item.get("file")),
                "started_at": text(item.get("started_at")),
                "duration_s": number(item.get("duration_s")),
            }
        )
    return envelope(
        "fixture",
        running=running,
        elapsed_s=number(data.get("elapsed_s")),
        channels=int(channels_value) if channels_value is not None else CHANNELS,
        target=text(data.get("target")),
        last=entries,
    )


def status_payload(args):
    if args.fixture:
        return fixture_status(args)
    key = "status|bin=%s|calls=%s|probe=%s" % (
        resolve_bin(args) or "-", calls_root(args), not args.no_process_probe
    )
    if not args.no_cache:
        hit = cache_get(args.cache, key)
        if hit is not None:
            payload, age = hit
            fresh = dict(payload)
            fresh["cached"] = True
            fresh["cache_age_s"] = round(age, 1)
            return fresh
    payload = live_status(args)
    payload["cached"] = False
    if not args.no_cache:
        cache_put(args.cache, key, payload)
    return payload


def refusal(reason, **extra):
    payload = {"ok": False, "source": "live", "generated_at": iso_now(), "reason": tilde_text(reason)}
    payload.update(extra)
    return payload


def act(args):
    verb = "start" if args.start is not None else "stop"
    argv_tail = [verb]
    label = None
    if verb == "start":
        label = args.start or "hud"
        if not LABEL_RE.match(label):
            return refusal("label must match %s" % LABEL_RE.pattern, action=verb), EXIT_PROGRAMMING
        argv_tail.append(label)

    if args.fixture:
        return (
            refusal("fixture mode never acts; drop --fixture to reach the host", action=verb),
            EXIT_PROGRAMMING,
        )

    bin_path = resolve_bin(args)
    if bin_path is None:
        return (
            refusal("%s not on this host" % DEFAULT_BIN, action=verb, bin=DEFAULT_BIN),
            EXIT_PROGRAMMING,
        )

    argv = [bin_path] + argv_tail

    if verb == "stop" and args.confirm is not None and args.confirm != CONFIRM_TOKEN:
        return (
            refusal("unknown --confirm token; the token for --stop is %r" % CONFIRM_TOKEN, action=verb),
            EXIT_PROGRAMMING,
        )

    running, probe = probe_running(args, recording_dirs(calls_root(args)), bin_path)
    is_running = running is not None or probe == "status-rec-unnamed"

    if verb == "start" and is_running:
        return (
            refusal(
                "a recording is already running; stop it first",
                action=verb,
                target=tilde(running["path"]) if running else None,
                probe=probe,
            ),
            EXIT_PROGRAMMING,
        )

    if verb == "stop" and is_running and args.confirm != CONFIRM_TOKEN:
        return (
            refusal(
                "stopping a live call recording needs --confirm %s" % CONFIRM_TOKEN,
                action=verb,
                target=tilde(running["path"]) if running else None,
                probe=probe,
                was_running=True,
            ),
            EXIT_PROGRAMMING,
        )

    if args.dry_run:
        return (
            envelope(
                "live",
                action=verb,
                dry_run=True,
                command=" ".join(argv),
                would_stop_running=is_running if verb == "stop" else None,
            ),
            EXIT_OK,
        )

    rc, out, err = shell(argv, ACTION_TIMEOUT)
    if rc != 0:
        return (
            refusal(
                "%s %s failed (exit %d): %s" % (DEFAULT_BIN, verb, rc, text(err) or text(out) or "no output"),
                action=verb,
                exit_code=rc,
                command=" ".join(argv),
            ),
            EXIT_PROGRAMMING,
        )

    after, after_probe = probe_running(args, recording_dirs(calls_root(args)), bin_path)
    if verb == "stop":
        running_after = after is not None
    else:
        running_after = True if after is not None else None
    payload = envelope(
        "live",
        action=verb,
        exit_code=rc,
        command=" ".join(argv),
        running=running_after,
        target=tilde(after["path"]) if after else None,
        stdout=text(out, 400),
    )
    payload["probe"] = after_probe or "none"
    if verb == "stop":
        payload["was_running"] = is_running
    return payload, EXIT_OK


# ---------------------------------------------------------------------- self-check


_CHILD_ENV = None


def _run_child(argv, env=None):
    proc = subprocess.run(
        [sys.executable, os.path.abspath(__file__)] + argv,
        capture_output=True, text=True, timeout=120, check=False,
        env=env or _CHILD_ENV,
    )
    payload = None
    if proc.stdout.strip():
        try:
            payload = json.loads(proc.stdout)
        except ValueError:
            payload = None
    return proc.returncode, payload, proc.stdout, proc.stderr


def self_check(args):
    checks = []

    def check(name, ok, detail=""):
        checks.append({"check": name, "ok": bool(ok), "detail": detail})
        sys.stderr.write("%-4s %s%s\n" % ("ok" if ok else "FAIL", name, ("  " + detail) if detail and not ok else ""))
        sys.stderr.flush()

    root = tempfile.mkdtemp(prefix="f7-callcap-")
    calls = os.path.join(root, "calls")
    cache = os.path.join(root, "cache.json")
    stub = os.path.join(root, "callcap")
    stub_log = os.path.join(root, "stub.log")
    fixture = os.path.join(root, "callcap.json")
    malformed = os.path.join(root, "malformed.json")
    empty = os.path.join(root, "empty.json")

    # A finished recording and a live one, both shaped like callcap leaves them.
    finished = os.path.join(calls, "20261022-1812-review")
    live = os.path.join(calls, "20261023-2140-standup")
    for path in (finished, live):
        os.makedirs(path, exist_ok=True)
        with open(os.path.join(path, "meta.txt"), "w", encoding="utf-8") as handle:
            handle.write("pid=%d\nsource=mke600_voice\nsink=easyeffects_sink.monitor\n" % os.getpid())
    with open(os.path.join(finished, "call.wav"), "wb") as handle:
        handle.write(b"RIFF" + b"\x00" * (WAV_HEADER - 4) + b"\x00" * (BYTES_PER_SEC // 4))
    with open(os.path.join(live, "call.wav"), "wb") as handle:
        handle.write(b"RIFF" + b"\x00" * (WAV_HEADER - 4) + b"\x00" * int(BYTES_PER_SEC * 42.5))

    with open(stub, "w", encoding="utf-8") as handle:
        handle.write(
            "#!/bin/sh\n"
            'printf \'%s\\n\' "$*" >> "$CALLCAP_STUB_LOG"\n'
            'printf \'stub: %s\\n\' "$*"\n'
            "exit 0\n"
        )
    os.chmod(stub, 0o755)

    with open(fixture, "w", encoding="utf-8") as handle:
        json.dump(
            {
                "running": True,
                "elapsed_s": 42.5,
                "channels": 2,
                "target": "~/calls/20261023-2140-standup",
                "last": [
                    {"file": "~/calls/20261022-1812-review/call.wav",
                     "started_at": "2026-10-22T16:12:03Z", "duration_s": 1812.4}
                ],
            },
            handle,
        )
    with open(malformed, "w", encoding="utf-8") as handle:
        handle.write("{not json")
    with open(empty, "w", encoding="utf-8") as handle:
        handle.write("")

    env = dict(os.environ)
    env["CALLCAP_STUB_LOG"] = stub_log
    global _CHILD_ENV
    _CHILD_ENV = env

    # 1. fixture status shape
    rc, payload, _, err = _run_child(["--status", "--fixture", fixture, "--json"])
    ok = (
        rc == 0 and isinstance(payload, dict) and payload.get("ok") is True
        and payload.get("source") == "fixture"
        and payload.get("running") is True
        and isinstance(payload.get("elapsed_s"), float) and payload["elapsed_s"] == 42.5
        and payload.get("channels") == 2
        and isinstance(payload.get("target"), str)
        and isinstance(payload.get("last"), list) and len(payload["last"]) == 1
        and set(payload["last"][0]) >= {"file", "started_at", "duration_s"}
        and str(payload.get("generated_at", "")).endswith("Z")
    )
    check("fixture --status shape", ok, "rc=%s out=%r" % (rc, err[-200:] if not ok else ""))

    # 2. default output is still exactly one JSON object
    rc, payload, out, _ = _run_child(["--status", "--fixture", fixture])
    check(
        "default output is one JSON object",
        rc == 0 and isinstance(payload, dict) and payload.get("ok") is True
        and out.strip().startswith("{") and out.strip().endswith("}"),
        "rc=%s" % rc,
    )

    # 3. malformed fixture -> ok:false, exit 0
    rc, payload, _, _ = _run_child(["--status", "--fixture", malformed, "--json"])
    check("malformed fixture is an answer", rc == 0 and isinstance(payload, dict) and payload.get("ok") is False, "rc=%s" % rc)

    # 4. empty fixture -> ok:false, exit 0
    rc, payload, _, _ = _run_child(["--status", "--fixture", empty, "--json"])
    check("empty fixture is an answer", rc == 0 and isinstance(payload, dict) and payload.get("ok") is False, "rc=%s" % rc)

    # 5. a named fixture that does not exist -> exit 2
    rc, payload, _, _ = _run_child(["--status", "--fixture", os.path.join(root, "nope.json"), "--json"])
    check("missing named fixture -> exit 2", rc == 2 and isinstance(payload, dict) and payload.get("ok") is False, "rc=%s" % rc)

    # 6. bad arguments -> exit 2, no traceback
    rc, payload, out, err = _run_child(["--bogus-flag"])
    check("unknown flag -> exit 2, no traceback", rc == 2 and "Traceback" not in err, "rc=%s" % rc)

    # 7. live absence: no binary, no recordings -> ok:false exit 0 (honest absence)
    empty_calls = os.path.join(root, "calls-empty")
    os.makedirs(empty_calls, exist_ok=True)
    rc, payload, _, _ = _run_child(
        ["--status", "--json", "--bin", "", "--calls-dir", empty_calls,
         "--no-process-probe", "--no-cache", "--cache", cache]
    )
    check(
        "live absence -> ok:false exit 0",
        rc == 0 and isinstance(payload, dict) and payload.get("ok") is False
        and "callcap" in str(payload.get("reason", "")),
        "rc=%s payload=%r" % (rc, payload),
    )

    # 8. action refused cleanly when the binary is absent, nothing written
    before = sorted(os.listdir(empty_calls))
    rc, payload, _, _ = _run_child(
        ["--start", "selfcheck", "--json", "--bin", os.path.join(root, "no-such-callcap"),
         "--calls-dir", empty_calls, "--no-process-probe"]
    )
    check(
        "start without the binary -> exit 2, ok:false, nothing changed",
        rc == 2 and isinstance(payload, dict) and payload.get("ok") is False
        and payload.get("reason") == "callcap not on this host"
        and sorted(os.listdir(empty_calls)) == before,
        "rc=%s payload=%r" % (rc, payload),
    )

    # 9. live status from the pid the wrapper writes (real recordings, stub binary)
    rc, payload, _, _ = _run_child(
        ["--status", "--json", "--bin", stub, "--calls-dir", calls,
         "--no-process-probe", "--no-cache", "--cache", cache]
    )
    ok = (
        rc == 0 and isinstance(payload, dict) and payload.get("ok") is True
        and payload.get("running") is True
        and payload.get("target") == tilde(live)
        and payload.get("probe") == "meta-pid"
        and abs((payload.get("elapsed_s") or 0) - 42.5) < 1.0
        and len(payload.get("last") or []) == 1
    )
    check("live --status reads meta.txt pid and wav duration", ok, "payload=%r" % (payload,))

    # 10. --stop while recording, no --confirm -> refused, tool not called
    open(stub_log, "w").close()
    rc, payload, _, _ = _run_child(
        ["--stop", "--json", "--bin", stub, "--calls-dir", calls, "--no-process-probe"]
    )
    log_after = open(stub_log, encoding="utf-8").read()
    check(
        "unconfirmed --stop refused, binary not invoked",
        rc == 2 and isinstance(payload, dict) and payload.get("ok") is False
        and "--confirm stop" in str(payload.get("reason", "")) and log_after == "",
        "rc=%s log=%r payload=%r" % (rc, log_after, payload),
    )

    # 11. --confirm with a wrong token -> refused
    rc, payload, _, _ = _run_child(
        ["--stop", "--confirm", "yes", "--json", "--bin", stub, "--calls-dir", calls, "--no-process-probe"]
    )
    check("wrong --confirm token refused", rc == 2 and isinstance(payload, dict) and payload.get("ok") is False, "rc=%s" % rc)

    # 12. confirmed --stop reaches the binary
    open(stub_log, "w").close()
    rc, payload, _, _ = _run_child(
        ["--stop", "--confirm", "stop", "--json", "--bin", stub, "--calls-dir", calls, "--no-process-probe"]
    )
    log_after = open(stub_log, encoding="utf-8").read()
    check(
        "confirmed --stop invokes callcap stop once",
        rc == 0 and isinstance(payload, dict) and payload.get("ok") is True
        and log_after.strip() == "stop",
        "rc=%s log=%r payload=%r" % (rc, log_after, payload),
    )

    # 13. --dry-run reaches nothing
    open(stub_log, "w").close()
    rc, payload, _, _ = _run_child(
        ["--start", "selfcheck", "--dry-run", "--json", "--bin", stub,
         "--calls-dir", os.path.join(root, "calls-dry"), "--no-process-probe"]
    )
    log_after = open(stub_log, encoding="utf-8").read()
    check(
        "--dry-run prints the command and runs nothing",
        rc == 0 and isinstance(payload, dict) and payload.get("dry_run") is True
        and payload.get("command", "").endswith("callcap start selfcheck")
        and "start" not in log_after.split(),
        "rc=%s payload=%r log=%r" % (rc, payload, log_after),
    )

    # 14. cache: two --status in a row cost one probe
    open(stub_log, "w").close()
    _run_child(["--status", "--json", "--bin", stub, "--calls-dir", calls,
                "--no-process-probe", "--cache", cache])
    rc2, second, _, _ = _run_child(["--status", "--json", "--bin", stub, "--calls-dir", calls,
                                    "--no-process-probe", "--cache", cache])
    check(
        "second --status inside 10 s is cached",
        rc2 == 0 and isinstance(second, dict) and second.get("cached") is True
        and isinstance(second.get("cache_age_s"), float),
        "second=%r" % (second,),
    )

    # 15. the cache never serves a fixture read (fixtures are parity checks)
    rc, payload, _, _ = _run_child(["--status", "--fixture", fixture, "--json",
                                    "--cache", cache, "--bin", stub, "--calls-dir", calls])
    check("fixture reads bypass the cache", rc == 0 and isinstance(payload, dict) and "cached" not in payload, "payload=%r" % (payload,))

    shutil.rmtree(root, ignore_errors=True)
    failed = [item for item in checks if not item["ok"]]
    emit({"ok": not failed, "source": SOURCE, "self_check": True, "checks": checks}, args.json)
    return 0 if not failed else 1


# ---------------------------------------------------------------------------- cli


def build_parser():
    parser = argparse.ArgumentParser(
        description="callcap bridge for the v5 HUD (status, start, stop)"
    )
    parser.add_argument("--status", action="store_true", help="print the current capture state")
    parser.add_argument("--start", metavar="LABEL", default=None, help="start a recording (default label: hud)")
    parser.add_argument("--stop", action="store_true", help="stop the running recording")
    parser.add_argument("--confirm", metavar="TOKEN", default=None, help="required for --stop while recording; the token is 'stop'")
    parser.add_argument("--dry-run", action="store_true", help="print the command instead of running it")
    parser.add_argument("--fixture", metavar="PATH", help="read a snapshot instead of the host")
    parser.add_argument("--json", action="store_true", help="one compact JSON line")
    parser.add_argument("--bin", metavar="PATH", default=None,
                        help="callcap executable (default: PATH, then ~/.local/bin); empty string forces absence")
    parser.add_argument("--calls-dir", metavar="PATH", default=DEFAULT_CALLS, help="recording root (default %s)" % DEFAULT_CALLS)
    parser.add_argument("--cache", metavar="PATH", default=DEFAULT_CACHE, help="cache file (default %s)" % DEFAULT_CACHE)
    parser.add_argument("--no-cache", action="store_true", help="ignore and do not write the cache")
    parser.add_argument("--no-process-probe", action="store_true", help="skip the ffmpeg process probe")
    parser.add_argument("--last", type=int, default=3, metavar="N", help="recent recordings to list (default 3)")
    parser.add_argument("--self-check", action="store_true", help="run the built-in checks and exit")
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.self_check:
        return self_check(args)

    actions = [bool(args.status), args.start is not None, bool(args.stop)]
    if sum(1 for item in actions if item) != 1:
        emit(
            {"ok": False, "source": SOURCE, "generated_at": iso_now(),
             "reason": "choose exactly one of --status, --start, --stop"},
            args.json,
        )
        return EXIT_PROGRAMMING

    try:
        if args.status:
            payload = status_payload(args)
        else:
            payload, code = act(args)
            emit(payload, args.json)
            return code
    except DataProblem as exc:
        emit(failure(exc), args.json)
        return EXIT_PROGRAMMING if isinstance(exc, Caller) else EXIT_OK
    except (KeyboardInterrupt, SystemExit):
        raise
    except BaseException as exc:  # noqa: BLE001 - a bug is a bug, report and exit 2
        emit(
            {"ok": False, "source": SOURCE, "generated_at": iso_now(),
             "reason": tilde_text("programming error: %s: %s" % (type(exc).__name__, exc)),
             "kind": "programming"},
            args.json,
        )
        return EXIT_PROGRAMMING

    emit(payload, args.json)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
