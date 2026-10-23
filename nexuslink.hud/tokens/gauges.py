#!/usr/bin/env python3
"""gauges - one collector for every usage gauge, one contract per gauge.

Writes $XDG_RUNTIME_DIR/gauges/<name>.json (atomic) on change and at least
every ttl, plus collector.json as the heartbeat. Each gauge file:

  name, label, source, exact, ttl, fetchedAt (source timestamp of the data),
  state fresh|stale|error, error (reason or null), missing (not measurable),
  windows [{label, value, limit, unit, resetsAt, exact, note}], writtenAt.

On error, windows is empty and lastGood is kept for reference only; the
renderer never shows lastGood as the current number.

Usage: gauges.py run            (long-running; systemd restarts it)
       gauges.py show [--json]  (render every gauge with age and state)
"""
import importlib.machinery, importlib.util, json, os, re, sqlite3, subprocess, sys, tempfile, time
from datetime import datetime, timezone
from pathlib import Path

HOME = Path.home()
RUN = Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}") / "gauges"
TOKENS = Path(__file__).resolve().parent
TICK = 5                     # scheduler wake-up, seconds (idle cost only)
HEARTBEAT_S = 30             # collector.json rewrite cadence
CLAUDE_REFRESH_S = 900       # at most one `claude auth status` refresh per 15 min
ERROR_RETRY_S = 60           # a failed fetch is retried this soon


class GaugeError(Exception):
    pass


def iso(ts):
    return datetime.fromtimestamp(ts, timezone.utc).isoformat(timespec="seconds") if ts else None


def atomic_write(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix="." + path.name + ".")
    with os.fdopen(fd, "w") as fh:
        json.dump(obj, fh, indent=1)
    os.replace(tmp, path)


def win(label, value, limit=100, unit="%", resets=None, exact=True, note=""):
    return {"label": label, "value": value, "limit": limit, "unit": unit,
            "resetsAt": resets, "exact": exact, "note": note}


# ---------------------------------------------------------------- Claude
_omarchy = None


