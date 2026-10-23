#!/usr/bin/env python3
"""game_mode.py - HUD v5 F3 game mode controller (Marcel's DP-2 deck).

One tap flips dictation and game: runs ptt-toggle on Linux, reports the ptt
state, the mouse profile, ping and jitter to the router and to 1.1.1.1, and
proposes a pause-heavy flag for the Mac fleet dispatcher while a game process
runs.

Host reality (checked on this Mac, 2026-10-23): ptt-toggle and hyprctl are
Linux-only and absent here; ping and pgrep exist on both. So every Linux
command sits behind --fixture PATH or --host linux, and the whole script passes
--self-check on the Mac with no Linux host state.

Subcommands (exactly one):
  --status      one status JSON (mode, game, mouse profile, net, pause flag)
  --probe       network only, same cache as --status
  --toggle      flip dictation/game; runs ptt-toggle on Linux, simulated from a
                fixture on the Mac; writes the pause-heavy flag
  --self-check  hermetic checks, exit non-zero on any failure

Signals:
  /proc/<pid>/cmdline        game process, read directly (no subprocess per poll);
                             patterns PioneerGame and ArcRaiders, override with
                             --pattern (repeatable). pgrep -f only with --pgrep-cmd
                             or on a host without /proc
  hyprctl clients -j         window classes, Linux only (fixture-only on the Mac)
  ~/.cache/ptt-toggle.state  dictation/game state written by ptt-toggle
  ~/.cache/mouse-profile     optional one-line mouse profile, if such a file exists

Output: one JSON object on stdout, UTC ISO timestamps. --json prints it as one
compact line for a Process consumer; the default is the same object pretty
printed. Exit 0 for data and for honest absence ({"ok": false, "reason": ...,
"kind": ...}), exit 2 only for a bad argument or a file the caller named that
does not exist.

Writes: ~/.local/state/nexuslink/game_mode.json (the proposed pause-heavy flag,
atomic) and ~/.local/state/nexuslink/game_mode_net.json (net cache, atomic, 10 s
floor, keyed on both ping targets). --state-dir moves both; --no-write suppresses
writes and --dry-run suppresses writes and the network probe (both targets come
back null with reason "dry-run"). A --fixture run writes neither and reads no
host state unless the caller names --state-dir, --flag-file or --cache-file;
--toggle --fixture keeps its documented ptt.state write. Nothing else is
written. In --fixture mode generated_at is the only live clock stamp: the
pause-heavy since and net.measured_at come from the fixture or are null, never
from the host clock. Contract: GAME_MODE_CONTRACT.md next to this file.

Stdlib only, Python 3.9+.
"""

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
from pathlib import Path

PROGRAM = "game_mode.py"
DEFAULT_PATTERNS = ("PioneerGame", "ArcRaiders")
PUBLIC_HOST = "1.1.1.1"

STATE_DIR = Path.home() / ".local" / "state" / "nexuslink"
FLAG_NAME = "game_mode.json"
CACHE_NAME = "game_mode_net.json"
PTT_STATE = Path.home() / ".cache" / "ptt-toggle.state"
MOUSE_STATE = Path.home() / ".cache" / "mouse-profile"

CACHE_TTL_FLOOR_S = 10.0       # contract: never probe the network faster than this
NET_TIMEOUT_S = 25.0
PGREP_TIMEOUT_S = 5.0
HYPRCTL_TIMEOUT_S = 5.0
TOGGLE_TIMEOUT_S = 10.0

DICTATION_TOKENS = ("on", "dictation", "ptt", "push-to-talk", "push to talk", "talk",
                    "enabled", "active", "1", "true", "yes")
GAME_TOKENS = ("off", "game", "gaming", "disabled", "inactive", "0", "false", "no")


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


def display_path(path):
    """~-relative path so the feed never prints an absolute home path."""
    try:
        p = Path(path)
        home = Path.home()
        rel = p.relative_to(home)
        return "~/" + str(rel)
    except (ValueError, TypeError):
        return str(path)


def tilde_text(message):
    """A message that may quote a path: the home prefix becomes ~.

    Same job as W8's tilde_text in _common.py; F3 keeps its own copy so this
    file stays standalone (W8 is not in v5/main-deck yet). The home prefix only
    matches a whole path component, so a sibling like /Users/marcelspatz plus a
    suffix is left alone. Every reason or warning built from an OSError goes
    through it, so an error never prints $HOME absolute.
    """
    text = str(message or "")
    for root in (str(Path.home()), os.path.realpath(str(Path.home()))):
        if root and root != "/":
            text = re.sub(re.escape(root) + r"(?=$|[/\\'\"\s:,)])", "~", text)
    return text


def read_text(path):
    try:
        with open(str(path), "r", encoding="utf-8", errors="replace") as f:
            return f.read(), None
    except FileNotFoundError:
        return None, "missing"
    except OSError as e:
        return None, tilde_text(e)


def read_json(path):
    text, err = read_text(path)
    if text is None:
        return None, err
    try:
        return json.loads(text), None
    except ValueError as e:
        return None, "malformed json: %s" % e


def atomic_write_json(path, obj):
    """temp file in the same directory + os.replace. Returns (ok, error)."""
    path = Path(path)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".%s." % path.name, dir=str(path.parent))
    except OSError as e:
        return False, tilde_text(e)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, str(path))
        return True, None
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False, tilde_text(e)


def run_cmd(cmd, timeout):
    """(returncode|None, stdout, stderr-or-reason). Never raises."""
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=timeout)
    except FileNotFoundError:
        return None, "", "command not found: %s" % tilde_text(cmd[0])
    except subprocess.TimeoutExpired:
        return None, "", "timed out after %ss: %s" % (timeout, tilde_text(" ".join(cmd)))
    except OSError as e:
        return None, "", tilde_text("could not run %s: %s" % (cmd[0], e))
    out = proc.stdout.decode("utf-8", "replace") if isinstance(proc.stdout, bytes) else proc.stdout
    err = proc.stderr.decode("utf-8", "replace") if isinstance(proc.stderr, bytes) else proc.stderr
    return proc.returncode, out, err


def short(text, limit=160):
    if not text:
        return ""
    line = " ".join(str(text).split())
    return line[:limit]


ERR_MISSING = "missing"
ERR_MALFORMED = "malformed"
ERR_UNAVAILABLE = "unavailable"
ERR_FAILED = "failed"


def fail_payload(reason, kind=None, **extra):
    """ok:false envelope. kind says why the data is absent, never a plausible value."""
    payload = {"ok": False, "generated_at": utc_now_iso(), "reason": reason}
    if kind:
        payload["kind"] = kind
    payload.update(extra)
    return payload


