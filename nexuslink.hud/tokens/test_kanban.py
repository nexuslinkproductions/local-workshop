#!/usr/bin/env python3
"""Scratch checks for the board feed in pull_remote.py.

python3 test_kanban.py

Covers the acceptance items for HUD 01:
  * a 3-card fixture parses into the documented shape
  * card bodies (and results) never reach the board file
  * the 24 h done filter works (old done dropped, fresh done kept)
  * a malformed kanban section keeps the previous file and sets stale
  * the token output is byte-identical with and without the kanban section
"""
import json
import os
import sys
import tempfile
from pathlib import Path

TMP = tempfile.mkdtemp(prefix="kanban-test-")
os.environ["XDG_STATE_HOME"] = TMP          # pull_remote reads env at import
sys.path.insert(0, str(Path(__file__).resolve().parent))
import pull_remote as pr                    # noqa: E402

OUT = Path(TMP) / "nexuslink" / "remote"
OUT.mkdir(parents=True)
pr.OUT_DIR = OUT
BOARD = OUT / "mac-kanban.json"

NOW = 1792528000.0
HOUR = 3600.0

# The fixture clock IS the test clock. keep_card() drops `done` cards older
# than the 24 h window, and run() -> parse_kanban() falls back to time.time()
# when no `now=` is passed. An unpinned wall clock therefore ages the
# `t_ccc` card (done 30 min before NOW) out of the window and this file goes
# red by itself ~21 h after the fixture was written. Pin the module's clock
# to NOW so the file can never expire.
pr.time.time = lambda: NOW
assert pr.time.time() == NOW, "the test clock must stay pinned to the fixture"


def card(**kw):
    base = {
        "id": "t_x",
        "title": "a card",
        "body": "SENSITIVE BODY TEXT",
        "result": "SENSITIVE RESULT TEXT",
        "status": "running",
        "assignee": "zenitsu",
        "model_override": None,
        "started_at": int(NOW - 600),
        "completed_at": None,
        "last_failure_error": None,
    }
    base.update(kw)
    return base


def section(tag, body):
    return "@@%s\n%s\n" % (tag, body)


def run(ssh_out):
    """Drive run() with a fake ssh, exactly as the real code path does."""
    class _FakeProc:
        returncode = 0
        stdout = ssh_out
        stderr = ""

    pr.subprocess = type("S", (), {"run": staticmethod(
        lambda *a, **k: _FakeProc())})
    pr.run()


# ---------------------------------------------------------------- fixture
THREE = [
    card(id="t_aaa", title="HUD 01: Kanban tasks on the Linux HUD",
         status="running", assignee="zenitsu", started_at=NOW - 900),
    card(id="t_bbb", title="HUD 01 verify", status="blocked",
         assignee="levi", started_at=NOW - 3600,
         last_failure_error="boom " * 40),
    card(id="t_ccc", title="BRIDGE 01 done", status="done",
         assignee="kakashi", started_at=NOW - 7200, completed_at=NOW - 1800),
]
TOKEN_BODY = json.dumps([{"session_id": "s1", "model": "m",
                          "billing_provider": "openai-codex",
                          "input_tokens": 10, "output_tokens": 5,
                          "last_seen": 1787000000.0}])

# --- 1. parse a fixture of 3 cards -----------------------------------
cards, err = pr.parse_kanban(json.dumps(THREE))
assert err is None, err
assert cards is not None and len(cards) == 3, cards

# --- 2. bodies are dropped -------------------------------------------
for c in cards:
    assert "body" not in c, c
    assert "result" not in c, c
    assert set(c) == set(pr.CARD_KEYS), sorted(c)
blob = json.dumps(cards)
assert "SENSITIVE BODY TEXT" not in blob
assert "SENSITIVE RESULT TEXT" not in blob

