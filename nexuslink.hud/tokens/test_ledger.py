#!/usr/bin/env python3
"""Scratch checks for ledger.py + pull_remote.py — python3 test_ledger.py."""
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

TMP = tempfile.mkdtemp(prefix="ledger-test-")
os.environ["XDG_STATE_HOME"] = TMP          # ledger reads env at import
sys.path.insert(0, str(Path(__file__).resolve().parent))
import ledger, pull_remote                 # noqa: E402

NOW = datetime(2026, 10, 19, 12, 0, tzinfo=timezone.utc)
TS = 1787000000.0

# @mac suffix -> own provider id
led = ledger.Ledger({})
ledger._smu_fold(led, "mac:default", "x",
                 ("s1", "m", "openai-codex", "", "", "", 10, 5, 0, 0,
                  None, None, TS), suffix="@mac")
assert "codex@mac" in led.days and "codex" not in led.days

# LIVE_PROVIDERS / REMOTE_PROVIDERS filter build() output; cursor keeps the rest
led = ledger.Ledger({})
for p in ("haze", "custom", "fireworks", "fireworks@mac", "codex@mac",
          "claude@mac", "codex", "claude", "devin", "opencode",
          "opencode-go", "devin@mac", "opencode-go@mac"):
    led.add(p, "rid:" + p, NOW, 1, 1)
out = ledger.build(led, NOW)
assert set(out["providers"]) == {"claude", "codex", "devin", "opencode",
                                 "opencode-go", "devin@mac", "opencode-go@mac"}
assert set(out["history"]) == set(out["providers"])
assert "haze" in led.days and "custom" in led.days and "fireworks" in led.days

assert ledger._label("codex@mac") == "Codex (mac)"
assert ledger._label("codex") == "Codex"

# pull_remote.parse: @@ sections -> records; empty section -> []
sample = ("@@/Users/m/.hermes/state.db\n"
          '[{"session_id":"s1","model":"m","billing_provider":"openai-codex",'
          '"billing_base_url":null,"billing_mode":"sub","task":"chat",'
          '"input_tokens":10,"output_tokens":5,"cache_read_tokens":0,'
          '"cache_write_tokens":0,"estimated_cost_usd":null,'
          '"cost_status":"included","last_seen":1787000000.0}]\n'
          "@@/Users/m/.hermes/profiles/levi/state.db\n\n"
          "@@devin\n"
          '[{"row_id":7,"session_id":"sA","created_at":1787000000,'
          '"metrics":"{\\"input_tokens\\":100,\\"output_tokens\\":20}",'
          '"acu":0.5,"model":"m"}]\n')
recs = pull_remote.parse(sample)
assert len(recs) == 2
assert recs[0]["profile"] == "default" and recs[0]["input_tokens"] == 10
assert recs[1]["kind"] == "devin" and recs[1]["row_id"] == 7
assert pull_remote.parse("@@/x/profiles/levi/state.db\n\n") == []

# collect_remote: session_model_usage row -> codex@mac; devin row -> devin@mac;
# both idempotent on re-feed
rdir = Path(TMP) / "nexuslink" / "remote"
rdir.mkdir(parents=True)
smu = {"profile": "default", "session_id": "s1", "model": "m",
       "billing_provider": "openai-codex", "billing_base_url": None,
       "billing_mode": "sub", "task": "chat", "input_tokens": 10,
       "output_tokens": 5, "cache_read_tokens": 0, "cache_write_tokens": 0,
       "estimated_cost_usd": None, "cost_status": "included", "last_seen": TS}
dev = {"kind": "devin", "row_id": 7, "session_id": "sA",
       "created_at": 1787000000,
       "metrics": "{\"input_tokens\":100,\"output_tokens\":20}",
       "acu": 0.5, "model": "m"}
(rdir / "mac.jsonl").write_text(json.dumps(smu) + "\n" + json.dumps(dev)
                                + "\nnot json\n")
led = ledger.Ledger({})
ledger.collect_remote(led)
day = list(led.days["codex@mac"].values())[0]
assert (day["in"], day["out"]) == (10, 5)
dday = list(led.days["devin@mac"].values())[0]
assert (dday["in"], dday["out"], round(dday["acu"], 2)) == (100, 20, 0.5)
assert "dv:mac:sA:7" in led.seen["devin@mac"]
before = json.dumps(led.days, sort_keys=True)
ledger.collect_remote(led)
assert json.dumps(led.days, sort_keys=True) == before

# pull_remote.run(): an empty snapshot must NOT overwrite the previous file
# (a silent empty mac.jsonl would wipe the Mac lanes in the HUD).
import pull_remote as _pr
_out = _pr.OUT_DIR
_pr.OUT_DIR = rdir
prev = (rdir / "mac.jsonl").read_text()


class _FakeProc:
    returncode = 0
    stdout = "@@/x/state.db\n\n"
    stderr = ""


_pr.subprocess = type("S", (), {"run": staticmethod(
    lambda *a, **k: _FakeProc())})
try:
    _pr.run()
    raise SystemExit("FAIL: empty snapshot was accepted")
except RuntimeError as e:
    assert "empty snapshot" in str(e), e
assert (rdir / "mac.jsonl").read_text() == prev   # previous file kept
_pr.OUT_DIR = _out

print("ok")