def emit(payload, code=0, compact=False):
    """One JSON object on stdout. --json = one compact line, default = pretty."""
    if compact:
        sys.stdout.write(json.dumps(payload, separators=(",", ":"), ensure_ascii=False) + "\n")
    else:
        sys.stdout.write(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    return code


# --------------------------------------------------------------------------
# arguments
# --------------------------------------------------------------------------

class Cfg(object):
    def __init__(self, args):
        self.action = ("status" if args.status else
                       "probe" if args.probe else
                       "toggle" if args.toggle else "self_check")
        self.fixture = Path(args.fixture).expanduser() if args.fixture else None
        self.host = "mac" if args.host == "darwin" else args.host
        if self.host == "auto":
            self.host = host_platform()
        self.patterns = list(args.patterns) if args.patterns else list(DEFAULT_PATTERNS)
        self.gateway_host = args.gateway_host
        self.public_host = args.public_host or PUBLIC_HOST
        self.ping_cmd = args.ping_cmd
        self.pgrep_cmd = args.pgrep_cmd
        self.hyprctl_cmd = args.hyprctl_cmd
        self.toggle_cmd = args.toggle_cmd
        self.mouse_override = args.mouse_profile
        self.state_dir = Path(args.state_dir).expanduser() if args.state_dir else STATE_DIR
        self.flag_file = (Path(args.flag_file).expanduser() if args.flag_file
                          else self.state_dir / FLAG_NAME)
        self.cache_file = (Path(args.cache_file).expanduser() if args.cache_file
                           else self.state_dir / CACHE_NAME)
        self.ptt_state = Path(args.ptt_state).expanduser() if args.ptt_state else PTT_STATE
        self.ptt_state_given = args.ptt_state is not None
        self.sim_ptt_state = self.state_dir / "ptt.state"
        self.mouse_state = Path(args.mouse_state).expanduser() if args.mouse_state else MOUSE_STATE
        self.cache_ttl = max(CACHE_TTL_FLOOR_S, float(args.cache_ttl or 0.0))
        self.dry_run = bool(args.dry_run)
        self.no_write = bool(args.no_write)
        self.no_net = bool(args.no_net)
        self.live_net = bool(args.live_net)     # fixture signals + real network (Mac demo)
        self.json_output = bool(args.json)      # one compact line for a Process consumer
        self.state_dir_given = args.state_dir is not None
        self.flag_file_given = args.flag_file is not None
        self.cache_file_given = args.cache_file is not None


def parse_args(argv):
    p = argparse.ArgumentParser(
        prog=PROGRAM,
        description="HUD v5 F3 game mode controller: dictation/game toggle, game "
                    "detection, ping+jitter, pause-heavy flag.")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--status", action="store_true", help="one status JSON object")
    g.add_argument("--probe", action="store_true", help="network probe only")
    g.add_argument("--toggle", action="store_true", help="flip dictation/game and write state")
    g.add_argument("--self-check", action="store_true", help="hermetic checks, non-zero on failure")

    p.add_argument("--json", action="store_true",
                   help="print one compact JSON line (default: the same object, pretty printed)")
    p.add_argument("--fixture", metavar="PATH", help="fixture file or directory instead of the live host")
    p.add_argument("--host", choices=["auto", "mac", "linux", "darwin"], default="auto",
                   help="host profile; Linux commands only run with 'linux'")
    p.add_argument("--pattern", action="append", dest="patterns", metavar="PATTERN",
                   help="game process pattern (repeatable; default PioneerGame, ArcRaiders)")
    p.add_argument("--gateway-host", help="router to ping (default: this host's default route)")
    p.add_argument("--public-host", default=PUBLIC_HOST, help="public target (default 1.1.1.1)")
    p.add_argument("--ping-cmd", help="ping binary to use")
    p.add_argument("--pgrep-cmd", help="pgrep binary to use")
    p.add_argument("--hyprctl-cmd", help="hyprctl binary to use; forces the Linux window path")
    p.add_argument("--toggle-cmd", help="ptt-toggle binary to run")
    p.add_argument("--mouse-profile", help="report this mouse profile instead of reading a source")
    p.add_argument("--state-dir", help="state directory (default ~/.local/state/nexuslink)")
    p.add_argument("--flag-file", help="pause-heavy flag path")
    p.add_argument("--cache-file", help="net cache path")
    p.add_argument("--ptt-state", help="ptt state file (default ~/.cache/ptt-toggle.state)")
    p.add_argument("--mouse-state", help="mouse profile file (default ~/.cache/mouse-profile)")
    p.add_argument("--cache-ttl", type=float, default=CACHE_TTL_FLOOR_S,
                   help="net cache seconds; clamped to the 10 s floor")
    p.add_argument("--no-write", action="store_true", help="do not write the flag or the cache")
    p.add_argument("--dry-run", action="store_true",
                   help="report intent: no network probe, no writes")
    p.add_argument("--no-net", action="store_true", help="skip the network probe in --status")
    p.add_argument("--live-net", action="store_true",
                   help="with --fixture, still probe the real network (Mac demo)")
    return p.parse_args(argv)


# --------------------------------------------------------------------------
# fixture loading
# --------------------------------------------------------------------------

FIXTURE_MAIN = "game_mode.json"


def load_fixture(path):
    """Returns (fx dict | None, error_kind | None, error message | None).

    error_kind: 'missing' (caller named a path that is not there -> exit 2)
                'malformed' (unreadable or not JSON -> ok:false, exit 0)
                'empty' (directory without a fixture, or a zero-byte file ->
                         ok:false, exit 0, reported as kind 'missing')
    """
    if path is None:
        return None, None, None
    path = Path(path)
    if not path.exists():
        return None, "missing", "fixture not found: %s" % display_path(path)
    if path.is_dir():
        main = path / FIXTURE_MAIN
        if not main.is_file():
            return None, "empty", "fixture directory has no %s: %s" % (
                FIXTURE_MAIN, display_path(path))
        target = main
        text, err = read_text(main)
    else:
        target = path
        text, err = read_text(path)
    if text is None:
        return None, "malformed", "fixture unreadable: %s" % err
    if not text.strip():
        # The contract counts an absent and an empty fixture the same way.
        return None, "empty", "fixture is empty: %s" % display_path(target)
    try:
        obj = json.loads(text)
    except ValueError as e:
        return None, "malformed", "malformed fixture: %s" % e
    if not isinstance(obj, dict):
        return None, "malformed", "malformed fixture: top level is not an object"
    return obj, None, None


def fixture_string(fx, key):
    """A non-empty string a fixture names under key, else None. Never invents one."""
    if not isinstance(fx, dict):
        return None
    value = fx.get(key)
    if isinstance(value, str) and value.strip():
        return value.strip()
    return None


def fixture_block_string(fx, block, key):
    """A non-empty string inside a fixture's object block, else None."""
    if not isinstance(fx, dict):
        return None
    inner = fx.get(block)
    if not isinstance(inner, dict):
        return None
    value = inner.get(key)
    if isinstance(value, str) and value.strip():
        return value.strip()
    return None


def fixture_since(fx):
    """The gaming run start a fixture names: pause_heavy.since, else top-level now.

    Fixture mode never reads a clock, so a fixture that names neither reports
    since: null with a reason instead of a host timestamp.
    """
    return fixture_block_string(fx, "pause_heavy", "since") or fixture_string(fx, "now")


def fixture_measured_at(fx):
    """The snapshot time a fixture names: generated_at, else top-level now."""
    return fixture_string(fx, "generated_at") or fixture_string(fx, "now")


# --------------------------------------------------------------------------
# ping parsing
# --------------------------------------------------------------------------

def ping_argv(ping_cmd, target):
    cmd = [ping_cmd or "ping"]
    if host_platform() == "linux":
        # iputils: -W is SECONDS. 5 pings, 1 s reply wait, same shape as the card.
        cmd += ["-c", "5", "-W", "1"]
    else:
        # BSD/macOS: -W is MILLISECONDS.
        cmd += ["-c", "5", "-W", "1000"]
    cmd.append(target)
    return cmd


def _num(value):
    if value is None:
        return None
    return int(value) if float(value).is_integer() else round(float(value), 1)


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
    """mean rtt and mdev/stddev from a ping -c 5 capture. Never invents a number."""
    out = {"rtt_ms": None, "jitter_ms": None, "loss": None, "samples": 0, "reason": None}
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
        out["jitter_ms"] = round(float(stats.group(4)), 2)
    elif times:
        vals = [float(v) for v in times]
        mean = sum(vals) / len(vals)
        var = sum((v - mean) ** 2 for v in vals) / len(vals)
        out["rtt_ms"] = round(mean, 2)
        out["jitter_ms"] = round(var ** 0.5, 2)

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
             "jitter_ms": parsed.get("jitter_ms"), "loss": parsed.get("loss")}
    if parsed.get("samples"):
        entry["samples"] = parsed["samples"]
    if parsed.get("reason"):
        entry["reason"] = parsed["reason"]
    return entry


def null_entry(host, reason):
    return {"host": host, "rtt_ms": None, "jitter_ms": None, "loss": None,
            "reason": reason or "not measured"}


# --------------------------------------------------------------------------
# network probe and cache
# --------------------------------------------------------------------------

def discover_gateway():
    """Default-route gateway on this host: the router. Returns (host|None, reason|None)."""
    if host_platform() == "linux":
        if shutil.which("ip"):
            rc, out, err = run_cmd(["ip", "route", "show", "default"], PGREP_TIMEOUT_S)
            if rc == 0:
                m = re.search(r"default\s+via\s+(\S+)", out)
                if m:
                    return m.group(1), None
        if shutil.which("route"):
            rc, out, _ = run_cmd(["route", "-n"], PGREP_TIMEOUT_S)
            if rc == 0:
                for line in out.splitlines():
                    parts = line.split()
                    if len(parts) >= 2 and parts[0] == "0.0.0.0" and "UG" in line:
                        return parts[1], None
        return None, "default gateway not found (ip/route)"
    if host_platform() == "mac":
        rc, out, err = run_cmd(["route", "-n", "get", "default"], PGREP_TIMEOUT_S)
        if rc == 0:
            m = re.search(r"^\s*gateway:\s*(\S+)", out, re.MULTILINE)
            if m:
                return m.group(1), None
        return None, "default gateway not found (route): %s" % short(err or out)
    return None, "gateway discovery unsupported on %s" % host_platform()


def net_live(cfg, gateway_host=None, gateway_reason=None):
    if gateway_host is None:
        gateway_host = cfg.gateway_host
    if not gateway_host:
        gateway_host, gateway_reason = discover_gateway()

    targets = [gateway_host, cfg.public_host]
    started = []
    for target in targets:
        if not target:
            started.append(("skip", None, None))
            continue
        cmd = ping_argv(cfg.ping_cmd, target)
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE)
            started.append(("proc", proc, None))
        except FileNotFoundError:
            started.append(("err", None, "ping not found: %s" % tilde_text(cmd[0])))
        except OSError as e:
            started.append(("err", None, tilde_text("could not run ping: %s" % e)))

    entries = []
    for target, (kind, proc, err) in zip(targets, started):
        if kind == "skip":
            entries.append(null_entry(target, gateway_reason or "gateway host unknown"))
        elif kind == "err":
            entries.append(null_entry(target, err))
        else:
            try:
                out_b, err_b = proc.communicate(timeout=NET_TIMEOUT_S)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.communicate()
                entries.append(null_entry(target, "ping timed out after %ss" % NET_TIMEOUT_S))
                continue
            text = (out_b or b"").decode("utf-8", "replace") + \
                   (err_b or b"").decode("utf-8", "replace")
            entries.append(net_entry(target, parse_ping(text)))

    return {"gateway": entries[0], "public": entries[1],
            "measured_at": utc_now_iso(), "source": "live", "cached": False}


def sanitize_entry(entry, host):
    if not isinstance(entry, dict):
        return null_entry(host, "fixture entry is not an object")
    out = {"host": entry.get("host", host),
           "rtt_ms": entry.get("rtt_ms"),
           "jitter_ms": entry.get("jitter_ms"),
           "loss": entry.get("loss")}
    for key in ("samples", "reason"):
        if entry.get(key) is not None:
            out[key] = entry[key]
    return out


def fixture_net_hosts(cfg, fx):
    """The two hosts a fixture names, used for the payload and for the cache key."""
    if not isinstance(fx, dict):
        fx = {}
    net = fx.get("net")
    if not isinstance(net, dict):
        net = {}
    gateway = net.get("gateway")
    gateway = gateway if isinstance(gateway, dict) else {}
    public = net.get("public")
    public = public if isinstance(public, dict) else {}
    gateway_host = fx.get("gateway_host") or gateway.get("host") or cfg.gateway_host
    public_host = fx.get("public_host") or public.get("host") or cfg.public_host
    return gateway_host, public_host


def net_from_fixture(cfg, fx):
    ping = fx.get("ping") if isinstance(fx.get("ping"), dict) else {}
    pre = fx.get("net") if isinstance(fx.get("net"), dict) else {}
    pre_gw = pre.get("gateway") if isinstance(pre.get("gateway"), dict) else {}
    pre_pub = pre.get("public") if isinstance(pre.get("public"), dict) else {}

    gateway_host, public_host = fixture_net_hosts(cfg, fx)
    measured = fixture_measured_at(fx)

    out = {"measured_at": measured, "source": "fixture", "cached": False}
    for key, host, pre_entry in (("gateway", gateway_host, pre_gw),
                                 ("public", public_host, pre_pub)):
        text = ping.get(key)
        if isinstance(text, str) and text.strip():
            out[key] = net_entry(host, parse_ping(text))
        elif pre_entry.get("rtt_ms") is not None or pre_entry.get("reason"):
            out[key] = sanitize_entry(pre_entry, host)
        else:
            out[key] = null_entry(host, "fixture has no ping data for %s" % key)
    return out


def flag_persist_allowed(cfg):
    """Live mode owns the flag. A fixture run writes it only where the caller pointed."""
    return cfg.fixture is None or cfg.state_dir_given or cfg.flag_file_given


def cache_persist_allowed(cfg):
    """Live mode owns the net cache. A fixture run shares one only when it was named."""
    return cfg.fixture is None or cfg.state_dir_given or cfg.cache_file_given


