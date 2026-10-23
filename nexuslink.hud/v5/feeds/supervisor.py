#!/usr/bin/env python3
"""supervisor.py - one process that runs the v5 feed readers on a schedule.

Why: a fresh `python3 reader.py` costs about 38 ms CPU of interpreter start
(measured, reports/feeds-f*.json). At DeckMain's cadence that is ~1.4 percent of
one core for four readers, before any real work. This supervisor imports each
reader module once, forks a child per run, and lets the child call the reader's
own main() with stdout pointed at a temp file. The warm parent costs one
interpreter start for the whole session; a child costs a fork plus the work.

Failure isolation is the second reason: every run is its own child, so a
reader that crashes, calls sys.exit, or hangs can only kill its child. A hang is
SIGKILLed at the job timeout. The last good snapshot stays on disk.

Snapshots: ${XDG_RUNTIME_DIR:-/tmp}/nexuslink-hud/feeds/<name>.json, written
atomically (temp file plus os.replace), shaped

    {"name","ok","ran_at","duration_ms","payload": <reader json>}

A failed run keeps the previous payload and records the failure under "error"
and "last_ok_at", so a consumer can tell a stale-but-usable snapshot from a
broken one.

Modes:
  (default)      run until SIGTERM/SIGINT
  --once         run every enabled job once, exit
  --self-check   prove fixture reads, crash, timeout, atomic write, retention
  --list         print the job table and exit
  --enable NAME  enable an optional job (repeatable); core jobs are always on
  --out DIR      override the snapshot root (testing)

Stdlib only. No threads. One monotonic loop: sleep until the next due job.
"""
import argparse
import errno
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
    # Optional. Linux-live per reports/feeds-f*.json; off by default so the
    # supervisor's default cost is the four readers the deck binds today.
    "callcap": dict(script="callcap.py", argv=["--status", "--json"],
                    interval=30, timeout=8),
    "chief": dict(script="chief.py", argv=["--status", "--json"],
                  interval=30, timeout=8),
    "level": dict(script="level.py", argv=["--once", "--json"],
                  interval=30, timeout=5),
    "recent": dict(script="recent.py", argv=["--json"], interval=30, timeout=8),
    "game_mode": dict(script="game_mode.py", argv=["status", "--json"],
                      interval=30, timeout=5),
}

STOP = False


def _on_signal(signum, frame):
    global STOP
    STOP = True


def snapshot_root(out=None):
    if out:
        return os.path.join(out, "nexuslink-hud", "feeds")
    base = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    return os.path.join(base, "nexuslink-hud", "feeds")


def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def write_json_atomic(path, obj):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="." + os.path.basename(path) + ".",
                               suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f, separators=(",", ":"))
            f.write("\n")
            f.flush()
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


def _load_module(script):
    name = "feed_" + os.path.splitext(script)[0]
    path = os.path.join(HERE, script)
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)  # import cost paid once, in the parent
    return mod


