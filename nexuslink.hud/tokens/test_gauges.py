#!/usr/bin/env python3
"""Self-check for the gauge contract: error never shows the last good number."""
import json, os, tempfile, time
import gauges

tmp = tempfile.mkdtemp()
os.environ["XDG_RUNTIME_DIR"] = tmp
gauges.RUN = gauges.Path(tmp) / "gauges"

def good():
    return [gauges.win("Weekly", 12.5, resets="2026-10-30T06:00:00+00:00")], None

def boom():
    raise gauges.GaugeError("sign-in expired")

# fresh: a successful poll writes a fresh contract with the value
g = gauges.Gauge("t", "T", "src", 300, good, True, [])
now = time.time()
g.poll(now); g.write(now)
d = json.loads((gauges.RUN / "t.json").read_text())
assert d["state"] == "fresh" and d["windows"][0]["value"] == 12.5, d

# error: value is gone, reason is shown, last good kept only as lastGood
g.fetch = boom
g.next_due = 0
g.poll(now + 1); g.write(now + 1)
d = json.loads((gauges.RUN / "t.json").read_text())
assert d["state"] == "error" and d["windows"] == [], d
assert d["error"] == "sign-in expired" and d["lastGood"]["windows"][0]["value"] == 12.5, d

# stale: data older than its ttl is marked stale, not fresh
g2 = gauges.Gauge("s", "S", "src", 300, lambda: ([], now - 900), True, [])
g2.poll(now); g2.write(now)
assert json.loads((gauges.RUN / "s.json").read_text())["state"] == "stale"

# units: contract percent (66.0) becomes the ledger fraction (0.66) the HUD expects
import types, ledger
(gauges.RUN / "claude.json").write_text(json.dumps({
    "state": "fresh", "fetchedAt": "2026-10-23T11:00:00+00:00", "ttl": 300, "error": None,
    "windows": [{"label": "Session (5-hour)", "value": 66.0, "unit": "%", "resetsAt": None}]}))
led = types.SimpleNamespace(meta={})
ledger.merge_gauge_contract(led)
assert abs(led.meta["claude"]["limits"][0]["percent"] - 0.66) < 1e-9, led.meta
assert led.meta["claude"]["gauge"]["ttl"] == 300
print("test_gauges: ok")
