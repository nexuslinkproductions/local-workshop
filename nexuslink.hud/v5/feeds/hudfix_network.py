#!/usr/bin/env python3
"""hudfix_network.py - network actions for the hudfix maintenance CLI (HUD v5 F8e).

Five typed actions for the Network utility view. Every one is ``read`` or
``safe``: this module never changes routing, addresses, DNS servers or the VPN.
The commands it runs are a closed allowlist (ping, netstat, ifconfig, scutil,
tailscale status, and for the one safe action dscacheutil, killall -HUP and
resolvectl), asserted in ``--self-check``.

Exported surface (what F8a's ``hudfix.py`` imports)::

    ACTIONS = {"<name>": {"class": ..., "doc": ..., "plan": callable,
                          "run": callable, "linux_only": bool}}

    plan(ctx=None)          -> the dry-run object: the exact argv, items,
                               bytes (0, nothing is deleted), what run would do
    run(ctx=None, confirm=None) -> performs it, or returns the plan when
                               ctx["dry_run"] is true

``ctx`` is optional and may be a dict or an object with attributes. Keys read:
``fixture`` (path; no host state at all when set), ``runner`` (callable
``(argv, timeout) -> (stdout, stderr, code)``; replaces subprocess, used by the
self-check), ``now`` (callable returning epoch seconds), ``dry_run`` (bool),
``host`` ("mac" or "linux"), ``state_dir`` / ``cache_dir`` / ``cache_path``,
``tailnet_gateway`` (host override), ``target`` (jitter target override),
``dns_name``, ``cache`` (bool), ``timeout_scale`` (float, 0.01 to 3600,
multiplies every command timeout; the CLI refuses anything else with exit 2).
Unknown keys are ignored, a missing key takes
the live default. Nothing here imports F8a.

Actions
  network.latency      read  5 pings to the tailnet gateway and 5 to 1.1.1.1,
                             mean rtt and ping's own mdev, loss, cached 10 s
  network.jitter       read  20 pings to 1.1.1.1 at 0.5 s spacing, mean absolute
                             difference between consecutive rtts, p95, a one
                             word verdict; cached 10 s; thresholds in
                             HUDFIX_NETWORK.md and in every payload
  network.route        read  default route, interface, tunnel address, DNS
                             servers (netstat -rn, ifconfig, scutil --dns on
                             macOS; fixture everywhere else)
  network.flush-dns    safe  macOS: dscacheutil -flushcache then killall -HUP
                             mDNSResponder. Linux: resolvectl flush-caches.
                             Self healing, no confirmation, nothing deleted;
                             live only, refuses to run in fixture mode
  network.connectivity read  four checks, each with its own boolean and a
                             reason when false: gateway reachable, public
                             reachable, DNS resolves, tunnel up

Contract (cards/feeds-brief.md)
  stdlib only, one JSON object on stdout, UTC ISO timestamps, ``--json`` is one
  compact line, ``--fixture`` touches no host state at all (no ping, no
  netstat, no clock derived age, no cache file), a missing file the caller
  named is exit 2, everything else exits 0 including honest absence
  (``{"ok": false, "reason": ...}``). No secrets, no absolute home paths.

Ping parser: F3's ``game_mode.py`` on branch ``v5/f3-gamemode`` (head
33903de) carries the same parser but was not merged into ``v5/main-deck`` when
this module was written, so ``ping_argv``, ``parse_ping``, ``net_entry`` and
``null_entry`` are copied from it. One key is renamed: F3 publishes the ping
summary's mdev/stddev as ``jitter_ms``, which is not jitter; here that value is
``mdev_ms`` everywhere, and mean absolute difference is the only thing called
jitter. The other keys (``rtt_ms``, ``loss``, ``samples``, ``host``,
``reason``) are unchanged, so the two readers still agree about the same ping.
When F3 merges, F8a can import it and delete the copy.

Self-check: ``python3 hudfix_network.py --self-check`` (no arguments).

Doc, thresholds, the "not offered" list and the recording recipe:
``HUDFIX_NETWORK.md`` next to this file.
"""

from __future__ import annotations

import argparse
import datetime
import json
import math
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

PROGRAM = "hudfix_network.py"

CLASSES = ("read", "safe", "reversible", "destructive")
OWN_CLASSES = ("read", "safe")

PUBLIC_HOST = "1.1.1.1"
DEFAULT_DNS_NAME = "example.com"
DEFAULT_CACHE_DIR = "~/.local/state/nexuslink"
LATENCY_CACHE_NAME = "hudfix_network_latency.json"
JITTER_CACHE_NAME = "hudfix_network_jitter.json"
ROUTE_CACHE_NAME = "hudfix_network_route.json"
CONNECTIVITY_CACHE_NAME = "hudfix_network_connectivity.json"
CACHE_TTL_S = 10.0            # feeds-brief: a read is never cached for less
LATENCY_COUNT = 5
JITTER_COUNT = 20
JITTER_INTERVAL_S = 0.5        # 20 samples in about 9.5 s; 1 s would be 19 s
CONNECTIVITY_COUNT = 3
PING_TIMEOUT_S = 25.0
JITTER_TIMEOUT_S = 40.0
PROBE_TIMEOUT_S = 10.0
DNS_TIMEOUT_S = 3.0

# --timeout-scale is a documented multiplier, not an unbounded one: the top of
# the range is 3600, so 40 s becomes 40 h, still far under the poll timeout
# that used to overflow at scale 1000000.
TIMEOUT_SCALE_MIN = 0.01
TIMEOUT_SCALE_MAX = 3600.0

FIXTURE_MAIN = "network.json"
FIXTURE_MAIN_DOWN = "network_down.json"

# verdict thresholds, also emitted in every jitter payload and quoted in the doc
STEADY_MEAN_ABS_MS = 2.0
STEADY_P95_MS = 5.0
UNSTABLE_MEAN_ABS_MS = 8.0
UNSTABLE_P95_MS = 20.0
UNSTABLE_LOSS_PCT = 5.0

# Tailscale's own reserved ranges: the CGNAT block it hands out, quad-100 for
# MagicDNS, and the fd7a:115c:a1e0::/48 ULA it uses for the same purpose.
TAILNET_V4 = "100.64.0.0/10"
TAILNET_V6_PREFIX = "fd7a:115c:a1e0:"

# a plan may only ever name one of these binaries, and the self-check proves it
ALLOWED_BINARIES = frozenset([
    "ping", "netstat", "ifconfig", "scutil", "tailscale",
    "dscacheutil", "killall", "resolvectl",
])

FORBIDDEN_ARGV_TOKENS = (
    "route add", "route delete", "route change", "networksetup",
    "pfctl", "tailscale up", "tailscale down", "tailscale set",
    "ifconfig en", "netcfg", "ip route add", "ip route del",
)


# --------------------------------------------------------------------------
# small utilities
# --------------------------------------------------------------------------

def utc_now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def host_platform():
    if sys.platform.startswith("linux"):
        return "linux"
    if sys.platform == "darwin":
        return "mac"
    return sys.platform


def display_path(value):
    """~-relative path, so the payload never carries an absolute home path."""
    try:
        path = Path(str(value))
        rel = path.relative_to(Path.home())
        return "~/" + str(rel)
    except (ValueError, TypeError):
        return str(value)


def _num(value):
    if value is None:
        return None
    return int(value) if float(value).is_integer() else round(float(value), 1)


def short(text, limit=160):
    flat = " ".join((text or "").split())
    return flat if len(flat) <= limit else flat[: limit - 3] + "..."


def in_tailnet(address):
    """True for an address from one of Tailscale's own ranges."""
    address = (address or "").strip().strip("%")
    if not address:
        return False
    if address.startswith(TAILNET_V6_PREFIX):
        return True
    try:
        parts = [int(piece) for piece in address.split(".")]
    except (TypeError, ValueError):
        return False
    if len(parts) != 4 or any(piece < 0 or piece > 255 for piece in parts):
        return False
    return parts[0] == 100 and 64 <= parts[1] <= 127


# --------------------------------------------------------------------------
# context
# --------------------------------------------------------------------------

def _ctx_value(ctx, key, default=None):
    """Read one key from a dict-like or attribute-like ctx. None means absent."""
    if ctx is None:
        return default
    if isinstance(ctx, dict):
        value = ctx.get(key, default)
    else:
        value = getattr(ctx, key, default)
    return default if value is None else value


def _ctx(ctx=None, **overrides):
    ctx = default_ctx() if ctx is None else ctx
    if overrides:
        merged = dict(ctx) if isinstance(ctx, dict) else _ctx_as_dict(ctx)
        merged.update(overrides)
        return merged
    return ctx


def _ctx_as_dict(ctx):
    out = {}
    for key in ("fixture", "runner", "now", "dry_run", "host", "state_dir",
                "cache_dir", "cache_path", "tailnet_gateway", "target",
                "dns_name", "cache", "ping_cmd"):
        value = _ctx_value(ctx, key)
        if value is not None:
            out[key] = value
    return out


def default_ctx():
    return {
        "fixture": None,
        "runner": None,
        "now": time.time,
        "dry_run": False,
        "host": host_platform(),
        "state_dir": DEFAULT_CACHE_DIR,
        "cache": True,
        "ping_cmd": None,
    }


def _now(ctx):
    fn = _ctx_value(ctx, "now")
    try:
        return float(fn() if callable(fn) else fn)
    except (TypeError, ValueError):
        return time.time()


def _host(ctx):
    value = _ctx_value(ctx, "host")
    return str(value).lower() if value else host_platform()


def _fixture_path(ctx):
    value = _ctx_value(ctx, "fixture")
    if not value:
        return None
    path = Path(str(value))
    if path.is_dir():
        main = path / FIXTURE_MAIN
        return main if main.exists() else path
    return path


# --------------------------------------------------------------------------
# fixture loading
# --------------------------------------------------------------------------

class FixtureProblem(Exception):
    """A fixture the caller named is missing or malformed.

    A missing file or directory is a usage error (exit 2). A file that exists
    but cannot be parsed is an answer: ``ok: false`` with a reason, exit 0,
    the same as any other honest absence, and never a silent fall back to live.
    """

    def __init__(self, reason, kind="malformed"):
        super(FixtureProblem, self).__init__(reason)
        self.reason = str(reason)
        self.kind = kind


def load_fixture(ctx):
    """The recorded fixture object. Raises FixtureProblem when unusable."""
    path = _fixture_path(ctx)
    if path is None:
        raise FixtureProblem("no fixture path", "missing")
    if path.is_dir():
        main = path / FIXTURE_MAIN
        if not main.exists():
            raise FixtureProblem("fixture directory has no %s: %s"
                                 % (FIXTURE_MAIN, display_path(path)), "missing")
        path = main
    if not path.exists():
        raise FixtureProblem("fixture does not exist: %s" % display_path(path), "missing")
    try:
        with open(str(path), "r", encoding="utf-8") as handle:
            obj = json.load(handle)
    except OSError as exc:
        # It exists but cannot be read: that is unreadable input, not a usage error.
        raise FixtureProblem("fixture unreadable: %s" % exc, "unreadable")
    except ValueError as exc:
        raise FixtureProblem("fixture is not JSON: %s" % exc, "malformed")
    if not isinstance(obj, dict):
        raise FixtureProblem("fixture top level is not an object", "malformed")
    return obj


def fixture_commands(fixture):
    commands = fixture.get("commands")
    return commands if isinstance(commands, dict) else {}


def fixture_text(fixture, key):
    value = fixture_commands(fixture).get(key)
    return value if isinstance(value, str) else None


# --------------------------------------------------------------------------
# command runner
# --------------------------------------------------------------------------

def validate_timeout_scale(value):
    """(scale, reason). The one gate for ``--timeout-scale``, called by the CLI.

    The multiplier exists for slow hosts, so its range is stated: 0.01 to 3600.
    Anything else, NaN and the infinities included, is a bad argument and is
    refused with exit 2 before a ctx is built. That matters: 1000000 times a
    10 s base overflows the poll timeout inside ``subprocess.run`` with an
    ``OverflowError``, and ``inf`` cannot be converted to an integer at all, so
    the value must never reach the conversion.
    """
    try:
        scale = float(value)
    except (TypeError, ValueError):
        return None, ("--timeout-scale must be a number between %g and %g"
                      % (TIMEOUT_SCALE_MIN, TIMEOUT_SCALE_MAX))
    if not math.isfinite(scale):
        return None, ("--timeout-scale must be finite, between %g and %g"
                      % (TIMEOUT_SCALE_MIN, TIMEOUT_SCALE_MAX))
    if scale < TIMEOUT_SCALE_MIN or scale > TIMEOUT_SCALE_MAX:
        return None, ("--timeout-scale must be between %g and %g, got %g"
                      % (TIMEOUT_SCALE_MIN, TIMEOUT_SCALE_MAX, scale))
    return scale, None


def timeout_for(ctx, base):
    """``base`` seconds times ``ctx["timeout_scale"]``: the one place it is read.

    ``--timeout-scale`` exists for slow hosts, so it multiplies every command
    timeout and nothing else. The CLI refuses anything outside the documented
    range before a ctx is ever built (``validate_timeout_scale``); a ctx built
    by hand with no scale, a non numeric one or one outside that range leaves
    the base alone, so no timeout can be infinite or overflow the poll call.
    """
    scale = _ctx_value(ctx, "timeout_scale", 1.0)
    try:
        scale = float(scale)
    except (TypeError, ValueError):
        return base
    if not math.isfinite(scale) or scale < TIMEOUT_SCALE_MIN or scale > TIMEOUT_SCALE_MAX:
        return base
    return round(base * scale, 4)


def trace_begin(ctx):
    """Start a run trace on ``ctx`` and return it.

    ``_run`` appends ``{"argv": [...], "exit": code}`` to this list for every
    command it issues, and a payload publishes the list itself as ``commands``,
    so the argv a run reports cannot drift from the argv the runner was called
    with. It lives on the ctx because latency calls ``_run`` from two probe
    threads and both must reach the same list; each operation replaces it
    rather than appending, so a reused ctx never carries a stale trace.
    """
    trace = []
    if isinstance(ctx, dict):
        ctx["_trace"] = trace
    else:
        setattr(ctx, "_trace", trace)
    return trace


def trace_of(ctx):
    trace = _ctx_value(ctx, "_trace")
    return trace if isinstance(trace, list) else None


def _run(argv, ctx, timeout):
    """(stdout, stderr, exit code). An injected runner replaces subprocess.

    The argv is recorded here, once, after the call, so every command a run
    issues lands in the trace whether it came from subprocess or an injected
    runner, and whether it succeeded or not.
    """
    argv = [str(piece) for piece in argv]
    out, err, code = _run_once(argv, ctx, timeout)
    trace = trace_of(ctx)
    if trace is not None:
        trace.append({"argv": list(argv), "exit": code})
    return out, err, code


def _run_once(argv, ctx, timeout):
    timeout = timeout_for(ctx, timeout)
    runner = _ctx_value(ctx, "runner")
    if runner is not None:
        try:
            out, err, code = runner(list(argv), timeout)
        except Exception as exc:  # a runner that raises must not kill the tick
            return "", "runner failed: %s" % exc, 126
        return _text(out), _text(err), _code(code)
    try:
        proc = subprocess.run(list(argv), stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=timeout)
        return _text(proc.stdout), _text(proc.stderr), int(proc.returncode)
    except FileNotFoundError:
        return "", "command not found: %s" % argv[0], 127
    except subprocess.TimeoutExpired:
        return "", "timed out after %ss" % timeout, 124
    except OSError as exc:
        return "", "could not run %s: %s" % (argv[0], exc), 126


def _text(value):
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return str(value)


def _code(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def _argv_list(commands):
    """Flatten plan command entries to argv lists for the allowlist check."""
    out = []
    for item in commands or []:
        argv = item.get("argv") if isinstance(item, dict) else item
        if isinstance(argv, list) and argv:
            out.append([str(piece) for piece in argv])
    return out


# --------------------------------------------------------------------------
# cache (atomic, 10 s floor, keyed on the targets)
# --------------------------------------------------------------------------

def _cache_path(ctx, name):
    explicit = _ctx_value(ctx, "cache_path")
    if explicit:
        return Path(str(explicit))
    directory = _ctx_value(ctx, "cache_dir") or _ctx_value(ctx, "state_dir")
    return Path(str(directory or DEFAULT_CACHE_DIR)).expanduser() / name


def _cache_enabled(ctx):
    # Fixture mode never touches the cache: no read, no write, whatever
    # --cache-path or --state-dir says. A recording has no clock-derived age
    # and two fixture runs must answer the same numbers.
    if _fixture_path(ctx) is not None:
        return False
    return bool(_ctx_value(ctx, "cache", True))


def atomic_write_json(path, payload):
    path = Path(str(path))
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temp = tempfile.mkstemp(dir=str(path.parent), prefix=".hudfix-", suffix=".tmp")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, ensure_ascii=False, sort_keys=True)
            stream.write("\n")
        os.replace(temp, str(path))
    except Exception:
        try:
            os.unlink(temp)
        except OSError:
            pass
        raise


