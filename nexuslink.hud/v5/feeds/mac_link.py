#!/usr/bin/env python3
"""Mac link feed for the v5 HUD: one collector round trip, cached 10 s.

One JSON status object per call: battery and charge state, load average, memory
pressure, SoC temperature, uptime, tunnel RTT, running Kanban cards and Devin
runs. Everything is measured on the Mac by ONE shell script, run through a
pluggable runner:

    --host local     /bin/sh -c <script> on this Mac
    --host ssh:mac   ssh mac <script> from the Linux HUD
    --fixture PATH   a recorded collector output, parsed by the same parser

The collector prints its values between ``@@NAME`` marker lines. The parser is
the only place that knows the command output shapes, so a fixture exercises
exactly the live path minus the subprocess.

Absence is an answer, never an exception: a value that could not be read is
``null`` and carries a reason in the ``reasons`` map (keyed by its dotted path).
When the collector produced no readable section at all the payload becomes
``{"ok": false, "reason": "..."}`` and the process still exits 0, so a HUD tick
never sees a broken process. Exit 2 is reserved for a caller error (bad
arguments, a fixture file the caller named that does not exist).

Reads are cached in ``~/.local/state/nexuslink/mac_link.json`` (atomic write)
for 10 s and never faster: a second call inside the window runs zero collectors
and returns the same sample with ``cached: true`` and ``cache_age_s`` set.

Nothing here writes to the live HUD tree, Marcel's config, or the Mac beyond
read-only probes.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time

SOURCE = "mac_link"
CACHE_TTL_S = 10.0  # never faster than this; a HUD tick may not raise the cost
DEFAULT_CACHE = "~/.local/state/nexuslink/mac_link.json"
DEFAULT_PEER = "omarchylink"  # the Linux HUD host's tailscale name
DEFAULT_TIMEOUT_S = 20.0
HOME = os.path.expanduser("~")
EXIT_OK = 0
EXIT_PROGRAMMING = 2

SECTION_RE = re.compile(r"^@@([A-Z][A-Z0-9_]*)$")
PRESSURE_NAMES = {1: "normal", 2: "warning", 4: "critical"}


# ------------------------------------------------------------------ plumbing


class DataProblem(Exception):
    """A source is missing, empty or malformed. An answer, not a crash."""

    kind = "data"

    def __init__(self, reason):
        super(DataProblem, self).__init__(reason)
        self.reason = str(reason)


class Missing(DataProblem):
    kind = "missing"


class Malformed(DataProblem):
    kind = "malformed"


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


def envelope(source, mode, **fields):
    payload = {
        "ok": True,
        "source": source,
        "mode": mode,
        "generated_at": iso_now(),
    }
    payload.update(fields)
    return payload


def failure(source, mode, problem):
    return {
        "ok": False,
        "source": source,
        "mode": mode,
        "generated_at": iso_now(),
        "reason": tilde_text(getattr(problem, "reason", None) or str(problem)),
        "kind": getattr(problem, "kind", "data"),
    }


def emit(payload, compact):
    if compact:
        line = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=False)
    else:
        line = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=False)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def read_json(path, what):
    shown = tilde(path)
    target = os.path.expanduser(str(path))
    if not os.path.exists(target):
        raise Missing("no %s at %s" % (what, shown))
    try:
        with open(target, "r", encoding="utf-8") as handle:
            raw = handle.read()
    except OSError as exc:
        raise Missing("cannot read %s at %s: %s" % (what, shown, exc.strerror or exc))
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
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=False)
            handle.write("\n")
        os.replace(handle.name, target)
    except BaseException:
        try:
            os.unlink(handle.name)
        except OSError:
            pass
        raise


# ----------------------------------------------------------------- collector


def collector_script(peer):
    """The ONE shell script. Every value printed once, between @@ markers.

    Absolute fallbacks for PATH: a non-interactive ssh shell gets
    /usr/bin:/bin:/usr/sbin:/sbin only, so ``hermes`` (~/.local/bin) and
    ``tailscale`` (/usr/local/bin) are invisible there otherwise.

    The kanban call strips the delegate-context markers Hermes sets in a spawned
    worker. They fence *mutations* of the board; this is a read-only list, and
    without the strip a locally run feed would report the board as unreadable
    while the same command works over ssh.
    """
    peer_q = shlex.quote(peer)
    lines = [
        "# mac_link collector: one round trip, every value once.",
        'H="$HOME/.local/bin/hermes"',
        '[ -x "$H" ] || H="$HOME/.hermes/hermes-agent/.hermes/bin/hermes"',
        'T="/usr/local/bin/tailscale"',
        '[ -x "$T" ] || T="tailscale"',
        "echo '@@HOST'",
        "scutil --get LocalHostName 2>/dev/null || hostname -s 2>&1",
        "echo '@@NOW'",
        "date -u +%s 2>&1",
        "echo '@@BATT'",
        "pmset -g batt 2>&1",
        "echo '@@LOAD'",
        "sysctl -n vm.loadavg 2>&1",
        "echo '@@CORES'",
        "sysctl -n hw.ncpu 2>&1",
        "echo '@@UPTIME'",
        "uptime 2>&1",
        "echo '@@BOOTTIME'",
        "sysctl -n kern.boottime 2>&1",
        "echo '@@MEMPRESSURE'",
        "memory_pressure -Q 2>&1",
        "echo '@@MEMSTATUS'",
        "sysctl -n kern.memorystatus_vm_pressure_level 2>&1",
        "echo '@@THERM'",
        "pmset -g therm 2>&1",
        "echo '@@PING'",
        '"$T" ping --c=1 %s 2>&1' % peer_q,
        "echo '@@KANBAN'",
        'env -u HERMES_DELEGATED_CHILD_CONTEXT -u HERMES_KANBAN_TASK '
        '-u HERMES_KANBAN_RUN_ID -u HERMES_KANBAN_CLAIM_LOCK '
        '"$H" kanban list --status running --json 2>&1',
        "echo '@@DEVIN'",
        "pgrep -fl '(^|/)devin( |$)' 2>&1",
        "echo '@@END'",
    ]
    return "\n".join(lines) + "\n"


def local_runner(script, timeout):
    try:
        proc = subprocess.run(
            ["/bin/sh", "-c", script], capture_output=True, text=True, timeout=timeout, check=False
        )
        return proc.stdout or "", proc.stderr or "", proc.returncode
    except subprocess.TimeoutExpired:
        return "", "collector timed out after %ss" % timeout, 124
    except OSError as exc:
        return "", str(exc), 1


def ssh_runner(host, script, timeout):
    try:
        proc = subprocess.run(
            [
                "ssh",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=%d" % max(int(timeout) - 2, 3),
                "-o", "StrictHostKeyChecking=accept-new",
                host,
                script,
            ],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return proc.stdout or "", proc.stderr or "", proc.returncode
    except subprocess.TimeoutExpired:
        return "", "ssh %s timed out after %ss" % (host, timeout), 124
    except OSError as exc:
        return "", "ssh %s: %s" % (host, exc), 1


def runner_for(host, host_name):
    if host == "local":
        return local_runner
    return lambda script, timeout: ssh_runner(host_name, script, timeout)


# -------------------------------------------------------------------- parser


def split_sections(raw):
    """``@@NAME`` delimited blocks -> {name: text}. One parser for all runners."""
    sections = {}
    current = None
    for line in (raw or "").splitlines():
        match = SECTION_RE.match(line.strip())
        if match:
            current = match.group(1)
            sections.setdefault(current, [])
            continue
        if current is not None:
            sections[current].append(line)
    return {name: "\n".join(lines).strip() for name, lines in sections.items()}


def parse_battery(block, reasons):
    out: dict = {"percent": None, "state": None, "remaining": None, "present": None, "power_source": None}
    if not block:
        reasons["mac.battery"] = "pmset -g batt printed nothing"
        return out

    source = re.search(r"drawing from '([^']+)'", block)
    if source:
        out["power_source"] = text(source.group(1))

    line = re.search(
        r"(\d{1,3})%;\s*([^;]+);\s*([0-9:]+)\s+remaining\s+present:\s*(true|false)", block
    ) or re.search(r"(\d{1,3})%;\s*([^;]+);\s*([0-9:]+)", block)
    if not line:
        reason = first_line(block, 160) or "no battery line"
        if "no batteries" in block.lower():
            reason = "pmset reports no battery on this Mac"
        reasons["mac.battery.percent"] = reason
        reasons["mac.battery.state"] = reason
        return out

    out["percent"] = max(0, min(100, int(line.group(1))))
    out["state"] = text(line.group(2).lower())
    out["remaining"] = text(line.group(3))
    out["present"] = (line.group(4) == "true") if line.lastindex and line.lastindex >= 4 else None
    return out


def parse_load(block, cores, reasons):
    out: dict = {"avg": None, "load1_frac": None, "cores": cores}
    if not block:
        reasons["mac.load"] = "sysctl vm.loadavg printed nothing"
        return out
    match = re.search(r"\{\s*([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s*\}", block)
    if not match:
        reasons["mac.load"] = first_line(block, 160) or "vm.loadavg is not a triple"
        return out
    out["avg"] = [round(float(value), 2) for value in match.groups()]
    if cores:
        out["load1_frac"] = round(out["avg"][0] / float(cores), 3)
    else:
        reasons["mac.load.load1_frac"] = "cpu core count unavailable"
    return out


def parse_cores(block):
    match = re.search(r"(\d+)", block or "")
    value = int(match.group(1)) if match else None
    return value if value and value > 0 else None


def parse_memory(pressure_block, status_block, reasons):
    out: dict = {"pressure": None, "pressure_raw": None, "free_pct": None}

    raw = None
    match = re.search(r"(\d+)", status_block or "")
    if match:
        raw = int(match.group(1))
        out["pressure_raw"] = raw
        if raw in PRESSURE_NAMES:
            out["pressure"] = PRESSURE_NAMES[raw]
        else:
            reasons["mac.memory.pressure"] = "unmapped kern.memorystatus_vm_pressure_level %d" % raw
    else:
        reasons["mac.memory.pressure"] = (
            first_line(status_block, 160) or "kern.memorystatus_vm_pressure_level unreadable"
        )

    match = re.search(r"memory free percentage:\s*(\d+)", pressure_block or "", re.IGNORECASE)
    if match:
        out["free_pct"] = max(0, min(100, int(match.group(1))))
    else:
        reasons["mac.memory.free_pct"] = (
            first_line(pressure_block, 160) or "memory_pressure -Q printed nothing"
        )
    return out


def parse_thermal(block, reasons):
    out: dict = {"temp_c": None, "scheduler_limit": None, "speed_limit": None}
    if not block:
        reasons["mac.soc_temp_c"] = "pmset -g therm printed nothing"
        return out

    temp = re.search(r"(?:cpu|soc|die|package)\s*temp[a-z]*\s*[:=]\s*([0-9.]+)", block, re.I)
    if temp:
        out["temp_c"] = round(float(temp.group(1)), 1)
    else:
        if "no thermal warning level" in block.lower():
            reasons["mac.soc_temp_c"] = (
                "pmset -g therm records no temperature on this Mac (Apple Silicon); "
                "the SoC sensor needs root (powermetrics)"
            )
        else:
            reasons["mac.soc_temp_c"] = first_line(block, 160) or "no temperature in pmset -g therm"

    limit = re.search(r"CPU_Scheduler_Limit\s*=\s*(\d+)", block)
    if limit:
        out["scheduler_limit"] = int(limit.group(1))
    speed = re.search(r"CPU_Speed_Limit\s*=\s*(\d+)", block)
    if speed:
        out["speed_limit"] = int(speed.group(1))
    return out


def parse_boottime(block):
    match = re.search(r"sec\s*=\s*(\d+)", block or "")
    return int(match.group(1)) if match else None


def parse_uptime_text(block):
    """`uptime` fallback when kern.boottime is unreadable. Seconds or None."""
    body = block or ""
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


def human_uptime(seconds):
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


def parse_ping(block, peer, reasons):
    out: dict = {"peer": peer, "up": None, "rtt_ms": None, "route": None}
    body = block or ""
    if not body:
        reasons["tunnel.rtt_ms"] = "tailscale ping printed nothing"
        return out

    pongs = [line for line in body.splitlines() if re.search(r"in\s+[0-9.]+\s*ms", line)]
    line = pongs[-1] if pongs else body
    match = re.search(r"in\s+([0-9]+(?:\.[0-9]+)?)\s*ms", line)
    if not match:
        lowered = body.lower()
        if "not found" in lowered:
            reason = "tailscale binary not found on the Mac"
        elif "no such host" in lowered or "looking up" in lowered:
            reason = "peer %r not in the tailnet" % peer
        elif "no matching peer" in lowered:
            reason = "peer %r not in the tailnet" % peer
        elif "timeout" in lowered or "timed out" in lowered:
            reason = "ping timed out"
        else:
            reason = first_line(body, 160) or "no pong"
        out["up"] = False
        reasons["tunnel.rtt_ms"] = reason
        return out

    out["up"] = True
    out["rtt_ms"] = round(float(match.group(1)), 1)
    # Route from the same line as the RTT: a pong over DERP is a relay, any
    # other "via <addr>" is a direct path (IPv4 or IPv6 literal).
    lowered = line.lower()
    if "derp" in lowered:
        out["route"] = "relay"
    elif "via" in lowered:
        out["route"] = "direct"
    return out


def parse_kanban(block, now_epoch, reasons):
    out: dict = {"running": None, "items": []}
    body = block or ""
    if not body:
        reasons["kanban"] = "hermes kanban list printed nothing"
        return out
    if not body.lstrip().startswith("["):
        reasons["kanban"] = "hermes kanban list: %s" % (first_line(body, 180) or "no JSON")
        return out
    try:
        data = json.loads(body)
    except ValueError as exc:
        reasons["kanban"] = "hermes kanban list is not JSON: %s" % exc
        return out
    if not isinstance(data, list):
        reasons["kanban"] = "hermes kanban list is not an array"
        return out

    items = []
    for task in data:
        if not isinstance(task, dict):
            continue
        status = text(task.get("status"))
        if status and status != "running":
            continue
        started = integer(task.get("started_at"))
        items.append(
            {
                "id": text(task.get("id")),
                "title": text(task.get("title"), 120),
                "assignee": text(task.get("assignee")),
                "started_at": iso(started),
                "age_s": int(now_epoch - started) if (started and now_epoch) else None,
            }
        )
    items.sort(key=lambda item: item["age_s"] or 0, reverse=True)
    out["running"] = len(items)
    out["items"] = items
    return out


def parse_devin(block):
    items = []
    for line in (block or "").splitlines():
        match = re.match(r"^(\d+)\s+(.+)$", line.strip())
        if not match:
            continue
        command = match.group(2)
        model = re.search(r"--model\s+(\S+)", command)
        items.append(
            {
                "pid": int(match.group(1)),
                "model": text(model.group(1)) if model else None,
                "command": text(command, 200),
            }
        )
    return {"running": len(items), "items": items}


def parse_collector(raw, peer):
    """Shared by live, ssh and fixture. Returns (mac, tunnel, kanban, devin, reasons)."""
    sections = split_sections(raw)
    if not sections:
        raise Missing(
            "collector printed no @@ sections: %s" % (first_line(raw, 160) or "empty output")
        )

    reasons = {}
    returned = [name for name, body in sections.items() if name != "END" and body]
    if not returned:
        raise Missing("collector printed markers but no values")

    now_epoch = integer(sections.get("NOW"))
    clock_note = None
    if now_epoch is None:
        now_epoch = int(time.time())
        clock_note = "collector did not report its clock; ages use the reader clock"

    hostname = first_line(sections.get("HOST"), 80)
    if not hostname:
        reasons["mac.hostname"] = "hostname -s printed nothing"

    cores = parse_cores(sections.get("CORES"))
    battery = parse_battery(sections.get("BATT"), reasons)
    load = parse_load(sections.get("LOAD"), cores, reasons)
    memory = parse_memory(sections.get("MEMPRESSURE"), sections.get("MEMSTATUS"), reasons)
    thermal = parse_thermal(sections.get("THERM"), reasons)

    boot = parse_boottime(sections.get("BOOTTIME"))
    uptime_s = None
    uptime_source = None
    if boot is not None and now_epoch >= boot:
        uptime_s = int(now_epoch - boot)
        uptime_source = "kern.boottime"
    else:
        uptime_s = parse_uptime_text(sections.get("UPTIME"))
        uptime_source = "uptime" if uptime_s is not None else None
    if uptime_s is None:
        reasons["mac.uptime_s"] = "neither kern.boottime nor uptime could be read"
    elif uptime_source == "uptime":
        reasons["mac.uptime_s"] = "kern.boottime unreadable; uptime text used"

    mac = {
        "hostname": hostname,
        "battery": battery,
        "load": load,
        "memory": memory,
        "soc_temp_c": thermal["temp_c"],
        "thermal": {
            "scheduler_limit": thermal["scheduler_limit"],
            "speed_limit": thermal["speed_limit"],
        },
        "uptime_s": uptime_s,
        "uptime_human": human_uptime(uptime_s),
    }
    if clock_note:
        reasons["mac.now"] = clock_note

    tunnel = parse_ping(sections.get("PING"), peer, reasons)
    kanban = parse_kanban(sections.get("KANBAN"), now_epoch, reasons)
    devin = parse_devin(sections.get("DEVIN"))

    if "END" not in sections:
        reasons["collector_output"] = "output ended before @@END (truncated)"

    return {
        "mac": mac,
        "tunnel": tunnel,
        "kanban": kanban,
        "devin": devin,
        "reasons": reasons,
        "collected_epoch": now_epoch,
    }


# ------------------------------------------------------------------- payload


def payload_for(raw, mode, host, peer, collector_exit=None, collector_error=None):
    parsed = parse_collector(raw, peer)
    reasons = parsed["reasons"]
    if collector_error:
        reasons["collector_stderr"] = text(collector_error, 240)

    payload = envelope(
        SOURCE,
        mode,
        host=host,
        collected_at=iso(parsed["collected_epoch"]),
        cache_age_s=0.0,
        cached=False,
        mac=parsed["mac"],
        tunnel=parsed["tunnel"],
        kanban=parsed["kanban"],
        devin=parsed["devin"],
    )
    if collector_exit not in (None, 0):
        payload["collector_exit"] = collector_exit
    if reasons:
        payload["reasons"] = reasons
    return payload, parsed["collected_epoch"]


# --------------------------------------------------------------------- cache


def cache_read(path):
    try:
        root = read_json(path, "mac link cache")
    except DataProblem:
        return None
    return root if isinstance(root, dict) else None


def cache_lookup(root, host, peer, now_epoch, ttl):
    if not root or root.get("host") != host or root.get("peer") != peer:
        return None
    at = number(root.get("collected_epoch"))
    payload = root.get("payload")
    if at is None or not isinstance(payload, dict):
        return None
    age = max(now_epoch - at, 0.0)
    if age > ttl:
        return None
    return payload, age


def cache_store(path, host, peer, collected_epoch, payload):
    write_json(
        path,
        {
            "version": 1,
            "host": host,
            "peer": peer,
            "collected_epoch": collected_epoch,
            "updated_at": iso_now(),
            "payload": payload,
        },
    )


# ----------------------------------------------------------------------- run


def build(args, runner=None):
    if args.fixture:
        target = os.path.expanduser(args.fixture)
        try:
            with open(target, "r", encoding="utf-8") as handle:
                raw = handle.read()
        except OSError as exc:
            raise Missing("cannot read fixture %s: %s" % (tilde(target), exc.strerror or exc))
        payload, _epoch = payload_for(raw, "fixture", args.host, args.peer)
        return payload

    now_epoch = time.time()
    cached = cache_lookup(cache_read(args.state), args.host, args.peer, now_epoch, CACHE_TTL_S)
    if cached:
        payload, age = cached
        out = dict(payload)
        out["generated_at"] = iso_now()
        out["cached"] = True
        out["cache_age_s"] = round(age, 1)
        return out

    script = collector_script(args.peer)
    run = runner or runner_for(args.host, args.host_name)
    raw, err, code = run(script, args.timeout)  # ONE collector round trip
    if not (raw or "").strip():
        detail = first_line(err, 200) or "no output"
        raise Missing("collector returned nothing (exit %s): %s" % (code, detail))
    payload, _collected_epoch = payload_for(raw, "live", args.host, args.peer, code, err)
    payload["cached"] = False
    payload["cache_age_s"] = 0.0
    try:
        # Cache age is measured on the reader's clock, not the Mac's: the two
        # hosts keep their own time and a skewed Mac must not freeze the cache.
        cache_store(args.state, args.host, args.peer, now_epoch, payload)
    except OSError as exc:
        payload.setdefault("reasons", {})["cache"] = "cache not written: %s" % (exc.strerror or exc)
    return payload


# ----------------------------------------------------------------- self-check


def _cli(argv):
    proc = subprocess.run(
        [sys.executable, os.path.abspath(__file__)] + argv, capture_output=True, text=True
    )
    try:
        parsed = json.loads(proc.stdout) if proc.stdout.strip() else None
    except ValueError:
        parsed = None
    return proc.returncode, parsed, proc.stdout, proc.stderr


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

    fixture = os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", "fixtures", "mac_link.txt")
    )
    with open(fixture, "r", encoding="utf-8") as handle:
        recorded = handle.read()

    # --- the collector is one script, every probe exactly once ---------------
    script = collector_script("omarchylink")
    for probe in (
        "pmset -g batt",
        "sysctl -n vm.loadavg",
        "sysctl -n hw.ncpu",
        "uptime",
        "sysctl -n kern.boottime",
        "memory_pressure -Q",
        "sysctl -n kern.memorystatus_vm_pressure_level",
        "pmset -g therm",
        'ping --c=1 omarchylink',
        "kanban list --status running --json",
        "pgrep -fl",
    ):
        check("script-probe:%s" % probe, script.count(probe) == 1, "count=%d" % script.count(probe))
    check("script-one-end", script.count("@@END") == 1, "")
    check("script-single-shape", "ssh " not in script, "collector must not call ssh itself")

    # --- every key from the recorded fixture --------------------------------
    parsed = parse_collector(recorded, "omarchylink")
    mac, tunnel, kanban, devin, reasons = (
        parsed["mac"], parsed["tunnel"], parsed["kanban"], parsed["devin"], parsed["reasons"]
    )
    check("batt-percent", isinstance(mac["battery"]["percent"], int), str(mac["battery"]))
    check("batt-state", mac["battery"]["state"] in ("charging", "charged", "discharging"), str(mac["battery"]["state"]))
    check("batt-power-source", mac["battery"]["power_source"] in ("AC Power", "Battery Power"), str(mac["battery"]["power_source"]))
    check("batt-remaining", isinstance(mac["battery"]["remaining"], str), str(mac["battery"]["remaining"]))
    check("batt-present", mac["battery"]["present"] is True, str(mac["battery"]["present"]))
    check("load-triple", isinstance(mac["load"]["avg"], list) and len(mac["load"]["avg"]) == 3, str(mac["load"]["avg"]))
    check("load-cores", mac["load"]["cores"] == 12, str(mac["load"]["cores"]))
    check(
        "load-frac",
        mac["load"]["load1_frac"] is not None
        and abs(mac["load"]["load1_frac"] - mac["load"]["avg"][0] / 12.0) < 0.001,
        str(mac["load"]["load1_frac"]),
    )
    check("mem-pressure", mac["memory"]["pressure"] in ("normal", "warning", "critical"), str(mac["memory"]))
    check("mem-raw", mac["memory"]["pressure_raw"] in (1, 2, 4), str(mac["memory"]["pressure_raw"]))
    check("mem-free-pct", isinstance(mac["memory"]["free_pct"], int), str(mac["memory"]["free_pct"]))
    check("temp-null-with-reason", mac["soc_temp_c"] is None and "mac.soc_temp_c" in reasons, str(mac["soc_temp_c"]))
    check("uptime", isinstance(mac["uptime_s"], int) and mac["uptime_s"] > 0, str(mac["uptime_s"]))
    check("uptime-human", isinstance(mac["uptime_human"], str), str(mac["uptime_human"]))
    check("tunnel-up", tunnel["up"] is True, str(tunnel))
    check("tunnel-rtt", isinstance(tunnel["rtt_ms"], float), str(tunnel["rtt_ms"]))
    check("tunnel-route", tunnel["route"] in ("direct", "relay"), str(tunnel["route"]))
    check("tunnel-peer", tunnel["peer"] == "omarchylink", str(tunnel["peer"]))
    check("kanban-count", kanban["running"] == len(kanban["items"]) and kanban["running"] > 0, str(kanban["running"]))
    check(
        "kanban-item-keys",
        all(set(item) == {"id", "title", "assignee", "started_at", "age_s"} for item in kanban["items"]),
        str(kanban["items"][:1]),
    )
    check("devin-count", devin["running"] == len(devin["items"]), str(devin["running"]))
    check("canvas-none", "canvas" not in json.dumps(parsed).lower(), "unexpected key")

    # --- ping shapes --------------------------------------------------------
    direct_ipv6 = parse_ping(
        "pong from omarchylink (100.104.64.3) via [fd7a:115c:a1e0::1]:41641 in 7ms",
        "omarchylink",
        {},
    )
    check(
        "ping-ipv6-direct",
        direct_ipv6["route"] == "direct" and direct_ipv6["rtt_ms"] == 7.0,
        str(direct_ipv6),
    )
    two_lines = parse_ping(
        "pong from omarchylink (100.104.64.3) via DERP(ams) in 92ms\n"
        "pong from omarchylink (100.104.64.3) via 192.168.0.112:41641 in 4ms",
        "omarchylink",
        {},
    )
    check(
        "ping-last-line-wins",
        two_lines["rtt_ms"] == 4.0 and two_lines["route"] == "direct",
        str(two_lines),
    )
    relay_only = parse_ping("pong from omarchylink via DERP(ams) in 92ms", "omarchylink", {})
    check("ping-relay", relay_only["route"] == "relay", str(relay_only))
    failed_ping = parse_ping('error looking up IP of "nope": no such host', "nope", {})
    check(
        "ping-lookup-error",
        failed_ping["up"] is False and failed_ping["rtt_ms"] is None,
        str(failed_ping),
    )

    # --- fixture mode through the CLI ---------------------------------------
    code, payload, stdout, stderr = _cli(["--fixture", fixture, "--json"])
    check("fixture-exit-0", code == 0, "exit=%s %s" % (code, stderr.strip()[:200]))
    check("fixture-one-line", stdout.strip().count("\n") == 0, "stdout is not one line")
    check("fixture-ok", (payload or {}).get("ok") is True, str(payload)[:200])
    check("fixture-source", (payload or {}).get("source") == "mac_link", str((payload or {}).get("source")))
    check("fixture-mode", (payload or {}).get("mode") == "fixture", str((payload or {}).get("mode")))
    check("fixture-generated-at", str((payload or {}).get("generated_at", "")).endswith("Z"), str((payload or {}).get("generated_at")))
    check("fixture-collected-at", str((payload or {}).get("collected_at", "")).endswith("Z"), str((payload or {}).get("collected_at")))
    check("fixture-cached-false", (payload or {}).get("cached") is False, str((payload or {}).get("cached")))
    check(
        "fixture-no-home-path",
        HOME not in json.dumps(payload),
        "absolute home path in payload",
    )

    # --- cache: two calls inside 10 s run zero collectors -------------------
    root = tempfile.mkdtemp(prefix="f1-mac-link-", dir=os.environ.get("TMPDIR"))
    state = os.path.join(root, "mac_link.json")
    calls = []

    def fake_runner(script_text, timeout):
        calls.append(script_text)
        return recorded, "", 0

    fake_args = types.SimpleNamespace(
        host="local", host_name=None, peer="omarchylink", timeout=5.0, state=state, fixture=None
    )
    first = build(fake_args, runner=fake_runner)
    second = build(fake_args, runner=fake_runner)
    check("cache-one-collector-for-two-calls", len(calls) == 1, "%d collectors" % len(calls))
    check("cache-first-live", first.get("cached") is False and first.get("cache_age_s") == 0.0, str(first.get("cached")))
    check("cache-second-hit", second.get("cached") is True, str(second.get("cached")))
    check("cache-second-age", isinstance(second.get("cache_age_s"), float) and second["cache_age_s"] <= 10.0, str(second.get("cache_age_s")))
    check("cache-file-written", os.path.isfile(state), "no cache file")
    check("cache-keeps-values", (second.get("kanban") or {}).get("running") == kanban["running"], str((second.get("kanban") or {}).get("running")))
    check(
        "cache-timestamp-preserved",
        second.get("collected_at") == first.get("collected_at"),
        "%s vs %s" % (second.get("collected_at"), first.get("collected_at")),
    )

    # Age the cache past the TTL: the next call must collect again.
    with open(state, "r", encoding="utf-8") as handle:
        aged = json.load(handle)
    aged["collected_epoch"] = aged["collected_epoch"] - (CACHE_TTL_S + 5)
    with open(state, "w", encoding="utf-8") as handle:
        json.dump(aged, handle)
    third = build(fake_args, runner=fake_runner)
    check("cache-expiry-recollects", len(calls) == 2 and third.get("cached") is False, "%d collectors" % len(calls))

    # --- a runner that returns nothing is an answer, not a crash -----------
    blank_state = os.path.join(root, "blank-state.json")

    def blank_runner(script_text, timeout):
        return "", "connect: no route to host", 255

    blank_args = types.SimpleNamespace(
        host="local", host_name=None, peer="omarchylink", timeout=2.0, state=blank_state, fixture=None
    )
    blank_problem = None
    try:
        build(blank_args, runner=blank_runner)
    except Missing as exc:
        blank_problem = exc
    check(
        "empty-runner-is-missing",
        blank_problem is not None
        and "exit 255" in blank_problem.reason
        and "no route to host" in blank_problem.reason,
        str(blank_problem),
    )
    check("empty-runner-writes-no-cache", not os.path.exists(blank_state), "a failed collection was cached")

    # --- absence path -------------------------------------------------------
    empty = os.path.join(root, "empty.txt")
    with open(empty, "w", encoding="utf-8") as handle:
        handle.write("")
    code, payload, _out, _err = _cli(["--fixture", empty, "--json"])
    check("empty-exit-0", code == 0, "exit=%s" % code)
    check("empty-ok-false", (payload or {}).get("ok") is False, str(payload))
    check("empty-kind", (payload or {}).get("kind") == "missing", str((payload or {}).get("kind")))
    check("empty-reason", bool((payload or {}).get("reason")), str(payload))

    markers_only = os.path.join(root, "markers.txt")
    with open(markers_only, "w", encoding="utf-8") as handle:
        handle.write("@@BATT\n@@LOAD\n@@END\n")
    code, payload, _out, _err = _cli(["--fixture", markers_only, "--json"])
    check("markers-only-ok-false", (payload or {}).get("ok") is False, str(payload))

    partial = os.path.join(root, "partial.txt")
    with open(partial, "w", encoding="utf-8") as handle:
        handle.write(
            "@@NOW\n1792710500\n@@BATT\nNow drawing from 'AC Power'\n"
            " -InternalBattery-0 (id=1)\t72%; charging; 2:14 remaining present: true\n@@END\n"
            )
    code, payload, _out, _err = _cli(["--fixture", partial, "--json"])
    check("partial-exit-0", code == 0, "exit=%s" % code)
    check("partial-ok-true", (payload or {}).get("ok") is True, str(payload)[:200])
    partial_mac = (payload or {}).get("mac") or {}
    check("partial-batt", (partial_mac.get("battery") or {}).get("percent") == 72, str(partial_mac.get("battery")))
    check("partial-load-null", (partial_mac.get("load") or {}).get("avg") is None, str(partial_mac.get("load")))
    check("partial-load-reason", "mac.load" in ((payload or {}).get("reasons") or {}), str((payload or {}).get("reasons")))
    check("partial-uptime-null", partial_mac.get("uptime_s") is None, str(partial_mac.get("uptime_s")))
    check("partial-tunnel-null", ((payload or {}).get("tunnel") or {}).get("rtt_ms") is None, str((payload or {}).get("tunnel")))

    # --- caller errors exit 2 ----------------------------------------------
    code, _payload, _out, err = _cli(["--fixture", os.path.join(root, "nope.txt"), "--json"])
    check("missing-fixture-exit-2", code == 2, "exit=%s" % code)
    check("missing-fixture-one-line", len(err.strip().splitlines()) == 1, err.strip()[:200])
    code, _payload, _out, _err = _cli(["--host", "elsewhere", "--json"])
    check("bad-host-exit-2", code == 2, "exit=%s" % code)

    # --- ssh runner shape (never invoked here) ------------------------------
    argv = [
        "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=4",
        "-o", "StrictHostKeyChecking=accept-new", "mac", "SCRIPT",
    ]
    check("ssh-argv-single-round-trip", argv[-1] == "SCRIPT" and argv.count("mac") == 1, str(argv))
    check("self-check-no-ssh-run", not os.path.exists(os.path.join(root, "ssh")), "")

    print("\nself-check %s: %d passed, %d failed" % ("ok" if not bad else "FAILED", len(ok), len(bad)))
    if bad:
        print("failed: %s" % ", ".join(bad))
    return 0 if not bad else 1


# ----------------------------------------------------------------------- cli


def parse(argv):
    parser = argparse.ArgumentParser(description="Mac link feed for the v5 HUD.")
    parser.add_argument("--host", default="local", help="local or ssh:<host> (default local)")
    parser.add_argument(
        "--peer",
        default=os.environ.get("NEXUS_HUD_PEER") or DEFAULT_PEER,
        help="tailscale peer for the tunnel RTT (default %s)" % DEFAULT_PEER,
    )
    parser.add_argument("--fixture", metavar="PATH", help="read a recorded collector output")
    parser.add_argument("--json", action="store_true", help="emit one compact JSON line")
    parser.add_argument(
        "--state", default=DEFAULT_CACHE, help="cache file (default %s)" % DEFAULT_CACHE
    )
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S, help="collector timeout seconds (default %s)" % DEFAULT_TIMEOUT_S)
    parser.add_argument("--self-check", action="store_true", help="run the built-in checks and exit")
    args = parser.parse_args(argv)

    if args.host == "local":
        args.host_name = None
    elif args.host.startswith("ssh:") and len(args.host) > 4:
        args.host_name = args.host[4:].strip()
        if not args.host_name:
            parser.error("--host ssh: needs a host name")
    else:
        parser.error("--host must be 'local' or 'ssh:<host>', got %r" % args.host)
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    return args


def main(argv=None):
    args = parse(argv)
    if args.self_check:
        return self_check(args)
    if args.fixture is not None:
        target = os.path.expanduser(args.fixture)
        if not os.path.exists(target):
            sys.stderr.write("mac_link: --fixture file not found: %s\n" % tilde(target))
            return EXIT_PROGRAMMING
    mode = "fixture" if args.fixture else "live"
    try:
        payload = build(args)
    except DataProblem as exc:
        emit(failure(SOURCE, mode, exc), bool(args.json))
        return EXIT_OK
    except (KeyboardInterrupt, SystemExit):
        raise
    except BaseException as exc:
        emit(
            {
                "ok": False,
                "source": SOURCE,
                "mode": mode,
                "generated_at": iso_now(),
                "reason": tilde_text("programming error: %s: %s" % (type(exc).__name__, exc)),
                "kind": "programming",
            },
            bool(args.json),
        )
        return EXIT_PROGRAMMING
    emit(payload, bool(args.json))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
