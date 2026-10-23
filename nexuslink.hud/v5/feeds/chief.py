#!/usr/bin/env python3
"""Local-AI dock bridge: what the Linux box's chief is running, and the on/off taps.

Reads ``/run/user/1000/chief/metrics.json`` on the Linux box. That file is
written by the same poller as ``chief/state.json`` at most 1 Hz, only on change,
temp file plus rename (see ``recon/05-local-ai.md`` and the
``quickshell-hud-development`` reference ``chief-overlay-and-local-ai-feeds.md``).
Keys used, with the source of each:

    model            loaded model id (llama-swap ``/running``, under 1 ms)
    tokens_per_s     last completed generation, read only, never prompted for
    queue            llama-swap pending requests, else null
    vram_used_mib    per-pid fdinfo sum over /dev/dri/renderD* holders, ~2.1 ms
    vram_total_mib   same walk; the B580 has no sysfs VRAM entry

Payload (``--status``)::

    {"ok": true, "source": "fixture|live", "generated_at": "<UTC ISO>",
     "running": true, "model": "ornith-chief-v3", "vram_gb": 10.75,
     "tokens_per_s": 41.6, "metrics_age_s": 0.4}

``--fixture`` reads no clock: ``metrics_age_s`` and ``stale`` are null,
``metrics_age_reason`` says why, and ``snapshot_ts`` carries the fixture's own
``ts`` as UTC ISO. An age is a fact about this host's clock, not about the
snapshot, so a fixture run never claims one.

``--on`` / ``--off`` run ``chief-on`` / ``chief-off`` when they are on this host,
else exit 2 with ``{"ok": false, "reason": "chief-on not on this host"}`` and
change nothing. Both tools support ``--dry-run`` upstream; this wrapper's
``--dry-run`` goes one step further and only prints the command. When the
metrics file is missing the answer is honest absence: ``ok: false`` with a
reason, exit 0.

Local models run on the Linux box, never on this Mac. On the Mac every path in
this file is either fixture or a read over the tunnel; there is no local model
to start, and nothing here will ever find one. ``--self-check`` proves the
fixture path and the refusals without a model, a GPU or a Linux host.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

EXIT_OK = 0
EXIT_PROGRAMMING = 2

HOME = os.path.expanduser("~")
DEFAULT_METRICS = "/run/user/1000/chief/metrics.json"
DEFAULT_CACHE = "~/.local/state/nexuslink/chief.json"
CACHE_TTL_S = 10.0
MIB_PER_GB = 1024.0
STALE_AFTER_S = 5.0  # the writer runs at 1 Hz; five missed ticks is stale
STATUS_TIMEOUT = 4.0
ON_TIMEOUT = 120.0
OFF_TIMEOUT = 240.0  # chief-off polls for the child llama-server to exit
LAB_BIN = "~/NEXUS_AI_CENTER/04_PROJECTS/LOCAL-AI-LAB/chief/bin"


# --------------------------------------------------------------- shared plumbing
# Same generic half as callcap.py and level.py (and feeds/_common.py once W8
# lands), so each reader stands alone from a bare checkout.


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


def display_path(value):
    """A path as the payload shows it: ``~`` for the home root, else unchanged.

    Only an absolute or already home-relative path is rewritten, so a bare
    command name such as ``chief-on`` stays a name.
    """
    if not value or not isinstance(value, str):
        return value
    if not (value.startswith(os.sep) or value.startswith("~")):
        return value
    return tilde(value)


def display_argv(value):
    """``bin arg arg`` -> the same string with only the program shortened."""
    if not isinstance(value, str) or not value:
        return value
    head, sep, tail = value.partition(" ")
    return display_path(head) + sep + tail


def display_fields(fields, keep_paths=False):
    """Shorten every path-bearing field, once, for every payload this file emits.

    ``command`` and ``would_run`` are argv strings, so only their first word is a
    path. ``keep_paths`` is the documented ``--dry-run`` exception: that envelope
    prints the exact argv.
    """
    out = dict(fields)
    if keep_paths:
        return out
    for name in ("command", "would_run"):
        if out.get(name):
            out[name] = display_argv(out[name])
    for name in ("target", "file", "tool"):
        if out.get(name):
            out[name] = display_path(out[name])
    return out


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


def text(value, limit=None):
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


def origin(args):
    """Where this answer's data came from. The contract allows two values only."""
    return "fixture" if getattr(args, "fixture", None) else "live"