def cache_get(ctx, name, key):
    """(data, age_s) when a fresh entry matches the key, else (None, None)."""
    if not _cache_enabled(ctx):
        return None, None
    path = _cache_path(ctx, name)
    try:
        with open(str(path), "r", encoding="utf-8") as handle:
            entry = json.load(handle)
    except (OSError, ValueError):
        return None, None
    if not isinstance(entry, dict) or entry.get("key") != key:
        return None, None
    try:
        cached_at = float(entry.get("cached_at"))
    except (TypeError, ValueError):
        return None, None
    age = _now(ctx) - cached_at
    if age < 0 or age > CACHE_TTL_S:
        return None, None
    data = entry.get("data")
    return (data if isinstance(data, dict) else None), round(age, 1)


def cache_put(ctx, name, key, data):
    if not _cache_enabled(ctx):
        return None
    path = _cache_path(ctx, name)
    try:
        atomic_write_json(path, {"key": key, "cached_at": _now(ctx), "data": data})
    except OSError:
        return None
    return display_path(path)


def cache_note(ctx, name, key):
    """Plan-time cache state. Fixture mode does not read the cache file."""
    if not _cache_enabled(ctx):
        return {"enabled": False,
                "reason": "fixture run: no host state, no cache file"}
    data, age = cache_get(ctx, name, key)
    return {"enabled": True,
            "path": display_path(_cache_path(ctx, name)),
            "ttl_s": CACHE_TTL_S,
            "would_hit": data is not None,
            "age_s": age}


# --------------------------------------------------------------------------
# ping parsing (copied from F3 game_mode.py, same key names)
# --------------------------------------------------------------------------

def ping_argv(target, count=LATENCY_COUNT, interval=None, ping_cmd=None):
    cmd = [ping_cmd or "ping"]
    if host_platform() == "linux":
        # iputils: -W is SECONDS.
        cmd += ["-c", str(count), "-W", "1"]
    else:
        # BSD/macOS: -W is MILLISECONDS.
        cmd += ["-c", str(count), "-W", "1000"]
    if interval:
        cmd += ["-i", str(interval)]
    cmd.append(target)
    return cmd


PING_HOST_ERRORS = ("cannot resolve", "unknown host", "name or service not known",
                    "network is unreachable", "no route to host", "sendto: ")


def ping_host_error(text):
    """The resolver's own line, so a bad target says why. None when ping said nothing."""
    for line in (text or "").splitlines():
        low = line.lower()
        if any(needle in low for needle in PING_HOST_ERRORS):
            return short(line, 120)
    return None


def parse_ping(text):
    """mean rtt and mdev/stddev from a ping -c N capture. Never invents a number.

    The summary's mdev (macOS) or stddev (Linux) is published as ``mdev_ms``.
    It is a standard deviation, not jitter; the jitter statistic this module
    reports is the mean absolute difference between consecutive rtts.
    """
    out = {"rtt_ms": None, "mdev_ms": None, "loss": None, "samples": 0, "reason": None}
    if not text:
        out["reason"] = "no ping output"
        return out

    loss_m = re.search(r"([\d.]+)%\s+packet loss", text)
    recv_m = re.search(r"(\d+)\s+(?:packets\s+)?received", text)
    trans_m = re.search(r"(\d+)\s+packets transmitted", text)
    times = re.findall(r"time[=<]([\d.]+)\s*ms", text)

    if loss_m:
        out["loss"] = _num(float(loss_m.group(1)))
    if recv_m:
        out["samples"] = int(recv_m.group(1))
    elif times:
        out["samples"] = len(times)

    stats = re.search(
        r"(?:rtt|round-trip)\s+min/avg/max/(?:mdev|stddev)\s*=\s*"
        r"([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)", text)
    if stats:
        out["rtt_ms"] = round(float(stats.group(2)), 2)
        out["mdev_ms"] = round(float(stats.group(4)), 2)
    elif times:
        vals = [float(v) for v in times]
        mean = sum(vals) / len(vals)
        var = sum((v - mean) ** 2 for v in vals) / len(vals)
        out["rtt_ms"] = round(mean, 2)
        out["mdev_ms"] = round(var ** 0.5, 2)

    if out["loss"] is None and trans_m and recv_m:
        trans = int(trans_m.group(1))
        if trans:
            out["loss"] = _num(100.0 * (trans - int(recv_m.group(1))) / trans)

    if out["rtt_ms"] is None:
        if out["loss"] == 100:
            out["reason"] = "no replies"
        else:
            out["reason"] = "no rtt in ping output"
        detail = ping_host_error(text)
        if detail:
            out["reason"] = "%s: %s" % (out["reason"], detail)
    return out


def net_entry(host, parsed):
    entry = {"host": host, "rtt_ms": parsed.get("rtt_ms"),
             "mdev_ms": parsed.get("mdev_ms"), "loss": parsed.get("loss")}
    if parsed.get("samples"):
        entry["samples"] = parsed["samples"]
    if parsed.get("reason"):
        entry["reason"] = parsed["reason"]
    return entry


def null_entry(host, reason):
    return {"host": host, "rtt_ms": None, "mdev_ms": None, "loss": None,
            "reason": reason or "not measured"}


def ping_target(text):
    """The target as ping itself printed it: ``PING 1.1.1.1 (1.1.1.1)``."""
    match = re.search(r"(?m)^PING\s+(\S+?)(?:\s+\(([^)]+)\))?:", text or "")
    if not match:
        return None
    return match.group(2) or match.group(1)


def parse_ping_times(text):
    """Every per-reply rtt from a ping capture, in reply order."""
    return [float(value) for value in re.findall(r"time[=<]([\d.]+)\s*ms", text or "")]


def parse_ping_counts(text):
    """(transmitted, received). Either may be None."""
    trans = re.search(r"(\d+)\s+packets transmitted", text or "")
    recv = re.search(r"(\d+)\s+(?:packets\s+)?received", text or "")
    return (int(trans.group(1)) if trans else None,
            int(recv.group(1)) if recv else None)


def measure_ping(target, count, ctx, timeout, interval=None):
    """(entry, argv, stderr, exit). A missing ping is an entry with a reason."""
    argv = ping_argv(target, count, interval, _ctx_value(ctx, "ping_cmd"))
    out, err, code = _run(argv, ctx, timeout)
    parsed = parse_ping(out)
    if parsed.get("rtt_ms") is None and not parsed.get("reason"):
        parsed["reason"] = "no measurement"
    if parsed.get("rtt_ms") is None and err and not parsed.get("reason"):
        parsed["reason"] = short(err, 120)
    if parsed.get("rtt_ms") is None and code in (124, 127, 126):
        parsed["reason"] = short(err or "exit %d" % code, 120)
    return net_entry(target, parsed), argv, err, code


# --------------------------------------------------------------------------
# route and DNS parsing (macOS live, fixture everywhere)
# --------------------------------------------------------------------------

IFACE_RE = re.compile(r"^([A-Za-z0-9_.-]+):\s+flags=([0-9a-fA-F]+)<([^>]*)>\s+mtu\s+(\d+)")


def parse_interfaces(text):
    """name -> {up, running, mtu, inet, inet6, peer} from ``ifconfig``."""
    table = {}
    current = None
    for line in (text or "").splitlines():
        match = IFACE_RE.match(line)
        if match:
            flags = match.group(3).upper().split(",")
            current = {
                "name": match.group(1),
                "up": "UP" in flags,
                "running": "RUNNING" in flags,
                "mtu": int(match.group(4)),
                "inet": [],
                "inet6": [],
            }
            table[current["name"]] = current
            continue
        if current is None or not line.startswith(("\t", " ")):
            continue
        stripped = line.strip()
        if stripped.startswith("inet "):
            body = stripped[5:]
            peer = None
            if "-->" in body:
                left, right = body.split("-->", 1)
                body = left
                peer = right.split()[0] if right.split() else None
            parts = body.split()
            if parts:
                current["inet"].append({"address": parts[0], "peer": peer})
        elif stripped.startswith("inet6 "):
            parts = stripped[6:].split()
            if parts:
                current["inet6"].append({"address": parts[0].split("%")[0]})
    return table


def parse_default_routes(text):
    """Every ``default`` row from ``netstat -rn -f inet``, in table order."""
    rows = []
    for line in (text or "").splitlines():
        parts = line.split()
        if len(parts) < 4 or parts[0] != "default":
            continue
        gateway, flags, netif = parts[1], parts[2], parts[3]
        if not re.match(r"^[A-Za-z0-9#._-]+$", gateway) or not re.match(r"^[A-Za-z0-9#._-]+$", netif):
            continue
        if not re.match(r"^[A-Za-z]+$", flags):
            continue
        gateway_is_address = bool(re.match(r"^\d{1,3}(\.\d{1,3}){3}$", gateway))
        rows.append({
            "gateway": gateway,
            "interface": netif,
            "flags": flags,
            "usable": gateway_is_address and "G" in flags and "U" in flags,
            "link_level": gateway.startswith("link#"),
        })
    return rows


def parse_scutil_dns(text):
    """DNS servers with their interface plus search domains from ``scutil --dns``."""
    resolvers = []
    current = None
    for raw in (text or "").splitlines():
        line = raw.rstrip()
        stripped = line.strip()
        if stripped.startswith("resolver #"):
            if current is not None:
                resolvers.append(current)
            current = {"index": stripped.split("#", 1)[1].strip(),
                       "nameservers": [], "search": [], "if_index": None,
                       "iface": None, "flags": None, "order": None,
                       "reachable": None}
            continue
        if current is None:
            continue
        if stripped.startswith("nameserver["):
            address = stripped.split(":", 1)[1].strip() if ":" in stripped else ""
            if address:
                current["nameservers"].append(address)
        elif stripped.startswith("search domain["):
            domain = stripped.split(":", 1)[1].strip() if ":" in stripped else ""
            if domain:
                current["search"].append(domain)
        elif stripped.startswith("if_index"):
            match = re.search(r"if_index\s*:\s*(\d+)\s*(?:\(([^)]+)\))?", stripped)
            if match:
                current["if_index"] = int(match.group(1))
                current["iface"] = match.group(2)
        elif stripped.startswith("flags"):
            current["flags"] = stripped.split(":", 1)[1].strip() if ":" in stripped else None
        elif stripped.startswith("order"):
            current["order"] = stripped.split(":", 1)[1].strip() if ":" in stripped else None
        elif stripped.startswith("reach"):
            current["reachable"] = "Reachable" in stripped
    if current is not None:
        resolvers.append(current)

    servers = []
    seen = set()
    for resolver in resolvers:
        for address in resolver["nameservers"]:
            if address in seen:
                continue
            seen.add(address)
            servers.append({
                "address": address,
                "interface": resolver.get("iface"),
                "if_index": resolver.get("if_index"),
                "resolver": resolver.get("index"),
                "tailnet": in_tailnet(address),
            })
    domains = []
    for resolver in resolvers:
        for domain in resolver["search"]:
            if domain not in domains:
                domains.append(domain)
    return {
        "servers": servers,
        "search_domains": domains,
        "resolvers": len(resolvers),
        "tailnet_resolver": any(server["tailnet"] for server in servers),
    }


def tunnel_of(interfaces, tailscale_ips=None):
    """The tunnel interface and address: a utun carrying a Tailscale range."""
    wanted = [ip for ip in (tailscale_ips or []) if ip]
    for name, iface in interfaces.items():
        for entry in iface["inet"]:
            address = entry["address"]
            if not in_tailnet(address):
                continue
            if not (name.lower().startswith("utun") or address in wanted):
                continue
            return {"interface": name, "address": address,
                    "peer": entry.get("peer"), "up": bool(iface["up"]),
                    "running": bool(iface["running"]), "mtu": iface["mtu"]}
    return None


def local_route(text):
    """(gateway, interface) of the first usable default route, else (None, None)."""
    for row in parse_default_routes(text):
        if row["usable"]:
            return row["gateway"], row["interface"]
    return None, None


# --------------------------------------------------------------------------
# tailscale
# --------------------------------------------------------------------------

def tailscale_status(ctx, fixture=None):
    """(status object, reason). Fixture mode reads only the fixture."""
    if fixture is not None:
        block = fixture.get("tailscale")
        if not isinstance(block, dict) or not block:
            return None, "fixture has no tailscale block"
        return block, None
    out, err, code = _run(["tailscale", "status", "--json"], ctx, PROBE_TIMEOUT_S)
    if not out:
        return None, short(err or "tailscale status failed (exit %d)" % code, 160)
    try:
        obj = json.loads(out)
    except ValueError:
        return None, "tailscale status is not JSON"
    if not isinstance(obj, dict):
        return None, "tailscale status is not an object"
    return obj, None


def peers_of(status):
    peers = []
    raw = status.get("Peer") if isinstance(status, dict) else None
    if not isinstance(raw, dict):
        return peers
    for key, value in raw.items():
        if not isinstance(value, dict):
            continue
        ips = value.get("TailscaleIPs")
        ips = [ip for ip in ips if isinstance(ip, str)] if isinstance(ips, list) else []
        peers.append({
            "id": key,
            "host": value.get("HostName") or key,
            "dns": value.get("DNSName") or "",
            "ips": ips,
            "online": bool(value.get("Online")),
            "exit_node": bool(value.get("ExitNode")),
            "routes": value.get("PrimaryRoutes") if isinstance(value.get("PrimaryRoutes"), list) else [],
            "os": value.get("OS"),
        })
    peers.sort(key=lambda item: (item["host"] or "").lower())
    return peers


def resolve_tailnet_gateway(ctx, fixture=None):
    """(host, reason, source).

    Order: an explicit override; the exit node in use; an online peer that
    advertises subnet routes; the first online peer by host name. A tailnet has
    no single router, so the documented answer is "the node that carries this
    host's traffic", which for a two node tailnet is the other box.
    """
    override = _ctx_value(ctx, "tailnet_gateway")
    if override:
        return str(override), None, "argument"

    status, reason = tailscale_status(ctx, fixture)
    if status is None:
        return None, reason, None

    exit_node = status.get("ExitNodeStatus")
    if isinstance(exit_node, dict):
        for key in ("TailscaleIPs", "NodeIP", "Node"):
            value = exit_node.get(key)
            if isinstance(value, str) and value:
                return value, None, "exit_node"
            if isinstance(value, list) and value and isinstance(value[0], str):
                return value[0], None, "exit_node"

    peers = peers_of(status)
    for peer in peers:
        if peer["online"] and peer["routes"]:
            return (peer["ips"][0] if peer["ips"] else None), None, "subnet_router"
    for peer in peers:
        if peer["online"] and peer["ips"]:
            return peer["ips"][0], None, "online_peer"
    if status.get("BackendState") not in (None, "Running"):
        return None, "tailscale backend is %s" % status.get("BackendState"), None
    return None, "no online tailscale peer", None


# --------------------------------------------------------------------------
# shared payload helpers
# --------------------------------------------------------------------------

def envelope(action, ctx, source, **fields):
    """The one success constructor. Every payload carries ``generated_at``.

    Run, plan and dry-run payloads all come through here, so no emit site can
    skip the timestamp or the four identity keys: a plan is built by
    ``_plan_base`` on top of this, and ``_dry_run_payload`` copies the plan.
    Errors come through ``error_payload``, the one error constructor, so an
    ``ok: false`` answer cannot skip the stamp either.
    """
    payload = {
        "ok": True,
        "generated_at": utc_now_iso(),
        "source": source,
        "action": action,
        "class": ACTIONS[action]["class"],
    }
    payload.update(fields)
    return payload


def error_payload(reason, kind=None, **fields):
    """The one error constructor: no ``ok: false`` answer can skip the stamp.

    Argument failures, refusals, fixture problems and a caught crash all emit
    exactly this object, so ``generated_at`` is on every envelope, success or
    error, as the feeds brief requires.
    """
    payload = {"ok": False, "generated_at": utc_now_iso(), "reason": reason}
    if kind is not None:
        payload["kind"] = kind
    payload.update(fields)
    return payload



