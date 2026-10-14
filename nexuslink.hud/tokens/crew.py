#!/usr/bin/env python3
"""crew-feed — fold Hermes session stores into crew.json (M1 DP-1).

Sources (read-only sqlite, file:...?mode=ro + PRAGMA query_only):
  ~/.hermes/state.db                    -> bot "default"
  ~/.hermes/profiles/<name>/state.db    -> bot <name>
Model/provider come from each profile's config.yaml `model:` block
(simple line parse — no yaml lib). Profiles with a config but no state.db
still appear (dormant, last_active null). Atomic write to
$XDG_STATE_HOME/nexuslink/crew.json. Stdlib only; target < 1 s.
Schema: docs/m1/CONTRACT.md. Usage: python3 crew.py
"""
import json
import os
import sqlite3
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import quote

HOME = Path.home()
STATE_HOME = Path(os.environ.get("XDG_STATE_HOME") or
                  HOME / ".local/state").expanduser()
OUT = STATE_HOME / "nexuslink" / "crew.json"
HERMES = HOME / ".hermes"
PROFILES = HERMES / "profiles"

ACTIVE_S, WARM_S, IDLE_S = 120, 1800, 86400   # state thresholds, seconds
EVENT_CAP = 60                                 # per-bot event rows

WHERE = "archived = 0 AND hidden = 0"
LAST = "COALESCE(last_activity_at, ended_at, started_at)"
TOK_SUM = "input_tokens + cache_read_tokens + cache_write_tokens + output_tokens"


def denied(path):
    s = str(path).lower()
    return any(d in s for d in ("credentials", "auth.json", "cookie",
                                ".lock", "secret"))


def _ro_db(path):
    if path is None or not path.is_file() or denied(path):
        return None
    try:
        con = sqlite3.connect("file:%s?mode=ro" % quote(str(path)), uri=True)
        con.execute("PRAGMA query_only=ON")
        return con
    except sqlite3.Error:
        return None


def _tables(con):
    try:
        return {r[0] for r in con.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")}
    except sqlite3.Error:
        return set()


def model_block(cfg):
    """config.yaml `model:` block -> (default_model, provider). Line parse."""
    if cfg is None or not cfg.is_file() or denied(cfg):
        return None, None
    try:
        lines = cfg.read_text(errors="replace").splitlines()
    except OSError:
        return None, None
    in_model, base, model, provider = False, None, None, None
    for ln in lines:
        stripped = ln.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(ln) - len(ln.lstrip())
        if indent == 0:
            in_model = stripped == "model:" or stripped.startswith("model: ")
            base = None
            continue
        if in_model:
            if base is None:
                base = indent          # first key level under model:
            if indent != base:
                continue               # nested maps (aliases, default_headers)
            k, _, v = stripped.partition(":")
            k, v = k.strip(), v.strip().strip('"').strip("'")
            if k == "default":
                model = v or model
            elif k == "provider":
                provider = v or provider
    return model, provider


def stores():
    """(db_path|None, bot_name, config_path) for every known profile."""
    out = [(HERMES / "state.db", "default", HERMES / "config.yaml")]
    if PROFILES.is_dir():
        have_db = set()
        for p in sorted(PROFILES.glob("*/state.db")):
            have_db.add(p.parent.name)
            out.append((p, p.parent.name, p.parent / "config.yaml"))
        for d in sorted(PROFILES.iterdir()):
            if (d.is_dir() and d.name not in have_db
                    and (d / "config.yaml").is_file()):
                out.append((None, d.name, d / "config.yaml"))
    return out


def scan_store(db, name, cfg, cutoff, now):
    model, provider = model_block(cfg)
    bot = {"name": name, "model": model, "provider": provider,
           "state": "dormant", "last_active": None,
           "sessions_24h": 0, "calls_24h": 0, "tokens_24h": 0,
           "current_title": None, "events": []}
    con = _ro_db(db)
    if con is None:
        return bot
    try:
        if "sessions" not in _tables(con):
            return bot
        cols = {r[1] for r in con.execute("PRAGMA table_info(sessions)")}
        need = {"started_at", "ended_at", "last_activity_at", "title",
                "api_call_count", "input_tokens", "output_tokens",
                "cache_read_tokens", "cache_write_tokens",
                "archived", "hidden"}
        if not need <= cols:
            return bot
        last = con.execute(
            "SELECT MAX(%s) FROM sessions WHERE %s" % (LAST, WHERE)).fetchone()
        if last and last[0] is not None:
            bot["last_active"] = float(last[0])
        current_model = "model" if "model" in cols else "NULL"
        current_provider = "billing_provider" if "billing_provider" in cols else "NULL"
        cur = con.execute(
            "SELECT title, %s, %s FROM sessions WHERE %s "
            "ORDER BY %s DESC LIMIT 1"
            % (current_model, current_provider, WHERE, LAST)).fetchone()
        if cur:
            bot["current_title"] = cur[0]
            bot["model"] = cur[1] or model
            bot["provider"] = cur[2] or provider
        n24, c24, t24 = con.execute(
            "SELECT COUNT(*), COALESCE(SUM(api_call_count),0),"
            " COALESCE(SUM(%s),0) FROM sessions"
            " WHERE %s AND started_at >= ?" % (TOK_SUM, WHERE),
            (cutoff,)).fetchone()
        bot["sessions_24h"] = int(n24 or 0)
        bot["calls_24h"] = int(c24 or 0)
        bot["tokens_24h"] = int(t24 or 0)
        # sessions whose [start, end|now] interval overlaps the window
        rows = con.execute(
            "SELECT started_at, ended_at, title FROM sessions"
            " WHERE %s AND started_at <= ?"
            " AND COALESCE(ended_at, last_activity_at, started_at) >= ?"
            " ORDER BY started_at DESC LIMIT %d" % (WHERE, EVENT_CAP),
            (now, cutoff)).fetchall()
        bot["events"] = [[float(s), float(e) if e is not None else None,
                          t or ""] for s, e, t in rows]
    except sqlite3.Error:
        return bot
    finally:
        con.close()
    la = bot["last_active"]
    if la is not None:
        age = now - la
        bot["state"] = ("active" if age <= ACTIVE_S else
                        "warm" if age <= WARM_S else
                        "idle" if age <= IDLE_S else "dormant")
    return bot


def atomic_write(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(obj, fh, separators=(",", ":"))
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main():
    now = time.time()
    cutoff = now - IDLE_S
    bots = [scan_store(db, name, cfg, cutoff, now)
            for db, name, cfg in stores()]
    totals = {"bots": len(bots),
              "active": sum(1 for b in bots if b["state"] == "active"),
              "warm": sum(1 for b in bots if b["state"] == "warm"),
              "idle": sum(1 for b in bots if b["state"] == "idle"),
              "dormant": sum(1 for b in bots if b["state"] == "dormant"),
              "sessions_24h": sum(b["sessions_24h"] for b in bots),
              "calls_24h": sum(b["calls_24h"] for b in bots),
              "tokens_24h": sum(b["tokens_24h"] for b in bots)}
    try:
        atomic_write(OUT, {"generated": int(now), "bots": bots,
                           "totals": totals})
    except OSError as e:
        print("error: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
