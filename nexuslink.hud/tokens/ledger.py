#!/usr/bin/env python3
"""token-ledger — fold local AI-agent token/ACU records into tokens.json.

Sources (read-only; never auth/cookie/config files): omarchy usage snapshots,
opencode.db, devin sessions.db + transcripts, claude jsonl transcripts,
hermes state.db session_model_usage, remote/<host>.jsonl pull snapshots.
Incremental via ledger-cursor.json. Stdlib only.
Usage: python3 ledger.py [--once] [--reset] [-v]   — see SCHEMA.md.
"""
import argparse
import glob
import json
import os
import re
import sqlite3
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote

HOME = Path.home()
STATE_HOME = Path(os.environ.get("XDG_STATE_HOME") or
                  HOME / ".local/state").expanduser()
DATA_HOME = Path(os.environ.get("XDG_DATA_HOME") or
                 HOME / ".local/share").expanduser()
OUT = STATE_HOME / "nexuslink" / "tokens.json"
CURSOR = STATE_HOME / "nexuslink" / "ledger-cursor.json"
HISTORY_DAYS = 90
SEEN_CAP = 20000
SESS_WINDOW_DAYS = 14
SESS_TOP = 10
DENY = ("credentials", "auth.json", "mcp_config", "service.json", "cookie",
        ".vscdb", "mcp-tokens", ".lock", "bus-principals", "secret")
KINDS = {"claude": "sub", "codex": "sub", "fireworks": "api",
         "opencode": "sub", "opencode-go": "sub", "devin": "sub"}
LABELS = {"opencode": "opencode CLI", "opencode-go": "OpenCode Go",
          "devin": "Devin", "claude": "Claude", "codex": "Codex"}
# Output allow-list: the cursor keeps every provider's data — only
# build() output is filtered to these ids (or `<id>@<host>`). haze is
# not in it.
LIVE_PROVIDERS = {"claude", "codex", "devin", "fireworks",
                  "opencode", "opencode-go"}


def _label(p):
    base, _, host = p.partition("@")
    lab = LABELS.get(base, base)
    return "%s (%s)" % (lab, host) if host else lab


# Hermes billing_provider -> ledger id. Omarchy's codex/claude snapshot
# collectors never scan Hermes paths (0 hits grepping for hermes), so folding
# these onto the merged ids cannot double-count the snapshot lane.
# `opencode-go` gets its OWN id, not a fold onto `opencode`: the local
# opencode.db lane (collect_opencode) and the Hermes crew lane are disjoint
# event feeds of the same product — rendered as separate labelled lanes
# (OCG crew / OCG CLI on DP-2), never summed silently.
HERMES_PROVIDER_MAP = {"anthropic": "claude", "openai-codex": "codex",
                       "opencode-go": "opencode-go"}
SID_TS = re.compile(r"^(\d{8})_(\d{6})")          # hermes session_id prefix


def denied(path):
    s = str(path).lower()
    return any(d in s for d in DENY)


def parse_ts(v):
    """ISO string | epoch s/ms/us | 'YYYYMMDD_HHMMSS' -> aware datetime|None."""
    if v is None or isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        if v > 1e14:
            v /= 1e6
        elif v > 1e11:
            v /= 1e3
        try:
            return datetime.fromtimestamp(v, timezone.utc)
        except (OSError, OverflowError, ValueError):
            return None
    if isinstance(v, str):
        s = v.strip()
        m = SID_TS.match(s)
        if m:
            try:
                return datetime.strptime(m.group(0), "%Y%m%d_%H%M%S") \
                    .replace(tzinfo=timezone.utc)
            except ValueError:
                pass
        try:
            dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
            return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
        except ValueError:
            return None
    return None


def day_of(dt):
    return dt.astimezone().strftime("%Y-%m-%d") if dt else None


def num(*vals):
    for v in vals:
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            return v
    return None


