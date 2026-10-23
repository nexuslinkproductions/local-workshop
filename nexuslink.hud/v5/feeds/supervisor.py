#!/usr/bin/env python3
"""supervisor.py - one process that runs the v5 feed readers on a schedule.

Why: a fresh `python3 reader.py` costs about 38 ms CPU of interpreter start
(measured, reports/feeds-f*.json). This supervisor imports each reader module
once, then forks one child per run; the child calls the reader's own main()
with stdout pointed at a scratch file. The warm parent pays one interpreter
start for the whole session.

The loop never waits on a child. Each wake it reaps finished children,
SIGKILLs the ones past their timeout, starts the jobs that are due, refreshes
the heartbeat, and sleeps until the next event. A reader that hangs forever,
crashes, or prints garbage costs its own job one failed snapshot and nothing
else: the other jobs keep their cadence.

Snapshots: ${XDG_RUNTIME_DIR:-/tmp}/nexuslink-hud/feeds/<name>.json, written
atomically (temp file plus os.replace), shaped

    {"name", "ok", "ran_at", "ttl_s", "duration_ms", "payload", "last_ok_at"}

  ran_at      epoch seconds (float, wall clock) when the run started, taken
              before the fork. The consumer ages it on its own clock.
  ttl_s       3 x the job interval. Older than ttl_s means stale.
  payload     the reader's own JSON object, untouched (generated_at included).
  ok          the run worked: exit 0 and exactly one JSON object on stdout.
              The reader's own answer (payload.ok) is a separate field.
  last_ok_at  epoch seconds of the last successful run, or null.
  error       present only when ok is false, with stderr_tail when there is one.
              On a failed run the previous payload is kept, so a consumer must
              show it only as a stale value (ok false, error set).

Heartbeat: ${root}/supervisor.json, rewritten about once a second:
    {"pid", "started_at", "beat_at", "heartbeat_s", "jobs", "spawns", "kills",
     "skipped", "runs", "run_ms"}
A consumer that sees beat_at older than 3 x heartbeat_s treats the supervisor
as dead and runs the readers itself (FEED-MODEL.md, fallback rule).

Modes:
  (default)         run until SIGTERM/SIGINT
  --once            run every enabled job once, in parallel, then exit
  --self-check      prove the contracts by name (exit 0 only if all pass)
  --list            print the job table and exit
  --enable NAME     enable an optional job (repeatable); core jobs always run
  --link-fixture P  run link.py with --fixture P (bench only: no ssh, no tailscale)
  --out DIR         override the snapshot root (testing)

Stdlib only. No threads. One monotonic loop.
"""
import argparse
import importlib.util
import json
import os
import signal
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))

CORE = ("sessions", "link", "metrics", "apps")

# name -> script, argv, interval seconds, timeout seconds
JOBS = {
    "sessions": dict(script="sessions.py", argv=["--json"], interval=10, timeout=5),
    "link": dict(script="link.py", argv=["--json"], interval=10, timeout=8),
    "metrics": dict(script="metrics.py", argv=["--json"], interval=10, timeout=5),
    "apps": dict(script="apps.py", argv=["--json"], interval=60, timeout=5),
    # Optional. Off by default so the default cost is the four readers the deck binds.
    "callcap": dict(script="callcap.py", argv=["--status", "--json"], interval=30, timeout=8),
    "chief": dict(script="chief.py", argv=["--status", "--json"], interval=30, timeout=8),
    "level": dict(script="level.py", argv=["--once", "--json"], interval=30, timeout=5),
    "recent": dict(script="recent.py", argv=["--json"], interval=30, timeout=8),
    "game_mode": dict(script="game_mode.py", argv=["status", "--json"], interval=30, timeout=5),
}
OPTIONAL_SCRIPTS = ("callcap", "chief", "level", "recent", "game_mode")

HEARTBEAT_S = 1.0    # the loop wakes at least this often and rewrites the heartbeat
POLL_S = 0.05        # wake interval while a child is in flight (reap and deadline checks)
HEARTBEAT_NAME = "supervisor.json"
SCRATCH = ".run"     # per-job stdout and stderr files live here, removed after each run

STOP = False


def _on_signal(signum, frame):
    global STOP
    STOP = True


def snapshot_root(out=None):
    if out:
        return os.path.join(out, "nexuslink-hud", "feeds")
    base = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    return os.path.join(base, "nexuslink-hud", "feeds")