def read_cache(cfg, source, gateway_host, public_host):
    """A cache hit needs the same source and the same two targets, inside the TTL."""
    if not isinstance(gateway_host, str) or not gateway_host:
        return None
    if not isinstance(public_host, str) or not public_host:
        return None
    obj, err = read_json(cfg.cache_file)
    if not isinstance(obj, dict) or err:
        return None
    if obj.get("source") != source:
        return None                       # a fixture probe never feeds a live status
    if obj.get("gateway_host") != gateway_host or obj.get("public_host") != public_host:
        return None                       # a round aimed at other targets is not a hit
    ts = obj.get("ts")
    if not isinstance(ts, (int, float)):
        return None
    age = time.time() - ts
    if age < 0 or age >= cfg.cache_ttl:
        return None
    gateway = obj.get("gateway")
    public = obj.get("public")
    if not isinstance(gateway, dict) or not isinstance(public, dict):
        return None
    if gateway.get("host") != gateway_host or public.get("host") != public_host:
        return None
    return {"gateway": gateway, "public": public,
            "measured_at": obj.get("measured_at") or (utc_now_iso() if source == "live" else None),
            "source": source, "cached": True}


def probe_net(cfg, fx=None):
    source = "live" if (cfg.fixture is None or cfg.live_net) else "fixture"
    gateway_reason = None
    if source == "fixture":
        gateway_host, public_host = fixture_net_hosts(cfg, fx or {})
    else:
        gateway_host = cfg.gateway_host
        public_host = cfg.public_host

    if cfg.dry_run:
        # --dry-run runs nothing: no gateway discovery, no ping, no cache read,
        # no cache write. Both targets are null with a reason, never a number.
        return {"gateway": null_entry(gateway_host, "dry-run"),
                "public": null_entry(public_host, "dry-run"),
                "measured_at": None, "source": source, "cached": False}

    if source == "live" and not gateway_host:
        gateway_host, gateway_reason = discover_gateway()

    shared_cache = cache_persist_allowed(cfg)
    if shared_cache and source == "live":
        # A fixture carries its own net values, so it never reads the cache: a
        # cached hit would make the second of two fixture runs differ from the
        # first. Live probes keep the 10 s floor.
        cached = read_cache(cfg, source, gateway_host, public_host)
        if cached:
            return cached

    if source == "fixture":
        net = net_from_fixture(cfg, fx or {})
    else:
        net = net_live(cfg, gateway_host, gateway_reason)

    if shared_cache and not cfg.dry_run and not cfg.no_write:
        measured = net.get("measured_at")
        if measured is None and source == "live":
            measured = utc_now_iso()
        atomic_write_json(cfg.cache_file, {
            "measured_at": measured,
            "ts": time.time(),
            "source": source,
            "gateway_host": gateway_host,
            "public_host": public_host,
            "gateway": net["gateway"],
            "public": net["public"],
        })
    return net


# --------------------------------------------------------------------------
# game detection
# --------------------------------------------------------------------------

def match_pattern(text, patterns):
    low = str(text or "").lower()
    for pattern in patterns:
        if pattern and pattern.lower() in low:
            return pattern
    return None


def fixture_processes(fx):
    """pgrep block: list of {pid, command} | list of strings | {running, process}.

    Returns (entries, explicit_dict, has_signal). An empty list is a signal
    ("pgrep printed nothing"), a missing key is honest absence.
    """
    raw = fx.get("pgrep")
    entries = []
    explicit = None
    has_signal = False
    if isinstance(raw, dict):
        explicit = raw
        has_signal = True
        if isinstance(raw.get("processes"), list):
            entries = raw["processes"]
        elif raw.get("command") or raw.get("name") or raw.get("cmdline"):
            entries = [raw]
    elif isinstance(raw, list):
        entries = raw
        has_signal = True
    elif isinstance(raw, str):
        entries = [line for line in raw.splitlines() if line.strip()]
        has_signal = True
    return entries, explicit, has_signal


def game_from_fixture(fx, patterns):
    game = {"running": None, "process": None, "class": None, "pid": None}
    entries, explicit, has_signal = fixture_processes(fx)
    for entry in entries:
        if isinstance(entry, dict):
            text = entry.get("command") or entry.get("cmdline") or entry.get("name") or ""
            pid = entry.get("pid")
        else:
            text, pid = str(entry), None
        hit = match_pattern(text, patterns)
        if hit:
            game.update({"running": True, "process": hit, "pid": pid})
            break

    clients = fx.get("hyprctl")
    if isinstance(clients, str):
        try:
            clients = json.loads(clients)
        except ValueError:
            clients = []
    if isinstance(clients, dict):
        clients = clients.get("clients") or []
    if isinstance(clients, list):
        for client in clients:
            if not isinstance(client, dict):
                continue
            klass = client.get("class") or client.get("initialClass") or ""
            if match_pattern(klass, patterns):
                game["class"] = klass
                if game["running"] is not True:
                    game.update({"running": True, "process": match_pattern(klass, patterns),
                                 "pid": client.get("pid")})
                break

    if explicit is not None and "running" in explicit:
        game["running"] = bool(explicit.get("running"))
        if explicit.get("process"):
            game["process"] = explicit["process"]
        if explicit.get("class"):
            game["class"] = explicit["class"]
        if explicit.get("pid") is not None:
            game["pid"] = explicit.get("pid")

    if game["running"] is None:
        if has_signal:
            game["running"] = False      # a capture that matched nothing is a measurement
        else:
            game["reason"] = "fixture has no pgrep or hyprctl signal"
    return game


def proc_available():
    return os.path.isdir("/proc/self")


def proc_cmdline_text(pid_name):
    """Command line of one /proc entry, or its comm name for kernel threads."""
    base = "/proc/%s/" % pid_name
    try:
        with open(base + "cmdline", "rb") as fh:
            text = fh.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
    except OSError:
        text = ""
    if not text:
        try:
            with open(base + "comm", "rb") as fh:
                text = fh.read().decode("utf-8", "replace").strip()
        except OSError:
            text = ""
    return text


def proc_match(patterns):
    """Game process from /proc alone: no subprocess, same answer shape as pgrep_match.

    A process matches when its command line (or comm, for kernel threads)
    contains one of the patterns. The scanner's own pid is skipped, as pgrep
    does for itself.
    """
    try:
        names = [n for n in os.listdir("/proc") if n.isdigit()]
    except OSError as e:
        return {"running": None, "process": None, "pid": None,
                "reason": "cannot read /proc: %s" % short(e.strerror or e)}
    me = os.getpid()
    live = [p for p in patterns if p]
    for name in sorted(names, key=int):
        if int(name) == me:
            continue
        text = proc_cmdline_text(name)
        if not text:
            continue
        for pattern in live:
            if pattern in text:
                return {"running": True, "process": pattern, "pid": int(name), "reason": None}
    return {"running": False, "process": None, "pid": None, "reason": None}


def process_match(cfg):
    """Process signal: /proc on Linux; pgrep only when --pgrep-cmd is given or /proc is absent."""
    if cfg.pgrep_cmd or not proc_available():
        return pgrep_match(cfg)
    return proc_match(cfg.patterns)


def pgrep_match(cfg):
    binary = cfg.pgrep_cmd or shutil.which("pgrep") or "pgrep"
    errors = []
    for pattern in cfg.patterns:
        rc, out, err = run_cmd([binary, "-f", pattern], PGREP_TIMEOUT_S)
        if rc == 0:
            pids = [int(tok) for tok in out.split() if tok.isdigit()]
            if pids:
                return {"running": True, "process": pattern, "pid": pids[0], "reason": None}
        elif rc == 1:
            continue
        elif rc is None:
            errors.append(err)
        else:
            errors.append("pgrep exit %s: %s" % (rc, short(err)))
    if errors and len(errors) == len(cfg.patterns):
        return {"running": None, "process": None, "pid": None,
                "reason": "; ".join(errors[:2])}
    return {"running": False, "process": None, "pid": None, "reason": None}


def hyprctl_clients(cfg):
    """Window list on Linux (or through an explicit --hyprctl-cmd)."""
    binary = cfg.hyprctl_cmd
    if not binary:
        if cfg.host != "linux" or host_platform() != "linux":
            return None, "hyprctl is Linux-only on this host"
        binary = shutil.which("hyprctl")
        if not binary:
            return None, "hyprctl not installed"
    rc, out, err = run_cmd([binary, "clients", "-j"], HYPRCTL_TIMEOUT_S)
    if rc is None:
        return None, err
    if rc != 0:
        return None, "hyprctl exit %s: %s" % (rc, short(err))
    try:
        data = json.loads(out)
    except ValueError as e:
        return None, "hyprctl json: %s" % e
    if isinstance(data, dict):
        data = data.get("clients") or []
    if not isinstance(data, list):
        return None, "hyprctl clients is not a list"
    return data, None


def detect_live(cfg):
    found = process_match(cfg)
    game = {"running": found["running"], "process": found["process"],
            "class": None, "pid": found.get("pid")}
    if found.get("reason"):
        game["reason"] = found["reason"]

    if game["running"] is not True:
        clients, cerr = hyprctl_clients(cfg)
        if clients:
            for client in clients:
                klass = client.get("class") or client.get("initialClass") or ""
                hit = match_pattern(klass, cfg.patterns)
                if hit:
                    game.update({"running": True, "class": klass,
                                 "process": game.get("process") or hit,
                                 "pid": client.get("pid")})
                    game.pop("reason", None)
                    break
        elif cerr and game["running"] is None and "reason" not in game:
            game["reason"] = cerr
    return game


# --------------------------------------------------------------------------
# ptt state, mode, mouse profile
# --------------------------------------------------------------------------

def normalize_state(token):
    low = str(token or "").strip().lower()
    if low in DICTATION_TOKENS:
        return "dictation"
    if low in GAME_TOKENS:
        return "game"
    return "unknown"


def parse_state_text(text):
    raw = (text or "").strip()
    if not raw:
        return "unknown", None
    if raw.startswith("{"):
        try:
            obj = json.loads(raw)
            if isinstance(obj, dict):
                for key in ("state", "mode", "ptt", "value"):
                    if isinstance(obj.get(key), str):
                        return normalize_state(obj[key]), short(obj[key], 40)
        except ValueError:
            pass
    for line in raw.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            if key.strip().lower() in ("state", "mode", "ptt"):
                return normalize_state(value), short(value, 40)
    first = raw.splitlines()[0]
    return normalize_state(first), short(first, 40)