class Ledger:
    """Accumulates per-provider per-day rows in the cursor; emits windows."""

    def __init__(self, cur):
        self.cur = cur
        self.days = cur.setdefault("days", {})       # prov -> date -> row
        self.undated = cur.setdefault("undated", {}) # prov -> row
        self.seen = cur.setdefault("seen", {})       # prov -> rid -> [in,out,cost,acu]
        self.meta = {}    # prov -> dict (rebuilt fresh each run)
        self.models = {}  # prov -> model -> {in,out}
        self.sources = {} # prov -> set(str)
        self.top_sessions = []  # session rows, rebuilt fresh each run

    def src(self, prov, path):
        self.sources.setdefault(prov, set()).add(str(path))

    def _row(self, prov, ts):
        day = day_of(ts)
        if day:
            return self.days.setdefault(prov, {}).setdefault(
                day, {"in": 0, "out": 0, "cost": 0.0, "acu": 0.0, "msgs": 0})
        return self.undated.setdefault(
            prov, {"in": 0, "out": 0, "cost": 0.0, "acu": 0.0, "msgs": 0})

    def add(self, prov, rid, ts, tin=0, tout=0, cost=None, acu=0.0,
            model=None, path=None, msgs=0):
        """Dedupe by rid (delta-aware); fold into per-day or undated row."""
        if path:
            self.src(prov, path)
        tin, tout, acu = int(tin or 0), int(tout or 0), float(acu or 0.0)
        cost = float(cost) if isinstance(cost, (int, float)) and \
            not isinstance(cost, bool) else None
        if rid is not None:
            slot = self.seen.setdefault(prov, {})
            prev = slot.get(str(rid))
            cur = [tin, tout, cost or 0.0, acu]
            if prev == cur:
                return
            if prev:  # record mutated (streaming totals) -> add only the delta
                tin, tout = max(0, tin - prev[0]), max(0, tout - prev[1])
                acu = max(0.0, acu - prev[3])
                cost = None if cost is None else max(0.0, cost - prev[2])
            slot[str(rid)] = cur
        if not (tin or tout or cost or acu or msgs):
            return
        row = self._row(prov, ts)
        row["in"] += tin
        row["out"] += tout
        row["cost"] += cost or 0.0
        row["acu"] = row.get("acu", 0.0) + acu
        row["msgs"] = row.get("msgs", 0) + msgs
        if model and (tin or tout):
            m = self.models.setdefault(prov, {}).setdefault(
                str(model), {"in": 0, "out": 0})
            m["in"], m["out"] = m["in"] + tin, m["out"] + tout

    def snap(self, prov, date, total=0, msgs=0):
        """Snapshot-style rollup: overwrite today's `snap`/`msgs` (idempotent)."""
        if not date:
            return
        row = self.days.setdefault(prov, {}).setdefault(
            date, {"in": 0, "out": 0, "cost": 0.0, "acu": 0.0, "msgs": 0})
        if total:
            row["snap"] = int(total)  # authoritative rollup, NOT summed w/ in/out
        row["msgs"] = max(row.get("msgs", 0), int(msgs or 0))


# ---------- collectors ------------------------------------------------------

def collect_omarchy(led):
    d = STATE_HOME / "omarchy" / "agents" / "usage"
    for f in sorted(d.glob("*.json")) if d.is_dir() else []:
        try:
            j = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        prov = str(j.get("id") or f.stem)
        led.src(prov, f)
        m = led.meta.setdefault(prov, {})
        m.update(label=j.get("name"), ready=j.get("ready"),
                 tier=j.get("tierLabel") or None,
                 status=j.get("usageStatusText") or None,
                 today_tokens=j.get("todayTotalTokens") or 0,
                 today_prompts=j.get("todayPrompts") or 0,
                 today_sessions=j.get("todaySessions") or 0,
                 limits=j.get("limits") or [])
        if j.get("todayTokensByModel"):
            m["today_by_model"] = j["todayTokensByModel"]
        ts = parse_ts(j.get("updatedAt"))
        led.snap(prov, day_of(ts) or datetime.now().strftime("%Y-%m-%d"),
                 total=j.get("todayTotalTokens") or 0,
                 msgs=j.get("todayPrompts") or 0)
        for r in j.get("recentDays") or []:
            if isinstance(r, dict) and r.get("date"):
                led.snap(prov, str(r["date"]), msgs=r.get("messageCount"))


def _ro_db(path):
    if not path.is_file() or denied(path):
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


def _json(v):
    try:
        return json.loads(v) if isinstance(v, (str, bytes)) else v
    except ValueError:
        return None


