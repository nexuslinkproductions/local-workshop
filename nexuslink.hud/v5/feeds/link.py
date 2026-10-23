#!/usr/bin/env python3
"""Mac link reader: tailscale RTT, tunnel state, one ssh for battery and load.

This is the "is the link to the other box healthy" feed behind ``PulseRing``
(RTT), ``DotArc`` (battery) and ``DotBar`` (load). It runs on the Linux box and
looks at the Mac; every probe is read-only and every command is bounded.

Cost, measured on the Linux box (recon/03-feeds.md): tailscale status 6.8 ms,
ping 14.3 ms, tunnel unit 3.9 ms, one combined ssh 46 ms. No single cheap
combined call exists, so the reader keeps a local ring buffer of RTT samples and
publishes both the latest probe and a rolling window (median, min, max, last).

Live mode writes exactly one file: the ring buffer at
``~/.local/state/nexuslink/rtt.json`` (or ``--state``). Fixture mode
(``--fixture v5/fixtures/link.json`` or any file with the same shape) touches
nothing, runs nothing, and calls no process.

Payload ``link`` object, fixture-compatible:

    {"ts": 1792703222, "ts_iso": "2026-10-22T21:07:02Z",
     "route": "direct" | "relay" | null,
     "tunnel": "active" | "inactive" | null,
     "rtt_ms": {"median": 7.5, "last": 5, "min": 5, "max": 92,
                "samples": [8, 7, ...], "count": 24},
     "pulse_period_s": 2.933,
     "mac": {"load": [3.94, 4.45, 4.81], "load1_frac": 0.33, "cores": 12,
             "batt": 100, "state": "charged", "rem": "0:00", "up_min": 13},
     "peers": [{"name": "nexus-macbook", "on": true}, ...]}

``pulse_period_s`` is the breathing period the RTT maps to:
``clamp(22 / median_ms, 0.9, 6.0)``. A calm link breathes slowly; a bad one
gets close to the 0.9 s floor, which is the alarm in motion form. No text.

Every probe failure is a ``degraded`` entry, not an exception: a dead tunnel
must leave the gauge dim, not break the shell. Only when nothing at all could be
measured does the payload become ``{"ok": false, "reason": ...}``.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import statistics
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as common  # noqa: E402

SOURCE = "link"
DEFAULT_STATE = "~/.local/state/nexuslink/rtt.json"
DEFAULT_SSH_HOST = "mac"
DEFAULT_RING_CAP = 240
DEFAULT_SAMPLES = 24
TUNNEL_UNIT = "hermes-peer-mac-tunnel.service"
PULSE_NUMERATOR = 22.0  # ms * s; 22 ms maps to a 1 s period
PULSE_MIN, PULSE_MAX = 0.9, 6.0

# One ssh, one shell, three facts. Order is fixed: load, battery, uptime, cores.
SSH_PROBES = (
    "sysctl -n vm.loadavg",
    "pmset -g batt | tail -1",
    "uptime",
    "sysctl -n hw.ncpu",
)

# `vm.loadavg` is one brace group of three numbers on its own line. Anything
# else in that position (a version string like `1.2.3`, bare dots) is data we
# cannot read: it is dropped with a note, never floated.
LOAD_LINE = re.compile(r"^[ \t]*\{[ \t]*([^}\n]*?)[ \t]*\}[ \t]*$", re.MULTILINE)


# ------------------------------------------------------------------------ shell


def run_command(argv, timeout):
    """Run a command, return (stdout, stderr, returncode). Never raises."""
    try:
        proc = subprocess.run(
            argv, capture_output=True, text=True, timeout=timeout, check=False
        )
        return proc.stdout or "", proc.stderr or "", proc.returncode
    except FileNotFoundError:
        return "", "not installed", 127
    except subprocess.TimeoutExpired:
        return "", "timeout after %ss" % timeout, 124
    except OSError as exc:
        return "", str(exc), 1


def ssh_command(host):
    """The single remote command line. One ssh call, no second round trip."""
    remote = "%s; echo ---; %s; echo ---; %s; echo ---; %s" % SSH_PROBES
    return [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=3",
        "-o",
        "StrictHostKeyChecking=accept-new",
        host,
        remote,
    ]


# ----------------------------------------------------------------------- probes


def tailscale_status(timeout, runner=run_command):
    out, err, code = runner(["tailscale", "status", "--json"], timeout)
    if code != 0 or not out.strip():
        raise common.Missing("tailscale status failed: %s" % (common.text(err) or "exit %d" % code))
    try:
        return json.loads(out)
    except ValueError as exc:
        raise common.Malformed("tailscale status is not JSON: %s" % exc)


def peers_of(status):
    peers = []
    for item in (status.get("Peer") or {}).values():
        if not isinstance(item, dict):
            continue
        name = common.text(item.get("HostName")) or common.text(item.get("DNSName"))
        if not name:
            continue
        peers.append(
            {
                "name": name,
                "on": bool(item.get("Online")),
                "os": common.text(item.get("OS")),
                "exit_node": bool(item.get("ExitNode")),
                "dns": common.text(item.get("DNSName")),
            }
        )
    peers.sort(key=lambda item: item["name"].lower())
    return peers


def pick_peer(peers, wanted):
    """Explicit name wins; otherwise the first online non-exit peer by name."""
    if wanted:
        wanted_low = wanted.lower()
        for peer in peers:
            names = (peer["name"] or "").lower(), (peer.get("dns") or "").lower().rstrip(".")
            if wanted_low in names or (peer.get("dns") or "").lower().startswith(wanted_low):
                return peer
        raise common.Missing("tailscale peer %r is not in the tailnet" % wanted)
    for peer in peers:
        if peer["on"] and not peer["exit_node"]:
            return peer
    raise common.Missing("no online tailscale peer")


def parse_ping(text):
    """`pong from mac (100.x) via 192.0.2.16:41641 in 5ms` -> (ms, route, detail)."""
    body = text or ""
    match = re.search(r"in\s+([0-9]+(?:\.[0-9]+)?)\s*ms", body)
    if not match:
        lowered = body.strip().lower()
        if "no matching peer" in lowered or "not found" in lowered:
            return None, None, "peer not found"
        if "timeout" in lowered or "no response" in lowered:
            return None, None, "ping timeout"
        return None, None, common.text(body) or "no pong"
    rtt = float(match.group(1))
    route = None
    if re.search(r"via\s+\d{1,3}(?:\.\d{1,3}){3}:\d+", body):
        route = "direct"
    elif "derp" in body.lower():
        route = "relay"
    return rtt, route, None


def parse_ssh_facts(text, notes=None):
    """Parse the one combined ssh answer. Missing pieces stay None.

    ``notes`` (a list, optional) collects what looked like a fact but could not
    be read, so the caller can surface it as a ``degraded`` entry instead of
    guessing a value or raising.
    """
    body = text or ""
    facts: dict = {
        "load": None,
        "load1": None,
        "batt": None,
        "state": None,
        "rem": None,
        "up_min": None,
        "cores": None,
    }  # type: dict

    load = LOAD_LINE.search(body)
    if load:
        values = [common.number(token) for token in load.group(1).split()]
        if len(values) == 3 and all(value is not None for value in values):
            facts["load"] = values
            facts["load1"] = values[0]
        elif notes is not None:
            notes.append("load line unreadable")

    batt = re.search(r"(\d{1,3})%;\s*([A-Za-z ]+?);\s*([0-9:]+)", body)
    if batt:
        facts["batt"] = int(batt.group(1))
        facts["state"] = common.text(batt.group(2))
        facts["rem"] = batt.group(3)

    up = re.search(r"up\s+(\d+)\s+days?,?\s+(\d+):(\d+)", body)
    if up:
        facts["up_min"] = (
            int(up.group(1)) * 1440 + int(up.group(2)) * 60 + int(up.group(3))
        )
    else:
        days = re.search(r"up\s+(\d+)\s+days?", body)
        if days:
            facts["up_min"] = int(days.group(1)) * 1440
        else:
            clock = re.search(r"up\s+(\d+):(\d+)", body)
            if clock:
                facts["up_min"] = int(clock.group(1)) * 60 + int(clock.group(2))
            else:
                mins = re.search(r"up\s+(\d+)\s+min", body)
                if mins:
                    facts["up_min"] = int(mins.group(1))

    cores = re.search(r"^(\d+)$", body.strip().splitlines()[-1] if body.strip() else "")
    if cores:
        facts["cores"] = int(cores.group(1))

    return facts


def collect_ssh_facts(host, timeout, runner=run_command):
    """Exactly one ssh call. Returns (facts, error_or_note).

    The second slot is a fatal error when ``facts`` is None, and a note about a
    piece that could not be read when ``facts`` is a dict. Both end up in the
    payload's ``degraded`` list; neither raises.
    """
    out, err, code = runner(ssh_command(host), timeout)
    if code != 0 and not out.strip():
        return None, common.text(err) or ("ssh exit %d" % code)
    notes = []
    facts = parse_ssh_facts(out, notes)
    if facts["batt"] is None and facts["load"] is None:
        notes.insert(0, common.text(err) or "ssh answered without battery or load")
        return None, "; ".join(notes)
    if facts["load1"] is not None and facts["cores"]:
        facts["load1_frac"] = round(facts["load1"] / float(facts["cores"]), 4)
    facts.pop("load1", None)
    if facts["load"] is not None:
        facts["load"] = [round(value, 2) for value in facts["load"]]
    note = "; ".join(notes) if notes else None
    return facts, note


def tunnel_state(timeout, status, runner=run_command):
    """systemd user unit on the Linux box; tailscale backend state elsewhere."""
    if shutil.which("systemctl"):
        out, _err, code = runner(["systemctl", "--user", "is-active", TUNNEL_UNIT], timeout)
        value = (out or "").strip()
        if value in ("active", "inactive", "failed", "activating", "deactivating"):
            return value, None
        if code not in (0, 3) and not value:
            pass  # fall through to tailscale
    backend = common.text(status.get("BackendState")) if isinstance(status, dict) else None
    if backend:
        return ("active" if backend == "Running" else backend.lower()), "tunnel unit not checked, tailscale says %s" % backend
    return None, "tunnel state unavailable"


# ------------------------------------------------------------------ ring buffer


def read_ring(path):
    """(samples, warning). A corrupt ring is a fresh ring, never a crash."""
    try:
        root = common.read_json(path, "rtt ring buffer")
    except common.DataProblem as exc:
        if isinstance(exc, common.Missing):
            return [], None
        return [], "rtt ring buffer reset: %s" % exc.reason
    if not isinstance(root, dict):
        return [], "rtt ring buffer reset: not an object"
    raw = root.get("samples")
    if not isinstance(raw, list):
        return [], "rtt ring buffer reset: no samples array"
    samples = []
    dropped = 0
    for item in raw:
        if not isinstance(item, dict):
            dropped += 1
            continue
        value = common.number(item.get("ms"))
        if value is None:
            dropped += 1
            continue
        samples.append(
            {
                "ts": item.get("ts"),
                "epoch": common.integer(item.get("epoch")),
                "ms": round(value, 3),
                "route": common.text(item.get("route")),
            }
        )
    warning = "rtt ring buffer dropped %d unusable samples" % dropped if dropped else None
    return samples, warning


def push_ring(path, samples, cap):
    window = samples[-cap:] if cap > 0 else samples
    common.write_json(
        path,
        {
            "version": 1,
            "updated_at": common.iso_now(),
            "count": len(window),
            "samples": window,
        },
    )
    return window


def ring_stats(samples, limit):
    values = [item["ms"] for item in samples if item.get("ms") is not None]
    if not values:
        return None
    tail = values[-limit:] if limit > 0 else values
    median = round(statistics.median(values), 2)
    return {
        "median": median,
        "last": round(values[-1], 2),
        "min": round(min(values), 2),
        "max": round(max(values), 2),
        "count": len(values),
        "samples": [round(value, 1) for value in tail],
    }


def pulse_period(stats):
    if not stats or not stats.get("median"):
        return None
    period = PULSE_NUMERATOR / float(stats["median"])
    return round(min(max(period, PULSE_MIN), PULSE_MAX), 3)


def finite_floats(value, limit=None):
    """Coerce a list or a whitespace-separated string into finite floats.

    All or nothing: one non-finite element (NaN, Infinity, a string that is not
    a number, a nested object) makes the whole value ``None``. The slot position
    is the meaning in a load triple (1, 5 and 15 minutes), so dropping a bad
    element would slide every later value into an earlier slot and report it as
    the wrong thing. This matches the live path, where ``parse_ssh_facts`` drops
    the whole triple. ``limit`` still trims a finite list to its first values.
    """
    if isinstance(value, str):
        value = value.replace(",", " ").split()
    if not isinstance(value, (list, tuple)):
        return None
    out = []
    for item in value:
        number = common.number(item)
        if number is None:
            return None
        out.append(round(number, 3))
    if limit is not None:
        out = out[:limit]
    return out or None


def string_field(value):
    """A text field: only a real string is text, never ``str(float)``.

    ``common.text`` stringifies anything it is given, so a fixture carrying
    ``{"state": NaN}`` used to publish ``"nan"``. ``state`` and ``rem`` are the
    battery's word and clock, so a non-string is no value at all.
    """
    return common.text(value) if isinstance(value, str) else None


def mac_block(value):
    """The mac block with every value finite and typed, or None.

    Same discipline as metrics.py: numbers through ``number``/``integer``,
    strings through ``text``, so a fixture carrying ``NaN``, ``Infinity`` or a
    string where a number belongs cannot reach the output (QML's JSON.parse
    rejects those tokens). ``load`` is all or nothing: one non-finite element
    nulls the triple rather than shifting the remaining values into earlier
    slots. ``state`` and ``rem`` are text or null, never ``"nan"``/``"inf"``.
    ``load1_frac`` is derived only from finite values with a positive core
    count.
    """
    if not isinstance(value, dict):
        return None
    raw_load = value.get("load")
    load = finite_floats(raw_load, limit=3)
    cores = common.integer(value.get("cores"))
    block = {
        "load": load,
        "load1_frac": common.number(value.get("load1_frac")),
        "cores": cores,
        "batt": common.integer(value.get("batt")),
        "state": string_field(value.get("state")),
        "rem": string_field(value.get("rem")),
        "up_min": common.integer(value.get("up_min")),
    }
    if load is None and raw_load is not None:
        # The triple was present and rejected: any stated ratio belongs to it.
        block["load1_frac"] = None
    if block["load1_frac"] is None and load and cores and cores > 0:
        block["load1_frac"] = round(load[0] / float(cores), 4)
    return block if any(item is not None for item in block.values()) else None


# ------------------------------------------------------------------------ shape


def link_object(args, route, tunnel, rtt_stats, mac, peers, ts):
    return {
        "ts": ts,
        "ts_iso": common.iso(ts),
        "route": route,
        "tunnel": tunnel,
        "rtt_ms": rtt_stats,
        "pulse_period_s": pulse_period(rtt_stats),
        "mac": mac,
        "peers": [{"name": peer["name"], "on": peer["on"]} for peer in peers],
    }


def payload(args, link, degraded):
    out = common.envelope(
        SOURCE,
        "fixture" if args.fixture else "live",
        link=link,
    )
    # Every degraded entry is display text that reaches the HUD: shorten home
    # paths here, at the single choke point, so the success envelope is covered
    # exactly like the failure one (common.failure also applies tilde_text).
    clean = [common.tilde_text(str(item)) for item in degraded if item]
    if clean:
        out["degraded"] = clean
    return out


def live(args):
    ts = common.utc_now_epoch()
    degraded = []
    status = None
    peers = []
    route = None
    rtt = None

    try:
        status = tailscale_status(args.timeout)
        peers = peers_of(status)
        peer = pick_peer(peers, args.peer)
    except common.DataProblem as exc:
        peer = None
        degraded.append("tailscale: %s" % exc.reason)

    if peer is not None:
        target = args.peer or peer.get("dns") or peer["name"]
        out, err, code = run_command(
            ["tailscale", "ping", "--c=1", target], args.timeout
        )
        rtt, ping_route, detail = parse_ping(out if out.strip() else err)
        route = ping_route
        if rtt is None:
            degraded.append("ping %s: %s" % (peer["name"], detail or "no pong"))
        elif code not in (0, None):
            degraded.append("ping %s: exit %d" % (peer["name"], code))

    tunnel = None
    try:
        tunnel, note = tunnel_state(args.timeout, status)
        if note:
            degraded.append(note)
    except common.DataProblem as exc:
        degraded.append("tunnel: %s" % exc.reason)

    mac = None
    try:
        mac, error = collect_ssh_facts(args.ssh_host, args.timeout)
        if error:
            degraded.append("ssh %s: %s" % (args.ssh_host, error))
    except common.DataProblem as exc:
        degraded.append("ssh %s: %s" % (args.ssh_host, exc.reason))

    # Ring buffer: append the fresh sample, publish the rolling window.
    samples, warning = read_ring(args.state)
    if warning:
        degraded.append(warning)
    if rtt is not None:
        samples.append(
            {"ts": common.iso(ts), "epoch": ts, "ms": round(rtt, 3), "route": route}
        )
    try:
        samples = push_ring(args.state, samples, args.ring_cap)
    except OSError as exc:
        degraded.append("ring buffer not written: %s" % (exc.strerror or exc))
    stats = ring_stats(samples, args.samples)

    if stats is None and mac is None and tunnel is None:
        raise common.Missing(
            "no link signal (tailscale, ping, tunnel and ssh all failed): %s"
            % "; ".join(degraded) if degraded else "no link signal"
        )

    return payload(args, link_object(args, route, tunnel, stats, mac, peers, ts), degraded)


# ---------------------------------------------------------------------- fixture


def normalise_link_entry(args, root):
    if not isinstance(root, dict):
        raise common.Malformed("link fixture must be an object")
    ts = common.integer(root.get("ts"))
    if ts is None and root.get("ts_iso"):
        ts = common.integer(common.epoch_from_iso(root.get("ts_iso")))
    if ts is None:
        ts = common.utc_now_epoch()

    stats = None
    raw_rtt = root.get("rtt_ms")
    if isinstance(raw_rtt, dict):
        samples = raw_rtt.get("samples")
        values = []
        if isinstance(samples, list):
            values = [common.number(item) for item in samples]
            values = [value for value in values if value is not None]
        stats = {
            "median": common.number(raw_rtt.get("median")),
            "last": common.number(raw_rtt.get("last")),
            "min": common.number(raw_rtt.get("min")),
            "max": common.number(raw_rtt.get("max")),
            "count": len(values) if values else common.integer(raw_rtt.get("samples_total")),
            "samples": [round(value, 1) for value in values[-args.samples:]],
        }
        if stats["median"] is None and values:
            stats["median"] = round(statistics.median(values), 2)
        if stats["last"] is None and values:
            stats["last"] = round(values[-1], 2)
        if stats["min"] is None and values:
            stats["min"] = round(min(values), 2)
        if stats["max"] is None and values:
            stats["max"] = round(max(values), 2)
        stats = {key: value for key, value in stats.items() if value is not None} or None
    elif raw_rtt is not None:
        raise common.Malformed("link fixture rtt_ms must be an object")

    mac = None
    raw_mac = root.get("mac")
    if raw_mac is not None and not isinstance(raw_mac, dict):
        raise common.Malformed("link fixture mac must be an object")
    mac = mac_block(raw_mac)

    peers = []
    raw_peers = root.get("peers")
    if isinstance(raw_peers, list):
        for item in raw_peers:
            if isinstance(item, dict) and (common.text(item.get("name")) or common.text(item.get("n"))):
                peers.append(
                    {
                        "name": common.text(item.get("name")) or common.text(item.get("n")),
                        "on": bool(item.get("on")),
                    }
                )
    elif raw_peers is not None:
        raise common.Malformed("link fixture peers must be an array")

    if stats is None and mac is None and not peers:
        raise common.Malformed("link fixture carries no rtt, mac or peer data")

    period = common.number(root.get("pulse_period_s"))
    if period is None:
        period = pulse_period(stats)
    return link_object(
        args,
        common.text(root.get("route")),
        common.text(root.get("tunnel")),
        stats,
        mac,
        peers,
        ts,
    ), period


def fixture(args):
    root = common.read_json(args.fixture, "link fixture")
    link, period = normalise_link_entry(args, root)
    link["pulse_period_s"] = period
    return payload(args, link, [])


# ------------------------------------------------------------------- self-check


def _cli(argv, env=None):
    import subprocess

    proc = subprocess.run(
        [sys.executable, os.path.abspath(__file__)] + argv,
        capture_output=True,
        text=True,
        env=env,
    )
    try:
        parsed = json.loads(proc.stdout) if proc.stdout.strip() else None
    except ValueError:
        parsed = None
    return proc.returncode, parsed, proc.stdout, proc.stderr


def self_check(args):
    import json
    import tempfile

    ok, bad = [], []

    def check(name, condition, detail=""):
        if condition:
            ok.append(name)
            print("PASS %s" % name)
        else:
            bad.append(name)
            print("FAIL %s %s" % (name, detail))

    # --- parsing, with the exact shapes the real commands emit --------------
    rtt, route, detail = parse_ping(
        "pong from nexus-macbook (100.64.12.2) via 192.0.2.16:41641 in 5ms"
    )
    check("ping-parse-rtt", rtt == 5.0, "rtt=%s" % rtt)
    check("ping-parse-direct", route == "direct", "route=%s" % route)
    check("ping-parse-clean", detail is None, str(detail))

    rtt, route, _ = parse_ping(
        "pong from mac (100.64.12.2) via DERP(ams) in 92.4ms"
    )
    check("ping-parse-relay", route == "relay" and rtt == 92.4, "%s %s" % (rtt, route))

    rtt, route, detail = parse_ping("timeout waiting for ping reply")
    check("ping-parse-timeout", rtt is None and detail == "ping timeout", str(detail))

    rtt, route, detail = parse_ping("no matching peer")
    check("ping-parse-nopeer", rtt is None and detail == "peer not found", str(detail))

    facts = parse_ssh_facts(
        "{ 3.94 4.45 4.81 }\nNow drawing from 'Battery Power'\n"
        "-InternalBattery-0 (id=1234567)\t100%; charged; 0:00 remaining present: true\n"
        " 23:06  up 13 days,  2:41, 2 users, load averages: 3.94 4.45 4.81\n12\n"
    )
    check("ssh-parse-load", facts["load"] == [3.94, 4.45, 4.81], str(facts["load"]))
    check("ssh-parse-batt", facts["batt"] == 100, str(facts["batt"]))
    check("ssh-parse-state", facts["state"] == "charged", str(facts["state"]))
    check("ssh-parse-rem", facts["rem"] == "0:00", str(facts["rem"]))
    check("ssh-parse-up", facts["up_min"] == 13 * 1440 + 161, str(facts["up_min"]))
    check("ssh-parse-cores", facts["cores"] == 12, str(facts["cores"]))

    clock = parse_ssh_facts(" 23:06 up 4:12, 1 user\n")
    check("ssh-parse-clock-up", clock["up_min"] == 252, str(clock["up_min"]))

    # --- exactly one ssh call, and the command is one ssh ------------------
    calls = []

    def fake_runner(argv, timeout):
        calls.append(list(argv))
        if argv[0] == "ssh":
            return (
                "{ 1.0 1.1 1.2 }\n-InternalBattery-0\t72%; charging; 0:43\n"
                " 10:00 up 2 days, 1:00, 1 user\n8\n",
                "",
                0,
            )
        return "", "unexpected", 1

    one_facts, one_error = collect_ssh_facts("mac", 4, runner=fake_runner)
    check("ssh-single-call", len(calls) == 1, "%d calls" % len(calls))
    check("ssh-call-is-ssh", calls and calls[0][0] == "ssh", str(calls[:1]))
    check(
        "ssh-call-probes",
        all(probe in calls[0][-1] for probe in SSH_PROBES),
        calls[0][-1] if calls else "",
    )
    check("ssh-call-no-second", one_error is None, str(one_error))
    check("ssh-facts-batt", (one_facts or {}).get("batt") == 72, str(one_facts))
    check(
        "ssh-facts-loadfrac",
        (one_facts or {}).get("load1_frac") == 0.125,
        str((one_facts or {}).get("load1_frac")),
    )

    broken_calls = []

    def broken_runner(argv, timeout):
        broken_calls.append(list(argv))
        return "", "Permission denied (publickey).", 255

    broken_facts, broken_error = collect_ssh_facts("mac", 4, runner=broken_runner)
    check("ssh-failure-is-data", broken_facts is None and "Permission" in (broken_error or ""), str(broken_error))
    check("ssh-failure-single-call", len(broken_calls) == 1, "%d calls" % len(broken_calls))

    # --- a malformed load line is dropped with a note, never a crash (R2) ---
    bad_load = (
        "{ 1.2.3 1.1 1.2 }\n"
        "-InternalBattery-0 (id=1) 72%; charging; 0:43 remaining present: true\n"
        " 10:00  up 2 days, 1:00, 1 user\n8\n"
    )
    bad_facts, bad_note = collect_ssh_facts(
        "mac", 4, runner=lambda argv, timeout: (bad_load, "", 0)
    )
    check("ssh-bad-load-is-data", isinstance(bad_facts, dict), str(bad_facts))
    check("ssh-bad-load-dropped", (bad_facts or {}).get("load") is None, str(bad_facts))
    check("ssh-bad-load-note", "load" in (bad_note or "").lower(), str(bad_note))
    check("ssh-bad-load-keeps-batt", (bad_facts or {}).get("batt") == 72, str(bad_facts))
    check("ssh-bad-load-no-frac", (bad_facts or {}).get("load1_frac") is None, str(bad_facts))

    dots_facts, dots_note = collect_ssh_facts(
        "mac", 4, runner=lambda argv, timeout: ("{ . . . }\n12\n", "", 0)
    )
    check("ssh-dots-load-is-data", dots_facts is None and "load" in (dots_note or "").lower(), str(dots_note))

    # --- peer selection ----------------------------------------------------
    peers = [
        {"name": "vm-small-AMS-1", "on": False, "exit_node": False, "dns": None},
        {"name": "nexus-macbook", "on": True, "exit_node": False, "dns": "nexus-macbook.example.ts.net."},
        {"name": "OmarchyLink", "on": True, "exit_node": True, "dns": "ol.example.ts.net."},
    ]
    check("peer-auto", pick_peer(peers, None)["name"] == "nexus-macbook", "")
    check("peer-by-name", pick_peer(peers, "nexus-macbook")["name"] == "nexus-macbook", "")
    check("peer-by-dns", pick_peer(peers, "nexus-macbook.example.ts.net")["name"] == "nexus-macbook", "")
    try:
        pick_peer([peers[0]], None)
        missing_peer = False
    except common.DataProblem:
        missing_peer = True
    check("peer-none-online", missing_peer, "offline peers must not be picked")

    # --- pulse period ------------------------------------------------------
    check("pulse-7.5", pulse_period({"median": 7.5}) == 2.933, str(pulse_period({"median": 7.5})))
    check("pulse-floor", pulse_period({"median": 400.0}) == 0.9, str(pulse_period({"median": 400.0})))
    check("pulse-ceiling", pulse_period({"median": 1.0}) == 6.0, str(pulse_period({"median": 1.0})))
    check("pulse-null", pulse_period(None) is None, "")

    # --- ring buffer -------------------------------------------------------
    root = tempfile.mkdtemp(prefix="w8-link-", dir=os.environ.get("TMPDIR"))
    ring = os.path.join(root, "rtt.json")
    sample = {"ts": common.iso_now(), "epoch": common.utc_now_epoch(), "ms": 7.0, "route": "direct"}
    ring_samples = []
    for _ in range(5):
        ring_samples, _warning = read_ring(ring)
        ring_samples.append(dict(sample))
        ring_samples = push_ring(ring, ring_samples, 3)
    check("ring-cap", len(ring_samples) == 3, "%d kept" % len(ring_samples))
    reread, warning = read_ring(ring)
    check("ring-roundtrip", len(reread) == 3 and warning is None, "%s %s" % (reread, warning))
    stats = ring_stats(reread, 24) or {}
    check("ring-stats", stats.get("median") == 7.0 and stats.get("count") == 3, str(stats))
    with open(ring, "w", encoding="utf-8") as handle:
        handle.write("{not json")
    corrupt, warning = read_ring(ring)
    check("ring-corrupt-reset", corrupt == [] and warning is not None, str(warning))
    with open(ring, "w", encoding="utf-8") as handle:
        json.dump({"samples": [{"ms": "fast"}, {"ms": 3}, "junk"]}, handle)
    mixed, warning = read_ring(ring)
    check("ring-drops-junk", len(mixed) == 1 and warning is not None, "%s %s" % (mixed, warning))

    # --- the shipped fixture, and fixture mode touching nothing ------------
    shipped = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "fixtures", "link.json"))
    state_before = os.path.exists(args.state)
    code, parsed, stdout, stderr = _cli(["--fixture", shipped, "--json"])
    check("fixture-exit-0", code == 0, "exit=%s %s" % (code, stderr.strip()[:200]))
    check("fixture-ok-true", (parsed or {}).get("ok") is True, str(parsed)[:300])
    link = (parsed or {}).get("link") or {}
    check("fixture-route", link.get("route") == "direct", str(link.get("route")))
    check("fixture-tunnel", link.get("tunnel") == "active", str(link.get("tunnel")))
    check("fixture-rtt-median", (link.get("rtt_ms") or {}).get("median") == 7.5, str(link.get("rtt_ms")))
    check("fixture-rtt-count", (link.get("rtt_ms") or {}).get("count") == 24, str(link.get("rtt_ms")))
    check("fixture-batt", (link.get("mac") or {}).get("batt") == 100, str(link.get("mac")))
    check("fixture-up", (link.get("mac") or {}).get("up_min") == 13, str(link.get("mac")))
    check("fixture-peers", len(link.get("peers") or []) == 4, str(link.get("peers")))
    check("fixture-pulse", isinstance(link.get("pulse_period_s"), float), str(link.get("pulse_period_s")))
    check("fixture-mode", (parsed or {}).get("mode") == "fixture", str((parsed or {}).get("mode")))
    check("fixture-no-ring", os.path.exists(args.state) == state_before, "fixture mode wrote a state file")
    check(
        "fixture-no-home-path",
        common.HOME not in json.dumps(parsed),
        "absolute home path in payload",
    )

    # --- data problems -----------------------------------------------------
    iso_only = os.path.join(root, "iso-only.json")
    with open(iso_only, "w", encoding="utf-8") as handle:
        json.dump({"ts_iso": "2026-10-22T21:07:02Z", "rtt_ms": {"samples": [4, 6]}, "route": "direct"}, handle)
    code, parsed, _, _ = _cli(["--fixture", iso_only, "--json"])
    link = (parsed or {}).get("link") or {}
    check("iso-only-ts", link.get("ts") == 1792703222, str(link.get("ts")))
    check("iso-only-stats", (link.get("rtt_ms") or {}).get("median") == 5.0, str(link.get("rtt_ms")))

    broken = os.path.join(root, "broken.json")
    with open(broken, "w", encoding="utf-8") as handle:
        handle.write("[")
    code, parsed, _, _ = _cli(["--fixture", broken, "--json"])
    check("bad-json-exit-0", code == 0, "exit=%s" % code)
    check("bad-json-ok-false", (parsed or {}).get("ok") is False, str(parsed))
    check("bad-json-kind", (parsed or {}).get("kind") == "malformed", str((parsed or {}).get("kind")))

    wrong = os.path.join(root, "wrong.json")
    with open(wrong, "w", encoding="utf-8") as handle:
        json.dump(["not", "an", "object"], handle)
    code, parsed, _, _ = _cli(["--fixture", wrong, "--json"])
    check("wrong-shape-ok-false", (parsed or {}).get("ok") is False, str(parsed))

    empty = os.path.join(root, "empty.json")
    with open(empty, "w", encoding="utf-8") as handle:
        json.dump({}, handle)
    code, parsed, _, _ = _cli(["--fixture", empty, "--json"])
    check("empty-ok-false", (parsed or {}).get("ok") is False, str(parsed))
    check("empty-reason", bool((parsed or {}).get("reason")), str(parsed))

    code, parsed, _, _ = _cli(["--fixture", os.path.join(root, "nope.json"), "--json"])
    check("missing-exit-0", code == 0, "exit=%s" % code)
    check("missing-kind", (parsed or {}).get("kind") == "missing", str(parsed))

    # --- NaN and Infinity never reach the output (R5) ----------------------
    def reject_constant(token):
        raise ValueError("non-JSON constant %s" % token)

    def strict(text):
        try:
            json.loads(text, parse_constant=reject_constant)
            return True
        except ValueError:
            return False

    nan_fixture = os.path.join(root, "nan.json")
    with open(nan_fixture, "w", encoding="utf-8") as handle:
        json.dump(
            {
                "ts": 1792703222,
                "route": "direct",
                "mac": {"load": [3.94, 4.45, 4.81], "cores": "NaN", "batt": 100},
            },
            handle,
        )
    code, parsed, stdout, stderr = _cli(["--fixture", nan_fixture, "--json"])
    mac = ((parsed or {}).get("link") or {}).get("mac") or {}
    check("nan-fixture-exit-0", code == 0, "exit=%s %s" % (code, stderr.strip()[:200]))
    check("nan-fixture-strict-json", strict(stdout), stdout.strip()[:200])
    check("nan-fixture-no-tokens", "NaN" not in stdout and "Infinity" not in stdout, stdout.strip()[:200])
    check("nan-fixture-cores-dropped", mac.get("cores") is None, str(mac))
    check("nan-fixture-no-frac", mac.get("load1_frac") is None, str(mac))
    check("nan-fixture-keeps-batt", mac.get("batt") == 100 and mac.get("load") == [3.94, 4.45, 4.81], str(mac))

    dirty_fixture = os.path.join(root, "dirty.json")
    with open(dirty_fixture, "w", encoding="utf-8") as handle:
        handle.write(
            '{"ts": 1792703222, "mac": {"load": [NaN, 3.94, Infinity], "batt": "Infinity",'
            ' "state": 5, "rem": "0:43", "up_min": "nan", "cores": 0, "load1_frac": "NaN"},'
            ' "peers": [{"name": "mac", "on": true}]}'
        )
    code, parsed, stdout, stderr = _cli(["--fixture", dirty_fixture, "--json"])
    mac = ((parsed or {}).get("link") or {}).get("mac") or {}
    check("dirty-fixture-exit-0", code == 0, "exit=%s %s" % (code, stderr.strip()[:200]))
    check("dirty-fixture-strict-json", strict(stdout), stdout.strip()[:200])
    check(
        "dirty-fixture-load-dropped",
        mac.get("load") is None and mac.get("batt") is None and mac.get("up_min") is None,
        str(mac),
    )
    check(
        "dirty-fixture-text-typed",
        mac.get("state") is None and mac.get("rem") == "0:43" and mac.get("cores") == 0,
        str(mac),
    )
    check("dirty-fixture-zero-cores-no-frac", mac.get("load1_frac") is None, str(mac))

    # --- a non-finite element nulls the whole load triple (R6) --------------
    # Slot position is the meaning: [3.94, Infinity, 4.81] must never become
    # [3.94, 4.81], where the 15 minute value would be read as the 5 minute one.
    def mac_of(stdout_text):
        parsed = json.loads(stdout_text) if stdout_text.strip() else None
        return ((parsed or {}).get("link") or {}).get("mac") or {}

    mid_inf = os.path.join(root, "load-mid-inf.json")
    with open(mid_inf, "w", encoding="utf-8") as handle:
        handle.write(
            '{"ts": 1792703222, "route": "direct",'
            ' "mac": {"load": [3.94, Infinity, 4.81], "cores": 12, "batt": 100}}'
        )
    code, parsed, stdout, stderr = _cli(["--fixture", mid_inf, "--json"])
    mac = mac_of(stdout)
    check("load-mid-inf-exit-0", code == 0, "exit=%s %s" % (code, stderr.strip()[:200]))
    check("load-mid-inf-strict-json", strict(stdout), stdout.strip()[:200])
    check("load-mid-inf-list-null", mac.get("load") is None, str(mac))
    check("load-mid-inf-no-frac", mac.get("load1_frac") is None, str(mac))
    check(
        "load-mid-inf-keeps-counters",
        mac.get("batt") == 100 and mac.get("cores") == 12,
        str(mac),
    )

    first_inf = os.path.join(root, "load-first-inf.json")
    with open(first_inf, "w", encoding="utf-8") as handle:
        handle.write(
            '{"ts": 1792703222, "route": "direct",'
            ' "mac": {"load": [Infinity, 4.45, 4.81], "cores": 12, "batt": 100}}'
        )
    code, parsed, stdout, stderr = _cli(["--fixture", first_inf, "--json"])
    mac = mac_of(stdout)
    check("load-first-inf-exit-0", code == 0, "exit=%s %s" % (code, stderr.strip()[:200]))
    check("load-first-inf-list-null", mac.get("load") is None, str(mac))
    check("load-first-inf-no-frac", mac.get("load1_frac") is None, str(mac))

    # A stated ratio cannot outlive the triple it describes.
    stated_frac = os.path.join(root, "load-inf-stated-frac.json")
    with open(stated_frac, "w", encoding="utf-8") as handle:
        handle.write(
            '{"ts": 1792703222, "mac": {"load": [3.94, Infinity, 4.81],'
            ' "load1_frac": 0.9, "cores": 12, "batt": 100}}'
        )
    code, parsed, stdout, stderr = _cli(["--fixture", stated_frac, "--json"])
    mac = mac_of(stdout)
    check("load-inf-stated-frac-exit-0", code == 0, "exit=%s %s" % (code, stderr.strip()[:200]))
    check(
        "load-inf-stated-frac-null",
        mac.get("load") is None and mac.get("load1_frac") is None,
        str(mac),
    )

    # The fix is narrow: a finite partial list still derives load1_frac.
    short_load = os.path.join(root, "load-short.json")
    with open(short_load, "w", encoding="utf-8") as handle:
        handle.write('{"mac": {"load": [1.5], "cores": 4, "batt": 72}}')
    code, parsed, stdout, stderr = _cli(["--fixture", short_load, "--json"])
    mac = mac_of(stdout)
    check("load-short-exit-0", code == 0, "exit=%s %s" % (code, stderr.strip()[:200]))
    check("load-short-kept", mac.get("load") == [1.5], str(mac))
    check("load-short-frac", mac.get("load1_frac") == 0.375, str(mac))

    # --- state and rem are text or null, never str(nan/inf) (R7) -----------
    text_fixture = os.path.join(root, "state-rem.json")
    with open(text_fixture, "w", encoding="utf-8") as handle:
        handle.write(
            '{"ts": 1792703222, "route": "direct", "mac": {"load": [3.94, 4.45, 4.81],'
            ' "cores": 12, "batt": 100, "state": NaN, "rem": Infinity}}'
        )
    code, parsed, stdout, stderr = _cli(["--fixture", text_fixture, "--json"])
    mac = mac_of(stdout)
    check("state-rem-nonstring-exit-0", code == 0, "exit=%s %s" % (code, stderr.strip()[:200]))
    check("state-rem-nonstring-strict-json", strict(stdout), stdout.strip()[:200])
    check(
        "state-rem-nonstring-null",
        mac.get("state") is None and mac.get("rem") is None,
        str(mac),
    )
    check(
        "state-rem-keeps-load",
        mac.get("load") == [3.94, 4.45, 4.81] and mac.get("load1_frac") == 0.3283,
        str(mac),
    )

    # --- the live success envelope carries no absolute home path (R4) ------
    shims = os.path.join(root, "bin")
    os.makedirs(shims)
    status_json = (
        '{"BackendState": "Running", "Peer": {"k1": {"HostName": "mac",'
        ' "DNSName": "mac.example.ts.net.", "Online": true, "ExitNode": false}}}'
    )
    shim_body = (
        "#!/bin/sh\n"
        "case \"$1\" in\n"
        "  status) printf '%%s' '%s' ;;\n"
        "  ping) echo \"pong from mac (100.64.0.2) via 192.0.2.15:41641 in 7ms\" ;;\n"
        "esac\n"
        "exit 0\n" % status_json
    )
    ssh_body = (
        "#!/bin/sh\n"
        "echo \"$HOME/.ssh/config: line 3: Bad configuration option: frobnicate\" >&2\n"
        "exit 255\n"
    )
    for name, body in (("tailscale", shim_body), ("ssh", ssh_body)):
        path = os.path.join(shims, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(body)
        os.chmod(path, 0o755)

    live_env = dict(os.environ, PATH="%s:/usr/bin:/bin" % shims)
    live_state = os.path.join(root, "live-rtt.json")
    code, parsed, stdout, stderr = _cli(
        ["--state", live_state, "--json"], env=live_env
    )
    payload = parsed or {}
    degraded = payload.get("degraded") or []
    check("live-ssh-fail-exit-0", code == 0, "exit=%s %s" % (code, stderr.strip()[:200]))
    check("live-ssh-fail-ok-true", payload.get("ok") is True and payload.get("mode") == "live", str(payload)[:200])
    check("live-ssh-fail-degraded-tilde", any("~/.ssh/config" in str(item) for item in degraded), str(degraded))
    check("live-ssh-fail-no-home-path", common.HOME not in stdout, "absolute home path in output")
    ring_check, ring_warning = read_ring(live_state)
    check("live-ssh-fail-rtt-ring", len(ring_check) == 1 and ring_warning is None, str(ring_check))

    print("\nself-check %s: %d passed, %d failed" % ("ok" if not bad else "FAILED", len(ok), len(bad)))
    if bad:
        print("failed: %s" % ", ".join(bad))
    return 0 if not bad else 1


# --------------------------------------------------------------------------- cli


def parse(argv):
    parser = argparse.ArgumentParser(description="Mac link feed for the v5 HUD.")
    common.add_common_args(parser)
    parser.add_argument("--state", default=DEFAULT_STATE, help="RTT ring buffer file (default %s)" % DEFAULT_STATE)
    parser.add_argument("--peer", default=None, help="tailscale peer hostname (default: first online peer)")
    parser.add_argument("--ssh-host", default=os.environ.get("NEXUS_HUD_SSH_HOST", DEFAULT_SSH_HOST), help="ssh host for battery and load (default %s)" % DEFAULT_SSH_HOST)
    parser.add_argument("--ring-cap", type=int, default=DEFAULT_RING_CAP, help="ring buffer length (default 240)")
    parser.add_argument("--samples", type=int, default=DEFAULT_SAMPLES, help="RTT samples to emit (default 24)")
    parser.add_argument("--timeout", type=float, default=6.0, help="seconds per probe (default 6)")
    parser.add_argument("--self-check", action="store_true", help="run the built-in checks and exit")
    args = parser.parse_args(argv)
    if args.ring_cap <= 0:
        parser.error("--ring-cap must be positive")
    if args.samples <= 0:
        parser.error("--samples must be positive")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    return args


def build(args):
    if args.fixture:
        return fixture(args)
    return live(args)


def main(argv=None):
    args = parse(argv)
    if args.self_check:
        return self_check(args)
    return common.run(SOURCE, build, args)


if __name__ == "__main__":
    sys.exit(main())