def envelope(source, **fields):
    payload = {"ok": True, "source": source, "generated_at": iso_now()}
    # --dry-run is the documented exception: its job is to print the exact argv.
    payload.update(display_fields(fields, keep_paths=fields.get("dry_run") is True))
    return payload


def failure(args, problem):
    reason = getattr(problem, "reason", None) or str(problem)
    return {
        "ok": False,
        "source": origin(args),
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
        raw_mtime = blob.get("metrics_mtime_ns")
        mtime_ns = int(raw_mtime) if isinstance(raw_mtime, (int, float)) else None
        return payload, age, mtime_ns
    return None


def cache_put(path, key, payload, metrics_mtime_ns=None):
    try:
        write_json(path, {
            "key": key,
            "at": time.time(),
            "metrics_mtime_ns": metrics_mtime_ns,
            "payload": payload,
        })
    except OSError:
        pass


def shell(argv, timeout):
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)
        return proc.returncode, proc.stdout or "", proc.stderr or ""
    except FileNotFoundError:
        return 127, "", "not found: %s" % argv[0]
    except subprocess.TimeoutExpired:
        return 124, "", "timed out after %.1fs: %s" % (timeout, " ".join(argv))
    except OSError as exc:
        return 126, "", str(exc)


# -------------------------------------------------------------------------- chief


def metrics_path(args):
    return os.path.abspath(os.path.expanduser(args.metrics or DEFAULT_METRICS))