def collect_opencode(led):
    con = _ro_db(DATA_HOME / "opencode" / "opencode.db")
    if not con:
        return
    try:
        tabs, db = _tables(con), DATA_HOME / "opencode" / "opencode.db"
        c = led.cur.setdefault("sqlite", {}).setdefault("opencode", {"mark": 0})
        if "message" in tabs:
            # assistant rows carry per-call tokens{in,out,reasoning,cache}+cost
            q = ("SELECT id, time_updated, data FROM message "
                 "WHERE time_updated > ? ORDER BY time_updated LIMIT 50000")
            try:
                rows = con.execute(q, (c["mark"],)).fetchall()
            except sqlite3.Error:
                rows = []
            for rid, tupd, data in rows:
                c["mark"] = max(c["mark"], tupd or 0)
                d = _json(data) or {}
                if d.get("role") != "assistant":
                    continue
                u = d.get("tokens") or d.get("usage") or {}
                cache = u.get("cache") or {}
                model = d.get("modelID") or d.get("model")
                if isinstance(model, dict):
                    model = model.get("modelID") or model.get("id")
                tin = (num(u.get("input"), u.get("input_tokens")) or 0) + \
                      (cache.get("read") or 0) + (cache.get("write") or 0)
                tout = (num(u.get("output"), u.get("output_tokens")) or 0) + \
                       (u.get("reasoning") or 0)
                led.add("opencode", "oc:" + str(rid), parse_ts(tupd), tin, tout,
                        num(d.get("cost"), d.get("cost_usd")), model=model,
                        path=db, msgs=1)
        elif "session" in tabs:
            # fallback: session-level aggregates on the creation day
            cols = {r[1] for r in con.execute("PRAGMA table_info(session)")}
            want = [x for x in ("id", "time_created", "time_updated", "cost",
                                "tokens_input", "tokens_output",
                                "tokens_reasoning", "tokens_cache_read",
                                "tokens_cache_write") if x in cols]
            if "id" in want:
                for row in con.execute("SELECT %s FROM session" % ",".join(want)):
                    r = dict(zip(want, row))
                    tin = (r.get("tokens_input") or 0) + \
                          (r.get("tokens_cache_read") or 0) + \
                          (r.get("tokens_cache_write") or 0)
                    tout = (r.get("tokens_output") or 0) + \
                           (r.get("tokens_reasoning") or 0)
                    led.add("opencode", "ocs:" + str(r["id"]),
                            parse_ts(r.get("time_updated") or
                                     r.get("time_created")),
                            tin, tout, r.get("cost"), path=db, msgs=1)
    finally:
        con.close()


def _metrics(obj):
    """(in,out,acu,model) from a devin chat_message / transcript-step dict."""
    meta = (obj or {}).get("metadata") or {}
    met = meta.get("metrics") or meta.get("usage") or {}
    tin = num(met.get("input_tokens"), met.get("prompt_tokens"),
              met.get("input"), met.get("tokens_in"),
              met.get("cached_input_tokens"), met.get("cache_read_tokens")) or 0
    tout = num(met.get("output_tokens"), met.get("completion_tokens"),
               met.get("output"), met.get("tokens_out"),
               met.get("reasoning_tokens")) or 0
    acu = num(meta.get("committed_acu_cost"), met.get("committed_acu_cost"),
              met.get("acu_cost"), met.get("acu")) or 0.0
    return tin, tout, acu, meta.get("generation_model") or met.get("model")


def collect_devin(led):
    db = HOME / ".local/share/devin/cli/sessions.db"
    con = _ro_db(db)
    if con:
        try:
            if "message_nodes" in _tables(con):
                c = led.cur.setdefault("sqlite", {}).setdefault(
                    "devin", {"mark": 0})
                q = ("SELECT row_id, session_id, chat_message, created_at "
                     "FROM message_nodes WHERE row_id > ? ORDER BY row_id "
                     "LIMIT 100000")
                try:
                    rows = con.execute(q, (c["mark"],)).fetchall()
                except sqlite3.Error:
                    rows = []
                for rid, sid, blob, created in rows:
                    c["mark"] = max(c["mark"], rid or 0)
                    tin, tout, acu, model = _metrics(_json(blob))
                    led.add("devin", "dv:%s:%s" % (sid, rid), parse_ts(created),
                            tin, tout, None, acu=acu, model=model, path=db)
            elif "sessions" in _tables(con):
                led.meta.setdefault("devin", {})["sessions_db"] = "present"
        finally:
            con.close()
    tdir = HOME / ".local/share/devin/cli/transcripts"
    for f in sorted(tdir.glob("*.json")) if tdir.is_dir() else []:
        if denied(f):
            continue
        try:
            j = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        for i, step in enumerate(j.get("steps") or []):
            tin, tout, acu, model = _metrics(step)
            ts = parse_ts((step or {}).get("timestamp") or
                          (step or {}).get("created_at") or j.get("created_at"))
            led.add("devin", "dvt:%s:%d" % (f.stem, i), ts, tin, tout, None,
                    acu=acu, model=model, path=f)