def read_ptt(cfg, fx):
    # Sources in order: a path the caller named, the simulated state a fixture
    # toggle wrote under a state dir the caller named, the real ptt-toggle state,
    # then the fixture's snapshot value. Live mode never writes a ptt state at all.
    candidates = []
    if cfg.ptt_state_given:
        candidates.append(cfg.ptt_state)
    if fx is not None:
        if cfg.state_dir_given:
            candidates.append(cfg.sim_ptt_state)   # only where the caller pointed
    else:
        candidates.append(cfg.ptt_state)
    for path in candidates:
        if path.is_file():
            text, err = read_text(path)
            if text is not None:
                state, raw = parse_state_text(text)
                return state, {"state": state, "raw": raw, "source": "file",
                               "path": display_path(path)}
            return "unknown", {"state": "unknown", "raw": None, "source": "file",
                               "path": display_path(path), "reason": err}
    if fx is not None:
        value = fx.get("ptt_state")
        if isinstance(value, dict):
            value = value.get("state") or value.get("mode")
        if isinstance(value, str) and value.strip():
            state, raw = parse_state_text(value)
            return state, {"state": state, "raw": raw, "source": "fixture"}
        return "unknown", {"state": "unknown", "raw": None, "source": "fixture"}
    return "unknown", {"state": "unknown", "raw": None, "source": "absent",
                       "path": display_path(cfg.ptt_state)}


def resolve_mode(ptt_state, running):
    if ptt_state in ("dictation", "game"):
        return ptt_state
    if running is True:
        return "game"
    return "unknown"


def read_mouse(cfg, fx):
    if cfg.mouse_override:
        return cfg.mouse_override, "flag"
    if fx is not None:
        value = fx.get("mouse_profile")
        if isinstance(value, str) and value.strip():
            return value.strip(), "fixture"
        return None, "no mouse profile in fixture"
    text, err = read_text(cfg.mouse_state)
    if text:
        for line in text.splitlines():
            if line.strip():
                return line.strip(), "file"
    return None, "no mouse profile source on this host"


# --------------------------------------------------------------------------
# the proposed pause-heavy flag
# --------------------------------------------------------------------------

def apply_flag(cfg, gaming, now_iso, fx=None):
    """Write ~/.local/state/nexuslink/game_mode.json atomically.

    Returns (obj, warning, since_reason). In fixture mode since comes from the
    fixture (pause_heavy.since, else a top-level now) or is null with a reason;
    the host clock never stamps it. Live mode keeps the start of a run the flag
    file already records, and otherwise starts the run at now_iso.
    """
    persist = flag_persist_allowed(cfg)
    fixture_mode = cfg.fixture is not None
    prev = read_json(cfg.flag_file)[0] if (persist and not fixture_mode) else None
    since = None
    since_reason = None
    if gaming:
        if fixture_mode:
            since = fixture_since(fx)
            if since is None:
                since_reason = "fixture has no since"
        elif isinstance(prev, dict) and prev.get("gaming") is True and isinstance(prev.get("since"), str):
            since = prev["since"]          # stable across ticks, not reset every poll
        else:
            since = now_iso
    obj = {"gaming": bool(gaming), "pause_heavy": bool(gaming),
           "since": since, "updated_at": now_iso}
    if not persist:
        return obj, "pause-heavy flag not written: fixture mode, no --state-dir or --flag-file", since_reason
    if cfg.dry_run:
        return obj, "pause-heavy flag not written (--dry-run)", since_reason
    if cfg.no_write:
        return obj, "pause-heavy flag not written (--no-write)", since_reason
    ok, err = atomic_write_json(cfg.flag_file, obj)
    if not ok:
        return obj, tilde_text("pause-heavy flag write failed: %s" % err), since_reason
    return obj, None, since_reason


# --------------------------------------------------------------------------
# status / probe / toggle
# --------------------------------------------------------------------------

def load_signals(cfg):
    """Returns (fx, error_kind, error_message)."""
    return load_fixture(cfg.fixture)


def fixture_error_payload(kind, message):
    """A missing or empty fixture is kind 'missing'; unreadable or bad JSON is 'malformed'."""
    payload = fail_payload(message, kind=ERR_MISSING if kind in ("missing", "empty") else ERR_MALFORMED)
    payload["source"] = "fixture"
    return payload, (2 if kind == "missing" else 0)


def build_status(cfg):
    fx, kind, message = load_signals(cfg)
    if kind:
        return fixture_error_payload(kind, message)

    source = "fixture" if fx is not None else "live"
    now_iso = utc_now_iso()
    game = game_from_fixture(fx, cfg.patterns) if fx is not None else detect_live(cfg)
    ptt_state, ptt_info = read_ptt(cfg, fx)
    mode = resolve_mode(ptt_state, game.get("running"))
    mouse, mouse_source = read_mouse(cfg, fx)

    if cfg.no_net:
        net = {"gateway": null_entry(cfg.gateway_host, "network probe skipped (--no-net)"),
               "public": null_entry(cfg.public_host, "network probe skipped (--no-net)"),
               "measured_at": None, "source": source, "cached": False}
    else:
        net = probe_net(cfg, fx)

    flag, flag_warning, since_reason = apply_flag(
        cfg, game.get("running") is True, now_iso, fx)

    reasons = []
    if game.get("running") is True and mode == "dictation":
        reasons.append("game process running while ptt state is dictation")
    if game.get("running") is None:
        reasons.append("game detection unavailable: %s" % game.get("reason", "no signal"))
    if flag_warning and "write failed" in flag_warning:
        reasons.append(flag_warning)
    if fx is not None and fx.get("needs_me") is True:
        reasons.append(str(fx.get("needs_me_reason") or "fixture requests attention"))
    needs_me = bool(reasons)

    warnings = []
    if flag_warning:
        warnings.append(flag_warning)
    if ptt_info.get("reason"):
        warnings.append("ptt state unreadable: %s" % ptt_info["reason"])
    if not cfg.no_net:
        if net.get("gateway", {}).get("reason") and net["gateway"].get("rtt_ms") is None:
            warnings.append("gateway: %s" % net["gateway"]["reason"])
        if net.get("public", {}).get("reason") and net["public"].get("rtt_ms") is None:
            warnings.append("public: %s" % net["public"]["reason"])

    if flag["pause_heavy"]:
        flag_reason = "game running"
    elif game.get("running") is False:
        flag_reason = "no game process"
    else:
        flag_reason = "game detection unavailable"

    payload = {
        "ok": True,
        "generated_at": now_iso,
        "source": source,
        "mode": mode,
        "game": game,
        "mouse_profile": mouse,
        "needs_me": needs_me,
    }
    if needs_me:
        payload["needs_me_reason"] = "; ".join(reasons)
    payload["net"] = net
    payload["pause_heavy"] = {"flag": flag["pause_heavy"], "since": flag["since"],
                              "reason": since_reason or flag_reason}
    payload["ptt"] = ptt_info
    if mouse is None:
        payload["mouse_profile_reason"] = mouse_source
    payload["flag_file"] = display_path(cfg.flag_file)
    if warnings:
        payload["warnings"] = warnings
    return payload, 0


def build_probe(cfg):
    fx, kind, message = load_signals(cfg)
    if kind:
        return fixture_error_payload(kind, message)
    source = "fixture" if (fx is not None and not cfg.live_net) else "live"
    return {"ok": True, "generated_at": utc_now_iso(), "source": source,
            "net": probe_net(cfg, fx if fx is not None else None)}, 0


def toggle_state_file(cfg, mode):
    """Simulated ptt-toggle on the Mac: persist the flipped state the next tick reads.

    Never touches the Mac's real ~/.cache: the simulated state lives under the
    state directory unless the caller names a path with --ptt-state.
    """
    token = "dictation" if mode == "dictation" else "game"
    target = cfg.ptt_state if cfg.ptt_state_given else cfg.sim_ptt_state
    if cfg.dry_run:
        return False, "not written (--dry-run)", target
    ok, err = atomic_write_text(target, token + "\n")
    if not ok:
        return False, tilde_text("ptt state write failed: %s" % err), target
    return True, None, target


def atomic_write_text(path, text):
    path = Path(path)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".%s." % path.name, dir=str(path.parent))
    except OSError as e:
        return False, tilde_text(e)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, str(path))
        return True, None
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False, tilde_text(e)


def flip(mode):
    """The other mode, or None when the current one is unknown (never a guess)."""
    if mode == "dictation":
        return "game"
    if mode == "game":
        return "dictation"
    return None


def build_toggle(cfg):
    fx, kind, message = load_signals(cfg)
    if kind:
        return fixture_error_payload(kind, message)

    source = "fixture" if fx is not None else "live"
    now_iso = utc_now_iso()
    game = game_from_fixture(fx, cfg.patterns) if fx is not None else detect_live(cfg)
    ptt_state, ptt_info = read_ptt(cfg, fx)
    before = resolve_mode(ptt_state, game.get("running"))

    result = {"ok": True, "generated_at": now_iso, "source": source, "action": "toggle",
              "before": before, "after": None, "mode": before, "ran": False,
              "simulated": False, "exit_code": None, "output": None,
              "dry_run": bool(cfg.dry_run), "source_of_truth": ptt_info.get("source")}

    if cfg.dry_run:
        after = flip(before)
        result["after"] = after
        result["mode"] = after or before
        if after is None:
            result["after_reason"] = "current dictation/game state is unknown"
        if cfg.fixture is not None:
            result["would_run"] = "fixture simulation (no command)"
        elif cfg.host == "linux":
            result["would_run"] = cfg.toggle_cmd or "ptt-toggle"
        else:
            result["would_run"] = "nothing: ptt-toggle is Linux-only and absent on this host"
    elif fx is not None:
        after = flip(before)
        result.update({"after": after, "mode": after or before,
                       "simulated": after is not None,
                       "ran": False, "command": "ptt-toggle (fixture)"})
        if after is None:
            result["after_reason"] = "current dictation/game state is unknown"
        else:
            written, err, ptt_target = toggle_state_file(cfg, after)
            result["ptt_state_file"] = display_path(ptt_target)
            captured = fx.get("toggle") if isinstance(fx.get("toggle"), dict) else None
            if captured:
                result["exit_code"] = captured.get("exit_code")
                result["output"] = short(captured.get("output"), 200)
            if not written and err:
                if "dry-run" not in err:
                    return fail_payload(
                        tilde_text("simulated toggle could not write ptt state: %s" % err),
                        kind=ERR_FAILED, source=source), 0
                result["ptt_state_write"] = err
    elif cfg.host == "linux":
        binary = cfg.toggle_cmd or shutil.which("ptt-toggle")
        if not binary:
            return fail_payload(
                "ptt-toggle not found on this host; pass --toggle-cmd or use --fixture",
                kind=ERR_UNAVAILABLE, source=source, action="toggle", before=before), 0
        rc, out, err = run_cmd([binary], TOGGLE_TIMEOUT_S)
        if rc is None:
            return fail_payload(tilde_text("ptt-toggle could not run: %s" % err),
                                kind=ERR_UNAVAILABLE,
                                source=source, action="toggle", before=before), 0
        after_state, after_info = read_ptt(cfg, None)
        after = resolve_mode(after_state, game.get("running"))
        result.update({"after": after, "mode": after, "ran": True,
                       "command": display_path(binary) if "/" in str(binary) else str(binary),
                       "exit_code": rc, "output": short(out + err, 200),
                       "source_of_truth": after_info.get("source")})
        if rc != 0:
            result["ok"] = False
            result["kind"] = ERR_FAILED
            result["reason"] = "ptt-toggle exited %s" % rc
    else:
        return fail_payload(
            "ptt-toggle is Linux-only and absent on this host; use --fixture PATH "
            "or --host linux (never simulated silently)",
            kind=ERR_UNAVAILABLE, source=source, action="toggle", before=before), 0

    gaming = game.get("running") is True
    flag, flag_warning, since_reason = apply_flag(cfg, gaming, now_iso, fx)
    result["pause_heavy"] = {"flag": flag["pause_heavy"], "since": flag["since"],
                             "reason": since_reason or ("game running" if gaming else "no game process")}
    result["game"] = game
    result["flag_file"] = display_path(cfg.flag_file)
    if flag_warning:
        result.setdefault("warnings", []).append(flag_warning)
    return result, 0


