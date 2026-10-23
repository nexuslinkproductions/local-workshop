#!/usr/bin/env python3
"""Usage reader: the four gauge files -> one freshness snapshot.

Reads ``$XDG_RUNTIME_DIR/gauges/{claude,devin,opencode-go,vram}.json`` (override
the folder with ``--gauge-dir``). Writes one JSON object. Stdlib only. Never
runs a command, never calls the network, never writes a file.

Freshness is judged here, by age, on this reader's clock:

* a gauge whose age (now - fetchedAt) exceeds its ttl is ``stale`` and shows no
  number, even when the file itself says ``fresh`` (the frozen case);
* a gauge whose own state is ``error`` or ``missing``, or whose file is absent
  or unparsable, shows no number and carries its error text;
* the file's own ``fresh`` never overrides the age. A file that says ``stale``
  is stale too.

Top level describes the Claude session gauge (the one the deck shows):
``source_as_of`` = its fetchedAt, ``ttl_s`` = its ttl, ``state`` = its judged
state. All four gauges are in ``gauges{}``.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
from datetime import datetime, timezone

SOURCE = "usage"
GAUGES = ("claude", "devin", "opencode-go", "vram")
PRIMARY = "claude"
ERROR_MAX = 200


def default_gauge_dir():
    base = os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
    return os.path.join(base, "gauges")


def utc_z(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(value):
    """UTC epoch seconds from an ISO string, or None."""
    if not isinstance(value, str) or not value:
        return None
    text = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if value != value or value in (float("inf"), float("-inf")):
        return None
    return float(value)


def clip(text):
    return str(text)[:ERROR_MAX]


def judge(name, path, now):
    """One gauge -> its snapshot entry. Never raises."""
    entry = {"name": name, "state": None, "age_s": None, "ttl_s": None,
             "source_as_of": None, "windows": None, "error": None, "file_state": None}
    if not os.path.exists(path):
        entry.update(state="missing", error="gauge file not found")
        return entry
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = json.load(fh)
    except (OSError, ValueError):
        entry.update(state="error", error="gauge file is not readable JSON")
        return entry
    if not isinstance(raw, dict):
        entry.update(state="error", error="gauge file is not a JSON object")
        return entry

    own = raw.get("state")
    entry["file_state"] = own if isinstance(own, str) else None
    fetched = parse_iso(raw.get("fetchedAt"))
    ttl = number(raw.get("ttl"))
    if fetched is not None:
        entry["source_as_of"] = utc_z(fetched)
        entry["age_s"] = int(max(0.0, now - fetched))
    if ttl is not None:
        entry["ttl_s"] = int(ttl)

    if own == "missing":
        entry.update(state="missing", error=clip(raw.get("error") or "gauge reports missing"))
        return entry
    if own == "error":
        entry.update(state="error", error=clip(raw.get("error") or "gauge reports error"))
        return entry
    if own not in ("fresh", "stale"):
        entry.update(state="error", error="gauge state is not fresh, stale, error or missing")
        return entry
    if fetched is None:
        entry.update(state="error", error="gauge has no usable fetchedAt")
        return entry
    if ttl is None or ttl <= 0:
        entry.update(state="error", error="gauge has no usable ttl")
        return entry
    if now - fetched > ttl:
        entry.update(state="stale", error="age %ds over ttl %ds" % (int(now - fetched), int(ttl)))
        return entry
    if own == "stale":
        entry.update(state="stale", error="gauge reports stale")
        return entry
    windows = raw.get("windows")
    entry.update(state="fresh", windows=windows if isinstance(windows, list) else [])
    return entry


def build(gauge_dir, now, mode):
    gauges = {}
    for name in GAUGES:
        gauges[name] = judge(name, os.path.join(gauge_dir, name + ".json"), now)
    primary = gauges[PRIMARY]
    return {
        "ok": True,
        "source": SOURCE,
        "mode": mode,
        "generated_at": utc_z(now),
        "source_as_of": primary["source_as_of"],
        "ttl_s": primary["ttl_s"],
        "state": primary["state"],
        "gauge_dir": gauge_dir if mode == "fixture" else "$XDG_RUNTIME_DIR/gauges",
        "gauges": gauges,
    }


def self_check():
    """Five named cases through the real CLI, as subprocesses."""
    here = os.path.abspath(__file__)
    tmp = tempfile.mkdtemp(prefix="usage-check-")
    now = time.time()
    fresh_ts = utc_z(now - 60)
    old_ts = utc_z(now - 900)
    windows = [{"label": "5h session", "value": 37, "limit": 100, "unit": "%",
                "resetsAt": utc_z(now + 3600), "exact": True, "note": ""}]

    def write(folder, name, obj):
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, name + ".json"), "w", encoding="utf-8") as fh:
            fh.write(obj if isinstance(obj, str) else json.dumps(obj))

    def others(folder):
        write(folder, "devin", {"state": "fresh", "fetchedAt": fresh_ts, "ttl": 1800, "windows": []})
        write(folder, "opencode-go", {"state": "fresh", "fetchedAt": fresh_ts, "ttl": 300, "windows": []})
        write(folder, "vram", {"state": "fresh", "fetchedAt": fresh_ts, "ttl": 30, "windows": []})

    cases = {}
    d = os.path.join(tmp, "fresh")
    others(d)
    write(d, "claude", {"state": "fresh", "fetchedAt": fresh_ts, "ttl": 300, "windows": windows})
    cases["fresh"] = d
    d = os.path.join(tmp, "stale-by-age")
    others(d)
    write(d, "claude", {"state": "fresh", "fetchedAt": old_ts, "ttl": 300, "windows": windows})
    cases["stale-by-age"] = d
    d = os.path.join(tmp, "error")
    others(d)
    write(d, "claude", {"state": "error", "fetchedAt": None, "ttl": 300,
                        "error": "usage endpoint rate limited", "windows": []})
    cases["error"] = d
    d = os.path.join(tmp, "missing")
    others(d)
    cases["missing"] = d
    d = os.path.join(tmp, "unparsable")
    others(d)
    write(d, "claude", "{not json")
    cases["unparsable"] = d

    fails = []

    def run(folder):
        import subprocess
        proc = subprocess.run([sys.executable, here, "--gauge-dir", folder, "--json"],
                              capture_output=True, text=True, timeout=20)
        if proc.returncode != 0:
            return None, "exit %d" % proc.returncode
        try:
            return json.loads(proc.stdout), None
        except ValueError:
            return None, "stdout not one JSON object"

    def expect(name, cond, detail):
        if cond:
            print("ok   %s  %s" % (name, detail))
        else:
            print("FAIL %s  %s" % (name, detail))
            fails.append(name)

    for name in ("fresh", "stale-by-age", "error", "missing", "unparsable"):
        snap, problem = run(cases[name])
        if snap is None:
            expect(name, False, problem)
            continue
        c = snap["gauges"]["claude"]
        if name == "fresh":
            expect(name, snap["state"] == "fresh" and c["state"] == "fresh"
                   and c["windows"] and c["age_s"] is not None and c["age_s"] < 300,
                   "state=%s age_s=%s windows=%d" % (c["state"], c["age_s"], len(c["windows"] or [])))
        elif name == "stale-by-age":
            expect(name, snap["state"] == "stale" and c["state"] == "stale"
                   and c["windows"] is None and c["file_state"] == "fresh" and c["age_s"] >= 900,
                   "file_state=%s state=%s age_s=%s windows=%s" % (
                       c["file_state"], c["state"], c["age_s"], c["windows"]))
        elif name == "error":
            expect(name, c["state"] == "error" and c["windows"] is None
                   and c["error"] == "usage endpoint rate limited",
                   "state=%s error=%s" % (c["state"], c["error"]))
        elif name == "missing":
            expect(name, c["state"] == "missing" and c["windows"] is None and bool(c["error"]),
                   "state=%s error=%s" % (c["state"], c["error"]))
        elif name == "unparsable":
            expect(name, c["state"] == "error" and c["windows"] is None and bool(c["error"]),
                   "state=%s error=%s" % (c["state"], c["error"]))

    if fails:
        print("SELF-CHECK FAILED: %s" % ", ".join(fails))
        return 1
    print("SELF-CHECK OK: fresh, stale-by-age, error, missing, unparsable")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Claude and other usage gauges -> one snapshot.")
    ap.add_argument("--gauge-dir", default="", help="folder of gauge JSON files (fixtures)")
    ap.add_argument("--json", action="store_true", help="one compact line")
    ap.add_argument("--self-check", action="store_true")
    a = ap.parse_args(argv)
    if a.self_check:
        return self_check()
    mode = "fixture" if a.gauge_dir else "live"
    gauge_dir = a.gauge_dir or default_gauge_dir()
    snap = build(gauge_dir, time.time(), mode)
    if a.json:
        sys.stdout.write(json.dumps(snap, separators=(",", ":")) + "\n")
    else:
        sys.stdout.write(json.dumps(snap, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