def _jsonl_tail(path, offsets):
    """New complete lines past the stored byte offset; advances the offset."""
    try:
        size = path.stat().st_size
        off = offsets.get(str(path), 0)
        if size < off:
            off = 0
        with open(path, "rb") as fh:
            fh.seek(off)
            buf = fh.read()
    except OSError:
        return
    cut = buf.rfind(b"\n")
    offsets[str(path)] = off + (cut + 1 if cut >= 0 else 0)
    for line in buf[:cut + 1].split(b"\n"):
        line = line.strip()
        if line:
            yield line


def collect_claude(led):
    offs = led.cur.setdefault("files", {})
    files = [Path(p) for r in (HOME / ".claude/projects", DATA_HOME / "claude")
             for p in glob.glob(str(r / "**" / "*.jsonl"), recursive=True)]
    for f in files:
        if denied(f):
            continue
        for line in _jsonl_tail(f, offs):
            j = _json(line)
            if not isinstance(j, dict):
                continue
            msg, u = j.get("message") or {}, \
                     (j.get("message") or {}).get("usage") or j.get("usage") or {}
            if not u:
                continue
            tin = (u.get("input_tokens") or 0) + \
                  (u.get("cache_read_input_tokens") or 0) + \
                  (u.get("cache_creation_input_tokens") or 0)
            rid = j.get("uuid") or msg.get("id") or j.get("requestId") or \
                hash(line)
            led.add("claude", "cl:" + str(rid), parse_ts(j.get("timestamp")),
                    tin, u.get("output_tokens") or 0, None,
                    model=msg.get("model") or j.get("model"), path=f, msgs=1)


def _smu_fold(led, profile, db, row, suffix=""):
    """Fold one session_model_usage row; returns its last_seen (float).

    Row -> mapped ledger id via HERMES_PROVIDER_MAP (`suffix` = `@<host>`
    for remote-pulled rows). Rid-dedup in Ledger.add makes re-reading a
    row harmless, so backfill passes and the incremental scan may overlap
    freely — only unrecorded tuples accrue."""
    (sid, model, prov, base, mode, task, tin_, tout_, rd_, wr_,
     cost, cstat, seen) = row
    p = HERMES_PROVIDER_MAP.get(str(prov))
    if p:
        if not isinstance(cost, (int, float)) or cost <= 0 or \
                str(cstat) in ("unknown", "included"):
            cost = None
        # in = input+cache_read+cache_write (SCHEMA: cache is prompt-side);
        # out = output_tokens only (Anthropic/Responses already contain
        # reasoning in it — adding reasoning_tokens would double count).
        # No msgs=: Ledger.add deltas tin/tout/cost/acu but not msgs.
        rid = "hm:%s:%s:%s:%s:%s:%s:%s" % (
            profile, sid, model, prov, base or "-", mode or "-",
            task or "-")
        led.add(p + suffix, rid, parse_ts(seen),
                tin=(tin_ or 0) + (rd_ or 0) + (wr_ or 0),
                tout=tout_ or 0, cost=cost, model=model, path=db)
    return float(seen or 0)