def _source(ctx):
    return "fixture" if _fixture_path(ctx) is not None else "live"


def _plan_base(action, ctx):
    host = _host(ctx)
    return envelope(
        action, ctx, _source(ctx),
        plan=True,
        dry_run=True,
        ran=False,
        changes_nothing=ACTIONS[action]["class"] == "read",
        host=host,
        linux_only=ACTIONS[action]["linux_only"],
        needs_confirmation=False,
        items=[],
        bytes=0,
        total_bytes=0,
        commands=[],
        effect="",
        interrupts=None,
        notes=[],
    )


def _command(argv, why):
    return {"argv": [str(piece) for piece in argv], "why": why}


def _dry_run_payload(plan):
    payload = dict(plan)
    payload["plan"] = False
    payload["dry_run"] = True
    payload["ran"] = False
    return payload


def _refusal(reason, kind="not_this_host"):
    return error_payload(reason, kind)


def _cache_hit_payload(data, age):
    """A hit answers from disk and ran nothing, so it must not claim commands.

    The stored payload carries the argv the original run issued. Returning it
    unchanged made a hit list pings it never ran. The original moves to
    ``cached_from`` and ``commands`` is empty. A cache file written before
    jitter published ``commands`` carried the argv under ``command`` instead;
    that key is moved out as well, in the same shape, so no hit ever carries a
    bare argv of its own.
    """
    payload = dict(data)
    original = data.get("commands")
    single = payload.pop("command", None)
    if (not isinstance(original, list) or not original) \
            and isinstance(single, dict) and isinstance(single.get("argv"), list):
        original = [single]
    payload["cached"] = True
    payload["cache_age_s"] = age
    payload["commands"] = []
    payload["cached_from"] = {
        "commands": list(original) if isinstance(original, list) else [],
    }
    return payload


# --------------------------------------------------------------------------
# network.latency
# --------------------------------------------------------------------------

def plan_latency(ctx=None):
    ctx = _ctx(ctx)
    host = _host(ctx)
    plan = _plan_base("network.latency", ctx)
    fixture = load_fixture(ctx) if _fixture_path(ctx) is not None else None

    resolution = []
    if fixture is not None:
        gateway = ping_target(fixture_text(fixture, "ping_tailnet_gateway")) \
            or fixture.get("tailnet_gateway")
        public = ping_target(fixture_text(fixture, "ping_public")) or PUBLIC_HOST
        gateway_reason = None if gateway else "fixture has no tailnet ping capture"
        gateway_source = "fixture"
    else:
        trace = trace_begin(ctx)
        gateway, gateway_reason, gateway_source = resolve_tailnet_gateway(ctx, None)
        public = PUBLIC_HOST
        # Resolving the peer is a real read, and the run issues it too: the
        # plan lists it from the trace so the two command lists stay identical.
        resolution = [{"argv": list(item["argv"]),
                       "why": "resolve the tailnet gateway (read only)"}
                      for item in trace]

    ping_cmd = _ctx_value(ctx, "ping_cmd")
    ping_commands = []
    if gateway:
        ping_commands.append(_command(ping_argv(gateway, LATENCY_COUNT, ping_cmd=ping_cmd),
                                      "5 pings to the tailnet gateway, mean and mdev"))
    ping_commands.append(_command(ping_argv(public, LATENCY_COUNT, ping_cmd=ping_cmd),
                                  "5 pings to the public resolver, mean and mdev"))
    commands = list(resolution) + ping_commands

    plan["targets"] = {"tailnet_gateway": gateway, "public": public}
    plan["gateway_source"] = gateway_source
    if gateway_reason:
        plan["notes"].append("tailnet gateway: %s" % gateway_reason)
    plan["commands"] = commands
    plan["items"] = [{"what": "ping capture", "host": item["argv"][-1],
                      "samples": LATENCY_COUNT, "bytes": 0} for item in ping_commands]
    plan["effect"] = ("takes about %d s (5 pings per target), writes the %d s cache, "
                      "changes nothing on the network" % (LATENCY_COUNT, int(CACHE_TTL_S)))
    plan["cache"] = cache_note(ctx, LATENCY_CACHE_NAME, latency_key(ctx))
    return plan


def latency_key(ctx):
    """The cache key. It must be computable without a command, so a cache hit is
    command free: the setting, not the resolved peer, is the key. The resolved
    peer travels inside the cached payload for anyone who wants to see it."""
    override = _ctx_value(ctx, "tailnet_gateway")
    return {"tailnet_gateway": str(override) if override else "auto",
            "public": PUBLIC_HOST}


def _latency_payload(ctx, fixture=None):
    host = _host(ctx)
    if fixture is not None:
        gateway_text = fixture_text(fixture, "ping_tailnet_gateway")
        public_text = fixture_text(fixture, "ping_public")
        gateway = ping_target(gateway_text) or fixture.get("tailnet_gateway")
        public = ping_target(public_text) or PUBLIC_HOST
        if gateway_text is None:
            gateway_entry = null_entry(gateway, "fixture has no tailnet ping capture")
        else:
            gateway_entry = net_entry(gateway, parse_ping(gateway_text))
        if public_text is None:
            public_entry = null_entry(public, "fixture has no public ping capture")
        else:
            public_entry = net_entry(public, parse_ping(public_text))
        gateway_source = "fixture"
        gateway_reason = None if gateway else "no tailnet gateway in the fixture"
        command_entries = []
        source = "fixture"
    else:
        trace = trace_begin(ctx)
        gateway, gateway_reason, gateway_source = resolve_tailnet_gateway(ctx, None)
        public = PUBLIC_HOST
        entries = {}

        def probe(key, target):
            entry, _argv, _err, _code = measure_ping(target, LATENCY_COUNT, ctx, PING_TIMEOUT_S)
            entries[key] = entry

        threads = []
        if gateway:
            threads.append(threading.Thread(target=probe, args=("gateway", gateway)))
        threads.append(threading.Thread(target=probe, args=("public", public)))
        for thread in threads:
            thread.daemon = True
            thread.start()
        for thread in threads:
            thread.join(timeout_for(ctx, PING_TIMEOUT_S) + 5)
        gateway_entry = entries.get("gateway") or null_entry(
            gateway, gateway_reason or "tailnet gateway did not answer in time")
        public_entry = entries.get("public") or null_entry(
            public, "public probe did not finish in time")
        source = "live"
        command_entries = list(trace)

    entries = [entry for entry in (gateway_entry, public_entry) if entry.get("rtt_ms") is not None]
    payload = envelope(
        "network.latency", ctx, source,
        cached=False,
        cache_age_s=0.0,
        cache_ttl_s=CACHE_TTL_S,
        targets={"tailnet_gateway": gateway, "public": public},
        gateway_source=gateway_source,
        tailnet_gateway=gateway_entry,
        public=public_entry,
        summary={
            "pings_per_target": LATENCY_COUNT,
            "targets_answered": len(entries),
            "targets_probed": 2 if gateway else 1,
            "worst_rtt_ms": max((entry["rtt_ms"] for entry in entries), default=None),
            "any_loss": any((entry.get("loss") or 0) > 0 for entry in entries) if entries else None,
        },
        commands=command_entries,
    )
    if gateway_reason:
        payload["degraded"] = True
        payload["reason"] = gateway_reason
    if not entries:
        # Absence is not success: no target answered, so ok is false and the
        # reason names each one. Never ok true with targets_answered 0.
        payload["ok"] = False
        payload["reason"] = "; ".join(
            "%s: %s" % (label, entry.get("reason") or "not measured")
            for label, entry in (("tailnet_gateway", gateway_entry),
                                 ("public", public_entry)))
    return payload


def run_latency(ctx=None, confirm=None):
    ctx = _ctx(ctx)
    if _ctx_value(ctx, "dry_run", False):
        return _dry_run_payload(plan_latency(ctx))
    key = latency_key(ctx)
    data, age = cache_get(ctx, LATENCY_CACHE_NAME, key)
    if data is not None:
        return _cache_hit_payload(data, age)
    fixture = load_fixture(ctx) if _fixture_path(ctx) is not None else None
    payload = _latency_payload(ctx, fixture)
    if payload.get("summary", {}).get("targets_answered"):
        written = cache_put(ctx, LATENCY_CACHE_NAME, key, payload)
        if written:
            payload["cache_path"] = written
    return payload


# --------------------------------------------------------------------------
# network.jitter
# --------------------------------------------------------------------------

def jitter_target(ctx, fixture=None):
    override = _ctx_value(ctx, "target")
    if override:
        return str(override)
    if fixture is not None:
        return ping_target(fixture_text(fixture, "ping_jitter")) or PUBLIC_HOST
    return PUBLIC_HOST


def percentile(values, fraction):
    """Nearest-rank percentile on a sorted copy. None for an empty list."""
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, int(round(fraction * len(ordered) + 0.4999)))
    return ordered[min(rank, len(ordered)) - 1]


def jitter_stats(text):
    """(stats dict, verdict, reason) from a 20 sample ping capture."""
    times = parse_ping_times(text)
    transmitted, received = parse_ping_counts(text)
    diffs = [abs(times[i] - times[i - 1]) for i in range(1, len(times))]
    mean_abs = round(sum(diffs) / len(diffs), 2) if diffs else None
    p95 = round(percentile(diffs, 0.95), 2) if diffs else None
    losses = None
    if transmitted and received is not None:
        losses = _num(round(100.0 * (transmitted - received) / transmitted, 1))
    elif transmitted == 0:
        losses = None
    stats = {
        "requested": JITTER_COUNT,
        "received": received if received is not None else len(times),
        "transmitted": transmitted,
        "loss": losses,
        "pairs": len(diffs),
        "mean_abs_diff_ms": mean_abs,
        "p95_abs_diff_ms": p95,
        "rtt_ms": {
            "min": round(min(times), 2) if times else None,
            "mean": round(sum(times) / len(times), 2) if times else None,
            "max": round(max(times), 2) if times else None,
            # ping's own summary figure (mdev on macOS, stddev on Linux) and
            # the plain max minus min range: different statistics, different
            # names. Neither of them is jitter.
            "mdev_ms": parse_ping(text).get("mdev_ms"),
            "range_ms": round(max(times) - min(times), 2) if times else None,
        },
    }

    if not diffs:
        reason = "need at least two replies to compare consecutive rtts"
        if losses == 100:
            reason = "no replies: every sample was lost"
        return stats, None, reason

    reason = None
    verdict = "steady"
    if losses is not None and losses >= UNSTABLE_LOSS_PCT:
        verdict = "unstable"
        reason = "loss %s%% >= %s%%" % (losses, UNSTABLE_LOSS_PCT)
    elif mean_abs >= UNSTABLE_MEAN_ABS_MS:
        verdict = "unstable"
        reason = "mean |diff| %s ms >= %s ms" % (mean_abs, UNSTABLE_MEAN_ABS_MS)
    elif p95 >= UNSTABLE_P95_MS:
        verdict = "unstable"
        reason = "p95 |diff| %s ms >= %s ms" % (p95, UNSTABLE_P95_MS)
    elif losses:
        verdict = "jittery"
        reason = "loss %s%%" % losses
    elif mean_abs >= STEADY_MEAN_ABS_MS:
        verdict = "jittery"
        reason = "mean |diff| %s ms >= %s ms" % (mean_abs, STEADY_MEAN_ABS_MS)
    elif p95 >= STEADY_P95_MS:
        verdict = "jittery"
        reason = "p95 |diff| %s ms >= %s ms" % (p95, STEADY_P95_MS)
    else:
        reason = "mean |diff| %s ms < %s ms and p95 %s ms < %s ms" % (
            mean_abs, STEADY_MEAN_ABS_MS, p95, STEADY_P95_MS)
    return stats, verdict, reason


def jitter_thresholds():
    return {
        "steady": "loss 0 and mean |diff| < %s ms and p95 |diff| < %s ms"
                  % (STEADY_MEAN_ABS_MS, STEADY_P95_MS),
        "jittery": "loss > 0, or mean |diff| >= %s ms, or p95 |diff| >= %s ms"
                   % (STEADY_MEAN_ABS_MS, STEADY_P95_MS),
        "unstable": "loss >= %s%%, or mean |diff| >= %s ms, or p95 |diff| >= %s ms"
                    % (UNSTABLE_LOSS_PCT, UNSTABLE_MEAN_ABS_MS, UNSTABLE_P95_MS),
    }


def plan_jitter(ctx=None):
    ctx = _ctx(ctx)
    plan = _plan_base("network.jitter", ctx)
    fixture = load_fixture(ctx) if _fixture_path(ctx) is not None else None
    target = jitter_target(ctx, fixture)
    argv = ping_argv(target, JITTER_COUNT, JITTER_INTERVAL_S)
    plan["target"] = target
    plan["commands"] = [_command(argv, "20 pings, 0.5 s apart, consecutive rtt differences")]
    plan["items"] = [{"what": "ping capture", "host": target,
                      "samples": JITTER_COUNT, "bytes": 0}]
    plan["effect"] = ("measures 20 pings about 9.5 s apart in total, computes mean "
                      "absolute difference and p95, writes the %d s cache, changes "
                      "nothing" % int(CACHE_TTL_S))
    plan["thresholds"] = jitter_thresholds()
    plan["cache"] = cache_note(ctx, JITTER_CACHE_NAME, {"target": target})
    return plan


def run_jitter(ctx=None, confirm=None):
    ctx = _ctx(ctx)
    if _ctx_value(ctx, "dry_run", False):
        return _dry_run_payload(plan_jitter(ctx))
    fixture = load_fixture(ctx) if _fixture_path(ctx) is not None else None
    target = jitter_target(ctx, fixture)
    key = {"target": target}
    data, age = cache_get(ctx, JITTER_CACHE_NAME, key)
    if data is not None:
        return _cache_hit_payload(data, age)

    argv = None
    code = None
    if fixture is not None:
        text = fixture_text(fixture, "ping_jitter")
        source = "fixture"
        if text is None:
            payload = envelope("network.jitter", ctx, source, cached=False,
                               target=target, verdict=None,
                               reason="fixture has no jitter ping capture",
                               thresholds=jitter_thresholds())
            payload["ok"] = False
            return payload
    else:
        argv = ping_argv(target, JITTER_COUNT, JITTER_INTERVAL_S)
        text, err, code = _run(argv, ctx, JITTER_TIMEOUT_S)
        source = "live"
        if not text and err:
            payload = envelope("network.jitter", ctx, source, cached=False,
                               target=target, verdict=None,
                               reason="ping failed: %s" % short(err, 160),
                               thresholds=jitter_thresholds())
            payload["ok"] = False
            return payload

    stats, verdict, reason = jitter_stats(text)
    payload = envelope(
        "network.jitter", ctx, source,
        cached=False,
        cache_age_s=0.0,
        cache_ttl_s=CACHE_TTL_S,
        target=target,
        samples={key_name: stats.get(key_name)
                 for key_name in ("requested", "received", "transmitted", "loss", "pairs")},
        rtt_ms=stats.get("rtt_ms"),
        mean_abs_diff_ms=stats.get("mean_abs_diff_ms"),
        p95_abs_diff_ms=stats.get("p95_abs_diff_ms"),
        verdict=verdict,
        verdict_reason=reason,
        thresholds=jitter_thresholds(),
        commands=([{"argv": [str(piece) for piece in argv], "exit": code}]
                  if argv is not None else []),
    )
    if stats.get("mean_abs_diff_ms") is None:
        payload["ok"] = False
        payload["reason"] = reason or "not measured"
        return payload
    written = cache_put(ctx, JITTER_CACHE_NAME, key, payload)
    if written:
        payload["cache_path"] = written
    return payload


# --------------------------------------------------------------------------
# network.route
# --------------------------------------------------------------------------

def plan_route(ctx=None):
    ctx = _ctx(ctx)
    plan = _plan_base("network.route", ctx)
    host = _host(ctx)
    fixture = load_fixture(ctx) if _fixture_path(ctx) is not None else None
    if fixture is None and host != "mac":
        plan["ok"] = False
        plan["reason"] = ("live route collection is macOS-only in this module "
                          "(netstat, ifconfig, scutil); run it with --fixture")
        plan["kind"] = "not_this_host"
        return plan
    if fixture is not None:
        plan["commands"] = [_command(["fixture", display_path(_fixture_path(ctx))],
                                     "read the recorded netstat, ifconfig and scutil output")]
    else:
        plan["commands"] = [
            _command(["netstat", "-rn", "-f", "inet"], "default route and its interface"),
            _command(["ifconfig"], "interfaces, tunnel address, MTU"),
            _command(["scutil", "--dns"], "DNS servers, search domains, resolvers"),
        ]
    plan["items"] = [
        {"what": "routing table", "source": "netstat -rn", "bytes": 0},
        {"what": "interfaces and tunnel", "source": "ifconfig", "bytes": 0},
        {"what": "DNS configuration", "source": "scutil --dns", "bytes": 0},
    ]
    plan["effect"] = "reads the routing table, interfaces and DNS configuration; changes nothing"
    plan["cache"] = cache_note(ctx, ROUTE_CACHE_NAME,
                               {"action": "network.route", "host": host or "mac"})
    return plan