# --- field caps -------------------------------------------------------
long_title = card(id="t_long", title="T" * 200)
long_err = card(id="t_longerr", title="ok", last_failure_error="E" * 300)
capped, err = pr.parse_kanban(json.dumps([long_title, long_err]))
assert err is None, err
assert capped is not None
assert len(capped[0]["title"]) == pr.TITLE_MAX, len(capped[0]["title"])
assert len(capped[1]["last_failure_error"]) == pr.ERROR_MAX

# epoch timestamps keep their integer type (no float round-trip on the wire)
assert isinstance(capped[0]["started_at"], int), capped[0]["started_at"]
assert capped[0]["started_at"] == NOW - 600

# a card with no timestamps yields None, not 0 (0 is a fake epoch)
nots, err = pr.parse_kanban(json.dumps([card(id="t_nots", started_at=None,
                                             completed_at=None)]))
assert err is None and nots is not None
assert nots[0]["started_at"] is None, nots[0]
assert nots[0]["completed_at"] is None, nots[0]

# --- 3. the 24 h done filter works ------------------------------------
old_done = card(id="t_old", status="done", completed_at=NOW - 25 * HOUR)
fresh_done = card(id="t_fresh", status="done", completed_at=NOW - 2 * HOUR)
mixed, err = pr.parse_kanban(json.dumps([old_done, fresh_done]), now=NOW)
assert err is None, err
assert mixed is not None
ids = [c["id"] for c in mixed]
assert "t_fresh" in ids, ids
assert "t_old" not in ids, ids
# non-done cards are always kept regardless of age
old_running = card(id="t_run", status="running", started_at=NOW - 90 * HOUR)
kept, err = pr.parse_kanban(json.dumps([old_running]), now=NOW)
assert err is None and kept is not None and [c["id"] for c in kept] == ["t_run"]

# --- 4. a malformed kanban part keeps the old file and sets stale -----
good_out = (section("/x/state.db", TOKEN_BODY)
            + section("kanban", json.dumps(THREE)))
run(good_out)
assert BOARD.exists(), "board file must exist after a good pull"
fresh = json.loads(BOARD.read_text())
assert fresh["cards"] and len(fresh["cards"]) == 3, fresh
assert "stale" not in fresh, fresh
assert fresh["host"] == "mac", fresh
assert fresh["updated"], fresh

previous_bytes = BOARD.read_bytes()

bad_out = (section("/x/state.db", TOKEN_BODY)
           + section("kanban", "{not json at all"))
run(bad_out)
after = json.loads(BOARD.read_text())
assert after.get("stale") is True, after
assert len(after["cards"]) == 3, "the previous cards must be kept: %s" % after

# an absent kanban section is also stale, not a crash
run(section("/x/state.db", TOKEN_BODY))
after2 = json.loads(BOARD.read_text())
assert after2.get("stale") is True, after2
assert len(after2["cards"]) == 3, after2

# with no previous file at all, a bare stale payload is written
BOARD.unlink()
run(bad_out)
bare = json.loads(BOARD.read_text())
assert bare.get("stale") is True, bare
assert bare.get("cards") == [], bare

# --- 5. the token output is byte-identical with and without kanban ----
TOKEN_OUT = section("/x/state.db", TOKEN_BODY)
with_k = TOKEN_OUT + section("kanban", json.dumps(THREE))
without_k = TOKEN_OUT

pr.OUT_DIR = OUT
run(with_k)
tok_with = (OUT / "mac.jsonl").read_bytes()
run(without_k)
tok_without = (OUT / "mac.jsonl").read_bytes()
assert tok_with == tok_without, (tok_with, tok_without)

# and the record lists themselves agree
assert pr.parse(with_k) == pr.parse(without_k)
assert len(pr.parse(with_k)) == 1

# the board file is written by the same call, so it must exist after the
# "without kanban" run too — marked stale, previous cards kept
stale_after = json.loads(BOARD.read_text())
assert stale_after.get("stale") is True, stale_after
assert len(stale_after["cards"]) == 3, stale_after

print("ok")