def collect_hermes(led):
    """Hermes state.db -> claude/codex event rows (read-only).

    Source: `~/.hermes/state.db` (default profile) and `~/.hermes/profiles/*/
    state.db`, table `session_model_usage`: one CUMULATIVE row per
    (session_id, model, billing_provider, billing_base_url, billing_mode,
    task) — the table `hermes insights` reads. Omarchy's codex/claude
    snapshots never scan Hermes paths, so `anthropic`->claude and
    `openai-codex`->codex add a second, disjoint traffic lane: day.in/out
    then counts Hermes events while snapshot `total` counts Codex-CLI /
    Claude-Code events (never sum the two, SCHEMA.md rule for `total`).
    `opencode-go` rows land on their own ledger id (the Hermes crew lane
    — disjoint from the local opencode.db `opencode` lane, both rendered
    as labelled lanes on DP-2). `nous`/`ollama-cloud` rows are still
    skipped (no ledger id; folding them is a product decision). Haze
    usage rollups are no longer ingested.

    Provider-map migration (cursor v2): each store records which
    billing_providers it has folded under `sqlite.hermes.__folded__`.
    Rows for a provider that joined the map after this store's mark already
    advanced were scanned past without folding — the version-1 cursor that
    predates `opencode-go` is exactly that case — so a newly mapped provider
    gets a one-time backfill of its OWN rows (`billing_provider IN (new)`),
    while already-mapped providers keep their normal incremental mark.
    Rid-dedup guarantees the two passes never double-count.
    """
    marks = led.cur.setdefault("sqlite", {}).setdefault("hermes", {})
    folded = marks.setdefault("__folded__", {})
    stores = [(HOME / ".hermes/state.db", "default")]
    pdir = HOME / ".hermes/profiles"
    stores += [(p, p.parent.name)
               for p in sorted(pdir.glob("*/state.db"))] if pdir.is_dir() else []
    for db, profile in stores:
        con = _ro_db(db)          # file:...?mode=ro + PRAGMA query_only (no writes)
        if not con:
            continue
        try:
            if "session_model_usage" not in _tables(con):
                continue
            mark = float(marks.get(str(db)) or 0)
            hi = mark
            done = set(folded.get(str(db)) or [])
            new = sorted(set(HERMES_PROVIDER_MAP) - done)
            # Register the store under both ids when it holds ANY mapped
            # provider row, so tokens.json `sources` stays stable across warm
            # cursor passes (a delta of zero must not erase the declared feed).
            if con.execute("SELECT 1 FROM session_model_usage WHERE"
                           " billing_provider IN (%s) LIMIT 1"
                           % ",".join("?" * len(HERMES_PROVIDER_MAP)),
                           tuple(HERMES_PROVIDER_MAP)).fetchone():
                for led_id in set(HERMES_PROVIDER_MAP.values()):
                    led.src(led_id, db)
            cols = ("session_id, model, billing_provider, billing_base_url,"
                    " billing_mode, task, input_tokens, output_tokens,"
                    " cache_read_tokens, cache_write_tokens,"
                    " estimated_cost_usd, cost_status, last_seen")
            if new and mark > 0:
                # Backfill only the newly-mapped providers' rows — a full
                # rescan is avoided on purpose: rows already in `seen` are
                # deduped anyway, but skipping them keeps the pass bounded
                # even if `seen` was pruned at SEEN_CAP.
                qb = ("SELECT %s FROM session_model_usage"
                      " WHERE billing_provider IN (%s)"
                      % (cols, ",".join("?" * len(new))))
                try:
                    for row in con.execute(qb, tuple(new)):
                        _smu_fold(led, profile, db, row)
                    done.update(new)
                except sqlite3.Error:
                    pass      # stays unfolded -> retried on the next pass
            elif mark == 0:
                done.update(HERMES_PROVIDER_MAP)   # full scan below covers all
            # No index on last_seen, but the table is ~5k rows (the 3 GB of the
            # db lives in messages/FTS), so the filtered scan is milliseconds.
            q = ("SELECT %s FROM session_model_usage"
                 " WHERE last_seen > ? ORDER BY last_seen LIMIT 50000" % cols)
            for row in con.execute(q, (mark,)):
                hi = max(hi, _smu_fold(led, profile, db, row))
            marks[str(db)] = hi   # cursor: next pass reads only rows touched since
            folded[str(db)] = sorted(done)
        finally:
            con.close()