def run_route(ctx=None, confirm=None):
    ctx = _ctx(ctx)
    if _ctx_value(ctx, "dry_run", False):
        return _dry_run_payload(plan_route(ctx))
    host = _host(ctx)
    fixture = load_fixture(ctx) if _fixture_path(ctx) is not None else None
    if fixture is None and host != "mac":
        return _refusal("live route collection is macOS-only in this module; "
                        "run it with --fixture")
    key = {"action": "network.route", "host": host or "mac"}
    cached, age = cache_get(ctx, ROUTE_CACHE_NAME, key)
    if cached is not None:
        return _cache_hit_payload(cached, age)

    trace = trace_begin(ctx)
    if fixture is not None:
        netstat_text = fixture_text(fixture, "netstat_route")
        ifconfig_text = fixture_text(fixture, "ifconfig")
        dns_text = fixture_text(fixture, "scutil_dns")
        source = "fixture"
        host_label = fixture.get("host") if isinstance(fixture.get("host"), str) else host
    else:
        netstat_text, err, code = _run(["netstat", "-rn", "-f", "inet"], ctx, PROBE_TIMEOUT_S)
        if not netstat_text and err:
            return _refusal(short("netstat failed: %s" % err, 160), "unavailable")
        ifconfig_text, err, code = _run(["ifconfig"], ctx, PROBE_TIMEOUT_S)
        dns_text, err, code = _run(["scutil", "--dns"], ctx, PROBE_TIMEOUT_S)
        source = "live"
        host_label = host

    missing = [name for name, text in (("netstat", netstat_text),
                                       ("ifconfig", ifconfig_text),
                                       ("scutil --dns", dns_text)) if not text]

    interfaces = parse_interfaces(ifconfig_text or "")
    routes = parse_default_routes(netstat_text or "")
    dns = parse_scutil_dns(dns_text or "")
    gateway, gateway_iface = local_route(netstat_text or "")

    status, _status_reason = (tailscale_status(ctx, fixture)
                              if fixture is not None else (None, None))
    tailscale_ips = []
    if isinstance(status, dict):
        ips = status.get("TailscaleIPs")
        if isinstance(ips, list):
            tailscale_ips = [ip for ip in ips if isinstance(ip, str)]
    tunnel = tunnel_of(interfaces, tailscale_ips)

    # A field that was not measured is null with a reason, never a quiet zero,
    # and the envelope only claims success when at least one measurement landed.
    default_route = {
        "gateway": gateway,
        "interface": gateway_iface,
        "reason": None if gateway else ("netstat unreadable" if not netstat_text
                                        else "no usable default route row in netstat"),
    }
    tunnel_block = tunnel or {
        "interface": None, "address": None, "up": False, "running": False,
        "reason": "no utun carrying a Tailscale address",
    }
    dns_block = dict(dns)
    if not dns_block["servers"]:
        dns_block["reason"] = ("scutil --dns unreadable" if not dns_text
                               else "no nameserver in scutil --dns")
    interfaces_block = {
        "count": len(interfaces),
        "tunnel_candidates": sorted(name for name, iface in interfaces.items()
                                    if any(in_tailnet(entry["address"])
                                           for entry in iface["inet"])),
    }
    if not interfaces:
        interfaces_block["reason"] = ("ifconfig unreadable" if not ifconfig_text
                                      else "no interface in ifconfig")

    measured = {
        "default_route": gateway is not None,
        "tunnel": tunnel is not None,
        "dns": bool(dns_block["servers"]),
        "interfaces": bool(interfaces),
    }
    unmeasured = {}
    if not measured["default_route"]:
        unmeasured["default_route"] = default_route["reason"]
    if not measured["tunnel"]:
        unmeasured["tunnel"] = tunnel_block["reason"]
    if not measured["dns"]:
        unmeasured["dns"] = dns_block["reason"]
    if not measured["interfaces"]:
        unmeasured["interfaces"] = interfaces_block["reason"]

    payload = envelope(
        "network.route", ctx, source,
        host=host_label,
        cached=False,
        cache_age_s=0.0,
        cache_ttl_s=CACHE_TTL_S,
        default_route=default_route,
        default_routes=routes,
        tunnel=tunnel_block,
        dns=dns_block,
        interfaces=interfaces_block,
        measured=measured,
        unmeasured=unmeasured,
        missing=missing,
        commands=list(trace),
    )
    reason_list = "; ".join("%s: %s" % (name, reason)
                            for name, reason in unmeasured.items())
    if not any(measured.values()):
        payload["ok"] = False
        payload["kind"] = "missing"
        payload["reason"] = "nothing measured: " + reason_list
        return payload
    if gateway is None:
        payload["ok"] = False
        payload["kind"] = "missing"
        payload["reason"] = "no usable default route: " + reason_list
        return payload
    written = cache_put(ctx, ROUTE_CACHE_NAME, key, payload)
    if written:
        payload["cache_path"] = written
    return payload


# --------------------------------------------------------------------------
# network.flush-dns
# --------------------------------------------------------------------------

FLUSH_COMMANDS = {
    "mac": [
        {"argv": ["dscacheutil", "-flushcache"],
         "why": "empty the directory service cache"},
        {"argv": ["killall", "-HUP", "mDNSResponder"],
         "why": "ask mDNSResponder to reload; SIGHUP is a reload, not a kill"},
    ],
    "linux": [
        {"argv": ["resolvectl", "flush-caches"],
         "why": "drop the systemd-resolved cache"},
    ],
}

FLUSH_INTERRUPTS = ("name resolution for about a second or two; lookups that land "
                    "in the window can fail once and succeed on retry")


def plan_flush_dns(ctx=None):
    ctx = _ctx(ctx)
    plan = _plan_base("network.flush-dns", ctx)
    host = _host(ctx)
    commands = FLUSH_COMMANDS.get(host)
    if commands is None:
        plan["ok"] = False
        plan["reason"] = "flush-dns has no command for host %r" % host
        plan["kind"] = "not_this_host"
        return plan
    plan["commands"] = [dict(item) for item in commands]
    plan["items"] = [{"what": "cache flush", "argv": item["argv"], "bytes": 0}
                     for item in commands]
    plan["effect"] = ("flushes the DNS cache and asks the resolver to reload; deletes "
                      "no file, changes no setting, heals itself")
    plan["interrupts"] = FLUSH_INTERRUPTS
    plan["needs_confirmation"] = False
    plan["notes"].append("safe class: no confirmation, because there is nothing to lose "
                         "and the state is rebuilt on the next lookup")
    if host == "linux":
        plan["notes"].append("linux command is linux_only; it runs only on a host with resolvectl")
    if _fixture_path(ctx) is not None:
        plan["notes"].append("fixture run: the plan is available, the action will not run")
    return plan


def run_flush_dns(ctx=None, confirm=None):
    ctx = _ctx(ctx)
    if _ctx_value(ctx, "dry_run", False):
        return _dry_run_payload(plan_flush_dns(ctx))
    if _fixture_path(ctx) is not None:
        return _refusal("flush-dns is a host action and does not run in fixture mode; "
                        "use --dry-run for the plan", "fixture")
    host = _host(ctx)
    commands = FLUSH_COMMANDS.get(host)
    if commands is None:
        return _refusal("flush-dns has no command for host %r" % host)

    results = []
    ok = True
    reason = None
    for item in commands:
        out, err, code = _run(item["argv"], ctx, PROBE_TIMEOUT_S)
        results.append({"argv": item["argv"], "exit": code,
                        "stderr": short(err, 200) if err else None})
        if code != 0:
            ok = False
            if reason is None:
                reason = "%s exited %d%s" % (" ".join(item["argv"]), code,
                                             (": " + short(err, 120)) if err else "")
    payload = envelope(
        "network.flush-dns", ctx, "live",
        ran=True,
        flushed=ok,
        host=host,
        commands=results,
        interrupts=FLUSH_INTERRUPTS,
        needs_confirmation=False,
        effect="DNS cache emptied; the resolver rebuilds it on the next lookup",
    )
    if not ok:
        payload["ok"] = False
        payload["reason"] = reason
    return payload


# --------------------------------------------------------------------------
# network.connectivity
# --------------------------------------------------------------------------

def _check(ok, reason=None, measured=True, **evidence):
    """One connectivity check. ``measured`` is false when there was no input
    to measure at all (no capture, no probe, no status), which is different
    from measuring a failure: a ping that timed out was measured."""
    return {"ok": bool(ok), "measured": bool(measured),
            "reason": None if ok else (reason or "check failed"),
            "evidence": evidence}


def dns_lookup(name, ctx):
    """(addresses, error, elapsed_ms). Bounded by a daemon thread, never raises."""
    result = {"addresses": [], "error": None, "elapsed_ms": None}
    started = time.time()

    def work():
        try:
            infos = socket.getaddrinfo(name, None, proto=socket.IPPROTO_TCP)
            seen = []
            for info in infos:
                address = info[4][0]
                if address not in seen:
                    seen.append(address)
            result["addresses"] = seen
        except Exception as exc:  # resolver errors are many types
            result["error"] = "%s: %s" % (type(exc).__name__, exc)

    thread = threading.Thread(target=work)
    thread.daemon = True
    thread.start()
    thread.join(DNS_TIMEOUT_S)
    result["elapsed_ms"] = int(round((time.time() - started) * 1000))
    if thread.is_alive():
        result["error"] = "no answer within %ss" % DNS_TIMEOUT_S
    return result


def plan_connectivity(ctx=None):
    ctx = _ctx(ctx)
    plan = _plan_base("network.connectivity", ctx)
    fixture = load_fixture(ctx) if _fixture_path(ctx) is not None else None
    host = _host(ctx)
    if fixture is not None:
        plan["commands"] = [_command(["fixture", display_path(_fixture_path(ctx))],
                                     "derive the four checks from the recorded capture")]
        plan["items"] = [{"what": "recorded capture", "bytes": 0}]
        plan["effect"] = ("reports gateway reachable, public reachable, DNS resolves and "
                          "tunnel up from the fixture; changes nothing")
        return plan

    if host != "mac":
        plan["ok"] = False
        plan["reason"] = ("live connectivity reads netstat, ifconfig and tailscale, "
                          "which this module drives on macOS only; run it with --fixture")
        plan["kind"] = "not_this_host"
        return plan

    netstat_text, _err, _code = _run(["netstat", "-rn", "-f", "inet"], ctx, PROBE_TIMEOUT_S)
    gateway, _iface = local_route(netstat_text)

    # The exact argv a live run issues, in the order it issues them: the
    # netstat and ifconfig reads, the tunnel status, then the two pings. The
    # run publishes its trace, so plan and run cannot drift; the self-check
    # compares the two lists.
    ping_cmd = _ctx_value(ctx, "ping_cmd")
    commands = [
        _command(["netstat", "-rn", "-f", "inet"], "default route gateway"),
        _command(["ifconfig"], "interfaces and the tunnel address"),
        _command(["tailscale", "status", "--json"], "tunnel up"),
    ]
    if gateway:
        commands.append(_command(ping_argv(gateway, CONNECTIVITY_COUNT, ping_cmd=ping_cmd),
                                 "gateway reachable"))
    commands.append(_command(ping_argv(PUBLIC_HOST, CONNECTIVITY_COUNT, ping_cmd=ping_cmd),
                             "public reachable"))
    plan["checks"] = ["gateway_reachable", "public_reachable", "dns_resolves", "tunnel_up"]
    plan["commands"] = commands
    plan["items"] = [{"what": "ping", "samples": CONNECTIVITY_COUNT, "bytes": 0},
                     {"what": "dns resolution", "name": _ctx_value(ctx, "dns_name") or DEFAULT_DNS_NAME,
                      "bytes": 0}]
    plan["effect"] = ("runs the four checks and reports four booleans; the only external "
                      "call is one DNS resolution, no HTTP; changes nothing")
    if not gateway:
        plan["notes"].append("no default route found, so gateway_reachable will be false "
                             "with that reason")
    plan["cache"] = cache_note(ctx, CONNECTIVITY_CACHE_NAME,
                               {"action": "network.connectivity", "host": host,
                                "dns": _ctx_value(ctx, "dns_name") or DEFAULT_DNS_NAME})
    return plan


def run_connectivity(ctx=None, confirm=None):
    ctx = _ctx(ctx)
    if _ctx_value(ctx, "dry_run", False):
        return _dry_run_payload(plan_connectivity(ctx))
    fixture = load_fixture(ctx) if _fixture_path(ctx) is not None else None
    host = _host(ctx)
    if fixture is None and host != "mac":
        return _refusal("live connectivity reads netstat, ifconfig and tailscale, which "
                        "this module drives on macOS only; run it with --fixture")
    dns_name = str(_ctx_value(ctx, "dns_name") or DEFAULT_DNS_NAME)
    key = {"action": "network.connectivity", "host": host, "dns": dns_name}
    cached, age = cache_get(ctx, CONNECTIVITY_CACHE_NAME, key)
    if cached is not None:
        return _cache_hit_payload(cached, age)
    source = "fixture" if fixture is not None else "live"
    trace = trace_begin(ctx)

    if fixture is not None:
        netstat_text = fixture_text(fixture, "netstat_route")
        ifconfig_text = fixture_text(fixture, "ifconfig")
        # The gateway check is about the LAN gateway from the routing table,
        # so it reads the LAN ping capture. The tailnet ping is a different
        # host and is not a stand in for it.
        gateway_text = fixture_text(fixture, "ping_gateway")
        public_text = fixture_text(fixture, "ping_public")
        status, status_reason = tailscale_status(ctx, fixture)
        probe = fixture.get("dns_probe") if isinstance(fixture.get("dns_probe"), dict) else {}
        dns_result = {
            "addresses": [a for a in probe.get("addresses", []) if isinstance(a, str)]
            if isinstance(probe.get("addresses"), list) else [],
            "error": probe.get("error"),
            "elapsed_ms": probe.get("elapsed_ms"),
        }
    else:
        netstat_text, netstat_err, netstat_code = _run(
            ["netstat", "-rn", "-f", "inet"], ctx, PROBE_TIMEOUT_S)
        ifconfig_text, ifconfig_err, ifconfig_code = _run(
            ["ifconfig"], ctx, PROBE_TIMEOUT_S)
        gateway_text = public_text = None
        status, status_reason = tailscale_status(ctx, None)
        dns_result = dns_lookup(dns_name, ctx)

    gateway, gateway_iface = local_route(netstat_text or "")

    # gateway reachable
    if gateway_text is not None:
        parsed = parse_ping(gateway_text)
        gateway_ping = net_entry(gateway, parsed)
    elif fixture is not None:
        gateway_ping = None
    elif gateway:
        entry, argv, _err, _code = measure_ping(gateway, CONNECTIVITY_COUNT, ctx,
                                                PING_TIMEOUT_S)
        gateway_ping = entry
    else:
        gateway_ping = None
    if gateway is None:
        gateway_check = _check(False, "no default route", measured=False, gateway=None)
    elif gateway_ping is None:
        gateway_check = _check(False, "no gateway ping capture in the fixture",
                               measured=False, gateway=gateway)
    else:
        answered = gateway_ping.get("rtt_ms") is not None
        gateway_check = _check(
            answered,
            gateway_ping.get("reason") or "no reply from the gateway",
            gateway=gateway, interface=gateway_iface,
            rtt_ms=gateway_ping.get("rtt_ms"), loss=gateway_ping.get("loss"))

    # public reachable
    if public_text is not None:
        public_ping = net_entry(PUBLIC_HOST, parse_ping(public_text))
    elif fixture is not None:
        public_ping = None
    else:
        entry, argv, _err, _code = measure_ping(PUBLIC_HOST, CONNECTIVITY_COUNT, ctx,
                                                PING_TIMEOUT_S)
        public_ping = entry
    if public_ping is None:
        public_check = _check(False, "no public ping capture in the fixture",
                              measured=False, host=PUBLIC_HOST)
    else:
        answered = public_ping.get("rtt_ms") is not None
        public_check = _check(
            answered, public_ping.get("reason") or "no reply from 1.1.1.1",
            host=PUBLIC_HOST, rtt_ms=public_ping.get("rtt_ms"),
            loss=public_ping.get("loss"))

    # dns resolves
    addresses = dns_result.get("addresses") or []
    if fixture is None:
        dns_measured = True
    else:
        probe_block = fixture.get("dns_probe")
        dns_measured = isinstance(probe_block, dict) and any(
            key in probe_block for key in ("addresses", "error", "elapsed_ms"))
    dns_check = _check(bool(addresses) and not dns_result.get("error"),
                       dns_result.get("error") or ("no dns_probe in the fixture"
                                                   if not dns_measured
                                                   else "no address returned"),
                       measured=dns_measured,
                       name=dns_name, addresses=addresses[:3],
                       count=len(addresses), elapsed_ms=dns_result.get("elapsed_ms"))

    # tunnel up
    interfaces = parse_interfaces(ifconfig_text or "")
    tailscale_ips = []
    backend = None
    if isinstance(status, dict):
        backend = status.get("BackendState")
        ips = status.get("TailscaleIPs")
        if isinstance(ips, list):
            tailscale_ips = [ip for ip in ips if isinstance(ip, str)]
    tunnel = tunnel_of(interfaces, tailscale_ips)
    if status is None:
        tunnel_check = _check(False, status_reason or "tailscale status unavailable",
                              measured=False, backend=None)
    elif backend not in (None, "Running"):
        tunnel_check = _check(False, "tailscale backend is %s" % backend,
                              backend=backend, address=None)
    elif not (tunnel or tailscale_ips):
        tunnel_check = _check(False, "tailscale is running but no tunnel address is present",
                              backend=backend, address=None)
    elif tunnel is None:
        tunnel_check = _check(False, "tailscale address present but no utun carries it",
                              backend=backend, address=(tailscale_ips[0] if tailscale_ips else None))
    else:
        tunnel_check = _check(True, None, backend=backend,
                              interface=tunnel["interface"], address=tunnel["address"],
                              up=tunnel["up"])

    checks = {
        "gateway_reachable": gateway_check,
        "public_reachable": public_check,
        "dns_resolves": dns_check,
        "tunnel_up": tunnel_check,
    }
    failed = [name for name, check in checks.items() if not check["ok"]]
    measured = {name: check["measured"] for name, check in checks.items()}
    unmeasured = [name for name, value in measured.items() if not value]
    payload = envelope(
        "network.connectivity", ctx, source,
        cached=False,
        cache_age_s=0.0,
        cache_ttl_s=CACHE_TTL_S,
        healthy=not failed,
        checks=checks,
        failed=failed,
        measured=measured,
        unmeasured=unmeasured,
        reason=None if not failed else "; ".join(
            "%s: %s" % (name, checks[name]["reason"]) for name in failed),
        commands=list(trace),
    )
    if not any(measured.values()):
        # Nothing was captured or probed: four false checks with reasons are an
        # honest absence, not a successful answer.
        payload["ok"] = False
        payload["kind"] = "missing"
        payload["reason"] = "nothing measured: " + "; ".join(
            "%s: %s" % (name, checks[name]["reason"]) for name in unmeasured)
        return payload
    written = cache_put(ctx, CONNECTIVITY_CACHE_NAME, key, payload)
    if written:
        payload["cache_path"] = written
    return payload