# --------------------------------------------------------------------------
# self-check
# --------------------------------------------------------------------------

PING_GATEWAY = (
    "PING 192.168.0.1 (192.168.0.1): 56 data bytes\n"
    "64 bytes from 192.168.0.1: icmp_seq=0 ttl=64 time=7.812 ms\n"
    "64 bytes from 192.168.0.1: icmp_seq=1 ttl=64 time=8.422 ms\n"
    "64 bytes from 192.168.0.1: icmp_seq=2 ttl=64 time=8.101 ms\n"
    "64 bytes from 192.168.0.1: icmp_seq=3 ttl=64 time=8.934 ms\n"
    "64 bytes from 192.168.0.1: icmp_seq=4 ttl=64 time=7.733 ms\n"
    "\n--- 192.168.0.1 ping statistics ---\n"
    "5 packets transmitted, 5 packets received, 0.0% packet loss\n"
    "round-trip min/avg/max/stddev = 7.733/8.200/8.934/0.451 ms\n"
)

PING_PUBLIC = (
    "PING 1.1.1.1 (1.1.1.1) 56(84) bytes of data.\n"
    "64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=13.102 ms\n"
    "64 bytes from 1.1.1.1: icmp_seq=2 ttl=57 time=14.011 ms\n"
    "64 bytes from 1.1.1.1: icmp_seq=3 ttl=57 time=15.200 ms\n"
    "64 bytes from 1.1.1.1: icmp_seq=4 ttl=57 time=13.440 ms\n"
    "64 bytes from 1.1.1.1: icmp_seq=5 ttl=57 time=14.290 ms\n"
    "\n--- 1.1.1.1 ping statistics ---\n"
    "5 packets transmitted, 5 received, 0% packet loss, time 4005ms\n"
    "rtt min/avg/max/mdev = 13.102/14.011/15.200/0.712 ms\n"
)

PING_DOWN = (
    "PING 192.168.0.1 (192.168.0.1): 56 data bytes\n"
    "Request timeout for icmp_seq 0\n"
    "Request timeout for icmp_seq 1\n"
    "Request timeout for icmp_seq 2\n"
    "Request timeout for icmp_seq 3\n"
    "Request timeout for icmp_seq 4\n"
    "\n--- 192.168.0.1 ping statistics ---\n"
    "5 packets transmitted, 0 packets received, 100.0% packet loss\n"
)

STUB_PING = """#!/bin/sh
# self-check stub: logs the call, prints canned output for the target
printf '%s\\n' "$*" >> "$PING_LOG"
case "$*" in
  *__PUBLIC__*) cat "$PING_PUBLIC_FILE" ;;
  *) cat "$PING_GATEWAY_FILE" ;;
esac
"""

STUB_PING_DOWN = """#!/bin/sh
printf '%s\\n' "$*" >> "$PING_LOG"
cat "$PING_DOWN_FILE"
"""


class Checks(object):
    def __init__(self):
        self.total = 0
        self.failures = []

    def eq(self, name, got, want):
        self.total += 1
        if got == want:
            print("ok   %s = %r" % (name, got))
        else:
            print("FAIL %s: expected %r, got %r" % (name, want, got))
            self.failures.append(name)

    def true(self, name, cond, detail=""):
        self.total += 1
        if cond:
            print("ok   %s" % name)
        else:
            print("FAIL %s %s" % (name, detail))
            self.failures.append(name)

    def summary(self):
        print("\n%d checks, %d failed" % (self.total, len(self.failures)))
        return 0 if not self.failures else 1


def _run_self(script, args, env=None, timeout=90):
    cmd = [sys.executable, script] + args
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return None, "", "self-check child timed out"
    out = proc.stdout.decode("utf-8", "replace")
    err = proc.stderr.decode("utf-8", "replace")
    return proc.returncode, out, err


def _json_of(out):
    text = out.strip()
    if not (text.startswith("{") and text.endswith("}")):
        return None, "stdout is not exactly one JSON object"
    try:
        return json.loads(text), None
    except ValueError as e:
        return None, str(e)