def collect_remote(led):
    """remote/<host>.jsonl pull snapshots -> `<base-prov>@<host>` lanes.

    Each file is a full snapshot of one host's session_model_usage rows
    (written by pull_remote.py over ssh); rid-dedup makes re-feeding it
    harmless. `profile` becomes `<host>:<profile>` inside the rid —
    cross-host rids cannot collide; the provider id gains `@<host>`."""
    rdir = STATE_HOME / "nexuslink" / "remote"
    for path in sorted(rdir.glob("*.jsonl")) if rdir.is_dir() else []:
        suffix = "@" + path.stem
        try:
            fh = open(path)
        except OSError:
            continue
        with fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(rec, dict):
                    continue
                row = tuple(rec.get(k) for k in (
                    "session_id", "model", "billing_provider",
                    "billing_base_url", "billing_mode", "task",
                    "input_tokens", "output_tokens", "cache_read_tokens",
                    "cache_write_tokens", "estimated_cost_usd",
                    "cost_status", "last_seen"))
                _smu_fold(led, "%s:%s" % (path.stem,
                                          rec.get("profile") or "default"),
                          path, row, suffix)


def collect_sessions(led):
    """Hermes `sessions` table -> led.top_sessions (top-N by tokens, 14 days).

    The DP-2 SES-05 table's source: one row per session with bot, provider,
    model, title, in/out tokens, api calls and last-seen. Unlike
    collect_hermes this reads `sessions` (per-session rollup), not
    `session_model_usage`, keeps EVERY billing_provider (opencode-go and
    nous included — attribution, not ledger folding) and is rebuilt fresh
    each run: a top-10 ranking needs no cursor.
    """
    cutoff = datetime.now(timezone.utc).timestamp() - SESS_WINDOW_DAYS * 86400
    stores = [(HOME / ".hermes/state.db", "default")]
    pdir = HOME / ".hermes/profiles"
    stores += [(p, p.parent.name)
               for p in sorted(pdir.glob("*/state.db"))] if pdir.is_dir() else []
    for db, profile in stores:
        con = _ro_db(db)
        if not con:
            continue
        try:
            if "sessions" not in _tables(con):
                continue
            cols = {r[1] for r in con.execute("PRAGMA table_info(sessions)")}
            if not {"id", "model", "billing_provider", "started_at",
                    "ended_at", "last_activity_at", "title", "api_call_count",
                    "input_tokens", "output_tokens", "cache_read_tokens",
                    "cache_write_tokens", "archived", "hidden"} <= cols:
                continue
            q = ("SELECT id, model, billing_provider, started_at,"
                 " COALESCE(last_activity_at, ended_at, started_at), title,"
                 " api_call_count,"
                 " input_tokens + cache_read_tokens + cache_write_tokens,"
                 " output_tokens FROM sessions"
                 " WHERE archived = 0 AND hidden = 0"
                 " AND COALESCE(last_activity_at, ended_at, started_at) >= ?")
            for (sid, model, prov, start, last, title, calls, tin, tout) \
                    in con.execute(q, (cutoff,)):
                if not (tin or tout) or prov == "haze":
                    continue
                led.top_sessions.append({
                    "id": sid, "bot": profile, "provider": prov,
                    "model": model, "title": title,
                    "in": int(tin or 0), "out": int(tout or 0),
                    "tokens": int((tin or 0) + (tout or 0)),
                    "calls": int(calls or 0),
                    "start": float(start or 0), "last": float(last or 0)})
        except sqlite3.Error:
            pass               # one bad store must not sink the pass
        finally:
            con.close()


# ---------- output ------------------------------------------------------------

def _bucket(rows, lo, hi):
    b = {"in": 0, "out": 0, "cost": None}
    cost, acu, msgs, snap = 0.0, 0.0, 0, 0
    for d, r in rows.items():
        if lo <= d <= hi:
            b["in"] += r["in"]
            b["out"] += r["out"]
            cost += r.get("cost") or 0.0
            acu += r.get("acu") or 0.0
            msgs += r.get("msgs") or 0
            snap += r.get("snap") or 0
    if cost:
        b["cost"] = round(cost, 6)
    if acu:
        b["acu"] = round(acu, 4)
    if msgs:
        b["msgs"] = msgs
    if snap:
        b["total"] = snap  # snapshot-rollup total (may overlap in/out — see SCHEMA)
    return b