def resolve_tool(name, args):
    """chief-on / chief-off: --bin-dir when given is the only directory searched.

    Without --bin-dir the lookup is PATH, then ~/.local/bin, then the lab's bin/.
    """
    explicit_dir = getattr(args, "bin_dir", None)
    if explicit_dir is not None:
        if not explicit_dir:
            return None
        candidate = os.path.join(os.path.expanduser(explicit_dir), name)
        return candidate if os.path.isfile(candidate) and os.access(candidate, os.X_OK) else None
    found = shutil.which(name)
    if found:
        return found
    for base in ("~/.local/bin", LAB_BIN):
        candidate = os.path.join(os.path.expanduser(base), name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def metrics_payload(data, age_s):
    """metrics.json shape -> the dock payload. Never invents a number."""
    model = text(data.get("model"))
    used = number(data.get("vram_used_mib"))
    total = number(data.get("vram_total_mib"))
    payload = envelope(
        "live",
        running=bool(model),
        model=model,
        vram_gb=round(used / MIB_PER_GB, 2) if used is not None else None,
        tokens_per_s=number(data.get("tokens_per_s")),
        metrics_age_s=round(age_s, 1) if age_s is not None else None,
    )
    if total is not None:
        payload["vram_total_gb"] = round(total / MIB_PER_GB, 2)
    queue = number(data.get("queue"))
    if queue is not None:
        payload["queue"] = int(queue)
    payload["stale"] = (age_s > STALE_AFTER_S) if age_s is not None else None
    return payload


def live_snapshot(args):
    """Live payload plus the metrics file's mtime in nanoseconds (for the cache)."""
    path = metrics_path(args)
    data = read_json(path, "chief metrics file")
    if not isinstance(data, dict):
        raise Malformed("chief metrics at %s is not a JSON object" % tilde(path))
    mtime_ns = None
    age = None
    try:
        info = os.stat(path)
        mtime_ns = int(info.st_mtime_ns)
        age = max(0.0, time.time() - info.st_mtime)
    except OSError:
        pass
    payload = metrics_payload(data, age)
    payload["source"] = "live"
    return payload, mtime_ns


def live_status(args):
    payload, _ = live_snapshot(args)
    return payload


def age_payload(payload, mtime_ns):
    """The payload with metrics_age_s and stale recomputed for right now.

    The cache holds the parsed file, not the reading of its clock: every answer
    re-derives the age from the file's mtime, hit or miss.
    """
    fresh = dict(payload)
    if mtime_ns is None:
        return fresh
    age = max(0.0, time.time() - (mtime_ns / 1000000000.0))
    fresh["metrics_age_s"] = round(age, 1)
    fresh["stale"] = age > STALE_AFTER_S
    return fresh


def fixture_status(args):
    target = os.path.expanduser(str(args.fixture))
    if not os.path.isfile(target):
        raise Caller("no chief fixture at %s" % tilde(args.fixture))
    data = read_json(args.fixture, "chief fixture")
    if not isinstance(data, dict):
        raise Malformed("chief fixture at %s is not a JSON object" % tilde(args.fixture))
    # Fixture purity: no clock is read here. An age is a fact about this host's
    # clock, not about the snapshot, so it is null with a reason instead. The
    # snapshot's own ts is in the fixture, so it is echoed as UTC ISO.
    payload = metrics_payload(data, None)
    payload["source"] = "fixture"
    payload["metrics_age_s"] = None
    payload["stale"] = None
    payload["metrics_age_reason"] = "fixture mode reads no clock; age and stale are not measured"
    payload["snapshot_ts"] = iso(number(data.get("ts")))
    return payload


def status_payload(args):
    if args.fixture:
        return fixture_status(args)
    path = metrics_path(args)
    key = "status|metrics=%s" % path
    if not args.no_cache:
        hit = cache_get(args.cache, key)
        if hit is not None:
            payload, age, cached_mtime_ns = hit
            try:
                mtime_ns = int(os.stat(path).st_mtime_ns)
            except OSError:
                mtime_ns = None
            if mtime_ns is not None and mtime_ns == cached_mtime_ns:
                fresh = age_payload(payload, mtime_ns)
                fresh["cached"] = True
                fresh["cache_age_s"] = round(age, 1)
                return fresh
            # The file appeared, vanished or was rewritten under the cache: the
            # cached parse no longer describes it, so fall through and re-read.
    payload, mtime_ns = live_snapshot(args)
    payload["cached"] = False
    if not args.no_cache:
        cache_put(args.cache, key, payload, mtime_ns)
    return payload


def refusal(args, reason, **extra):
    payload = {
        "ok": False,
        "source": origin(args),
        "generated_at": iso_now(),
        "reason": tilde_text(reason),
    }
    payload.update(display_fields(extra))
    return payload


def act(args):
    verb = "on" if args.on else "off"
    name = "chief-%s" % verb

    if args.fixture:
        return refusal(args, "fixture mode never acts; drop --fixture to reach the host", action=verb), EXIT_PROGRAMMING

    tool = resolve_tool(name, args)
    if tool is None:
        return (
            refusal(args, "%s not on this host" % name, action=verb, tool=name),
            EXIT_PROGRAMMING,
        )

    if args.dry_run:
        return (
            envelope("live", action=verb, dry_run=True, command=tool, would_run=tool),
            EXIT_OK,
        )

    timeout = ON_TIMEOUT if verb == "on" else OFF_TIMEOUT
    rc, out, err = shell([tool], timeout)
    if rc != 0:
        return (
            refusal(
                args,
                "%s failed (exit %d): %s" % (name, rc, text(err) or text(out) or "no output"),
                action=verb,
                exit_code=rc,
                command=tool,
            ),
            EXIT_PROGRAMMING,
        )

    payload = envelope(
        "live",
        action=verb,
        exit_code=rc,
        command=tool,
        stdout=text(out, 400),
    )
    after = None
    try:
        after = live_status(argparse.Namespace(metrics=args.metrics))
    except DataProblem:
        after = None
    if after is not None:
        payload["running"] = after.get("running")
        payload["model"] = after.get("model")
        payload["metrics_age_s"] = after.get("metrics_age_s")
    else:
        payload["running"] = None
        payload["model"] = None
        payload["metrics_age_s"] = None
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

    root = tempfile.mkdtemp(prefix="f7-chief-")
    stub_dir = os.path.join(root, "emptybin")
    os.makedirs(stub_dir, exist_ok=True)
    cache = os.path.join(root, "cache.json")
    shipped = os.path.abspath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fixtures", "chief.json")
    )

    # The committed fixture is part of the contract, so check it as shipped.
    try:
        with open(shipped, encoding="utf-8") as handle:
            shipped_data = json.load(handle)
    except (OSError, ValueError):
        shipped_data = {}
    if not isinstance(shipped_data, dict):
        shipped_data = {}
    rc, payload, _, err = _run_child(["--status", "--fixture", shipped, "--json"])
    shipped_payload = payload if isinstance(payload, dict) else {}
    ok = (
        rc == 0 and isinstance(payload, dict) and payload.get("ok") is True
        and payload.get("source") == "fixture"
        and isinstance(payload.get("running"), bool)
        and set(["running", "model", "vram_gb", "tokens_per_s", "metrics_age_s", "stale"]).issubset(payload)
        and payload.get("metrics_age_s") is None
        and payload.get("stale") is None
        and isinstance(payload.get("metrics_age_reason"), str)
        and payload.get("snapshot_ts") == iso(number(shipped_data.get("ts")))
        and str(payload.get("generated_at", "")).endswith("Z")
    )
    check("shipped fixture --status shape (no clock-derived age)", ok, "rc=%s err=%r" % (rc, err[-200:]))

    # Fixture purity, clock half: the same fixture read with the clock moved
    # 1000 s forward is identical except the generated_at stamp.
    fixture_args = argparse.Namespace(fixture=shipped)
    clock_real = time.time
    before = fixture_status(fixture_args)
    try:
        time.time = lambda: clock_real() + 1000.0
        after = fixture_status(fixture_args)
    finally:
        time.time = clock_real
    before.pop("generated_at", None)
    after.pop("generated_at", None)
    check(
        "fixture mode reads no clock (1000 s apart is identical)",
        before == after and before.get("metrics_age_s") is None and before.get("stale") is None,
        "before=%r after=%r" % (before, after),
    )

    # Fixture purity, host half: an empty HOME gives the same answer.
    blank_home = os.path.join(root, "blank-home")
    os.makedirs(blank_home, exist_ok=True)
    blank_env = dict(os.environ)
    blank_env["HOME"] = blank_home
    rc, payload, _, _ = _run_child(["--status", "--fixture", shipped, "--json"], env=blank_env)
    left = dict(shipped_payload)
    right = dict(payload) if isinstance(payload, dict) else {}
    left.pop("generated_at", None)
    right.pop("generated_at", None)
    check(
        "fixture mode reads no host state (empty HOME, same answer)",
        rc == 0 and left == right and bool(left),
        "rc=%s left=%r right=%r" % (rc, left, right),
    )

    # vram conversion is real arithmetic, not a copied field
    shipped_used = number(shipped_data.get("vram_used_mib"))
    check(
        "vram_used_mib -> vram_gb",
        shipped_used is not None and isinstance(shipped_payload, dict)
        and isinstance(shipped_payload.get("vram_gb"), float)
        and shipped_payload["vram_gb"] == round(shipped_used / MIB_PER_GB, 2),
        "payload=%r used=%r" % (shipped_payload, shipped_used),
    )

    # idle metrics: no model -> running false, nothing invented
    idle = os.path.join(root, "idle.json")
    with open(idle, "w", encoding="utf-8") as handle:
        json.dump({"ts": time.time(), "model": None, "tokens_per_s": None,
                   "queue": 0, "vram_used_mib": 0, "vram_total_mib": 12288}, handle)
    rc, payload, _, _ = _run_child(["--status", "--fixture", idle, "--json"])
    check(
        "idle metrics -> running false on the fixture path",
        rc == 0 and isinstance(payload, dict) and payload.get("running") is False
        and payload.get("model") is None and payload.get("vram_gb") == 0.0,
        "payload=%r" % (payload,),
    )

    # malformed / empty / missing named fixture
    bad = os.path.join(root, "bad.json")
    with open(bad, "w", encoding="utf-8") as handle:
        handle.write("[")
    rc, payload, _, _ = _run_child(["--status", "--fixture", bad, "--json"])
    check("malformed fixture is an answer", rc == 0 and isinstance(payload, dict) and payload.get("ok") is False, "rc=%s" % rc)

    empty = os.path.join(root, "empty.json")
    with open(empty, "w", encoding="utf-8") as handle:
        handle.write("")
    rc, payload, _, _ = _run_child(["--status", "--fixture", empty, "--json"])
    check("empty fixture is an answer", rc == 0 and isinstance(payload, dict) and payload.get("ok") is False, "rc=%s" % rc)

    rc, payload, _, _ = _run_child(["--status", "--fixture", os.path.join(root, "nope.json"), "--json"])
    check("missing named fixture -> exit 2", rc == 2 and isinstance(payload, dict) and payload.get("ok") is False, "rc=%s" % rc)

    rc, _, out, err = _run_child(["--bogus-flag"])
    check("unknown flag -> exit 2, no traceback", rc == 2 and "Traceback" not in err, "rc=%s" % rc)

    # live absence: no metrics file on this host -> ok:false, exit 0
    rc, payload, _, _ = _run_child(
        ["--status", "--json", "--metrics", os.path.join(root, "no-metrics.json"),
         "--cache", cache, "--no-cache"]
    )
    check(
        "missing metrics.json -> ok:false exit 0",
        rc == 0 and isinstance(payload, dict) and payload.get("ok") is False
        and "chief metrics" in str(payload.get("reason", "")),
        "rc=%s payload=%r" % (rc, payload),
    )

    # actions refused when the tools are absent
    for verb in ("on", "off"):
        rc, payload, _, _ = _run_child(["--%s" % verb, "--json", "--bin-dir", stub_dir])
        check(
            "--%s without the tool -> exit 2, ok:false" % verb,
            rc == 2 and isinstance(payload, dict) and payload.get("ok") is False
            and payload.get("reason") == "chief-%s not on this host" % verb,
            "rc=%s payload=%r" % (rc, payload),
        )

    # stub tools: prove invocation and that --dry-run never invokes
    log = os.path.join(root, "stub.log")
    for verb in ("on", "off"):
        tool = os.path.join(stub_dir, "chief-%s" % verb)
        with open(tool, "w", encoding="utf-8") as handle:
            handle.write("#!/bin/sh\n" 'printf \'%s\\n\' "$0" >> "$CHIEF_STUB_LOG"\n' "exit 0\n")
        os.chmod(tool, 0o755)
    env = dict(os.environ)
    env["CHIEF_STUB_LOG"] = log
    global _CHILD_ENV
    _CHILD_ENV = env

    open(log, "w").close()
    rc, payload, _, _ = _run_child(["--on", "--json", "--bin-dir", stub_dir, "--metrics", os.path.join(root, "no-metrics.json")])
    invoked = open(log, encoding="utf-8").read().strip()
    check(
        "--on invokes chief-on once",
        rc == 0 and isinstance(payload, dict) and payload.get("ok") is True
        and invoked.endswith("chief-on"),
        "rc=%s log=%r payload=%r" % (rc, invoked, payload),
    )

    open(log, "w").close()
    rc, payload, _, _ = _run_child(["--off", "--json", "--bin-dir", stub_dir, "--metrics", os.path.join(root, "no-metrics.json")])
    invoked = open(log, encoding="utf-8").read().strip()
    check(
        "--off invokes chief-off once",
        rc == 0 and isinstance(payload, dict) and payload.get("ok") is True
        and invoked.endswith("chief-off"),
        "rc=%s log=%r payload=%r" % (rc, invoked, payload),
    )

    open(log, "w").close()
    rc, payload, _, _ = _run_child(["--on", "--dry-run", "--json", "--bin-dir", stub_dir])
    invoked = open(log, encoding="utf-8").read()
    check(
        "--dry-run prints the command and runs nothing",
        rc == 0 and isinstance(payload, dict) and payload.get("dry_run") is True
        and invoked == "",
        "rc=%s payload=%r log=%r" % (rc, payload, invoked),
    )

    # An executed action shortens the tool path: no absolute home path in the
    # payload, as the README promises. The child gets its own HOME under the
    # temp root, so the check writes nothing into the real home directory.
    fake_home = os.path.join(root, "fake-home")
    fake_bin = os.path.join(fake_home, "bin")
    os.makedirs(fake_bin, exist_ok=True)
    home_env = dict(os.environ)
    home_env["HOME"] = fake_home
    for name, body in (("chief-on", "#!/bin/sh\nexit 0\n"), ("chief-off", "#!/bin/sh\nexit 3\n")):
        tool = os.path.join(fake_bin, name)
        with open(tool, "w", encoding="utf-8") as handle:
            handle.write(body)
        os.chmod(tool, 0o755)
    rc, payload, _, _ = _run_child(
        ["--on", "--json", "--bin-dir", fake_bin, "--metrics", os.path.join(root, "no-metrics.json")],
        env=home_env,
    )
    blob = json.dumps(payload or {})
    check(
        "an executed action shows the tool path shortened",
        rc == 0 and isinstance(payload, dict) and payload.get("ok") is True
        and payload.get("command") == "~/bin/chief-on" and fake_home not in blob,
        "rc=%s payload=%r" % (rc, payload),
    )

    rc, payload, _, _ = _run_child(
        ["--off", "--json", "--bin-dir", fake_bin, "--metrics", os.path.join(root, "no-metrics.json")],
        env=home_env,
    )
    blob = json.dumps(payload or {})
    check(
        "a failed action shows the tool path shortened",
        rc == 2 and isinstance(payload, dict) and payload.get("ok") is False
        and payload.get("command") == "~/bin/chief-off" and fake_home not in blob,
        "rc=%s payload=%r" % (rc, payload),
    )

    # cache: two status reads inside 10 s, the second one served from the cache
    live_metrics = os.path.join(root, "metrics.json")
    with open(live_metrics, "w", encoding="utf-8") as handle:
        json.dump({"ts": time.time(), "model": "ornith-chief-v3", "tokens_per_s": 41.6,
                   "queue": 0, "vram_used_mib": 11012, "vram_total_mib": 12288}, handle)
    _run_child(["--status", "--json", "--metrics", live_metrics, "--cache", cache])
    rc, second, _, _ = _run_child(["--status", "--json", "--metrics", live_metrics, "--cache", cache])
    check(
        "second --status inside 10 s is cached",
        rc == 0 and isinstance(second, dict) and second.get("cached") is True
        and isinstance(second.get("cache_age_s"), float),
        "second=%r" % (second,),
    )

    # A cached answer must never freeze the metrics age. This runs the real
    # status_payload in-process: first read a file 4.5 s old, then move the clock
    # 6.2 s forward with the file untouched (still inside the 10 s cache window).
    # The answer must report the file's true 10.7 s age and flip stale to true.
    aging = os.path.join(root, "aging.json")
    with open(aging, "w", encoding="utf-8") as handle:
        json.dump({"model": "ornith-chief-v3", "tokens_per_s": 41.6, "queue": 0,
                   "vram_used_mib": 11012, "vram_total_mib": 12288}, handle)
    read_at = time.time()
    os.utime(aging, (read_at - 4.5, read_at - 4.5))
    aging_cache = os.path.join(root, "aging-cache.json")
    age_args = argparse.Namespace(fixture=None, metrics=aging, cache=aging_cache, no_cache=False)
    first = status_payload(age_args)
    real_time = time.time
    try:
        time.time = lambda: real_time() + 6.2
        later = status_payload(age_args)
    finally:
        time.time = real_time
    first_age = first.get("metrics_age_s")
    later_age = later.get("metrics_age_s")
    check(
        "a cached answer reports the metrics file's true age",
        first.get("cached") is False and first_age is not None and abs(first_age - 4.5) <= 0.2
        and first.get("stale") is False
        and later.get("cached") is True and isinstance(later.get("cache_age_s"), float)
        and later_age is not None and 10.5 <= later_age <= 10.9
        and later.get("stale") is True,
        "first=%r later=%r" % (first, later),
    )

    # A metrics file rewritten under the cache is re-read, not served stale.
    with open(aging, "w", encoding="utf-8") as handle:
        json.dump({"model": "ornith-chief-v4", "tokens_per_s": 12.5, "queue": 1,
                   "vram_used_mib": 2048, "vram_total_mib": 12288}, handle)
    changed = status_payload(age_args)
    check(
        "a changed metrics file is re-read, not served from the cache",
        changed.get("cached") is False and changed.get("model") == "ornith-chief-v4"
        and isinstance(changed.get("metrics_age_s"), float) and changed["metrics_age_s"] < 1.0,
        "changed=%r" % (changed,),
    )

    # A fixture whose ts is ten minutes old still claims no age: fixture mode
    # reads no clock, so it can call the snapshot neither fresh nor stale.
    stale_fixture = os.path.join(root, "stale-fixture.json")
    with open(stale_fixture, "w", encoding="utf-8") as handle:
        json.dump({"ts": time.time() - 600, "model": "ornith-chief-v3",
                   "tokens_per_s": 41.6, "vram_used_mib": 11012, "vram_total_mib": 12288}, handle)
    rc, payload, _, _ = _run_child(["--status", "--json", "--fixture", stale_fixture])
    check(
        "an old fixture ts is still no age in fixture mode",
        rc == 0 and isinstance(payload, dict) and payload.get("metrics_age_s") is None
        and payload.get("stale") is None and isinstance(payload.get("snapshot_ts"), str),
        "payload=%r" % (payload,),
    )

    # The live path is where an age comes from: a metrics file whose mtime is
    # ten minutes old reports that age and stale:true.
    old = os.path.join(root, "old.json")
    with open(old, "w", encoding="utf-8") as handle:
        json.dump({"ts": time.time() - 600, "model": "ornith-chief-v3",
                   "tokens_per_s": 41.6, "vram_used_mib": 11012, "vram_total_mib": 12288}, handle)
    os.utime(old, (time.time() - 600, time.time() - 600))
    rc, payload, _, _ = _run_child(["--status", "--json", "--metrics", old, "--no-cache"])
    check(
        "a live metrics file ten minutes old reports a real age and stale:true",
        rc == 0 and isinstance(payload, dict) and payload.get("stale") is True
        and (payload.get("metrics_age_s") or 0) >= 599,
        "payload=%r" % (payload,),
    )

    shutil.rmtree(root, ignore_errors=True)
    failed = [item for item in checks if not item["ok"]]
    emit({"ok": not failed, "source": origin(args), "self_check": True, "checks": checks}, args.json)
    return 0 if not failed else 1