# --------------------------------------------------------------------------
# the table F8a imports
# --------------------------------------------------------------------------

ACTIONS = {
    "network.latency": {
        "class": "read",
        "doc": ("5 pings to the tailnet gateway and 5 to 1.1.1.1: mean rtt, ping's own "
                "mdev, loss per target. Cached 10 s on both targets."),
        "plan": plan_latency,
        "run": run_latency,
        "linux_only": False,
    },
    "network.jitter": {
        "class": "read",
        "doc": ("20 pings to 1.1.1.1 at 0.5 s spacing: mean absolute difference between "
                "consecutive rtts and p95, with a steady/jittery/unstable verdict. "
                "Cached 10 s."),
        "plan": plan_jitter,
        "run": run_jitter,
        "linux_only": False,
    },
    "network.route": {
        "class": "read",
        "doc": ("Default route, interface, tunnel address and DNS servers from "
                "netstat, ifconfig and scutil. Live on macOS, from a fixture on Linux."),
        "plan": plan_route,
        "run": run_route,
        "linux_only": False,
    },
    "network.flush-dns": {
        "class": "safe",
        "doc": ("Flush the DNS cache: dscacheutil -flushcache and killall -HUP "
                "mDNSResponder on macOS, resolvectl flush-caches on Linux. Interrupts "
                "name resolution for a second or two and heals itself, so no "
                "confirmation. Never runs in fixture mode."),
        "plan": plan_flush_dns,
        "run": run_flush_dns,
        "linux_only": False,
    },
    "network.connectivity": {
        "class": "read",
        "doc": ("Four checks, each with its own boolean and a reason when false: "
                "gateway reachable, public reachable, DNS resolves, tunnel up. One DNS "
                "lookup, no HTTP."),
        "plan": plan_connectivity,
        "run": run_connectivity,
        "linux_only": False,
    },
}


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def list_payload():
    return {
        "ok": True,
        "generated_at": utc_now_iso(),
        "source": "module",
        "count": len(ACTIONS),
        "actions": [
            {"name": name, "class": entry["class"], "doc": entry["doc"],
             "linux_only": bool(entry["linux_only"]),
             "plan": callable(entry["plan"]), "run": callable(entry["run"])}
            for name, entry in ACTIONS.items()
        ],
        "classes": {name: _count_class(name) for name in CLASSES},
    }


def _count_class(name):
    return len([1 for entry in ACTIONS.values() if entry["class"] == name])


class UsageProblem(Exception):
    """An argument argparse cannot accept, carried to main as one JSON answer."""


class JsonArgumentParser(argparse.ArgumentParser):
    """argparse that raises instead of printing usage and dying.

    The CLI contract is one JSON object on stdout for every argument failure,
    exit 2; argparse's stock behaviour (usage on stderr, ``SystemExit``, no
    stdout) breaks it for values it cannot bind, which is how
    ``--timeout-scale -inf`` used to produce no answer at all.
    """

    def error(self, message):
        raise UsageProblem(message)


def build_parser():
    parser = JsonArgumentParser(
        prog=PROGRAM,
        description="hudfix network actions: latency, jitter, route, flush-dns, connectivity.")
    parser.add_argument("--list", action="store_true", help="every action with its class")
    parser.add_argument("--plan", metavar="ACTION", help="dry-run object for one action")
    parser.add_argument("--run", metavar="ACTION", help="perform one action")
    parser.add_argument("--dry-run", action="store_true",
                        help="with --run: print the plan and run nothing")
    parser.add_argument("--confirm", metavar="ACTION",
                        help="accepted for the shared hudfix CLI; no safe action needs it")
    parser.add_argument("--json", action="store_true", help="one compact JSON line")
    parser.add_argument("--self-check", action="store_true", help="hermetic checks")
    parser.add_argument("--fixture", metavar="PATH", help="recorded capture instead of the host")
    parser.add_argument("--state-dir", metavar="PATH", help="cache directory")
    parser.add_argument("--cache-path", metavar="PATH", help="exact cache file")
    parser.add_argument("--tailnet-gateway", metavar="HOST", help="override the tailnet target")
    parser.add_argument("--target", metavar="HOST", help="override the jitter target")
    parser.add_argument("--dns-name", metavar="NAME", help="name used by the DNS check")
    parser.add_argument("--host", choices=("mac", "linux"), help="override host detection")
    parser.add_argument("--timeout-scale", type=str, default="1.0", metavar="FACTOR",
                        help="multiply every command timeout; a finite float from "
                             "%g to %g, default 1.0 (slow hosts)"
                             % (TIMEOUT_SCALE_MIN, TIMEOUT_SCALE_MAX))
    return parser


def _normalise_argv(argv):
    """Bind ``--timeout-scale VALUE`` as one token, whatever VALUE starts with.

    argparse refuses to take ``-inf`` or ``-1`` as the value of a separate
    option (it reads them as options), so the CLI would exit without an answer.
    The value is validated in ``main`` either way; merging it into the ``=``
    form lets the validator, not argparse, produce the refusal.
    """
    out = []
    index = 0
    while index < len(argv):
        token = argv[index]
        if token == "--timeout-scale":
            if index + 1 >= len(argv):
                raise UsageProblem("--timeout-scale needs a value")
            out.append("--timeout-scale=" + str(argv[index + 1]))
            index += 2
            continue
        out.append(token)
        index += 1
    return out


def ctx_from_args(args):
    ctx = default_ctx()
    ctx["fixture"] = args.fixture
    ctx["dry_run"] = bool(args.dry_run)
    ctx["state_dir"] = args.state_dir or DEFAULT_CACHE_DIR
    if args.cache_path:
        ctx["cache_path"] = args.cache_path
    if args.tailnet_gateway:
        ctx["tailnet_gateway"] = args.tailnet_gateway
    if args.target:
        ctx["target"] = args.target
    if args.dns_name:
        ctx["dns_name"] = args.dns_name
    if args.host:
        ctx["host"] = args.host
    if args.timeout_scale != 1.0:
        ctx["timeout_scale"] = args.timeout_scale
    return ctx


def print_json(payload, compact):
    if compact:
        sys.stdout.write(json.dumps(payload, ensure_ascii=False, sort_keys=False) + "\n")
    else:
        sys.stdout.write(json.dumps(payload, ensure_ascii=False, sort_keys=False, indent=2) + "\n")


def main(argv=None):
    raw = list(sys.argv[1:] if argv is None else argv)
    compact_hint = "--json" in raw

    # argparse must never print usage instead of an answer: every argument
    # failure is one JSON object on stdout and exit 2.
    try:
        args = build_parser().parse_args(_normalise_argv(raw))
    except UsageProblem as exc:
        print_json(error_payload(str(exc), "bad_argument"), compact_hint)
        return 2

    # A bad scale is a bad argument: refuse it here, before any ctx exists or
    # any timeout is converted, so an absurd value cannot reach subprocess.
    scale, scale_reason = validate_timeout_scale(args.timeout_scale)
    if scale_reason is not None:
        print_json(error_payload(scale_reason, "bad_argument"), args.json)
        return 2
    args.timeout_scale = scale

    if args.self_check:
        return self_check(compact=args.json)

    chosen = [flag for flag in (args.list, args.plan, args.run) if flag]
    if len(chosen) != 1:
        print_json(error_payload("give exactly one of --list, --plan, --run, "
                                 "--self-check", "bad_argument"), args.json)
        return 2

    ctx = ctx_from_args(args)

    if args.list:
        print_json(list_payload(), args.json)
        return 0

    name = args.plan or args.run
    if name not in ACTIONS:
        print_json(error_payload("unknown action %r" % name, "bad_argument",
                                 actions=sorted(ACTIONS)), args.json)
        return 2

    if _fixture_path(ctx) is not None and not Path(str(_fixture_path(ctx))).exists():
        print_json(error_payload("fixture does not exist: %s"
                                 % display_path(_fixture_path(ctx)), "missing"), args.json)
        return 2

    try:
        if args.plan:
            payload = ACTIONS[name]["plan"](ctx)
        else:
            payload = ACTIONS[name]["run"](ctx, args.confirm)
    except FixtureProblem as exc:
        # A named file that is missing is a usage error (exit 2). A file that
        # is there but unreadable or malformed is an answer: ok false, exit 0.
        print_json(error_payload(exc.reason, exc.kind), args.json)
        return 2 if exc.kind == "missing" else 0
    except (BrokenPipeError, KeyboardInterrupt):
        raise
    except Exception as exc:  # noqa: BLE001 - one JSON line, never a traceback
        # A crash path still owes the caller one JSON object on stdout.
        print_json(error_payload("%s: %s" % (type(exc).__name__, exc), "crash"),
                   args.json)
        return 1

    print_json(payload, args.json)
    if payload.get("ok") is False and payload.get("kind") == "not_this_host" and args.run:
        return 2
    return 0


# --------------------------------------------------------------------------
# self-check
# --------------------------------------------------------------------------