def _iso_epoch(text):
    """Seconds since the epoch for an ISO UTC stamp, or None. For freshness checks."""
    try:
        parsed = datetime.datetime.strptime(str(text), "%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError):
        return None
    return parsed.replace(tzinfo=datetime.timezone.utc).timestamp()


def _write(path, text, mode=None):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    if mode is not None:
        os.chmod(str(path), mode)
    return path


def _write_json(path, obj):
    return _write(path, json.dumps(obj, indent=2) + "\n")


def run_self_check(script):
    checks = Checks()
    tmp = Path(tempfile.mkdtemp(prefix="game-mode-selftest-"))
    state = tmp / "state"
    ptt = tmp / "ptt.state"
    cache = tmp / "net.json"
    home = str(Path.home())

    ping_env = dict(os.environ)
    ping_env.update({
        "PING_LOG": str(tmp / "ping.log"),
        "PING_GATEWAY_FILE": str(tmp / "gateway.txt"),
        "PING_PUBLIC_FILE": str(tmp / "public.txt"),
        "PING_DOWN_FILE": str(tmp / "down.txt"),
    })
    _write(tmp / "gateway.txt", PING_GATEWAY)
    _write(tmp / "public.txt", PING_PUBLIC)
    _write(tmp / "down.txt", PING_DOWN)
    stub = _write(tmp / "stub-ping.sh", STUB_PING.replace("__PUBLIC__", PUBLIC_HOST), 0o755)
    stub_down = _write(tmp / "stub-ping-down.sh", STUB_PING_DOWN, 0o755)
    log = tmp / "ping.log"

    base_fixture = {
        "generated_at": "2026-10-23T01:20:00Z",
        "host": "linux",
        "ptt_state": "game",
        "mouse_profile": "gaming",
        "pause_heavy": {"since": "2026-10-23T01:12:00Z"},
        "pgrep": [{"pid": 4821, "command": "PioneerGame.exe -vulkan"}],
        "hyprctl": [{"class": "PioneerGame", "title": "ARC Raiders", "pid": 4821}],
        "ping": {"gateway": PING_GATEWAY, "public": PING_PUBLIC},
        "toggle": {"exit_code": 0, "output": "dictation on"},
    }
    fixture_since_value = base_fixture["pause_heavy"]["since"]
    game_fx = _write_json(tmp / "game.json", base_fixture)

    dictation_fx = _write_json(tmp / "dictation.json", {
        "generated_at": "2026-10-23T01:21:00Z",
        "ptt_state": "dictation",
        "mouse_profile": "desktop",
        "pgrep": [],
        "ping": {"gateway": PING_GATEWAY, "public": PING_PUBLIC},
    })

    conflict_fx = _write_json(tmp / "conflict.json", {
        "generated_at": "2026-10-23T01:22:00Z",
        "ptt_state": "dictation",
        "pgrep": [{"pid": 913, "command": "/usr/bin/PioneerGame"}],
        "ping": {"gateway": PING_GATEWAY, "public": PING_PUBLIC},
    })

    malformed_fx = _write(tmp / "malformed.json", "{not json")
    empty_dir = tmp / "empty-fixture"
    empty_dir.mkdir()

    common = ["--state-dir", str(state), "--cache-file", str(cache), "--ptt-state", str(ptt)]

    def call(args, env=None):
        return _run_self(script, args, env=env)

    def ok_json(args, env=None):
        rc, out, err = call(args, env=env)
        payload, jerr = _json_of(out)
        return rc, payload, out, jerr or err

    print("game_mode.py self-check on %s (python %s)\n" % (host_platform(),
                                                           sys.version.split()[0]))

    # 1. fixture status: full shape
    rc, status, out, err = ok_json(["--status", "--fixture", str(game_fx)] + common)
    checks.eq("fixture status exit", rc, 0)
    checks.true("fixture status one JSON object", status is not None, err)
    status = status or {}
    checks.eq("fixture source", status.get("source"), "fixture")
    checks.eq("fixture mode", status.get("mode"), "game")
    checks.eq("fixture game.running", status.get("game", {}).get("running"), True)
    checks.eq("fixture game.process", status.get("game", {}).get("process"), "PioneerGame")
    checks.eq("fixture game.class", status.get("game", {}).get("class"), "PioneerGame")
    checks.eq("fixture mouse_profile", status.get("mouse_profile"), "gaming")
    checks.eq("fixture needs_me", status.get("needs_me"), False)
    checks.eq("fixture net.gateway.rtt_ms", status.get("net", {}).get("gateway", {}).get("rtt_ms"), 8.2)
    checks.eq("fixture net.gateway.jitter_ms", status.get("net", {}).get("gateway", {}).get("jitter_ms"), 0.45)
    checks.eq("fixture net.gateway.loss", status.get("net", {}).get("gateway", {}).get("loss"), 0)
    checks.eq("fixture net.public.rtt_ms", status.get("net", {}).get("public", {}).get("rtt_ms"), 14.01)
    checks.eq("fixture net.public.jitter_ms", status.get("net", {}).get("public", {}).get("jitter_ms"), 0.71)
    checks.eq("fixture net.cached", status.get("net", {}).get("cached"), False)
    checks.eq("fixture pause_heavy.flag", status.get("pause_heavy", {}).get("flag"), True)
    checks.eq("fixture pause_heavy.since",
              status.get("pause_heavy", {}).get("since"), fixture_since_value)
    checks.true("generated_at is UTC ISO",
                re.match(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$", str(status.get("generated_at"))))
    checks.true("no absolute home path in output", home not in out, "home leaked")

    flag_text, _ = read_text(state / FLAG_NAME)
    flag_obj = json.loads(flag_text) if flag_text else {}
    checks.eq("flag fields", sorted(flag_obj.keys()),
              ["gaming", "pause_heavy", "since", "updated_at"])
    checks.eq("flag gaming", flag_obj.get("gaming"), True)
    checks.eq("flag pause_heavy", flag_obj.get("pause_heavy"), True)
    since_first = flag_obj.get("since")
    checks.eq("flag since is the fixture since", since_first, fixture_since_value)
    checks.true("flag since ISO", re.match(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$",
                                           str(since_first)) is not None)

    # 2. since is stable across ticks
    time.sleep(1.1)
    rc, status2, out2, err2 = ok_json(["--status", "--fixture", str(game_fx)] + common)
    checks.eq("second tick exit", rc, 0)
    checks.eq("since stable across ticks",
              status2.get("pause_heavy", {}).get("since"), since_first)

    # 3. dictation fixture: no game, flag off, since null
    rc, status_d, out_d, err_d = ok_json(["--status", "--fixture", str(dictation_fx)] + common)
    checks.eq("dictation exit", rc, 0)
    checks.eq("dictation mode", status_d.get("mode"), "dictation")
    checks.eq("dictation game.running", status_d.get("game", {}).get("running"), False)
    checks.eq("dictation pause flag", status_d.get("pause_heavy", {}).get("flag"), False)
    checks.eq("dictation pause since", status_d.get("pause_heavy", {}).get("since"), None)
    flag_text, _ = read_text(state / FLAG_NAME)
    flag_obj = json.loads(flag_text) if flag_text else {}
    checks.eq("dictation flag gaming", flag_obj.get("gaming"), False)

    # 4. conflict: game process while dictation is on -> needs_me
    rc, status_c, out_c, err_c = ok_json(["--status", "--fixture", str(conflict_fx)] + common)
    checks.eq("conflict exit", rc, 0)
    checks.eq("conflict needs_me", status_c.get("needs_me"), True)
    checks.true("conflict reason", "game process running" in str(status_c.get("needs_me_reason")))

    # 5. malformed and empty fixtures are honest absence, exit 0
    rc, payload, out_m, err_m = ok_json(["--status", "--fixture", str(malformed_fx)] + common)
    checks.eq("malformed fixture exit", rc, 0)
    checks.eq("malformed fixture ok", payload.get("ok"), False)
    checks.true("malformed fixture reason", "malformed fixture" in str(payload.get("reason")))
    rc, payload, out_e, err_e = ok_json(["--status", "--fixture", str(empty_dir)] + common)
    checks.eq("empty fixture dir exit", rc, 0)
    checks.eq("empty fixture dir ok", payload.get("ok"), False)

    # 6. a named file that does not exist is a programming error
    rc, payload, out_x, err_x = ok_json(["--status", "--fixture", str(tmp / "nope.json")] + common)
    checks.eq("missing fixture exit", rc, 2)
    checks.eq("missing fixture ok", payload.get("ok"), False)

    # 7. unknown flag: argparse exit 2, no traceback
    rc, out_u, err_u = call(["--status", "--bogus-flag"])
    checks.eq("unknown flag exit", rc, 2)
    checks.true("unknown flag no traceback", "Traceback" not in err_u, err_u)

    # 8. probe: one round, two targets, cached for 10 s minimum
    if log.exists():
        log.unlink()
    rc, probe, out_p, err_p = ok_json(
        ["--probe", "--ping-cmd", str(stub), "--gateway-host", "192.168.0.1",
         "--cache-file", str(cache)] + ["--state-dir", str(state), "--ptt-state", str(ptt)],
        env=ping_env)
    checks.eq("probe exit", rc, 0)
    checks.eq("probe gateway rtt", probe.get("net", {}).get("gateway", {}).get("rtt_ms"), 8.2)
    checks.eq("probe public rtt", probe.get("net", {}).get("public", {}).get("rtt_ms"), 14.01)
    checks.eq("probe cached flag", probe.get("net", {}).get("cached"), False)
    lines = log.read_text().splitlines() if log.exists() else []
    checks.eq("probe one round = 2 pings", len(lines), 2)
    checks.true("probe pinged both targets", any("192.168.0.1" in l for l in lines)
                and any("1.1.1.1" in l for l in lines), str(lines))

    rc, probe2, out_p2, err_p2 = ok_json(
        ["--probe", "--ping-cmd", str(stub), "--gateway-host", "192.168.0.1",
         "--cache-file", str(cache)] + ["--state-dir", str(state), "--ptt-state", str(ptt)],
        env=ping_env)
    checks.eq("cached probe exit", rc, 0)
    checks.eq("cached probe flag", probe2.get("net", {}).get("cached"), True)
    checks.eq("cached probe measured_at",
              probe2.get("net", {}).get("measured_at"), probe.get("net", {}).get("measured_at"))
    lines = log.read_text().splitlines() if log.exists() else []
    checks.eq("cached probe ran no ping", len(lines), 2)

    rc, probe3, out_p3, err_p3 = ok_json(
        ["--probe", "--ping-cmd", str(stub), "--gateway-host", "192.168.0.1",
         "--cache-ttl", "1", "--cache-file", str(cache),
         "--state-dir", str(state), "--ptt-state", str(ptt)], env=ping_env)
    checks.eq("ttl floor clamped exit", rc, 0)
    checks.eq("ttl floor clamped cached", probe3.get("net", {}).get("cached"), True)
    lines = log.read_text().splitlines() if log.exists() else []
    checks.eq("ttl floor clamped no ping", len(lines), 2)

    # 9. network down: nulls with a reason, not zeros
    down_cache = tmp / "down-cache.json"
    rc, down, out_dn, err_dn = ok_json(
        ["--probe", "--ping-cmd", str(stub_down), "--gateway-host", "192.168.0.1",
         "--cache-file", str(down_cache), "--state-dir", str(state),
         "--ptt-state", str(ptt)], env=ping_env)
    checks.eq("down exit", rc, 0)
    checks.eq("down gateway rtt", down.get("net", {}).get("gateway", {}).get("rtt_ms"), None)
    checks.eq("down gateway loss", down.get("net", {}).get("gateway", {}).get("loss"), 100)
    checks.eq("down gateway reason", down.get("net", {}).get("gateway", {}).get("reason"),
              "no replies")

    # 10. ping binary missing
    rc, noping, out_np, err_np = ok_json(
        ["--probe", "--ping-cmd", str(tmp / "no-such-ping"), "--gateway-host", "192.168.0.1",
         "--cache-file", str(tmp / "noping-cache.json"), "--state-dir", str(state),
         "--ptt-state", str(ptt)])
    checks.eq("missing ping exit", rc, 0)
    checks.eq("missing ping rtt", noping.get("net", {}).get("public", {}).get("rtt_ms"), None)
    checks.true("missing ping reason",
                "not found" in str(noping.get("net", {}).get("public", {}).get("reason")))

    # 11. fixture cache never feeds a live status
    fixture_cache = tmp / "fixture-cache.json"
    ok_json(["--probe", "--fixture", str(game_fx), "--cache-file", str(fixture_cache),
             "--state-dir", str(state), "--ptt-state", str(ptt)], env=ping_env)
    if log.exists():
        log.unlink()
    rc, live_after_fixture, out_lf, err_lf = ok_json(
        ["--probe", "--ping-cmd", str(stub), "--gateway-host", "192.168.0.1",
         "--cache-file", str(fixture_cache), "--state-dir", str(state),
         "--ptt-state", str(ptt)], env=ping_env)
    checks.eq("source-split exit", rc, 0)
    checks.eq("fixture cache not reused live",
              live_after_fixture.get("net", {}).get("cached"), False)
    checks.eq("fixture cache not reused live (source)",
              live_after_fixture.get("source"), "live")

    # 12. toggle: dry-run changes nothing, real fixture toggle flips state
    ptt_before = ptt.read_text() if ptt.exists() else None
    flag_before = read_text(state / FLAG_NAME)[0]
    rc, dry, out_td, err_td = ok_json(
        ["--toggle", "--fixture", str(game_fx), "--dry-run"] + common)
    checks.eq("toggle dry-run exit", rc, 0)
    checks.eq("toggle dry-run flag", dry.get("dry_run"), True)
    checks.eq("toggle dry-run after", dry.get("after"), "dictation")
    checks.eq("toggle dry-run wrote no ptt state",
              ptt.read_text() if ptt.exists() else None, ptt_before)
    checks.eq("toggle dry-run wrote no flag", read_text(state / FLAG_NAME)[0], flag_before)

    rc, toggled, out_t, err_t = ok_json(["--toggle", "--fixture", str(game_fx)] + common)
    checks.eq("toggle exit", rc, 0)
    checks.eq("toggle before", toggled.get("before"), "game")
    checks.eq("toggle after", toggled.get("after"), "dictation")
    checks.eq("toggle simulated", toggled.get("simulated"), True)
    checks.eq("toggle ptt state written", ptt.read_text().strip(), "dictation")
    checks.eq("toggle keeps pause flag on a running game",
              toggled.get("pause_heavy", {}).get("flag"), True)
    checks.eq("toggle keeps the fixture since",
              toggled.get("pause_heavy", {}).get("since"), fixture_since_value)

    # 13. toggle on a Mac with no ptt-toggle and no fixture refuses, exit 0
    # host pinned to mac: an unpinned --toggle on Linux runs the live ptt-toggle
    rc, refused, out_r, err_r = ok_json(["--toggle", "--host", "mac"] + common)
    checks.eq("mac toggle exit", rc, 0)
    checks.eq("mac toggle ok", refused.get("ok"), False)
    checks.true("mac toggle reason", "Linux-only" in str(refused.get("reason")))

    # 14. Linux path without a ptt-toggle binary: honest absence, nothing runs
    rc, missing_ptt, out_mp, err_mp = ok_json(
        ["--toggle", "--host", "linux", "--toggle-cmd", str(tmp / "no-ptt-toggle")] + common)
    checks.eq("linux toggle exit", rc, 0)
    checks.eq("linux toggle ok", missing_ptt.get("ok"), False)
    checks.true("linux toggle reason", "not found" in str(missing_ptt.get("reason")))

    # 15. live pgrep detection on this host, no network, no writes.
    # macOS pgrep never reports its own parent, so the self-check stands up a
    # decoy process named like a game instead of matching itself.
    decoy = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)",
                              "PioneerGame"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        live = {}
        deadline = time.time() + 8
        while time.time() < deadline:
            rc, live, out_lv, err_lv = ok_json(
                ["--status", "--pattern", "PioneerGame", "--no-net", "--dry-run",
                 "--ptt-state", str(tmp / "absent.state"), "--state-dir", str(state)])
            if live.get("game", {}).get("running") is True:
                break
            time.sleep(0.2)
        checks.eq("live pgrep exit", rc, 0)
        checks.eq("live pgrep source", live.get("source"), "live")
        checks.eq("live pgrep running", live.get("game", {}).get("running"), True)
        checks.eq("live pgrep process", live.get("game", {}).get("process"), "PioneerGame")
        checks.true("live pgrep pid", isinstance(live.get("game", {}).get("pid"), int))
        checks.eq("live pgrep mode", live.get("mode"), "game")
        checks.eq("live pgrep pause flag", live.get("pause_heavy", {}).get("flag"), True)
        checks.eq("live no-net reason", live.get("net", {}).get("gateway", {}).get("reason"),
                  "network probe skipped (--no-net)")

        fresh_flag = tmp / "live-fresh-flag.json"
        rc, fresh, out_fr, err_fr = ok_json(
            ["--status", "--pattern", "PioneerGame", "--no-net",
             "--flag-file", str(fresh_flag), "--ptt-state", str(tmp / "absent.state")])
        fresh = fresh or {}
        fresh_since = fresh.get("pause_heavy", {}).get("since")
        checks.eq("live fresh since exit", rc, 0)
        checks.eq("live fresh flag", fresh.get("pause_heavy", {}).get("flag"), True)
        checks.true("live fresh since is ISO",
                    re.match(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$",
                             str(fresh_since)) is not None, str(fresh_since))
        checks.true("live fresh since is the host clock now",
                    abs((_iso_epoch(fresh_since) or 0.0) - time.time()) <= 120.0,
                    str(fresh_since))
        fresh_obj = json.loads(fresh_flag.read_text(encoding="utf-8")) if fresh_flag.exists() else {}
        checks.eq("live fresh flag file since", fresh_obj.get("since"), fresh_since)
    finally:
        decoy.terminate()
        try:
            decoy.wait(timeout=5)
        except subprocess.TimeoutExpired:
            decoy.kill()

    # 15b. /proc detection: finds a decoy by cmdline, skips its own pid,
    # names the pattern, and spawns no pgrep (run_cmd is spied on).
    if proc_available():
        decoy2 = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)",
                                   "PioneerGame"],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        real_run_cmd = globals()["run_cmd"]
        spied = []

        def spy_run_cmd(cmd, timeout):
            spied.append([str(x) for x in cmd])
            return real_run_cmd(cmd, timeout)

        try:
            hit = {}
            deadline = time.time() + 8
            while time.time() < deadline:
                hit = proc_match(["NoSuchGameXyz", "PioneerGame"])
                if hit.get("running") is True:
                    break
                time.sleep(0.2)
            checks.eq("proc scan finds decoy", hit.get("running"), True)
            checks.eq("proc scan names the pattern", hit.get("process"), "PioneerGame")
            checks.true("proc scan pid is a PioneerGame process",
                        "PioneerGame" in proc_cmdline_text(str(hit.get("pid"))), str(hit))
            checks.true("proc scan skips own pid", hit.get("pid") != os.getpid(), str(hit))
            checks.eq("proc scan no match", proc_match(["NoSuchGameXyz9f2"]).get("running"), False)
            globals()["run_cmd"] = spy_run_cmd
            hit2 = process_match(Cfg(parse_args(["--status", "--pattern", "PioneerGame"])))
            checks.eq("process_match running via proc", hit2.get("running"), True)
            checks.eq("proc path spawns no pgrep",
                      [c for c in spied if "pgrep" in " ".join(c)], [])
        finally:
            globals()["run_cmd"] = real_run_cmd
            decoy2.terminate()
            try:
                decoy2.wait(timeout=5)
            except subprocess.TimeoutExpired:
                decoy2.kill()

    # 16. an unwritable flag path degrades to a warning, not a crash
    bad_target = tmp / "flag-is-a-dir"
    bad_target.mkdir()
    rc, bad, out_b, err_b = ok_json(
        ["--status", "--fixture", str(game_fx), "--flag-file", str(bad_target)] + common)
    checks.eq("unwritable flag exit", rc, 0)
    checks.eq("unwritable flag needs_me", bad.get("needs_me"), True)
    checks.true("unwritable flag warning",
                any("write failed" in w for w in bad.get("warnings", [])), str(bad.get("warnings")))

    # 17. --json is one compact line; the default stays pretty printed
    rc, payload, out_j, err_j = ok_json(["--status", "--fixture", str(game_fx), "--json"] + common)
    checks.eq("--json exit", rc, 0)
    checks.eq("--json ok", payload.get("ok"), True)
    checks.eq("--json one line", out_j.count("\n"), 1)
    checks.true("--json compact (no indentation)", '\n  "' not in out_j, out_j[:120])
    checks.eq("--json starts at the envelope", out_j.startswith('{"ok":'), True)
    rc, pretty, out_pj, err_pj = ok_json(["--status", "--fixture", str(game_fx)] + common)
    checks.eq("pretty default exit", rc, 0)
    checks.true("pretty default is indented", out_pj.count("\n") > 1, out_pj[:60])
    rc, compact_err, out_ce, err_ce = ok_json(
        ["--status", "--fixture", str(tmp / "nope.json"), "--json"])
    checks.eq("compact error exit", rc, 2)
    checks.eq("compact error one line", out_ce.count("\n"), 1)
    checks.eq("compact error kind", (compact_err or {}).get("kind"), "missing")

    # 18. every error payload carries a kind
    rc, missing_kind, _, _ = ok_json(["--status", "--fixture", str(tmp / "nope.json")] + common)
    checks.eq("missing fixture kind", (missing_kind or {}).get("kind"), "missing")
    rc, empty_kind, _, _ = ok_json(["--status", "--fixture", str(empty_dir)] + common)
    checks.eq("empty fixture kind", (empty_kind or {}).get("kind"), "missing")
    rc, bad_kind, _, _ = ok_json(["--status", "--fixture", str(malformed_fx)] + common)
    checks.eq("malformed fixture kind", (bad_kind or {}).get("kind"), "malformed")
    rc, probe_kind, _, _ = ok_json(["--probe", "--fixture", str(malformed_fx)] + common)
    checks.eq("probe malformed kind", (probe_kind or {}).get("kind"), "malformed")
    rc, toggle_kind, _, _ = ok_json(["--toggle", "--fixture", str(tmp / "nope.json")] + common)
    checks.eq("toggle missing fixture kind", (toggle_kind or {}).get("kind"), "missing")
    rc, refuse_kind, _, _ = ok_json(["--toggle", "--host", "mac"] + common)
    checks.eq("refusal kind", (refuse_kind or {}).get("kind"), "unavailable")

    # 19. a fixture status neither writes nor reads host state without named paths
    pure_home = tmp / "pure-home"
    pure_home.mkdir()
    decoy_home = tmp / "decoy-home"
    decoy_state = decoy_home / ".local" / "state" / "nexuslink"
    decoy_state.mkdir(parents=True)
    _write_json(decoy_state / FLAG_NAME, {"gaming": False, "pause_heavy": False,
                                          "since": "2020-01-01T00:00:00Z",
                                          "updated_at": "2020-01-01T00:00:00Z"})
    _write_json(decoy_state / CACHE_NAME, {
        "measured_at": "2020-01-01T00:00:00Z", "ts": time.time(), "source": "fixture",
        "gateway_host": "10.9.9.9", "public_host": "10.9.9.8",
        "gateway": {"host": "10.9.9.9", "rtt_ms": 1.0, "jitter_ms": 0.1, "loss": 0},
        "public": {"host": "10.9.9.8", "rtt_ms": 2.0, "jitter_ms": 0.2, "loss": 0}})
    pure_env = dict(os.environ)
    pure_env["HOME"] = str(pure_home)
    pure_env["PYTHONDONTWRITEBYTECODE"] = "1"
    rc, pure, out_pu, err_pu = ok_json(["--status", "--fixture", str(game_fx)], env=pure_env)
    checks.eq("purity exit", rc, 0)
    pure = pure or {}
    checks.eq("purity ok", pure.get("ok"), True)
    checks.eq("purity empty HOME writes nothing",
              sorted(str(p.relative_to(pure_home)) for p in pure_home.rglob("*") if p.is_file()), [])
    checks.eq("purity creates no state dir", (pure_home / ".local").exists(), False)
    checks.eq("purity still reports the flag", pure.get("pause_heavy", {}).get("flag"), True)
    decoy_env = dict(pure_env)
    decoy_env["HOME"] = str(decoy_home)
    rc, decoy, out_de, err_de = ok_json(["--status", "--fixture", str(game_fx)], env=decoy_env)
    checks.eq("purity decoy exit", rc, 0)
    decoy = decoy or {}
    checks.eq("purity ignores the host flag",
              decoy.get("pause_heavy", {}).get("since"), fixture_since_value)
    checks.true("purity ignores the host cache",
                decoy.get("net", {}).get("gateway", {}).get("host") != "10.9.9.9",
                str(decoy.get("net", {}).get("gateway")))
    checks.eq("purity decoy cache not reused", decoy.get("net", {}).get("cached"), False)

    # 20. the net cache is keyed to both targets
    target_cache = tmp / "target-cache.json"
    target_args = ["--probe", "--ping-cmd", str(stub), "--cache-file", str(target_cache),
                   "--state-dir", str(state), "--ptt-state", str(ptt)]
    if log.exists():
        log.unlink()
    rc, target_a, _, _ = ok_json(target_args + ["--gateway-host", "192.168.0.1"], env=ping_env)
    checks.eq("target cache first exit", rc, 0)
    target_a = target_a or {}
    checks.eq("target cache first host", target_a.get("net", {}).get("gateway", {}).get("host"),
              "192.168.0.1")
    checks.eq("target cache first cached", target_a.get("net", {}).get("cached"), False)
    rc, target_b, _, _ = ok_json(target_args + ["--gateway-host", "192.0.2.1"], env=ping_env)
    checks.eq("target cache second exit", rc, 0)
    target_b = target_b or {}
    checks.eq("target cache second host", target_b.get("net", {}).get("gateway", {}).get("host"),
              "192.0.2.1")
    checks.eq("target cache second cached", target_b.get("net", {}).get("cached"), False)
    lines = log.read_text().splitlines() if log.exists() else []
    checks.eq("target cache second round pinged twice", len(lines), 4)
    checks.true("target cache second round pinged the new target",
                any("192.0.2.1" in line for line in lines), str(lines))
    rc, target_b2, _, _ = ok_json(target_args + ["--gateway-host", "192.0.2.1"], env=ping_env)
    target_b2 = target_b2 or {}
    checks.eq("target cache same target cached", target_b2.get("net", {}).get("cached"), True)
    lines = log.read_text().splitlines() if log.exists() else []
    checks.eq("target cache same target ran no ping", len(lines), 4)

    # 21. the shipped fixture's samples agree with its own summary
    shipped = Path(__file__).resolve().parent.parent / "fixtures" / FIXTURE_MAIN
    checks.true("shipped fixture present", shipped.is_file(), str(shipped))
    shipped_fx, shipped_err = read_json(shipped)
    shipped_ping = (shipped_fx or {}).get("ping") if isinstance(shipped_fx, dict) else None
    checks.true("shipped fixture parses", isinstance(shipped_ping, dict), str(shipped_err))
    checks.true("shipped fixture names a gaming since",
                fixture_since(shipped_fx) is not None, str(shipped_fx)[:120])
    for key in ("gateway", "public"):
        text = (shipped_ping or {}).get(key) if isinstance(shipped_ping, dict) else None
        times = [float(value) for value in re.findall(r"time[=<]([\d.]+)\s*ms", text or "")]
        summary = re.search(r"min/avg/max/(?:mdev|stddev)\s*=\s*"
                            r"([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)", text or "")
        mean = sum(times) / len(times) if times else None
        sd = (sum((t - mean) ** 2 for t in times) / len(times)) ** 0.5 if times else None
        parsed = parse_ping(text or "")
        checks.eq("shipped %s sample count" % key, len(times), 5)
        checks.true("shipped %s summary line" % key, summary is not None, str(text)[:80])
        if mean is not None and sd is not None and summary is not None:
            checks.true("shipped %s mean matches summary" % key,
                        abs(mean - float(summary.group(2))) <= 0.01,
                        "%r vs %s" % (mean, summary.group(2)))
            checks.true("shipped %s stddev matches summary" % key,
                        abs(sd - float(summary.group(4))) <= 0.01,
                        "%r vs %s" % (sd, summary.group(4)))
            checks.true("shipped %s reported jitter matches its samples" % key,
                        abs(float(parsed.get("jitter_ms") or -1.0) - sd) <= 0.01,
                        "%r vs %r" % (parsed.get("jitter_ms"), sd))

    # 22. a bad host keeps ping's own line; an unknown mode flips to null, not a guess
    unresolved = parse_ping("ping: cannot resolve nope.invalid: Unknown host\n")
    checks.eq("unresolved rtt", unresolved.get("rtt_ms"), None)
    checks.true("unresolved keeps the resolver line",
                "cannot resolve" in str(unresolved.get("reason")), str(unresolved.get("reason")))
    unknown_fx = _write_json(tmp / "unknown.json", {
        "generated_at": "2026-10-23T01:23:00Z",
        "ptt_state": "sideways",
        "pgrep": [],
        "ping": {"gateway": PING_GATEWAY, "public": PING_PUBLIC},
    })
    rc, unknown_dry, _, _ = ok_json(
        ["--toggle", "--fixture", str(unknown_fx), "--dry-run",
         "--state-dir", str(tmp / "unknown-state"),
         "--ptt-state", str(tmp / "absent-mode.state")])
    checks.eq("unknown mode exit", rc, 0)
    unknown_dry = unknown_dry or {}
    checks.eq("unknown mode before", unknown_dry.get("before"), "unknown")
    checks.eq("unknown mode after", unknown_dry.get("after"), None)

    # 23. --dry-run runs no probe and writes nothing
    dry_cache = tmp / "dry-cache.json"
    if log.exists():
        log.unlink()
    rc, dry_status, out_ds, err_ds = ok_json(
        ["--status", "--json", "--dry-run", "--ping-cmd", str(stub),
         "--gateway-host", "192.168.0.1", "--cache-file", str(dry_cache),
         "--state-dir", str(state), "--ptt-state", str(ptt)], env=ping_env)
    checks.eq("dry-run status exit", rc, 0)
    checks.eq("dry-run net gateway rtt",
              (dry_status or {}).get("net", {}).get("gateway", {}).get("rtt_ms"), None)
    checks.eq("dry-run net gateway reason",
              (dry_status or {}).get("net", {}).get("gateway", {}).get("reason"), "dry-run")
    checks.eq("dry-run net public reason",
              (dry_status or {}).get("net", {}).get("public", {}).get("reason"), "dry-run")
    checks.eq("dry-run net cached", (dry_status or {}).get("net", {}).get("cached"), False)
    checks.eq("dry-run ran no ping", len(log.read_text().splitlines()) if log.exists() else 0, 0)
    checks.eq("dry-run wrote no cache", dry_cache.exists(), False)
    rc, dry_probe, out_dpr, err_dpr = ok_json(
        ["--probe", "--json", "--dry-run", "--ping-cmd", str(stub),
         "--gateway-host", "192.168.0.1", "--cache-file", str(dry_cache)], env=ping_env)
    checks.eq("dry-run probe exit", rc, 0)
    checks.eq("dry-run probe rtt",
              (dry_probe or {}).get("net", {}).get("gateway", {}).get("rtt_ms"), None)
    checks.eq("dry-run probe ran no ping", len(log.read_text().splitlines()) if log.exists() else 0, 0)

    # 24. an unreadable fixture never prints an absolute home path
    unreadable = _write(tmp / "unreadable.json", json.dumps(base_fixture), 0o000)
    rc, unread, out_un, err_un = ok_json(["--status", "--fixture", str(unreadable)] + common)
    checks.eq("unreadable fixture exit", rc, 0)
    checks.eq("unreadable fixture ok", (unread or {}).get("ok"), False)
    checks.eq("unreadable fixture kind", (unread or {}).get("kind"), "malformed")
    checks.true("unreadable fixture reason",
                "fixture unreadable" in str((unread or {}).get("reason")), str(unread))
    checks.eq("unreadable fixture leaks no /Users", out_un.count("/Users"), 0)
    checks.eq("unreadable fixture leaks no home path", out_un.count(home), 0)

    # 25. a zero-byte fixture is kind missing, exit 0 (contract, exit codes)
    zero_file = _write(tmp / "zero-bytes.json", "")
    rc, zero, out_z, err_z = ok_json(["--status", "--fixture", str(zero_file)] + common)
    checks.eq("zero-byte fixture exit", rc, 0)
    checks.eq("zero-byte fixture ok", (zero or {}).get("ok"), False)
    checks.eq("zero-byte fixture kind", (zero or {}).get("kind"), "missing")
    checks.true("zero-byte fixture reason", "empty" in str((zero or {}).get("reason")), str(zero))

    # 26. a fixture run takes since from the fixture, never from the named flag file
    prior_flag = _write_json(tmp / "prior-flag.json", {
        "gaming": True, "pause_heavy": True, "since": "2020-01-01T00:00:00Z",
        "updated_at": "2020-01-01T00:00:00Z"})
    rc, prior, out_pri, err_pri = ok_json(
        ["--status", "--fixture", str(game_fx), "--flag-file", str(prior_flag),
         "--cache-file", str(tmp / "prior-cache.json"), "--ptt-state", str(ptt)])
    checks.eq("named flag exit", rc, 0)
    checks.eq("named flag uses the fixture since",
              (prior or {}).get("pause_heavy", {}).get("since"), fixture_since_value)
    prior_obj = json.loads(prior_flag.read_text(encoding="utf-8"))
    checks.eq("named flag file takes the fixture since",
              prior_obj.get("since"), fixture_since_value)
    checks.true("named flag updated_at moved",
                prior_obj.get("updated_at") != "2020-01-01T00:00:00Z", str(prior_obj))

    # 27. fixture mode stamps no host clock into since or measured_at
    no_since_fixture = json.loads(json.dumps(base_fixture))
    no_since_fixture.pop("pause_heavy", None)
    no_since_fx = _write_json(tmp / "no-since.json", no_since_fixture)

    def strip_clock(payload):
        body = json.loads(json.dumps(payload or {}))
        body.pop("generated_at", None)
        return body

    rc, det_a, out_da, err_da = ok_json(
        ["--status", "--fixture", str(game_fx), "--state-dir", str(tmp / "det-state"),
         "--ptt-state", str(tmp / "det.state")])
    time.sleep(1.1)
    rc2, det_b, out_db, err_db = ok_json(
        ["--status", "--fixture", str(game_fx), "--state-dir", str(tmp / "det-state"),
         "--ptt-state", str(tmp / "det.state")])
    checks.eq("fixture since first exit", rc, 0)
    checks.eq("fixture since second exit", rc2, 0)
    checks.eq("fixture since is the fixture value",
              (det_a or {}).get("pause_heavy", {}).get("since"), fixture_since_value)
    checks.eq("fixture runs read no net cache",
              (det_b or {}).get("net", {}).get("cached"), False)
    checks.eq("two fixture runs identical apart from generated_at",
              strip_clock(det_a), strip_clock(det_b))

    rc, det_c, out_dc, err_dc = ok_json(["--status", "--fixture", str(no_since_fx)])
    time.sleep(1.1)
    rc2, det_d, out_dd, err_dd = ok_json(["--status", "--fixture", str(no_since_fx)])
    checks.eq("no-since fixture first exit", rc, 0)
    checks.eq("no-since fixture second exit", rc2, 0)
    checks.eq("no-since fixture since null",
              (det_c or {}).get("pause_heavy", {}).get("since"), None)
    checks.eq("no-since fixture reason",
              (det_c or {}).get("pause_heavy", {}).get("reason"), "fixture has no since")
    checks.eq("two no-since runs identical apart from generated_at",
              strip_clock(det_c), strip_clock(det_d))

    bare_fx = _write_json(tmp / "bare.json", {
        "ptt_state": "game",
        "pgrep": [{"pid": 1, "command": "PioneerGame"}]})
    rc, bare, out_bf, err_bf = ok_json(["--status", "--fixture", str(bare_fx)])
    bare = bare or {}
    checks.eq("bare fixture exit", rc, 0)
    checks.eq("bare fixture measured_at null",
              bare.get("net", {}).get("measured_at"), None)
    checks.true("bare fixture names its missing net data",
                "fixture has no ping data" in str(
                    bare.get("net", {}).get("gateway", {}).get("reason")),
                str(bare.get("net")))

    print("\nfixtures and state under %s" % tmp)
    code = checks.summary()
    print("EXIT %d" % code)
    return code


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main(argv):
    args = parse_args(argv)
    cfg = Cfg(args)

    if cfg.action == "self_check":
        return run_self_check(os.path.abspath(__file__))
    if cfg.action == "probe":
        payload, code = build_probe(cfg)
        return emit(payload, code, cfg.json_output)
    if cfg.action == "toggle":
        payload, code = build_toggle(cfg)
        return emit(payload, code, cfg.json_output)
    payload, code = build_status(cfg)
    return emit(payload, code, cfg.json_output)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        sys.exit(0)
    except KeyboardInterrupt:
        sys.exit(130)