def omarchy_claude():
    """Reuse Omarchy's own collector module for the auth read and the probe."""
    global _omarchy
    if _omarchy is None:
        spec = importlib.util.spec_from_loader("omarchy_claude", importlib.machinery.SourceFileLoader(
            "omarchy_claude", "/usr/sbin/omarchy-agent-usage-claude"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)          # main() is behind __main__: no side effects
        _omarchy = mod
    return _omarchy


def refresh_claude_signin():
    """The Claude CLI is the only thing that refreshes the saved OAuth token.
    Run it once in a clean env (not the Hermes setup-token), rate limited."""
    stamp = RUN / ".claude-refresh"
    if stamp.exists() and time.time() - stamp.stat().st_mtime < CLAUDE_REFRESH_S:
        return False
    stamp.parent.mkdir(parents=True, exist_ok=True)
    stamp.touch()
    env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CODE_OAUTH_TOKEN"}
    exe = str(HOME / ".local/bin/claude")
    try:
        subprocess.run([exe, "auth", "status"], env=env, timeout=60, capture_output=True)
    except (OSError, subprocess.SubprocessError):
        return False
    return True


def fetch_claude():
    mod = omarchy_claude()
    cfg = Path(os.environ.get("CLAUDE_CONFIG_DIR") or HOME / ".claude")
    try:
        tok, exp_ms, _plan = mod.oauth_login(cfg)
    except Exception as e:
        raise GaugeError(f"no Claude sign-in readable ({type(e).__name__})")
    if not tok:
        raise GaugeError("no Claude sign-in: run `claude auth login`")
    if exp_ms and exp_ms <= time.time() * 1000:
        refresh_claude_signin()
        tok, exp_ms, _plan = mod.oauth_login(cfg)
        if exp_ms and exp_ms <= time.time() * 1000:
            raise GaugeError("saved sign-in expired; run `claude` once in a terminal to refresh it")
    probe = mod.probe_limits(tok)
    if not probe.get("ok"):
        raise GaugeError(probe.get("helpText") or "usage endpoint failed")
    wins = [win(l["label"], round(float(l["percent"]), 2), resets=l.get("resetsAt") or None)
            for l in probe["limits"]]
    return wins, None


# ---------------------------------------------------------------- Devin
class _Led:
    def __init__(self):
        self.meta = {}


def fetch_devin():
    sys.path.insert(0, str(TOKENS))
    import ledger                                   # reuse the cache decoder
    led = _Led()
    ledger.merge_devin_limits(led)
    m = led.meta.get("devin") or {}
    lim = m.get("limits") or []
    if not lim:
        raise GaugeError("no decodable Devin quota cache: run `devin` once")
    files = sorted(ledger.DEVIN_CACHE.glob("user_status.*.bin"), key=lambda f: -f.stat().st_mtime)
    src_ts = files[0].stat().st_mtime if files else None   # the data's own age
    wins = [win(l["label"], round(l["percent"] * 100, 2), resets=l.get("resetsAt")) for l in lim]
    # Source refresh is the devin-gauge timer; start it early when the cache ages out.
    if src_ts and time.time() - src_ts > 1500:
        subprocess.run(["systemctl", "--user", "start", "--no-block", "devin-gauge.service"],
                       capture_output=True, timeout=20)
    return wins, src_ts


# ---------------------------------------------------------------- OpenCode Go
GO_LOG = HOME / ".hermes/logs/agent.log"
GO_DB = HOME / ".hermes/state.db"
HIT_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*GoUsageLimitError.*?limitName': '(\w+)'")


def fetch_opencode_go():
    last_hit, limit_name = 0.0, ""
    if GO_LOG.exists():
        with open(GO_LOG, "rb") as fh:
            fh.seek(max(0, GO_LOG.stat().st_size - 4_000_000))
            for line in fh.read().decode("utf-8", "replace").splitlines():
                m = HIT_RE.match(line)
                if m:
                    last_hit = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").timestamp()
                    limit_name = m.group(2)
    last_ok, week_tokens = 0.0, 0
    if GO_DB.exists():
        con = sqlite3.connect(f"file:{GO_DB}?mode=ro", uri=True, timeout=2)
        try:
            row = con.execute("select max(last_seen) from session_model_usage where billing_provider='opencode-go'").fetchone()
            last_ok = float(row[0] or 0)
            week_cut = time.time() - 7 * 86400
            row = con.execute("select coalesce(sum(input_tokens+output_tokens),0) from session_model_usage "
                              "where billing_provider='opencode-go' and last_seen>?", (week_cut,)).fetchone()
            week_tokens = int(row[0] or 0)
        finally:
            con.close()
    wins = []
    if last_hit and last_hit > last_ok:
        note = (f"capped: 429 limitName={limit_name} at {iso(last_hit)}, "
                f"last successful call {iso(last_ok) or 'none'}; reset time not exposed")
        wins.append(win("Weekly", 100, resets=None, exact=True, note=note))
    else:
        wins.append(win("Weekly", None, exact=False,
                        note="no cap hit after last success; percent not exposed by OpenCode Go"))
    wins.append(win("Local tokens 7d", week_tokens, limit=None, unit="tokens", exact=True,
                    note="input+output from Hermes state.db; no limit known to convert to %"))
    return wins, None          # scan time is the fetch time: the facts are read now


# ---------------------------------------------------------------- VRAM
def fetch_vram():
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=memory.used,memory.total,utilization.gpu",
                              "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        raise GaugeError("nvidia-smi not runnable")
    if out.returncode != 0 or not out.stdout.strip():
        raise GaugeError(f"nvidia-smi exit {out.returncode}")
    used, total, util = (float(x) for x in out.stdout.strip().splitlines()[0].split(","))
    note = f"{int(used)}/{int(total)} MiB"
    return [win("VRAM", round(100 * used / total, 1), note=note),
            win("GPU util", round(util, 1))], None


GAUGES = [
    # name, label, source, ttl (s), fetch, exact, missing
    ("claude", "Claude Code", "Anthropic OAuth usage endpoint (5h session, 7d weekly)", 300, fetch_claude, True, []),
    ("devin", "Devin", "Devin CLI cached GetUserStatus (~/.cache/devin/cli)", 1800, fetch_devin, True, []),
    ("opencode-go", "OpenCode Go", "Hermes agent.log 429 limitName + state.db", 300, fetch_opencode_go, False,
     ["5h window", "monthly window"]),
    ("vram", "GPU VRAM", "nvidia-smi", 30, fetch_vram, True, []),
]
class Gauge:
    def __init__(self, name, label, source, ttl, fetch, exact, missing):
        self.name, self.label, self.source, self.ttl = name, label, source, ttl
        self.fetch, self.exact, self.missing = fetch, exact, missing
        self.next_due = 0.0
        self.last = {"windows": [], "fetched": None}
        self.error = None
        self.last_good = None
        self.written = None          # last contract written (sans writtenAt)
        self.written_at = 0.0

    def poll(self, now):
        if now < self.next_due:
            return False
        try:
            wins, src_ts = self.fetch()
            fetched = src_ts if src_ts is not None else now
            self.last = {"windows": wins, "fetched": fetched}
            self.last_good = {"fetchedAt": iso(fetched), "windows": wins}
            self.error = None
            self.next_due = now + self.ttl
        except Exception as e:
            reason = str(e) if isinstance(e, GaugeError) else f"{type(e).__name__}: {str(e)[:120]}"
            self.error = reason[:200]
            self.last = {"windows": [], "fetched": None}
            self.next_due = now + min(self.ttl, ERROR_RETRY_S)
        return True

    def contract(self, now):
        ok = not self.error and self.last["fetched"] is not None
        fetched = self.last.get("fetched") if ok else None
        age = now - fetched if fetched else None
        if self.error:
            state = "error"
        elif age is not None and age > self.ttl:
            state = "stale"
        else:
            state = "fresh"
        return {
            "name": self.name, "label": self.label, "source": self.source,
            "exact": self.exact, "ttl": self.ttl,
            "fetchedAt": iso(fetched), "state": state, "error": self.error,
            "missing": self.missing,
            "windows": self.last["windows"] if ok else [],
            "lastGood": self.last_good if self.error else None,
        }

    def write(self, now):
        doc = self.contract(now)
        if doc == self.written and now - self.written_at < self.ttl:
            return
        doc["writtenAt"] = iso(now)
        atomic_write(RUN / f"{self.name}.json", doc)
        self.written, self.written_at = doc, now
        self.written.pop("writtenAt", None)


def run():
    RUN.mkdir(parents=True, exist_ok=True)
    gauges = [Gauge(*g[:3], *g[3:]) for g in GAUGES]
    started = time.time()
    last_beat = 0.0
    while True:
        now = time.time()
        for g in gauges:
            try:
                g.poll(now)
                g.write(now)
            except Exception as e:      # one broken gauge never stops the others
                sys.stderr.write(f"gauge {g.name} write failed: {e}\n")
        if now - last_beat >= HEARTBEAT_S:
            atomic_write(RUN / "collector.json", {
                "pid": os.getpid(), "startedAt": iso(started), "lastTick": iso(now),
                "gauges": [g.name for g in gauges]})
            last_beat = now
        time.sleep(TICK)


def show(as_json=False):
    now = time.time()
    out, rows = {}, []
    hb = RUN / "collector.json"
    hb_age = now - hb.stat().st_mtime if hb.exists() else None
    for path in sorted(RUN.glob("*.json")):
        if path.name == "collector.json":
            continue
        doc = json.loads(path.read_text())
        fetched = datetime.fromisoformat(doc["fetchedAt"]).timestamp() if doc.get("fetchedAt") else None
        age = now - fetched if fetched else None
        state = doc["state"]
        if state != "error" and age is not None and age > 2 * doc["ttl"]:
            state = "stale"           # dimmed, with age
        doc["ageS"] = None if age is None else int(age)
        doc["displayState"] = state
        out[doc["name"]] = doc
        rows.append(doc)
    if as_json:
        print(json.dumps({"collectorAgeS": None if hb_age is None else int(hb_age), "gauges": out}, indent=1))
        return
    if hb_age is None or hb_age > 120:
        print(f"COLLECTOR DOWN (heartbeat age {'none' if hb_age is None else int(hb_age)}s)")
    for d in rows:
        head = f"{d['label']:<13} {d['displayState']:<6}"
        if d["ageS"] is not None and d["ageS"] > d["ttl"]:
            head += f" age {d['ageS']}s"
        if d["displayState"] == "stale" and d["ageS"] and d["ageS"] > 2 * d["ttl"]:
            head += f" stale {d['ageS'] // 60}m (refresh pending)"
        print(head)
        if d["state"] == "error":
            print(f"   error: {d['error']}")
            continue
        for w in d["windows"]:
            v = "n/a" if w["value"] is None else f"{w['value']}{'%' if w['unit'] == '%' else ' ' + w['unit']}"
            extra = f" resets {w['resetsAt']}" if w.get("resetsAt") else ""
            print(f"   {w['label']}: {v}{extra}" + (f" ({w['note']})" if w.get("note") else ""))
        if d.get("missing"):
            print(f"   not measured: {', '.join(d['missing'])}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "show"
    if cmd == "run":
        run()
    else:
        show("--json" in sys.argv)