def self_check(compact=False):  # noqa: C901 - one linear script is the point
    here = Path(__file__).resolve().parent
    fixtures = here.parent / "fixtures"
    healthy_path = fixtures / FIXTURE_MAIN
    down_path = fixtures / FIXTURE_MAIN_DOWN
    checks = []
    temp_root = Path(tempfile.mkdtemp(prefix="hudfix-network-selfcheck-"))

    def record(name, fn):
        try:
            detail = fn()
            checks.append({"name": name, "ok": True, "detail": detail})
        except Exception as exc:  # noqa: BLE001 - a failing check must not stop the rest
            checks.append({"name": name, "ok": False,
                           "detail": "%s: %s" % (type(exc).__name__, exc)})

    def assert_true(value, message):
        if not value:
            raise AssertionError(message)

    def fixture_ctx(path=None, **overrides):
        ctx = default_ctx()
        ctx["fixture"] = str(path) if path else None
        ctx["state_dir"] = str(temp_root / "state")
        ctx.update(overrides)
        return ctx

    class CountingRunner(object):
        """Records argv and answers with canned text, so no command runs."""

        def __init__(self, answers=None):
            self.calls = []
            self.answers = answers or {}

        def __call__(self, argv, timeout):
            self.calls.append(list(argv))
            return self.answers.get(argv[0], ("", "", 0))

    # 1. the table
    def check_table():
        assert_true(sorted(ACTIONS) == [
            "network.connectivity", "network.flush-dns", "network.jitter",
            "network.latency", "network.route"], "action names changed")
        for name, entry in ACTIONS.items():
            assert_true(name.startswith("network."), "%s is not a network action" % name)
            assert_true(entry["class"] in CLASSES, "%s has class %r" % (name, entry["class"]))
            assert_true(entry["class"] in OWN_CLASSES, "%s is not read or safe" % name)
            assert_true(isinstance(entry["doc"], str) and len(entry["doc"]) > 20,
                        "%s needs a real doc" % name)
            assert_true(callable(entry["plan"]), "%s plan is not callable" % name)
            assert_true(callable(entry["run"]), "%s run is not callable" % name)
            assert_true(isinstance(entry["linux_only"], bool), "%s linux_only is not a bool" % name)
            plan = entry["plan"](fixture_ctx(healthy_path))
            for key in ("ok", "action", "class", "plan", "changes_nothing", "items",
                        "bytes", "total_bytes", "needs_confirmation", "commands", "effect"):
                assert_true(key in plan, "%s plan has no %s" % (name, key))
            assert_true(plan["action"] == name, "%s plan names %r" % (name, plan["action"]))
            assert_true(plan["class"] == entry["class"], "%s plan class drifted" % name)
            assert_true(plan["bytes"] == 0 and plan["total_bytes"] == 0,
                        "%s plan claims bytes deleted" % name)
        return "5 actions, classes %s" % ({name: ACTIONS[name]["class"] for name in sorted(ACTIONS)})

    record("actions_table", check_table)

    # 2. allowlist: no plan and no live call may name a binary outside the list,
    #    and nothing may name a routing change
    def check_allowlist():
        seen = set()

        def scan(label, commands, calls):
            for argv in _argv_list(commands) + [list(call) for call in calls]:
                if not argv or argv[0] == "fixture":
                    continue
                binary = os.path.basename(argv[0])
                assert_true(binary in ALLOWED_BINARIES,
                            "%s names %r, outside the allowlist" % (label, argv[0]))
                joined = " ".join(argv)
                for token in FORBIDDEN_ARGV_TOKENS:
                    assert_true(token not in joined,
                                "%s plans a routing change: %s" % (label, joined))
                seen.add(binary)

        for name, entry in ACTIONS.items():
            plan = entry["plan"](fixture_ctx(healthy_path))
            scan("%s (fixture)" % name, plan.get("commands"), [])

        # live plans, with a runner that answers nothing: argv is still visible
        for label, host in (("mac", "mac"), ("linux", "linux")):
            runner = CountingRunner()
            ctx = default_ctx()
            ctx.update({"runner": runner, "host": host,
                        "state_dir": str(temp_root / ("allowlist-%s" % label)),
                        "cache": False})
            for name in sorted(ACTIONS):
                plan = ACTIONS[name]["plan"](ctx)
                scan("%s (%s live)" % (name, label), plan.get("commands"), [])
            scan("live calls (%s)" % label, [], runner.calls)
        return "binaries seen: %s" % sorted(seen)

    record("plan_allowlist", check_allowlist)

    # 3. CLI: --list is one JSON object, unknown action is exit 2
    def check_cli_list():
        out = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--list", "--json"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        text = out.stdout.decode("utf-8")
        assert_true(out.returncode == 0, "--list exit %d" % out.returncode)
        assert_true(text.count("\n") == 1, "--list printed %d lines" % text.count("\n"))
        payload = json.loads(text)
        assert_true(payload["ok"] is True, "--list ok is not true")
        assert_true(payload["count"] == 5, "--list count %r" % payload["count"])
        unknown = subprocess.run([sys.executable, str(Path(__file__).resolve()),
                                  "--plan", "network.nope", "--json"],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert_true(unknown.returncode == 2, "unknown action exit %d" % unknown.returncode)
        return "--list 5 actions, exit 0; unknown action exit 2"

    record("cli_contract", check_cli_list)

    # 4. a named fixture that does not exist is exit 2; one that is there but
    #    malformed is ok false with exit 0. Neither ever falls back to live.
    def check_fixture_exit_codes():
        missing = temp_root / "nope.json"
        out = subprocess.run([sys.executable, str(Path(__file__).resolve()),
                              "--fixture", str(missing), "--plan", "network.latency", "--json"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert_true(out.returncode == 2, "missing fixture exit %d" % out.returncode)
        payload = json.loads(out.stdout.decode("utf-8"))
        assert_true(payload.get("ok") is False, "missing fixture is not ok:false")
        assert_true(payload.get("kind") == "missing", "missing fixture kind %r" % payload.get("kind"))

        empty_dir = temp_root / "empty-fixture-dir"
        empty_dir.mkdir(parents=True, exist_ok=True)
        out = subprocess.run([sys.executable, str(Path(__file__).resolve()),
                              "--fixture", str(empty_dir), "--plan", "network.latency", "--json"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert_true(out.returncode == 2, "empty fixture dir exit %d" % out.returncode)
        payload = json.loads(out.stdout.decode("utf-8"))
        assert_true("network.json" in (payload.get("reason") or ""),
                    "the empty dir reason does not name the file it needs: %r"
                    % payload.get("reason"))

        out = subprocess.run([sys.executable, str(Path(__file__).resolve()),
                              "--fixture", str(fixtures), "--plan", "network.latency", "--json"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert_true(out.returncode == 0, "fixture directory exit %d" % out.returncode)
        payload = json.loads(out.stdout.decode("utf-8"))
        assert_true(payload.get("ok") is True and payload.get("source") == "fixture",
                    "the fixture directory was not read as a fixture")

        # unreadable input is an answer, not a usage error
        for label, body in (("empty", ""),
                            ("not-json", "{not json"),
                            ("not-an-object", "[1, 2, 3]")):
            path = temp_root / ("malformed-%s.json" % label)
            path.write_text(body, encoding="utf-8")
            out = subprocess.run([sys.executable, str(Path(__file__).resolve()),
                                  "--fixture", str(path), "--run", "network.latency", "--json"],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            assert_true(out.returncode == 0,
                        "%s fixture exit %d, expected 0" % (label, out.returncode))
            payload = json.loads(out.stdout.decode("utf-8"))
            assert_true(payload.get("ok") is False, "%s fixture is not ok:false" % label)
            assert_true(payload.get("kind") == "malformed",
                        "%s fixture kind %r" % (label, payload.get("kind")))
            assert_true(bool(payload.get("reason")), "%s fixture has no reason" % label)
        return "exit 2 missing file and empty dir, exit 0 for 3 malformed files"

    record("fixture_exit_codes", check_fixture_exit_codes)

    # 5. latency parses the recorded capture, twice, identically
    def check_latency_fixture():
        ctx = fixture_ctx(healthy_path)
        first = run_latency(ctx)
        second = run_latency(ctx)
        assert_true(first["ok"] is True, "latency ok is false: %r" % first.get("reason"))
        assert_true(first["source"] == "fixture", "latency source %r" % first["source"])
        for key in ("tailnet_gateway", "public"):
            assert_true(first[key] == second[key], "%s numbers differ between runs" % key)
        gateway = first["tailnet_gateway"]
        public = first["public"]
        assert_true(gateway["host"] == "100.100.0.1", "gateway host %r" % gateway["host"])
        assert_true(abs(gateway["rtt_ms"] - 5.04) < 0.02, "gateway rtt %r" % gateway["rtt_ms"])
        assert_true(abs(gateway["mdev_ms"] - 1.44) < 0.02, "gateway mdev %r" % gateway["mdev_ms"])
        assert_true("jitter_ms" not in gateway, "the mdev still travels as jitter_ms")
        assert_true(gateway["loss"] == 0, "gateway loss %r" % gateway["loss"])
        assert_true(gateway["samples"] == 5, "gateway samples %r" % gateway["samples"])
        assert_true(abs(public["rtt_ms"] - 31.37) < 0.02, "public rtt %r" % public["rtt_ms"])
        assert_true(public["loss"] == 0, "public loss %r" % public["loss"])
        assert_true(first["summary"]["targets_answered"] == 2,
                    "targets_answered %r" % first["summary"]["targets_answered"])

        # an empty recording is absence: ok false with a reason, never ok true
        # with targets_answered 0
        empty = temp_root / "latency-empty.json"
        empty.write_text(json.dumps({"host": "mac", "commands": {}}), encoding="utf-8")
        hollow = run_latency(fixture_ctx(empty))
        assert_true(hollow["ok"] is False, "an empty capture reported ok true")
        assert_true(hollow["summary"]["targets_answered"] == 0,
                    "an empty capture claims %r answers" % hollow["summary"]["targets_answered"])
        assert_true(bool(hollow.get("reason")), "an empty capture has no reason")
        return "gateway 5.04/1.44 ms, public 31.37 ms, identical twice; empty capture ok false"

    record("latency_fixture", check_latency_fixture)

    # 6. jitter parses the recorded capture, twice, identically
    def check_jitter_fixture():
        ctx = fixture_ctx(healthy_path)
        first = run_jitter(ctx)
        second = run_jitter(ctx)
        assert_true(first["ok"] is True, "jitter ok is false")
        assert_true(first["source"] == "fixture", "jitter source %r" % first["source"])
        for key in ("samples", "rtt_ms", "mean_abs_diff_ms", "p95_abs_diff_ms", "verdict"):
            assert_true(first[key] == second[key], "%s differs between runs" % key)
        assert_true(first["samples"]["transmitted"] == 20, "transmitted %r" % first["samples"])
        assert_true(first["samples"]["received"] == 20, "received %r" % first["samples"])
        assert_true(first["samples"]["pairs"] == 19, "pairs %r" % first["samples"])
        assert_true(first["verdict"] in ("steady", "jittery", "unstable"),
                    "verdict %r" % first["verdict"])
        assert_true(first["p95_abs_diff_ms"] >= first["mean_abs_diff_ms"],
                    "p95 below the mean, which cannot be")
        # mdev and range are the two numbers the README names, and neither is
        # called spread
        assert_true(first["rtt_ms"]["mdev_ms"] == 33.85,
                    "rtt_ms.mdev_ms %r" % first["rtt_ms"].get("mdev_ms"))
        assert_true(first["rtt_ms"]["range_ms"] == 105.39,
                    "rtt_ms.range_ms %r" % first["rtt_ms"].get("range_ms"))
        assert_true("spread" not in first["rtt_ms"], "rtt_ms still calls the range spread")

        # no jitter capture is absence: ok false, verdict null, a reason
        no_jitter = temp_root / "jitter-empty.json"
        no_jitter.write_text(json.dumps({"host": "mac", "commands": {"ping_public": "x"}}),
                             encoding="utf-8")
        hollow = run_jitter(fixture_ctx(no_jitter))
        assert_true(hollow["ok"] is False, "a capture without ping_jitter reported ok true")
        assert_true(hollow["verdict"] is None, "a capture without ping_jitter has a verdict")
        assert_true(bool(hollow.get("reason")), "a capture without ping_jitter has no reason")
        return ("20 replies, 19 pairs, mean %s ms, p95 %s ms, verdict %s, mdev 33.85, "
                "range 105.39; missing capture ok false" % (
                    first["mean_abs_diff_ms"], first["p95_abs_diff_ms"], first["verdict"]))

    record("jitter_fixture", check_jitter_fixture)

    # 7. the verdict thresholds hold at both sides of every boundary
    def synthetic(times, transmitted=None, received=None):
        text = "\n".join("64 bytes from 1.1.1.1: icmp_seq=%d ttl=53 time=%.3f ms" % (i, t)
                         for i, t in enumerate(times))
        if transmitted is not None:
            text += ("\n\n--- 1.1.1.1 ping statistics ---\n%d packets transmitted, %d received, "
                     "%.0f%% packet loss\n" % (transmitted, received,
                                               100.0 * (transmitted - received) / transmitted))
        return text

    def check_thresholds():
        steady = jitter_stats(synthetic([10.0, 10.4, 10.1, 10.3, 10.2, 10.4]))
        assert_true(steady[1] == "steady", "flat samples gave %r" % (steady[1],))
        jittery = jitter_stats(synthetic([10.0, 13.0, 10.0, 13.0, 10.0, 13.0]))
        assert_true(jittery[1] == "jittery", "2 to 3 ms swings gave %r" % (jittery[1],))
        unstable = jitter_stats(synthetic([10.0, 25.0, 10.0, 25.0, 10.0, 25.0]))
        assert_true(unstable[1] == "unstable", "15 ms swings gave %r" % (unstable[1],))
        lossy = jitter_stats(synthetic([10.0, 10.1, 10.1, 10.2], transmitted=20, received=18))
        assert_true(lossy[1] == "unstable", "10%% loss gave %r" % (lossy[1],))
        small_loss = jitter_stats(synthetic([10.0, 10.1, 10.1, 10.2], transmitted=50, received=49))
        assert_true(small_loss[1] == "jittery", "2%% loss gave %r" % (small_loss[1],))
        silent = jitter_stats(synthetic([], transmitted=20, received=0))
        assert_true(silent[1] is None, "100%% loss gave a verdict")
        assert_true("no replies" in (silent[2] or ""), "100%% loss reason %r" % (silent[2],))
        return "steady/jittery/unstable/2%% loss/100%% loss all classified"

    record("jitter_thresholds", check_thresholds)

    # 8. route parses the recorded capture
    def check_route_fixture():
        payload = run_route(fixture_ctx(healthy_path))
        assert_true(payload["ok"] is True, "route ok is false: %r" % payload.get("reason"))
        assert_true(payload["default_route"]["gateway"] == "192.0.2.1",
                    "gateway %r" % payload["default_route"])
        assert_true(payload["default_route"]["interface"] == "en0",
                    "interface %r" % payload["default_route"])
        assert_true(len(payload["default_routes"]) == 4,
                    "default rows %r" % len(payload["default_routes"]))
        assert_true(payload["tunnel"]["interface"] == "utun4",
                    "tunnel iface %r" % payload["tunnel"])
        assert_true(payload["tunnel"]["address"] == "100.100.123.2",
                    "tunnel address %r" % payload["tunnel"])
        assert_true(payload["tunnel"]["up"] is True, "tunnel is not up")
        addresses = [server["address"] for server in payload["dns"]["servers"]]
        assert_true("100.100.100.100" in addresses, "no tailnet resolver: %r" % addresses)
        assert_true("192.0.2.1" in addresses, "no LAN resolver: %r" % addresses)
        assert_true(payload["dns"]["tailnet_resolver"] is True, "tailnet_resolver false")
        assert_true("example-tailnet.ts.net" in payload["dns"]["search_domains"],
                    "search domains %r" % payload["dns"]["search_domains"])
        tailnet_server = [s for s in payload["dns"]["servers"]
                          if s["address"] == "100.100.100.100"][0]
        assert_true(tailnet_server["interface"] == "utun4",
                    "tailnet resolver interface %r" % tailnet_server)
        return "default 192.0.2.1/en0, tunnel utun4 100.100.123.2, 4 DNS servers"

    record("route_fixture", check_route_fixture)

    # 9. connectivity: healthy fixture is all true, down fixture is all false
    def check_connectivity_healthy():
        payload = run_connectivity(fixture_ctx(healthy_path))
        assert_true(payload["ok"] is True, "connectivity ok is false")
        assert_true(payload["healthy"] is True, "healthy fixture is not healthy: %r"
                    % payload.get("failed"))
        assert_true(sorted(payload["checks"]) == ["dns_resolves", "gateway_reachable",
                                                 "public_reachable", "tunnel_up"],
                    "check names %r" % sorted(payload["checks"]))
        for name, check in payload["checks"].items():
            assert_true(check["ok"] is True, "%s is false on the healthy fixture: %r"
                        % (name, check["reason"]))
        evidence = payload["checks"]["gateway_reachable"]["evidence"]
        assert_true(evidence["gateway"] == "192.0.2.1",
                    "gateway evidence names %r, not the default route gateway"
                    % evidence.get("gateway"))
        assert_true(abs(evidence["rtt_ms"] - 32.86) < 0.02,
                    "gateway rtt %r is not the LAN gateway capture" % evidence.get("rtt_ms"))
        return "4 of 4 true, gateway evidence 192.0.2.1 at 32.86 ms"

    record("connectivity_healthy", check_connectivity_healthy)

    def check_connectivity_down():
        payload = run_connectivity(fixture_ctx(down_path))
        assert_true(payload["ok"] is True, "down fixture is not an answer: %r" % payload)
        assert_true(payload["healthy"] is False, "down fixture reported healthy")
        for name, check in payload["checks"].items():
            assert_true(check["ok"] is False, "%s is true with everything down" % name)
            assert_true(bool(check["reason"]), "%s has no reason" % name)
        assert_true(sorted(payload["failed"]) == ["dns_resolves", "gateway_reachable",
                                                  "public_reachable", "tunnel_up"],
                    "failed list %r" % payload["failed"])
        assert_true(any(payload["measured"].values()),
                    "the down fixture measured nothing at all")
        return "4 of 4 false, each with a reason, healthy false, 3 of 4 measured"

    record("connectivity_down", check_connectivity_down)

    def check_connectivity_derived():
        base = json.loads(healthy_path.read_text(encoding="utf-8"))
        flips = []

        dns_case = json.loads(json.dumps(base))
        dns_case["dns_probe"]["addresses"] = []
        dns_case["dns_probe"]["error"] = None
        path = temp_root / "dns-empty.json"
        path.write_text(json.dumps(dns_case), encoding="utf-8")
        payload = run_connectivity(fixture_ctx(path))
        assert_true(payload["checks"]["dns_resolves"]["ok"] is False,
                    "empty address list still resolves")
        assert_true(sorted(payload["failed"]) == ["dns_resolves"],
                    "dns flip moved %r" % payload["failed"])
        flips.append("dns")

        tunnel_case = json.loads(json.dumps(base))
        tunnel_case["tailscale"]["BackendState"] = "Stopped"
        path = temp_root / "tunnel-down.json"
        path.write_text(json.dumps(tunnel_case), encoding="utf-8")
        payload = run_connectivity(fixture_ctx(path))
        assert_true(payload["checks"]["tunnel_up"]["ok"] is False, "stopped backend is up")
        assert_true(sorted(payload["failed"]) == ["tunnel_up"],
                    "tunnel flip moved %r" % payload["failed"])
        assert_true("Stopped" in payload["checks"]["tunnel_up"]["reason"],
                    "tunnel reason does not quote the backend")
        flips.append("tunnel")

        gateway_case = json.loads(json.dumps(base))
        gateway_case["commands"]["ping_gateway"] = (
            "PING 192.0.2.1 (192.0.2.1): 56 data bytes\n"
            "\n--- 192.0.2.1 ping statistics ---\n"
            "3 packets transmitted, 0 packets received, 100.0% packet loss\n")
        path = temp_root / "gateway-down.json"
        path.write_text(json.dumps(gateway_case), encoding="utf-8")
        payload = run_connectivity(fixture_ctx(path))
        assert_true(payload["checks"]["gateway_reachable"]["ok"] is False,
                    "100% loss gateway is reachable")
        assert_true(sorted(payload["failed"]) == ["gateway_reachable"],
                    "gateway flip moved %r" % payload["failed"])
        assert_true(payload["checks"]["gateway_reachable"]["evidence"]["loss"] == 100,
                    "gateway evidence does not carry the loss")
        flips.append("gateway")

        public_case = json.loads(json.dumps(base))
        public_case["commands"]["ping_public"] = (
            "PING 1.1.1.1 (1.1.1.1): 56 data bytes\n"
            "\n--- 1.1.1.1 ping statistics ---\n"
            "3 packets transmitted, 0 packets received, 100.0% packet loss\n")
        path = temp_root / "public-down.json"
        path.write_text(json.dumps(public_case), encoding="utf-8")
        payload = run_connectivity(fixture_ctx(path))
        assert_true(payload["checks"]["public_reachable"]["ok"] is False,
                    "100% loss to 1.1.1.1 is public reachable")
        assert_true(sorted(payload["failed"]) == ["public_reachable"],
                    "public flip moved %r" % payload["failed"])
        flips.append("public")

        return "one input flipped at a time: %s" % ", ".join(flips)

    record("connectivity_derived", check_connectivity_derived)

    # 10. the cache makes the second call command-free, and expires
    def check_cache():
        clock = {"now": 1000.0}
        runner = CountingRunner(answers={
            "ping": ("PING 100.100.0.1 (100.100.0.1): 56 data bytes\n"
                     "64 bytes from 100.100.0.1: icmp_seq=0 ttl=64 time=5.100 ms\n"
                     "64 bytes from 100.100.0.1: icmp_seq=1 ttl=64 time=5.000 ms\n"
                     "64 bytes from 100.100.0.1: icmp_seq=2 ttl=64 time=5.200 ms\n"
                     "64 bytes from 100.100.0.1: icmp_seq=3 ttl=64 time=5.050 ms\n"
                     "64 bytes from 100.100.0.1: icmp_seq=4 ttl=64 time=5.150 ms\n"
                     "\n--- 100.100.0.1 ping statistics ---\n"
                     "5 packets transmitted, 5 packets received, 0.0% packet loss\n"
                     "round-trip min/avg/max/stddev = 5.000/5.100/5.200/0.070 ms\n", "", 0),
            "tailscale": (json.dumps({
                "BackendState": "Running",
                "TailscaleIPs": ["100.100.123.2"],
                "Peer": {"node1": {"HostName": "node-linux",
                                   "TailscaleIPs": ["100.100.0.1"],
                                   "Online": True}},
            }), "", 0),
        })
        ctx = default_ctx()
        ctx.update({"runner": runner, "cache_dir": str(temp_root / "cache"),
                    "now": lambda: clock["now"]})
        first = run_latency(ctx)
        assert_true(first["ok"] is True, "live-shaped latency ok is false")
        assert_true(first["cached"] is False, "first call claims cached")
        assert_true(first["gateway_source"] == "online_peer",
                    "gateway source %r" % first["gateway_source"])
        assert_true(len(runner.calls) == 3, "first call ran %d commands, expected 3 "
                    "(tailscale, gateway ping, public ping)" % len(runner.calls))
        assert_true(first["tailnet_gateway"]["rtt_ms"] == 5.1,
                    "canned gateway rtt %r" % first["tailnet_gateway"]["rtt_ms"])
        second = run_latency(ctx)
        assert_true(len(runner.calls) == 3, "the second call ran %d more commands"
                    % (len(runner.calls) - 3))
        assert_true(second["cached"] is True, "second call is not cached")
        assert_true(second["cache_age_s"] == 0.0, "age %r" % second["cache_age_s"])
        assert_true(second["commands"] == [],
                    "the cached answer lists commands it did not run: %r" % second["commands"])
        assert_true(second["cached_from"]["commands"] == first["commands"],
                    "the original commands were not moved into cached_from")
        assert_true(second["tailnet_gateway"] == first["tailnet_gateway"],
                    "the cached numbers moved")
        clock["now"] += CACHE_TTL_S + 1
        third = run_latency(ctx)
        assert_true(len(runner.calls) == 6, "after the ttl the cache still answered (%d calls)"
                    % len(runner.calls))
        assert_true(third["cached"] is False, "expired call claims cached")

        # the same 10 s floor holds for the other two reads
        fixture_data = json.loads(healthy_path.read_text(encoding="utf-8"))
        answers = {
            "netstat": (fixture_data["commands"]["netstat_route"], "", 0),
            "ifconfig": (fixture_data["commands"]["ifconfig"], "", 0),
            "scutil": (fixture_data["commands"]["scutil_dns"], "", 0),
            "tailscale": (json.dumps(fixture_data["tailscale"]), "", 0),
            "ping": ("PING 1.1.1.1 (1.1.1.1): 56 data bytes\n"
                     "64 bytes from 1.1.1.1: icmp_seq=0 ttl=53 time=20.000 ms\n"
                     "64 bytes from 1.1.1.1: icmp_seq=1 ttl=53 time=20.400 ms\n"
                     "64 bytes from 1.1.1.1: icmp_seq=2 ttl=53 time=20.100 ms\n"
                     "64 bytes from 1.1.1.1: icmp_seq=3 ttl=53 time=20.300 ms\n"
                     "64 bytes from 1.1.1.1: icmp_seq=4 ttl=53 time=20.200 ms\n"
                     "\n--- 1.1.1.1 ping statistics ---\n"
                     "5 packets transmitted, 5 packets received, 0.0% packet loss\n"
                     "round-trip min/avg/max/stddev = 19.800/20.000/20.300/0.100 ms\n", "", 0),
        }
        cached_names = []
        for name in ("network.jitter", "network.route", "network.connectivity"):
            clock2 = {"now": 5000.0}
            runner2 = CountingRunner(answers=answers)
            ctx2 = default_ctx()
            ctx2.update({"runner": runner2, "now": (lambda c=clock2: c["now"]),
                         "cache_dir": str(temp_root / ("cache-%s" % name.split(".")[-1]))})
            first_call = ACTIONS[name]["run"](ctx2)
            assert_true(first_call["cached"] is False, "%s first call claims cached" % name)
            assert_true(len(runner2.calls) > 0, "%s ran no command at all" % name)
            assert_true(bool(first_call["commands"]),
                        "%s first call recorded no argv to replay" % name)
            seen = len(runner2.calls)
            second_call = ACTIONS[name]["run"](ctx2)
            assert_true(second_call["cached"] is True, "%s second call is not cached" % name)
            assert_true(len(runner2.calls) == seen, "%s second call ran %d more commands"
                        % (name, len(runner2.calls) - seen))
            assert_true(second_call["commands"] == [],
                        "%s cache hit lists commands it did not run" % name)
            assert_true(second_call["cached_from"]["commands"] == first_call["commands"],
                        "%s cached_from does not carry the argv of the run it answers from: %r"
                        % (name, second_call["cached_from"]["commands"]))
            cached_names.append(name)
        return ("3 commands, then 0 inside the 10 s window, then 3 after expiry; "
                "jitter, route and connectivity cached too, cached_from carrying "
                "the original argv")

    record("cache_second_call_free", check_cache)

    # 11. fixture mode writes nothing and reads no cache, even with --cache-path
    def check_fixture_purity():
        state = temp_root / "pure"
        state.mkdir(parents=True, exist_ok=True)
        # Seed a poisoned cache file under the exact latency key: if fixture
        # mode reads the cache it answers with this, and if it writes, the
        # bytes change. Neither may happen.
        explicit = state / "explicit-cache.json"
        poisoned = json.dumps({
            "key": {"tailnet_gateway": "auto", "public": "1.1.1.1"},
            "cached_at": time.time(),
            "data": {"ok": True, "cached": False, "poison": "healthy"},
        })
        explicit.write_text(poisoned, encoding="utf-8")
        ctx = fixture_ctx(healthy_path)
        ctx["state_dir"] = str(state)
        ctx["cache_path"] = str(explicit)
        before = sorted(p.name for p in state.iterdir())
        payloads = [run_latency(ctx), run_jitter(ctx), run_route(ctx), run_connectivity(ctx)]
        plan_latency(ctx)
        plan_jitter(ctx)
        plan_route(ctx)
        plan_connectivity(ctx)
        plan_flush_dns(ctx)
        after = sorted(p.name for p in state.iterdir())
        assert_true(before == after, "fixture mode created %r" % (set(after) - set(before)))
        assert_true(explicit.read_text(encoding="utf-8") == poisoned,
                    "fixture mode rewrote the file given in --cache-path")
        for payload in payloads:
            assert_true(payload.get("cached") is False, "a fixture run answered cached true")
            assert_true("poison" not in json.dumps(payload), "a fixture run read the cache file")
        assert_true(plan_latency(ctx)["cache"]["enabled"] is False,
                    "a fixture plan says the cache is enabled")
        refusal = run_flush_dns(ctx)
        assert_true(refusal["ok"] is False and refusal["kind"] == "fixture",
                    "flush-dns did not refuse in fixture mode: %r" % refusal)
        assert_true(sorted(p.name for p in state.iterdir()) == before,
                    "refused flush-dns wrote something")
        return "8 runs and plans, 0 files created, poisoned --cache-path untouched"

    record("fixture_purity", check_fixture_purity)

    # 12. flush-dns never runs a command in a test or a plan
    def check_flush_dns():
        calls = []

        def boom(argv, timeout):
            calls.append(list(argv))
            raise AssertionError("flush-dns reached the runner: %r" % (argv,))

        original = subprocess.run

        def no_subprocess(*args, **kwargs):
            raise AssertionError("flush-dns reached subprocess")

        ctx = default_ctx()
        ctx.update({"runner": boom, "host": "mac", "state_dir": str(temp_root / "flush")})
        try:
            subprocess.run = no_subprocess
            plan = plan_flush_dns(ctx)
            dry = run_flush_dns(dict(ctx, dry_run=True))
        finally:
            subprocess.run = original
        assert_true(calls == [], "flush-dns ran %r" % calls)
        assert_true(plan["class"] == "safe", "flush-dns class %r" % plan["class"])
        assert_true(plan["needs_confirmation"] is False, "flush-dns wants confirmation")
        assert_true(plan["changes_nothing"] is False, "flush-dns claims to change nothing")
        assert_true("name resolution" in (plan["interrupts"] or ""),
                    "the interruption is not documented")
        assert_true(dry["ran"] is False and dry["plan"] is False,
                    "dry run claims it ran")
        argv = [item["argv"] for item in plan["commands"]]
        assert_true(argv == [["dscacheutil", "-flushcache"],
                             ["killall", "-HUP", "mDNSResponder"]],
                    "macOS flush commands drifted: %r" % argv)
        linux_plan = plan_flush_dns(dict(ctx, host="linux"))
        assert_true([item["argv"] for item in linux_plan["commands"]]
                    == [["resolvectl", "flush-caches"]],
                    "linux flush command drifted")
        return "plan and dry run: 0 runner calls, 0 subprocess calls, exact argv pinned"

    record("flush_dns_never_runs", check_flush_dns)

    # 13. read actions that need macOS commands refuse to run live off macOS, and say why
    def check_route_host_refusal():
        ctx = default_ctx()
        ctx["host"] = "linux"
        for name in ("network.route", "network.connectivity"):
            payload = ACTIONS[name]["run"](ctx)
            assert_true(payload["ok"] is False, "%s pretended to run on linux" % name)
            assert_true(payload["kind"] == "not_this_host", "%s kind %r" % (name, payload["kind"]))
            assert_true("macOS" in payload["reason"],
                        "%s reason does not say why: %r" % (name, payload["reason"]))
            plan = ACTIONS[name]["plan"](ctx)
            assert_true(plan["ok"] is False and plan["kind"] == "not_this_host",
                        "%s plan did not report the refusal" % name)
            fixture_payload = ACTIONS[name]["run"](fixture_ctx(healthy_path, host="linux"))
            assert_true(fixture_payload["ok"] is True,
                        "%s fixture must work on any host: %r"
                        % (name, fixture_payload.get("reason")))
        return "route and connectivity refused on linux, fixtures still answer"

    record("route_host_refusal", check_route_host_refusal)

    # 14. no absolute home path in any payload
    def check_no_home_paths():
        home = str(Path.home())
        payloads = [list_payload(),
                    run_latency(fixture_ctx(healthy_path)),
                    run_jitter(fixture_ctx(healthy_path)),
                    run_route(fixture_ctx(healthy_path)),
                    run_connectivity(fixture_ctx(healthy_path)),
                    plan_flush_dns(fixture_ctx(healthy_path))]
        for payload in payloads:
            blob = json.dumps(payload, ensure_ascii=False)
            assert_true(home not in blob, "a payload carries the absolute home path")
        return "%d payloads, no %s" % (len(payloads), home)

    record("no_home_paths", check_no_home_paths)

    # 15. plans change nothing on disk
    def check_plans_change_nothing():
        state = temp_root / "plans"
        state.mkdir(parents=True, exist_ok=True)
        sentinel = state / "sentinel.txt"
        sentinel.write_text("keep\n", encoding="utf-8")
        before = sorted(p.name for p in state.iterdir()), sentinel.stat().st_mtime_ns
        ctx = fixture_ctx(healthy_path)
        ctx["state_dir"] = str(state)
        for name in sorted(ACTIONS):
            ACTIONS[name]["plan"](ctx)
        after = sorted(p.name for p in state.iterdir()), sentinel.stat().st_mtime_ns
        assert_true(before == after, "a plan touched the state dir")
        return "5 plans, state dir and sentinel untouched"

    record("plans_change_nothing", check_plans_change_nothing)

    # 16. --timeout-scale multiplies every command timeout, read in one place
    def check_timeout_scale():
        fixture_data = json.loads(healthy_path.read_text(encoding="utf-8"))
        ping_text = ("PING 100.100.0.1 (100.100.0.1): 56 data bytes\n"
                     "64 bytes from 100.100.0.1: icmp_seq=0 ttl=64 time=5.100 ms\n"
                     "64 bytes from 100.100.0.1: icmp_seq=1 ttl=64 time=5.000 ms\n"
                     "64 bytes from 100.100.0.1: icmp_seq=2 ttl=64 time=5.200 ms\n"
                     "\n--- 100.100.0.1 ping statistics ---\n"
                     "3 packets transmitted, 3 packets received, 0.0% packet loss\n"
                     "round-trip min/avg/max/stddev = 5.000/5.100/5.200/0.070 ms\n")
        answers = {
            "netstat": (fixture_data["commands"]["netstat_route"], "", 0),
            "ifconfig": (fixture_data["commands"]["ifconfig"], "", 0),
            "scutil": (fixture_data["commands"]["scutil_dns"], "", 0),
            "tailscale": (json.dumps(fixture_data["tailscale"]), "", 0),
            "ping": (ping_text, "", 0),
        }
        base = {"netstat": PROBE_TIMEOUT_S, "ifconfig": PROBE_TIMEOUT_S,
                "scutil": PROBE_TIMEOUT_S, "tailscale": PROBE_TIMEOUT_S,
                "ping": PING_TIMEOUT_S}

        def recording_ctx(scale):
            seen = []

            def runner(argv, timeout):
                seen.append((list(argv), timeout))
                return answers.get(os.path.basename(argv[0]), ("", "", 0))

            ctx = default_ctx()
            ctx.update({"runner": runner, "host": "mac", "cache": False,
                        "state_dir": str(temp_root / "scale")})
            if scale is not None:
                ctx["timeout_scale"] = scale
            return ctx, seen

        scale = 0.25
        ctx, seen = recording_ctx(scale)
        run_route(ctx)
        assert_true(len(seen) == 3, "route ran %d commands, expected 3" % len(seen))
        for argv, timeout in seen:
            wanted = base[os.path.basename(argv[0])] * scale
            assert_true(abs(timeout - wanted) < 1e-9,
                        "route %s got %ss, not %ss" % (argv[0], timeout, wanted))

        ctx, seen = recording_ctx(scale)
        run_jitter(ctx)
        assert_true(len(seen) == 1, "jitter ran %d commands, expected 1" % len(seen))
        assert_true(abs(seen[0][1] - JITTER_TIMEOUT_S * scale) < 1e-9,
                    "jitter got %ss, not %ss" % (seen[0][1], JITTER_TIMEOUT_S * scale))

        ctx, seen = recording_ctx(scale)
        run_latency(ctx)
        assert_true(any(os.path.basename(argv[0]) == "ping" for argv, _timeout in seen),
                    "latency ran no ping")
        for argv, timeout in seen:
            wanted = base[os.path.basename(argv[0])] * scale
            assert_true(abs(timeout - wanted) < 1e-9,
                        "latency %s got %ss, not %ss" % (argv[0], timeout, wanted))

        ctx, seen = recording_ctx(None)
        run_route(ctx)
        assert_true([timeout for _argv, timeout in seen] == [PROBE_TIMEOUT_S] * 3,
                    "without a scale the route timeouts moved: %r" % seen)
        return ("route, jitter and latency pass %s of their timeouts; no scale "
                "leaves the base numbers alone" % scale)

    record("timeout_scale", check_timeout_scale)

    # 19. the payload contract: a stated scale range refused before any timeout
    #     conversion, generated_at on every success including plans and dry
    #     runs, and commands equal to the trace the runner actually saw
    def check_payload_contract():
        stamp_re = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
        stamped = []

        def assert_stamp(payload, label):
            value = payload.get("generated_at")
            assert_true(isinstance(value, str) and bool(stamp_re.match(value)),
                        "%s carries no UTC ISO generated_at: %r" % (label, value))
            stamped.append(label)

        # every success: plan, dry run, run, and --list
        for name in sorted(ACTIONS):
            ctx = fixture_ctx(healthy_path)
            assert_stamp(ACTIONS[name]["plan"](ctx), "%s plan" % name)
            assert_stamp(ACTIONS[name]["run"](dict(ctx, dry_run=True)),
                         "%s dry run" % name)
            if name != "network.flush-dns":
                # flush-dns refuses in fixture mode by design; its run payload
                # is stamped below through a silent runner instead
                assert_stamp(ACTIONS[name]["run"](ctx), "%s fixture run" % name)
        flush_ctx = default_ctx()
        flush_ctx.update({"runner": CountingRunner(), "host": "mac",
                          "state_dir": str(temp_root / "stamp-flush")})
        flush_payload = run_flush_dns(flush_ctx)
        assert_true(flush_payload["ok"] is True and flush_payload["ran"] is True,
                    "the stamped flush-dns run did not run: %r" % flush_payload)
        assert_stamp(flush_payload, "network.flush-dns run")
        assert_stamp(list_payload(), "--list")

        # the scale is a stated range, and the CLI refuses outside it (exit 2)
        for value in (0.01, 0.25, 1.0, 3600.0):
            scale, reason = validate_timeout_scale(value)
            assert_true(scale == value and reason is None,
                        "scale %r was refused: %r" % (value, reason))
        for value in (0.0, -1.0, 0.009, 3600.5, 1000000.0, float("inf"), float("nan")):
            scale, reason = validate_timeout_scale(value)
            assert_true(scale is None and bool(reason),
                        "scale %r was accepted as %r" % (value, scale))
        refused_cli = []
        for text in ("1000000", "inf", "-inf", "nan", "-1", "abc"):
            out = subprocess.run([sys.executable, str(Path(__file__).resolve()),
                                  "--run", "network.route", "--json",
                                  "--timeout-scale", text,
                                  "--state-dir", str(temp_root / "scale-cli")],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            body = out.stdout.decode("utf-8")
            stderr = out.stderr.decode("utf-8")
            assert_true(out.returncode == 2,
                        "--timeout-scale %s exited %d, not 2" % (text, out.returncode))
            assert_true("Traceback" not in stderr,
                        "--timeout-scale %s raised a traceback: %s" % (text, stderr))
            assert_true(body.count("\n") == 1,
                        "--timeout-scale %s printed %d lines" % (text, body.count("\n")))
            payload = json.loads(body)
            assert_true(payload.get("ok") is False, "--timeout-scale %s is not ok:false" % text)
            assert_true(payload.get("kind") == "bad_argument",
                        "--timeout-scale %s kind %r" % (text, payload.get("kind")))
            assert_true(isinstance(payload.get("generated_at"), str)
                        and bool(stamp_re.match(payload["generated_at"])),
                        "--timeout-scale %s has no generated_at" % text)
            assert_true("0.01" in (payload.get("reason") or ""),
                        "--timeout-scale %s reason does not state the range: %r"
                        % (text, payload.get("reason")))
            refused_cli.append(text)

        # commands is the run trace: latency (3 calls) and connectivity (5)
        fixture_data = json.loads(healthy_path.read_text(encoding="utf-8"))
        ping_text = ("PING 100.100.0.1 (100.100.0.1): 56 data bytes\n"
                     "64 bytes from 100.100.0.1: icmp_seq=0 ttl=64 time=5.100 ms\n"
                     "64 bytes from 100.100.0.1: icmp_seq=1 ttl=64 time=5.000 ms\n"
                     "64 bytes from 100.100.0.1: icmp_seq=2 ttl=64 time=5.200 ms\n"
                     "64 bytes from 100.100.0.1: icmp_seq=3 ttl=64 time=5.050 ms\n"
                     "64 bytes from 100.100.0.1: icmp_seq=4 ttl=64 time=5.150 ms\n"
                     "\n--- 100.100.0.1 ping statistics ---\n"
                     "5 packets transmitted, 5 packets received, 0.0% packet loss\n"
                     "round-trip min/avg/max/stddev = 5.000/5.100/5.200/0.070 ms\n")
        answers = {
            "netstat": (fixture_data["commands"]["netstat_route"], "", 0),
            "ifconfig": (fixture_data["commands"]["ifconfig"], "", 0),
            "tailscale": (json.dumps(fixture_data["tailscale"]), "", 0),
            "ping": (ping_text, "", 0),
        }

        def live_ctx(label):
            runner = CountingRunner(answers=answers)
            ctx = default_ctx()
            ctx.update({"runner": runner, "host": "mac", "cache": False,
                        "state_dir": str(temp_root / label)})
            return ctx, runner

        def key(argv):
            return tuple(str(piece) for piece in argv)

        parity = []
        for name, plan_fn, expected in (("network.latency", plan_latency, 3),
                                        ("network.connectivity", plan_connectivity, 5)):
            ctx, runner = live_ctx("parity-%s" % name.split(".")[-1])
            payload = ACTIONS[name]["run"](ctx)
            assert_true(payload.get("ok") is True,
                        "%s live-shaped run failed: %r" % (name, payload.get("reason")))
            trace = [list(call) for call in runner.calls]
            listed = [item["argv"] for item in payload["commands"]]
            assert_true(len(trace) == expected,
                        "%s issued %d commands, expected %d" % (name, len(trace), expected))
            assert_true(len(listed) == len(trace),
                        "%s listed %d commands for %d runner calls"
                        % (name, len(listed), len(trace)))
            assert_true(sorted(key(argv) for argv in listed) == sorted(key(call) for call in trace),
                        "%s commands do not match the runner calls: %r vs %r"
                        % (name, listed, trace))
            for item in payload["commands"]:
                assert_true("exit" in item, "%s run command has no exit: %r" % (name, item))

            plan_ctx, _plan_runner = live_ctx("parity-plan-%s" % name.split(".")[-1])
            plan = plan_fn(plan_ctx)
            planned = [item["argv"] for item in plan["commands"]]
            assert_true(sorted(key(argv) for argv in planned) == sorted(key(call) for call in trace),
                        "%s plan lists %r while the run issues %r" % (name, planned, trace))
            for item in plan["commands"]:
                assert_true("why" in item, "%s plan command has no why: %r" % (name, item))
            parity.append("%s %d/%d" % (name, len(listed), len(trace)))

        # a cache hit inherits the whole list, tailscale status included
        clock = {"now": 3000.0}
        ctx = default_ctx()
        runner = CountingRunner(answers=answers)
        ctx.update({"runner": runner, "host": "mac", "now": lambda: clock["now"],
                    "state_dir": str(temp_root / "parity-cache")})
        first = run_connectivity(ctx)
        issued = len(runner.calls)
        second = run_connectivity(ctx)
        assert_true(first["ok"] is True, "the cached connectivity run failed")
        assert_true(second.get("cached") is True, "the second connectivity call is not cached")
        assert_true(len(runner.calls) == issued, "the cache hit issued %d commands"
                    % (len(runner.calls) - issued))
        assert_true(len(second["cached_from"]["commands"]) == issued,
                    "cached_from lists %d of the %d commands the run issued"
                    % (len(second["cached_from"]["commands"]), issued))
        assert_true(any(key(item["argv"])[-1] == "--json" for item in
                        second["cached_from"]["commands"]),
                    "cached_from lost the tailscale status call")
        return ("%d payloads stamped, plans and dry runs included; scale range "
                "0.01 to 3600, %d CLI refusals at exit 2; %s; cached_from %d/%d"
                % (len(stamped), len(refused_cli), ", ".join(parity), issued, issued))

    record("payload_contract", check_payload_contract)

    # 20. the committed fixtures carry no real identifiers: documentation MACs
    #     and documentation LAN ranges only, with the record counts unchanged.
    def check_fixture_sanitised():
        mac_re = re.compile(
            r"(?<![0-9A-Fa-f:])[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}(?![0-9A-Fa-f:])")
        dotted_re = re.compile(
            r"(?<![0-9A-Fa-f.])[0-9A-Fa-f]{2}(?:\.[0-9A-Fa-f]{2}){5}(?![0-9A-Fa-f.])")
        private_re = re.compile(r"192\.168\.|10\.[0-9]+\.|172\.(?:1[6-9]|2[0-9]|3[01])\.")
        doc_re = re.compile(r"192\.0\.2\.|198\.51\.100\.|203\.0\.113\.")
        mac_count = 0
        for path in (healthy_path, down_path):
            text = path.read_text(encoding="utf-8")
            for mac in mac_re.findall(text):
                assert_true(mac.startswith("02:00:5e:10:"),
                            "%s keeps a non-documentation MAC %r" % (path.name, mac))
            for mac in dotted_re.findall(text):
                assert_true(mac.startswith("02.00.5e."),
                            "%s keeps a non-documentation MAC %r" % (path.name, mac))
            found = private_re.search(text)
            assert_true(found is None,
                        "%s keeps a private LAN address: %r"
                        % (path.name, found.group(0) if found else None))
            mac_count += len(mac_re.findall(text))
        healthy = healthy_path.read_text(encoding="utf-8")
        assert_true(doc_re.search(healthy), "the healthy fixture has no documentation LAN")
        # IPv4 private ranges are covered by ``private_re`` just above.
        for needle in ("2001:4bb8", "fd9e:", "fd8d:"):
            assert_true(needle not in healthy
                        and needle not in down_path.read_text(encoding="utf-8"),
                        "a recording keeps the real identifier %r" % needle)
        data = json.loads(healthy)
        assert_true(len(data["commands"]) == 7,
                    "command capture count changed: %d" % len(data["commands"]))
        assert_true(len(parse_interfaces(data["commands"]["ifconfig"])) == 25,
                    "interface record count changed")
        assert_true(len(peers_of(data["tailscale"])) == 2, "peer record count changed")
        assert_true(len(parse_default_routes(data["commands"]["netstat_route"])) == 4,
                    "default route record count changed")
        return ("2 fixtures, %d MAC-shaped values all in 02:00:5e:10 / 02.00.5e, "
                "no private LAN, 7 captures, 25 interfaces, 2 peers, 4 default rows"
                % mac_count)

    record("fixture_sanitised", check_fixture_sanitised)

    # 21. a read that measured nothing is an error answer, not ok:true with
    #     four false checks; every unmeasured field is null with a reason.
    def check_null_measurements():
        empty = temp_root / "null-measurements.json"
        empty.write_text(json.dumps({"host": "mac", "commands": {}}), encoding="utf-8")

        route = run_route(fixture_ctx(empty))
        assert_true(route["ok"] is False, "a route read with nothing measured is ok:true")
        assert_true(route["kind"] == "missing", "route kind %r" % route.get("kind"))
        assert_true(not any(route["measured"].values()), "route claims a measurement")
        assert_true(set(route["unmeasured"]) == {"default_route", "tunnel", "dns",
                                                 "interfaces"},
                    "route unmeasured %r" % sorted(route["unmeasured"]))
        assert_true(route["default_route"]["gateway"] is None
                    and bool(route["default_route"]["reason"]),
                    "default_route is not null with a reason: %r" % route["default_route"])
        assert_true(route["tunnel"]["address"] is None and bool(route["tunnel"]["reason"]),
                    "tunnel is not null with a reason: %r" % route["tunnel"])
        assert_true(route["dns"]["servers"] == [] and bool(route["dns"]["reason"]),
                    "dns is not empty with a reason: %r" % route["dns"])
        assert_true(route["interfaces"]["count"] == 0
                    and bool(route["interfaces"]["reason"]),
                    "interfaces is not empty with a reason: %r" % route["interfaces"])
        assert_true("nothing measured" in route["reason"],
                    "route reason %r" % route["reason"])

        conn = run_connectivity(fixture_ctx(empty))
        assert_true(conn["ok"] is False,
                    "a connectivity read with nothing measured is ok:true")
        assert_true(conn["kind"] == "missing", "connectivity kind %r" % conn.get("kind"))
        assert_true(not any(conn["measured"].values()),
                    "connectivity claims a measurement")
        for name, check in conn["checks"].items():
            assert_true(check["measured"] is False, "%s claims measured" % name)
            assert_true(check["ok"] is False and bool(check["reason"]),
                        "%s has no reason" % name)
        assert_true("nothing measured" in conn["reason"],
                    "connectivity reason %r" % conn["reason"])

        # a measurement that reports failure is still a measurement: the down
        # fixture stays ok:true with healthy false
        down = run_connectivity(fixture_ctx(down_path))
        assert_true(down["ok"] is True and down["healthy"] is False,
                    "the down fixture is no longer an ok answer")
        assert_true(any(down["measured"].values()), "the down fixture measured nothing")
        return ("route 0/4 and connectivity 0/4 measured -> ok false with a reason "
                "list; down fixture measured and ok true, healthy false")

    record("null_measurements", check_null_measurements)

    # 22. every error answer, in-process and CLI, carries generated_at, and
    #     every argument failure is one JSON line on stdout with exit 2.
    def check_error_stamps():
        stamp_re = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

        def stamped(payload, label):
            value = payload.get("generated_at")
            assert_true(isinstance(value, str) and bool(stamp_re.match(value)),
                        "%s has no UTC ISO generated_at: %r" % (label, value))
            assert_true(payload.get("ok") is False, "%s is not ok:false" % label)
            assert_true(bool(payload.get("reason")), "%s has no reason" % label)

        stamped(_refusal("host refusal"), "_refusal")
        stamped(error_payload("boom", "malformed"), "error_payload")
        empty = temp_root / "stamp-empty.json"
        empty.write_text(json.dumps({"host": "mac", "commands": {}}), encoding="utf-8")
        stamped(run_route(fixture_ctx(empty)), "route nothing measured")
        stamped(run_connectivity(fixture_ctx(empty)), "connectivity nothing measured")
        stamped(run_flush_dns(fixture_ctx(healthy_path)), "flush-dns fixture refusal")

        bad = temp_root / "stamp-bad.json"
        bad.write_text("{not json", encoding="utf-8")
        cases = [
            (["--fixture", str(bad), "--run", "network.latency", "--json"], 0),
            (["--plan", "network.nope", "--json"], 2),
            (["--run", "network.route", "--json", "--timeout-scale", "abc"], 2),
            (["--run", "network.route", "--json", "--timeout-scale", "-inf"], 2),
            (["--run", "network.route", "--json", "--timeout-scale", "inf"], 2),
        ]
        for argv, code in cases:
            out = subprocess.run([sys.executable, str(Path(__file__).resolve())] + argv,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            body = out.stdout.decode("utf-8")
            stderr = out.stderr.decode("utf-8")
            assert_true(out.returncode == code,
                        "%r exit %d, expected %d" % (argv, out.returncode, code))
            assert_true(body.count("\n") == 1,
                        "%r printed %d lines on stdout" % (argv, body.count("\n")))
            assert_true("Traceback" not in stderr, "%r raised: %s" % (argv, stderr))
            stamped(json.loads(body), " ".join(argv))
        return ("5 in-process errors stamped, 5 CLI errors one JSON line each "
                "at the documented exit code")

    record("error_stamps", check_error_stamps)

    failed = [check for check in checks if not check["ok"]]
    payload = {
        "ok": not failed,
        "generated_at": utc_now_iso(),
        "self_check": True,
        "passed": len(checks) - len(failed),
        "failed": len(failed),
        "checks": checks,
        "fixtures": [display_path(healthy_path), display_path(down_path)],
    }
    print_json(payload, compact)
    try:
        for item in temp_root.iterdir():
            if item.is_file():
                item.unlink()
        for item in sorted(temp_root.rglob("*"), reverse=True):
            if item.is_dir():
                item.rmdir()
            elif item.is_file():
                item.unlink()
        temp_root.rmdir()
    except OSError:
        pass
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
