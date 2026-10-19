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

# LIVE_PROVIDERS filters build() output; cursor keeps hidden providers
led = ledger.Ledger({})
led.add("haze", "hz:1", NOW, 100, 100)
led.add("custom", "hm:x", NOW, 100, 100)
led.add("claude", "cl:1", NOW, 1, 1)
led.add("claude@mac", "x", NOW, 1, 1)
out = ledger.build(led, NOW)
assert set(out["providers"]) == {"claude", "claude@mac"}
assert set(out["history"]) == {"claude", "claude@mac"}
assert "haze" in led.days and "custom" in led.days

assert ledger._label("codex@mac") == "Codex (mac)"
assert ledger._label("codex") == "Codex"

# pull_remote.parse: @@ sections -> records; empty section -> []
sample = ("@@/Users/m/.hermes/state.db\n"
          '[{"session_id":"s1","model":"m","billing_provider":"openai-codex",'
          '"billing_base_url":null,"billing_mode":"sub","task":"chat",'
          '"input_tokens":10,"output_tokens":5,"cache_read_tokens":0,'
          '"cache_write_tokens":0,"estimated_cost_usd":null,'
          '"cost_status":"included","last_seen":1787000000.0}]\n'
          "@@/Users/m/.hermes/profiles/levi/state.db\n\n")
recs = pull_remote.parse(sample)
assert len(recs) == 1 and recs[0]["profile"] == "default" \
    and recs[0]["input_tokens"] == 10
assert pull_remote.parse("@@/x/profiles/levi/state.db\n\n") == []

# collect_remote: one jsonl record -> codex@mac with in/out; idempotent
rdir = Path(TMP) / "nexuslink" / "remote"
rdir.mkdir(parents=True)
(rdir / "mac.jsonl").write_text(
    json.dumps({"profile": "default", "session_id": "s1", "model": "m",
                "billing_provider": "openai-codex", "billing_base_url": None,
                "billing_mode": "sub", "task": "chat", "input_tokens": 10,
                "output_tokens": 5, "cache_read_tokens": 0,
                "cache_write_tokens": 0, "estimated_cost_usd": None,
                "cost_status": "included", "last_seen": TS})
    + "\nnot json\n")
led = ledger.Ledger({})
ledger.collect_remote(led)
day = list(led.days["codex@mac"].values())[0]
assert (day["in"], day["out"]) == (10, 5)
before = json.dumps(led.days, sort_keys=True)
ledger.collect_remote(led)
assert json.dumps(led.days, sort_keys=True) == before

print("ok")