def _child(script, argv, mod, out_path, err_path):
    """In the forked child: own session, stdout to file, call reader main()."""
    try:
        os.setsid()
    except OSError:
        pass
    out_fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    err_fd = os.open(err_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.dup2(out_fd, 1)
    os.dup2(err_fd, 2)
    os.close(out_fd)
    os.close(err_fd)
    sys.argv = [os.path.join(HERE, script)] + list(argv)
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


def run_once(name, job, mod, root, keep_payload=True):
    """Run one job in a child, enforce the timeout, return the envelope."""
    t0 = time.monotonic()
    target = os.path.join(root, name + ".json")
    prev = read_snapshot(target) if keep_payload else None
    fd, out_path = tempfile.mkstemp(prefix="." + name + ".out.", dir=root)
    os.close(fd)
    fd, err_path = tempfile.mkstemp(prefix="." + name + ".err.", dir=root)
    os.close(fd)
    pid = os.fork()
    if pid == 0:
        _child(job["script"], job["argv"], mod, out_path, err_path)
        os._exit(2)  # not reached
    timed_out = False
    status = 0
    deadline = t0 + job["timeout"]
    while True:
        done, st = os.waitpid(pid, os.WNOHANG)
        if done == pid:
            status = st
            break
        if time.monotonic() > deadline:
            timed_out = True
            try:
                os.killpg(pid, signal.SIGKILL)
            except OSError as e:
                if e.errno != errno.ESRCH:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except OSError:
                        pass
            try:
                os.waitpid(pid, 0)
            except OSError:
                pass
            break
        if STOP:
            try:
                os.killpg(pid, signal.SIGKILL)
            except OSError:
                pass
            os.waitpid(pid, 0)
            break
        time.sleep(0.005)
    duration_ms = round((time.monotonic() - t0) * 1000.0, 1)
    text = ""
    try:
        with open(out_path, "rb") as f:
            text = f.read().decode("utf-8", "replace")
    except OSError:
        text = ""
    err = ""
    try:
        with open(err_path, "rb") as f:
            err = f.read().decode("utf-8", "replace").strip()
    except OSError:
        err = ""
    for p in (out_path, err_path):
        try:
            os.unlink(p)
        except OSError:
            pass

    exit_ok = (not timed_out) and os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0
    payload = None
    problem = None
    if timed_out:
        problem = "timeout after %ss" % job["timeout"]
    elif not exit_ok:
        problem = "exit %s" % (os.WEXITSTATUS(status) if os.WIFEXITED(status)
                               else "signal")
    else:
        try:
            payload = json.loads(text)
            if not isinstance(payload, dict):
                problem = "not one JSON object"
                payload = None
        except ValueError:
            problem = "stdout is not one JSON object"

    env = {
        "name": name,
        "ok": problem is None,
        "ran_at": utc_now(),
        "duration_ms": duration_ms,
        "payload": payload if payload is not None else (
            prev.get("payload") if isinstance(prev, dict) else None),
        "last_ok_at": env_ts(prev) if problem is not None else utc_now(),
    }
    if problem is not None:
        env["error"] = problem
        if err:
            env["stderr_tail"] = err.splitlines()[-1][:200]
    write_json_atomic(target, env)
    return env


def env_ts(prev):
    if isinstance(prev, dict):
        if prev.get("ok"):
            return prev.get("ran_at")
        return prev.get("last_ok_at")
    return None


def enabled_jobs(names):
    out = {}
    for name in names:
        if name not in JOBS:
            raise SystemExit("unknown job: %s (see --list)" % name)
        out[name] = JOBS[name]
    return out


def loop(jobs, mods, root, once=False):
    now = time.monotonic()
    due = {}
    i = 0
    for name in jobs:
        # stagger the first tick so no two readers start in the same millisecond
        due[name] = now + 0.25 * i
        i += 1
    while not STOP:
        now = time.monotonic()
        if once:
            pending = [n for n in jobs if due[n] <= now + 0.25 * len(jobs)]
        else:
            pending = [n for n in jobs if due[n] <= now]
        if not pending:
            nxt = min(due.values())
            if once:
                break
            time.sleep(max(0.01, min(nxt - now, 1.0)))
            continue
        name = pending[0]
        if once:
            time.sleep(max(0.0, due[name] - time.monotonic()))
        run_once(name, jobs[name], mods[name], root)
        if once:
            due[name] = float("inf")
            if all(due[n] == float("inf") for n in jobs):
                break
        else:
            due[name] += jobs[name]["interval"]
            if due[name] < time.monotonic() - jobs[name]["interval"]:
                due[name] = time.monotonic() + jobs[name]["interval"]


def self_check():
    """Prove the contracts without touching a live source."""
    ok = True

    def check(label, cond, detail=""):
        nonlocal ok
        print(("ok   " if cond else "FAIL ") + label + ((" " + detail) if detail else ""))
        if not cond:
            ok = False

    tmp = tempfile.mkdtemp(prefix="feeds-sup-check-")
    root = os.path.join(tmp, "feeds")
    os.makedirs(root)
    fix = os.path.join(os.path.dirname(HERE), "fixtures")

    def script(name, body):
        p = os.path.join(tmp, name)
        with open(p, "w") as f:
            f.write(body)
        os.chmod(p, 0o755)
        return p

    good = script("good_reader.py", (
        "import json, sys\n"
        "def main(argv=None):\n"
        "    print(json.dumps({'ok': True, 'n': len(sys.argv)}))\n"
        "    return 0\n"))
    crash = script("crash_reader.py", (
        "import os\n"
        "def main(argv=None):\n"
        "    os.kill(os.getpid(), 9)\n"
        "    return 0\n"))
    hang = script("hang_reader.py", (
        "import time\n"
        "def main(argv=None):\n"
        "    time.sleep(30)\n"
        "    return 0\n"))
    junk = script("junk_reader.py", (
        "def main(argv=None):\n"
        "    print('not json')\n"
        "    return 0\n"))

    def mod_of(path):
        spec = importlib.util.spec_from_file_location(
            "chk_" + os.path.basename(path)[:-3], path)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        return m

    # (a) the four real readers through --fixture
    real = {
        "sessions": dict(script="sessions.py", argv=["--fixture", fix + "/sessions.json", "--json"], interval=10, timeout=10),
        "link": dict(script="link.py", argv=["--fixture", fix + "/link.json", "--json"], interval=10, timeout=10),
        "metrics": dict(script="metrics.py", argv=["--fixture", fix + "/metrics.json", "--json"], interval=10, timeout=10),
        "apps": dict(script="apps.py", argv=["--fixture", fix + "/apps.json", "--json"], interval=10, timeout=10),
    }
    for name, job in real.items():
        e = run_once(name, job, _load_module(job["script"]), root)
        check("fixture " + name, e["ok"] and isinstance(e["payload"], dict),
              "%.0f ms" % e["duration_ms"])

    # (b) one crash + one timeout + two healthy in one tick
    mixed = [
        ("h1", dict(script=good, argv=[], interval=10, timeout=5), mod_of(good)),
        ("crash", dict(script=crash, argv=[], interval=10, timeout=5), mod_of(crash)),
        ("hang", dict(script=hang, argv=[], interval=10, timeout=0.5), mod_of(hang)),
        ("h2", dict(script=good, argv=[], interval=10, timeout=5), mod_of(good)),
    ]
    res = {}
    for name, job, m in mixed:
        res[name] = run_once(name, job, m, root)
    check("crash isolated", res["h1"]["ok"] and res["h2"]["ok"] and not res["crash"]["ok"],
          "crash error=%r" % res["crash"].get("error"))
    check("timeout killed", (not res["hang"]["ok"]) and res["hang"]["duration_ms"] < 3000,
          "%.0f ms, %r" % (res["hang"]["duration_ms"], res["hang"].get("error")))

    # (c) stale payload retained after a failure, failure recorded
    first = run_once("keep", dict(script=good, argv=[], interval=10, timeout=5),
                     mod_of(good), root)
    bad = run_once("keep", dict(script=junk, argv=[], interval=10, timeout=5),
                   mod_of(junk), root)
    check("payload retained after failure",
          bad["ok"] is False and bad["payload"] == first["payload"]
          and bad.get("last_ok_at") == first["ran_at"],
          "error=%r" % bad.get("error"))

    # (d) atomic write leaves no temp file and one parseable snapshot
    names = [n for n in os.listdir(root) if n.startswith(".") and n.endswith(".tmp")]
    check("no temp files left", names == [], repr(names))
    with open(os.path.join(root, "keep.json")) as f:
        check("snapshot parses", isinstance(json.load(f), dict))

    check("crash before write keeps file", os.path.exists(os.path.join(root, "crash.json")))
    print(("ALL OK" if ok else "FAILURES") + " root=" + root)
    return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--self-check", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--enable", action="append", default=[])
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

    names = list(CORE) + [n for n in a.enable if n not in CORE]
    unknown = [n for n in names if n not in JOBS]
    if unknown:
        print("unknown job: %s" % ", ".join(unknown), file=sys.stderr)
        return 2
    for n in ("callcap", "chief", "level", "recent", "game_mode"):
        if n in a.enable and not os.path.exists(os.path.join(HERE, JOBS[n]["script"])):
            print("warning: %s.py not in %s, disabling %s" % (n, HERE, n),
                  file=sys.stderr)
            names.remove(n)
    jobs = enabled_jobs(names)
    root = snapshot_root(a.out)
    os.makedirs(root, exist_ok=True)
    mods = {}
    for name, job in jobs.items():
        mods[name] = _load_module(job["script"])  # preload: the whole point
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)
    loop(jobs, mods, root, once=a.once)
    return 0


if __name__ == "__main__":
    sys.exit(main())