# ---------------------------------------------------------------------------- cli


def build_parser():
    parser = argparse.ArgumentParser(
        description="chief (local AI) dock bridge for the v5 HUD (status, on, off)"
    )
    parser.add_argument("--status", action="store_true", help="print loaded model, VRAM, tokens/s")
    parser.add_argument("--on", action="store_true", help="run chief-on")
    parser.add_argument("--off", action="store_true", help="run chief-off")
    parser.add_argument("--dry-run", action="store_true", help="print the command instead of running it")
    parser.add_argument("--fixture", metavar="PATH", help="read a metrics.json snapshot instead of the host")
    parser.add_argument("--json", action="store_true", help="one compact JSON line")
    parser.add_argument("--metrics", metavar="PATH", default=DEFAULT_METRICS,
                        help="metrics file (default %s)" % DEFAULT_METRICS)
    parser.add_argument("--bin-dir", metavar="DIR", default=None,
                        help="directory holding chief-on/chief-off; when given it is the only directory searched (default: PATH, then ~/.local/bin, then the lab's bin/)")
    parser.add_argument("--cache", metavar="PATH", default=DEFAULT_CACHE, help="cache file (default %s)" % DEFAULT_CACHE)
    parser.add_argument("--no-cache", action="store_true", help="ignore and do not write the cache")
    parser.add_argument("--self-check", action="store_true", help="run the built-in checks and exit")
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.self_check:
        return self_check(args)

    actions = [bool(args.status), bool(args.on), bool(args.off)]
    if sum(1 for item in actions if item) != 1:
        emit(
            {"ok": False, "source": origin(args), "generated_at": iso_now(),
             "reason": "choose exactly one of --status, --on, --off"},
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
        emit(failure(args, exc), args.json)
        return EXIT_PROGRAMMING if isinstance(exc, Caller) else EXIT_OK
    except (KeyboardInterrupt, SystemExit):
        raise
    except BaseException as exc:  # noqa: BLE001
        emit(
            {"ok": False, "source": origin(args), "generated_at": iso_now(),
             "reason": tilde_text("programming error: %s: %s" % (type(exc).__name__, exc)),
             "kind": "programming"},
            args.json,
        )
        return EXIT_PROGRAMMING

    emit(payload, args.json)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