def write_json_atomic(path, obj, fsync=True):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="." + os.path.basename(path) + ".",
                               suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f, separators=(",", ":"))
            f.write("\n")
            f.flush()
            if fsync:
                os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_snapshot(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _read_text(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return ""


def _reject_constant(name):
    raise ValueError("non-finite number " + name)


def parse_payload(text):
    """Return (payload, problem): exactly one JSON object, no NaN or Infinity."""
    try:
        obj = json.loads(text, parse_constant=_reject_constant)
    except ValueError:
        return None, "stdout is not one JSON object"
    if not isinstance(obj, dict):
        return None, "stdout is not one JSON object"
    return obj, None


def _load_path(modname, path):
    spec = importlib.util.spec_from_file_location(modname, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[modname] = mod
    spec.loader.exec_module(mod)  # import cost paid once, in the parent
    return mod


def _load_module(script):
    stem = os.path.splitext(script)[0]
    return _load_path("feed_" + stem, os.path.join(HERE, script))


def _child(argv, mod, out_path, err_path):
    """In the forked child: own process group, default signals, stdout to file."""
    try:
        os.setsid()
    except OSError:
        pass
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    out_fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    err_fd = os.open(err_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.dup2(out_fd, 1)
    os.dup2(err_fd, 2)
    os.close(out_fd)
    os.close(err_fd)
    sys.argv = [getattr(mod, "__file__", "reader")] + list(argv)
    code = 0
    try:
        rc = mod.main(list(argv))
        code = int(rc) if isinstance(rc, int) else 0
    except SystemExit as e:
        code = int(e.code) if isinstance(e.code, int) else (0 if e.code is None else 2)
    except BaseException:
        import traceback
        traceback.print_exc()
        code = 2
    try:
        sys.stdout.flush()
    except Exception:
        pass
    os._exit(code & 0xFF)


def _kill(pid):
    """SIGKILL the child and its process group. Never blocks."""
    for call in (os.killpg, os.kill):
        try:
            call(pid, signal.SIGKILL)
        except OSError:
            pass


def _waitpid(pid):
    """Non-blocking reap. Returns the wait status, None while running, -1 if gone."""
    try:
        done, st = os.waitpid(pid, os.WNOHANG)
    except OSError:
        return -1
    return st if done == pid else None


class Supervisor:
    def __init__(self, jobs, mods, root):
        self.jobs = jobs            # name -> job dict
        self.mods = mods            # name -> preloaded module
        self.root = root
        self.scratch = os.path.join(root, SCRATCH)
        self.beat_path = os.path.join(root, HEARTBEAT_NAME)
        self.running = {}           # name -> run dict, in flight
        self.unreaped = {}          # pid -> name, killed, waiting for the kernel
        self.due = {}               # name -> next due (monotonic)
        self.counts = {"spawns": 0, "kills": 0, "skipped": 0}
        self.runs = {n: 0 for n in jobs}
        self.run_ms = {n: 0.0 for n in jobs}
        self.started_at = time.time()
        self.last_beat = 0.0
        self.beats = 0
        os.makedirs(self.scratch, exist_ok=True)
        for leftover in os.listdir(self.scratch):
            try:
                os.unlink(os.path.join(self.scratch, leftover))
            except OSError:
                pass

    # -- heartbeat ---------------------------------------------------------
    def beat(self, force=False):
        now = time.time()
        if not force and now - self.last_beat < HEARTBEAT_S:
            return
        self.last_beat = now
        self.beats += 1
        write_json_atomic(self.beat_path, {
            "pid": os.getpid(),
            "started_at": round(self.started_at, 3),
            "beat_at": round(now, 3),
            "heartbeat_s": HEARTBEAT_S,
            "jobs": sorted(self.jobs),
            "spawns": self.counts["spawns"],
            "kills": self.counts["kills"],
            "skipped": self.counts["skipped"],
            "runs": dict(self.runs),
            "run_ms": {k: round(v, 1) for k, v in self.run_ms.items()},
        }, fsync=False)

    # -- one run -----------------------------------------------------------
    def _spawn(self, name):
        job = self.jobs[name]
        out = os.path.join(self.scratch, name + ".out")
        err = os.path.join(self.scratch, name + ".err")
        t0 = time.monotonic()
        t0w = time.time()
        # Flush before fork: unflushed parent output would otherwise be written
        # into the child's stdout file at its exit and break the one-object rule.
        sys.stdout.flush()
        sys.stderr.flush()
        try:
            pid = os.fork()
        except OSError as e:
            self._publish(name, t0w, 0.0, None, "spawn failed: %s" % e.strerror, "")
            return
        if pid == 0:
            _child(job["argv"], self.mods[name], out, err)
            os._exit(2)  # not reached
        try:
            os.setpgid(pid, pid)  # race-free with the child's own setsid
        except OSError:
            pass
        self.counts["spawns"] += 1
        self.running[name] = dict(pid=pid, t0=t0, t0w=t0w,
                                  deadline=t0 + job["timeout"], out=out, err=err)

    def _complete(self, name, problem, text="", err=""):
        run = self.running.pop(name)
        duration_ms = round((time.monotonic() - run["t0"]) * 1000.0, 1)
        payload = None
        if problem is None:
            payload, problem = parse_payload(text)
        for p in (run["out"], run["err"]):
            try:
                os.unlink(p)
            except OSError:
                pass
        return self._publish(name, run["t0w"], duration_ms, payload, problem, err)

    def _exited(self, name, st):
        run = self.running[name]
        text = _read_text(run["out"])
        err = _read_text(run["err"]).strip()
        if st == -1:
            problem = "child lost"
        elif os.WIFEXITED(st) and os.WEXITSTATUS(st) == 0:
            problem = None
        elif os.WIFEXITED(st):
            problem = "exit %d" % os.WEXITSTATUS(st)
        else:
            problem = "signal %d" % os.WTERMSIG(st)
        self._complete(name, problem, text, err)

    def _publish(self, name, ran_at_epoch, duration_ms, payload, problem, err_text):
        target = os.path.join(self.root, name + ".json")
        prev = read_snapshot(target)
        ok = problem is None
        ran_at = round(ran_at_epoch, 3)
        if ok:
            body, last_ok = payload, ran_at
        else:
            body = prev.get("payload") if isinstance(prev, dict) else None
            if isinstance(prev, dict):
                last_ok = prev.get("ran_at") if prev.get("ok") else prev.get("last_ok_at")
            else:
                last_ok = None
        env = {
            "name": name,
            "ok": ok,
            "ran_at": ran_at,
            "ttl_s": 3 * self.jobs[name]["interval"],
            "duration_ms": duration_ms,
            "payload": body,
            "last_ok_at": last_ok,
        }
        if not ok:
            env["error"] = problem
            if err_text:
                env["stderr_tail"] = err_text.splitlines()[-1][:200]
        write_json_atomic(target, env)
        self.runs[name] += 1
        self.run_ms[name] += duration_ms
        return env

    # -- the loop: never waits on a child ----------------------------------
    def _reap(self, now):
        for pid in list(self.unreaped):
            if _waitpid(pid) is not None:
                self.unreaped.pop(pid, None)
        for name in list(self.running):
            run = self.running[name]
            st = _waitpid(run["pid"])
            if st is not None:
                self._exited(name, st)
            elif now >= run["deadline"]:
                _kill(run["pid"])
                self.unreaped[run["pid"]] = name
                self.counts["kills"] += 1
                self._complete(name, "timeout after %ss" % self.jobs[name]["timeout"])

    def _shutdown(self):
        for name in list(self.running):
            run = self.running.pop(name)
            _kill(run["pid"])
            self.unreaped[run["pid"]] = name
        deadline = time.monotonic() + 2.0
        while self.unreaped and time.monotonic() < deadline:
            for pid in list(self.unreaped):
                if _waitpid(pid) is not None:
                    self.unreaped.pop(pid, None)
            if self.unreaped:
                time.sleep(0.01)
        self.beat(force=True)

    def loop(self, until=None, once=False):
        t_start = time.monotonic()
        if once:
            for name in self.jobs:
                self._spawn(name)
        else:
            for i, name in enumerate(self.jobs):
                self.due[name] = t_start + 0.25 * i  # stagger first ticks
        self.beat(force=True)
        while not STOP:
            now = time.monotonic()
            if until is not None and now >= until:
                break
            self._reap(now)
            if once:
                if not self.running:
                    break
            else:
                for name in sorted(self.due, key=lambda n: self.due[n]):
                    if self.due[name] > now:
                        break
                    iv = self.jobs[name]["interval"]
                    if name in self.running:
                        self.counts["skipped"] += 1  # previous run still in flight
                    else:
                        self._spawn(name)
                    nxt = self.due[name] + iv
                    self.due[name] = nxt if nxt > now else now + iv
            self.beat()
            now = time.monotonic()
            if self.running or self.unreaped:
                wait = POLL_S
            elif self.due and not once:
                wait = min(min(self.due.values()) - now, HEARTBEAT_S)
            else:
                wait = HEARTBEAT_S
            if until is not None:
                wait = min(wait, until - now)
            time.sleep(max(0.001, wait))
        self._shutdown()


def _job(script, argv, interval=10.0, timeout=5.0):
    return dict(script=script, argv=list(argv), interval=interval, timeout=timeout)


def self_check():
    """Prove the contracts by name. Fixture reads, crash, hang, garbage, the loop."""
    ok = True

    def check(label, cond, detail=""):
        nonlocal ok
        print(("ok   " if cond else "FAIL ") + label + ((" " + detail) if detail else ""))
        if not cond:
            ok = False

    tmp = tempfile.mkdtemp(prefix="feeds-sup-check-")
    fix = os.path.join(os.path.dirname(HERE), "fixtures")

    def script(name, body):
        p = os.path.join(tmp, name)
        with open(p, "w") as f:
            f.write(body)
        os.chmod(p, 0o755)
        return p

    def mod_of(path):
        return _load_path("chk_" + os.path.basename(path)[:-3], path)

    def one(name, job, root):
        """Run one job through the real loop until it completes."""
        sup = Supervisor({name: job}, {name: mod_of(job["script"])}, root)
        sup.loop(once=True)
        return read_snapshot(os.path.join(root, name + ".json")), sup

    good = script("good_reader.py", (
        "import json, sys\n"
        "def main(argv=None):\n"
        "    print(json.dumps({'ok': True, 'generated_at': '2026-10-23T00:00:00Z'}))\n"
        "    return 0\n"))
    crash = script("crash_reader.py", (
        "import os\n"
        "def main(argv=None):\n"
        "    os.kill(os.getpid(), 9)\n"
        "    return 0\n"))
    hang = script("hang_reader.py", (
        "import time\n"
        "def main(argv=None):\n"
        "    while True:\n"
        "        time.sleep(1)\n"))
    junk = script("junk_reader.py", (
        "def main(argv=None):\n"
        "    print('not json')\n"
        "    return 0\n"))
    nan = script("nan_reader.py", (
        "def main(argv=None):\n"
        "    print('{\"ok\": true, \"x\": NaN}')\n"
        "    return 0\n"))

    # (a) the four real readers through --fixture
    real = [
        ("sessions", "sessions.py", ["--fixture", fix + "/sessions.json", "--json"]),
        ("link", "link.py", ["--fixture", fix + "/link.json", "--json"]),
        ("metrics", "metrics.py", ["--fixture", fix + "/metrics.json", "--json"]),
        ("apps", "apps.py", ["--fixture", fix + "/apps.json", "--json"]),
    ]
    root_fx = os.path.join(tmp, "fx", "feeds")
    sessions_env = None
    for name, scr, argv in real:
        job = _job(os.path.join(HERE, scr), argv, interval=10, timeout=10)
        env, _sup = one(name, job, root_fx)
        good_run = (env is not None and env.get("ok") is True
                    and isinstance(env.get("payload"), dict)
                    and env.get("ttl_s") == 30)
        check("fixture " + name, good_run,
              "%.0f ms" % (env or {}).get("duration_ms", -1))
        if name == "sessions":
            sessions_env = env
    fields = ("name", "ok", "ran_at", "ttl_s", "duration_ms", "payload", "last_ok_at")
    check("envelope fields", sessions_env is not None
          and all(k in sessions_env for k in fields)
          and isinstance(sessions_env["ran_at"], float)
          and isinstance(sessions_env["payload"].get("generated_at"), str),
          "payload.generated_at untouched: %s" % (sessions_env or {}).get("payload", {}).get("generated_at"))

    # (b) crash, hang, garbage, non-finite: each costs its own job only
    root = os.path.join(tmp, "feeds")
    env, _ = one("crash", _job(crash, [], timeout=5), root)
    check("crash isolated", env is not None and env["ok"] is False
          and env.get("error") == "signal 9", repr((env or {}).get("error")))
    env, _ = one("hang", _job(hang, [], timeout=0.5), root)
    check("hang killed at timeout", env is not None and env["ok"] is False
          and str(env.get("error", "")).startswith("timeout after")
          and env.get("duration_ms", 1e9) < 2000,
          "%s %.0f ms" % ((env or {}).get("error"), (env or {}).get("duration_ms", -1)))
    env, _ = one("junk", _job(junk, [], timeout=5), root)
    check("junk stdout rejected", env is not None and env["ok"] is False
          and env.get("error") == "stdout is not one JSON object", repr((env or {}).get("error")))
    env, _ = one("nan", _job(nan, [], timeout=5), root)
    check("non-finite number rejected", env is not None and env["ok"] is False
          and env.get("error") == "stdout is not one JSON object", repr((env or {}).get("error")))

    # (c) the last good payload survives a failed run
    first, _ = one("keep", _job(good, [], timeout=5), root)
    bad, _ = one("keep", _job(junk, [], timeout=5), root)
    check("payload kept after failure", first is not None and bad is not None
          and bad["ok"] is False and bad["payload"] == first["payload"]
          and bad["last_ok_at"] == first["ran_at"]
          and bad["error"] == "stdout is not one JSON object")

    # (d) the loop never waits on a hang or a crash
    root_loop = os.path.join(tmp, "loop", "feeds")
    jobs = {
        "hang": _job(hang, [], interval=10, timeout=1.5),
        "crash": _job(crash, [], interval=0.5, timeout=2),
        "good": _job(good, [], interval=0.2, timeout=2),
    }
    mods = {n: mod_of(j["script"]) for n, j in jobs.items()}
    sup = Supervisor(jobs, mods, root_loop)
    t0 = time.monotonic()
    sup.loop(until=t0 + 3.0)
    elapsed = time.monotonic() - t0
    check("loop not blocked by hang or crash",
          sup.runs["good"] >= 8 and sup.runs["crash"] >= 3 and elapsed < 3.5,
          "good %d runs, crash %d runs, hang killed %d, %.2f s" % (
              sup.runs["good"], sup.runs["crash"], sup.counts["kills"], elapsed))
    hang_env = read_snapshot(os.path.join(root_loop, "hang.json"))
    check("hung reader killed, error recorded", hang_env is not None
          and hang_env["ok"] is False and str(hang_env.get("error", "")).startswith("timeout after"),
          repr((hang_env or {}).get("error")))
    check("heartbeat beats during the run", sup.beats >= 2, "beats=%d" % sup.beats)
    hb = read_snapshot(os.path.join(root_loop, HEARTBEAT_NAME)) or {}
    check("heartbeat file fields", hb.get("pid") == os.getpid()
          and isinstance(hb.get("started_at"), (int, float))
          and isinstance(hb.get("beat_at"), (int, float))
          and hb["beat_at"] >= hb["started_at"] and hb.get("heartbeat_s") == HEARTBEAT_S,
          "pid=%s beat_at=%s" % (hb.get("pid"), hb.get("beat_at")))
    check("children reaped at exit", sup.running == {} and sup.unreaped == {},
          "running=%d unreaped=%d" % (len(sup.running), len(sup.unreaped)))

    # (e) files: no temp leftovers, scratch empty, snapshots parse
    names = [n for n in os.listdir(root_loop) if n.endswith(".tmp")]
    check("no temp files left", names == [], repr(names))
    check("scratch empty after runs", os.listdir(sup.scratch) == [],
          repr(os.listdir(sup.scratch)))
    snap_ok = True
    for n in ("good", "hang", "crash"):
        try:
            with open(os.path.join(root_loop, n + ".json")) as f:
                snap_ok = snap_ok and isinstance(json.load(f), dict)
        except (OSError, ValueError):
            snap_ok = False
    check("snapshots parse", snap_ok)

    print(("ALL OK" if ok else "FAILURES") + " root=" + root_loop)
    return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--self-check", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--enable", action="append", default=[])
    ap.add_argument("--link-fixture", default="")
    ap.add_argument("--out", default="")
    a = ap.parse_args(argv)

    if a.self_check:
        return self_check()
    if a.list:
        for name, job in JOBS.items():
            tag = "core" if name in CORE else "optional"
            print("%-10s %-8s %4ds  timeout %2ds  %s %s" % (
                name, tag, job["interval"], job["timeout"],
                job["script"], " ".join(job["argv"])))
        return 0

    names = list(CORE)
    for n in a.enable:
        if n not in names:
            names.append(n)
    unknown = [n for n in names if n not in JOBS]
    if unknown:
        print("unknown job: %s" % ", ".join(unknown), file=sys.stderr)
        return 2
    for n in OPTIONAL_SCRIPTS:
        if n in names and not os.path.exists(os.path.join(HERE, str(JOBS[n]["script"]))):
            print("warning: %s.py not in %s, disabling %s" % (n, HERE, n), file=sys.stderr)
            names.remove(n)
    jobs = {n: dict(JOBS[n]) for n in names}
    if a.link_fixture and "link" in jobs:
        jobs["link"]["argv"] = ["--fixture", a.link_fixture, "--json"]
    root = snapshot_root(a.out)
    mods = {n: _load_module(j["script"]) for n, j in jobs.items()}  # preload: the whole point
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)
    Supervisor(jobs, mods, root).loop(once=a.once)
    return 0


if __name__ == "__main__":
    sys.exit(main())