def build(led, now):
    today = now.astimezone().date()
    t_s = today.isoformat()
    w_s = (today - timedelta(days=today.weekday())).isoformat()  # ISO Mon start
    m_s = today.replace(day=1).isoformat()
    provs = {p for p in (set(led.days) | set(led.undated) | set(led.meta))
             if p.split("@")[0] in LIVE_PROVIDERS}
    out_p, hist, srcs = {}, {}, {}
    for p in sorted(provs):
        days, meta = led.days.get(p, {}), led.meta.get(p) or {}
        has_events = any(r["in"] or r["out"] or r.get("cost") or r.get("acu")
                         for r in days.values()) or bool(led.undated.get(p))
        entry = {"label": meta.get("label") or _label(p),
                 "kind": KINDS.get(p.split("@")[0], "api"),
                 "day": _bucket(days, t_s, t_s),
                 "week": _bucket(days, w_s, t_s),
                 "month": _bucket(days, m_s, t_s)}
        if not has_events and days:  # snapshot-only provider
            for b in (entry["day"], entry["week"], entry["month"]):
                b["in"] = b["out"] = None  # only the rollup `total` is real
        if led.undated.get(p):
            entry["undated"] = {k: v for k, v in led.undated[p].items() if v}
        m = {"label": entry["label"], "kind": entry["kind"]}
        for k in ("ready", "tier", "status", "today_tokens", "today_prompts",
                  "today_sessions", "limits", "today_by_model", "sessions_db"):
            if meta.get(k) not in (None, "", [], {}):
                m[k] = meta[k]
        if meta.get("upstreams"):
            m["upstreams"] = sorted(meta["upstreams"])
        if led.models.get(p):
            m["models"] = dict(sorted(led.models[p].items()))
        entry["meta"] = m
        out_p[p] = entry
        rows = []
        for d in sorted(days):
            r = days[d]
            row = {"d": d, "in": r["in"], "out": r["out"],
                   "cost": round(r["cost"], 6) if r.get("cost") else None}
            for k in ("acu", "msgs", "snap"):
                if r.get(k):
                    row[k if k != "snap" else "total"] = r[k]
            if r.get("snap") and not (r["in"] or r["out"]):
                row["in"] = row["out"] = None  # rollup-only day
            rows.append(row)
        hist[p] = rows[-HISTORY_DAYS:]
        if led.sources.get(p):
            srcs[p] = sorted(led.sources[p])
    sess = sorted(led.top_sessions,
                  key=lambda s: -s["tokens"])[:SESS_TOP]
    return {"updated": now.isoformat(timespec="seconds"),
            "generator": "token-ledger/1",
            "providers": out_p, "history": hist, "sources": srcs,
            "sessions": sess}


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
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--once", action="store_true", default=True,
                    help="single aggregation pass (default; kept for cron use)")
    ap.add_argument("--reset", action="store_true",
                    help="drop cursor + rebuild all sources from scratch")
    ap.add_argument("--verbose", "-v", action="store_true")
    a = ap.parse_args()
    cur = {}
    if not a.reset and CURSOR.is_file():
        try:
            cur = json.loads(CURSOR.read_text())
        except (OSError, ValueError):
            cur = {}
    led = Ledger(cur if isinstance(cur, dict) else {})
    for fn in (collect_omarchy, collect_opencode, collect_devin,
               collect_claude, collect_hermes, collect_remote,
               collect_sessions):
        try:
            fn(led)
        except Exception as e:  # a bad source must not sink the pass
            print("warn: %s failed: %s" % (fn.__name__, e), file=sys.stderr)
    now = datetime.now(timezone.utc)
    out = build(led, now)
    for p, seen in led.seen.items():  # bound cursor growth
        if len(seen) > SEEN_CAP:
            led.seen[p] = dict(list(seen.items())[-SEEN_CAP // 2:])
    try:
        atomic_write(OUT, out)
        # led.cur is the dict LOADED from the cursor, so it carries the stale
        # version/saved keys; spread first, then overwrite them, else `saved`
        # freezes at whatever the first-ever run wrote.
        atomic_write(CURSOR, {**led.cur, "version": 2,
                              "saved": now.isoformat(timespec="seconds")})
    except OSError as e:
        print("error: %s" % e, file=sys.stderr)
        return 1
    if a.verbose:
        for p, e in out["providers"].items():
            print("%-10s day=%s" % (p, e.get("day")))
        print("-> %s (%d providers)" % (OUT, len(out["providers"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
