#!/usr/bin/env python3
# ug fixtures: gauge dirs for feeds/usage.py (fresh, error) and a frozen snapshot.
# Scratch only. The live gauge files are never read.
import json, os, sys, time

FX = sys.argv[1]
now = time.time()


def z(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


os.makedirs(FX + "/fresh", exist_ok=True)
os.makedirs(FX + "/error", exist_ok=True)

windows = [{"label": "5h session", "value": 37, "limit": 100, "unit": "%",
            "resetsAt": z(now + 3600), "exact": True, "note": ""}]
with open(FX + "/fresh/claude.json", "w") as f:
    json.dump({"state": "fresh", "fetchedAt": z(now - 42), "ttl": 300, "windows": windows}, f)

with open(FX + "/error/claude.json", "w") as f:
    json.dump({"state": "error", "fetchedAt": None, "ttl": 300,
               "error": "usage endpoint rate limited", "windows": []}, f)

# Frozen case: the snapshot says state fresh, but its source is 50 min old and
# the claude gauge file says fresh too (the way a frozen cache looks).
frozen = {
    "ok": True, "source": "fixture", "mode": "fixture",
    "generated_at": z(now), "source_as_of": z(now - 3000),
    "ttl_s": 300, "state": "fresh", "gauge_dir": FX + "/frozen",
    "gauges": {"claude": {"file_state": "fresh", "state": "fresh", "age_s": 3000,
                          "ttl_s": 300, "source_as_of": z(now - 3000),
                          "windows": windows, "error": None}},
}
with open(FX + "/frozen.json", "w") as f:
    json.dump(frozen, f)
print("fixtures ok", FX)
