#!/usr/bin/env python3
"""Peak level source for the v5 HUD meter: two channels, 10 Hz maximum.

The meter behind the call-capture widget wants the level of what the box is
playing, per channel, ten times a second. This reader gives exactly that and
nothing else.

Modes::

    level.py --once                    one sample, one JSON object
    level.py --rate 10                 one JSON object per line, 10 Hz
    level.py --rate 5  --count 100     slower, bounded
    level.py --once --fixture PATH     replay a recorded series (Mac, tests)

Payload per sample::

    {"ok": true, "source": "fixture|live", "generated_at": "...",
     "channels": 2, "peak": [-12.4, -13.0], "rms": [-21.5, -23.1],
     "clipped": false, "at": "2026-10-23T01:23:45.123Z"}

Live path: read the default sink's monitor in raw s16le 48 kHz stereo through
``parec`` (pulse-compatible) or ``pw-record``, one block per sample, and compute
peak and RMS in Python. Channel 1 is what the box plays; channel 2 exists because
``callcap`` records two channels (mic, far end) and the widget shows the pair.

Silence is the floor ``-91.0`` dBFS, never ``0.0``: the wrapper's own skill calls
digital silence -91 dB, and a meter that reports silence as full scale would be a
lie the eye cannot catch. ``clipped`` is true only when a sample reaches the s16
ceiling (32767).

Rate: the HUD budget is 10 Hz. ``--rate`` above 10 is a caller error (exit 2) and
is refused before any audio is read. ``--once`` is not cached either: the
measurement *is* the read, so the 10 s cache rule that the status readers keep
(http-stule sources) does not apply to a meter. Every other reader in this
directory caches; this one cannot without lying about "now".

Host reality: PipeWire, ``parec``, ``pw-record`` and ``pactl`` are Linux-only. On
the Mac the live path answers ``ok: false`` with a reason and exit 0, and the
fixture path replays a committed series so the meter can be built and tested
end to end.
"""

from __future__ import annotations

import argparse
import array
import datetime
import json
import math
import os
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time

EXIT_OK = 0
EXIT_PROGRAMMING = 2

HOME = os.path.expanduser("~")
SOURCE = "level"

CHANNELS = 2
SAMPLE_RATE = 48000
BYTES_PER_SAMPLE = 2  # s16
FRAME_BYTES = CHANNELS * BYTES_PER_SAMPLE
MAX_RATE_HZ = 10.0
FLOOR_DB = -91.0
CLIP_SAMPLE = 32767

DEFAULT_TIMEOUT_S = 2.0
SHIPPED_FIXTURE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "fixtures", "level.json"
)


# --------------------------------------------------------------- shared plumbing


class DataProblem(Exception):
    """A source is missing, empty or malformed. Always an answer, never a crash."""

    kind = "data"

    def __init__(self, reason):
        super(DataProblem, self).__init__(reason)
        self.reason = str(reason)


class Missing(DataProblem):
    kind = "missing"


class Malformed(DataProblem):
    kind = "malformed"


class Caller(DataProblem):
    """The caller named a file that is not there, or asked for the impossible."""

    kind = "caller"


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc)


def iso_ms(epoch):
    """UTC ISO-8601 with milliseconds: a 10 Hz meter needs sub-second stamps."""
    try:
        value = float(epoch)
    except (TypeError, ValueError):
        return None
    try:
        stamp = datetime.datetime.fromtimestamp(value, datetime.timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None
    return stamp.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (stamp.microsecond // 1000)


def tilde(path):
    if not path:
        return ""
    path = os.path.abspath(os.path.expanduser(str(path)))
    if path == HOME:
        return "~"
    if path.startswith(HOME + os.sep):
        return "~" + path[len(HOME):]
    return path


def tilde_text(message):
    for root in (HOME, os.path.realpath(HOME)):
        if root and root != "/" and root in message:
            message = message.replace(root + os.sep, "~" + os.sep).replace(root, "~")
    return message


def number(value):
    if value is None or isinstance(value, bool):
        return None
    try:
        out = float(value)
    except (TypeError, ValueError):
        return None
    if out != out or out in (float("inf"), float("-inf")):
        return None
    return out


def text(value, limit=None):
    if value is None:
        return None
    if not isinstance(value, str):
        value = str(value)
    value = " ".join(value.split())
    if not value:
        return None
    if limit is not None and len(value) > limit:
        value = value[:limit].rstrip() + "\u2026"
    return value


def emit(payload, compact):
    line = json.dumps(payload, ensure_ascii=False, separators=(",", ":")) if compact \
        else json.dumps(payload, ensure_ascii=False, indent=2)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def read_json(path, what):
    shown = tilde(path)
    if not path:
        raise Missing("no %s path given" % what)
    target = os.path.expanduser(str(path))
    if not os.path.exists(target):
        raise Missing("no %s at %s" % (what, shown))
    if not os.path.isfile(target):
        raise Missing("%s is not a file: %s" % (what, shown))
    try:
        with open(target, "r", encoding="utf-8") as handle:
            raw = handle.read()
    except OSError as exc:
        raise Missing("cannot read %s at %s: %s" % (what, shown, exc))
    if not raw.strip():
        raise Missing("%s at %s is empty" % (what, shown))
    try:
        return json.loads(raw)
    except ValueError as exc:
        raise Malformed("%s at %s is not valid JSON: %s" % (what, shown, exc))


def envelope(**fields):
    payload = {"ok": True, "source": None, "generated_at": iso_ms(time.time())}
    payload.update(fields)
    return payload


def failure(problem):
    reason = getattr(problem, "reason", None) or str(problem)
    return {
        "ok": False,
        "source": SOURCE,
        "generated_at": iso_ms(time.time()),
        "reason": tilde_text(reason),
        "kind": getattr(problem, "kind", "data"),
    }


# -------------------------------------------------------------------------- audio


def db_from_amplitude(value):
    """Linear s16 amplitude -> dBFS, floored at FLOOR_DB (never -inf, never 0)."""
    if value <= 0:
        return FLOOR_DB
    return max(FLOOR_DB, 20.0 * math.log10(value / 32768.0))


def analyse(block):
    """Raw s16le stereo block -> {peak, rms, clipped} in dBFS."""
    if not block or len(block) % 2:
        raise Malformed("audio block is not a whole number of s16 samples (%d bytes)" % len(block or b""))
    samples = array.array("h")
    samples.frombytes(block[: len(block) - (len(block) % 2)])
    if sys.byteorder == "big":
        samples.byteswap()
    frames = len(samples) // CHANNELS
    if frames <= 0:
        raise Malformed("audio block carries no frames")
    peak, rms, clipped = [], [], False
    for channel in range(CHANNELS):
        values = samples[channel::CHANNELS]
        top = max(abs(value) for value in values)
        energy = sum(float(value) * value for value in values) / float(len(values))
        peak.append(round(db_from_amplitude(top), 1))
        rms.append(round(db_from_amplitude(math.sqrt(energy)), 1))
        if top >= CLIP_SAMPLE:
            clipped = True
    return {"peak": peak, "rms": rms, "clipped": clipped}


class Monitor(object):
    """A raw stereo stream from the default sink's monitor. Live path only."""

    def __init__(self, source, block_bytes):
        self.block_bytes = block_bytes
        argv = None
        binary = shutil.which("parec")
        if binary:
            argv = [binary, "--device", source, "--format=s16le", "--rate=%d" % SAMPLE_RATE,
                    "--channels=%d" % CHANNELS, "--raw", "--latency-msec=50"]
        else:
            binary = shutil.which("pw-record")
            if binary:
                argv = [binary, "--target", source, "--rate", str(SAMPLE_RATE),
                        "--channels", str(CHANNELS), "--format", "s16",
                        "--latency", "50ms", "-"]
        if argv is None:
            raise Missing("no PipeWire reader on this host (parec, pw-record absent)")
        self.argv = argv
        self.proc = None

    def open(self):
        try:
            self.proc = subprocess.Popen(
                self.argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0
            )
        except OSError as exc:
            raise Missing("cannot start %s: %s" % (self.argv[0], exc))

    def read(self, timeout):
        if self.proc is None or self.proc.stdout is None:
            raise Missing("monitor stream is not open")
        chunks = []
        want = self.block_bytes
        deadline = time.monotonic() + timeout
        while want > 0:
            ready, _, _ = select.select([self.proc.stdout], [], [], max(0.0, deadline - time.monotonic()))
            if not ready:
                raise Missing("no audio from the monitor within %.1fs" % timeout)
            chunk = self.proc.stdout.read(min(want, 65536))
            if not chunk:
                raise Missing("the monitor stream ended")
            chunks.append(chunk)
            want -= len(chunk)
        return b"".join(chunks)

    def close(self):
        if self.proc is None:
            return
        proc, self.proc = self.proc, None
        try:
            proc.terminate()
            proc.wait(timeout=2)
        except (OSError, subprocess.TimeoutExpired):
            try:
                proc.kill()
            except OSError:
                pass
        try:
            if proc.stderr is not None:
                proc.stderr.close()
        except OSError:
            pass


def resolve_source(args):
    if args.source:
        return args.source
    binary = shutil.which("pactl")
    if not binary:
        raise Missing("cannot resolve the default sink (pactl absent); pass --source")
    try:
        proc = subprocess.run([binary, "get-default-sink"], capture_output=True,
                              text=True, timeout=DEFAULT_TIMEOUT_S, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Missing("pactl get-default-sink failed: %s" % exc)
    if proc.returncode != 0 or not proc.stdout.strip():
        raise Missing("pactl get-default-sink returned nothing")
    name = proc.stdout.strip().splitlines()[-1].strip()
    if not name:
        raise Missing("pactl get-default-sink returned an empty name")
    return name + ".monitor"


def block_bytes_for(rate_hz):
    frames = int(round(SAMPLE_RATE / float(rate_hz)))
    return max(FRAME_BYTES, frames * FRAME_BYTES)


# ------------------------------------------------------------------------- fixture


def _db(value):
    """Fixture value -> dBFS float. 0.0 stays 0.0; only a missing value floors."""
    num = number(value)
    return FLOOR_DB if num is None else round(max(FLOOR_DB, num), 1)


def load_series(path):
    target = os.path.expanduser(str(path))
    if not os.path.isfile(target):
        raise Caller("no level fixture at %s" % tilde(path))
    data = read_json(path, "level fixture")
    if not isinstance(data, dict):
        raise Malformed("level fixture at %s is not a JSON object" % tilde(path))
    samples = data.get("samples")
    if not isinstance(samples, list) or not samples:
        raise Malformed("level fixture at %s has no samples" % tilde(path))
    out = []
    for item in samples:
        if not isinstance(item, dict):
            raise Malformed("level fixture at %s has a non-object sample" % tilde(path))
        peak = item.get("peak")
        rms = item.get("rms")
        if not isinstance(peak, list) or len(peak) != CHANNELS:
            raise Malformed("level fixture sample has no two-value peak")
        if not isinstance(rms, list) or len(rms) != CHANNELS:
            rms = list(peak)
        out.append(
            {
                "peak": [_db(value) for value in peak],
                "rms": [_db(value) for value in rms],
                "clipped": bool(item.get("clipped")),
            }
        )
    return out, data


def make_series():
    """The committed synthetic series. Deterministic; no host needed.

    Shape: five seconds of speech alternating near/far, three seconds of silence
    at the floor, a three-sample clipped burst, two seconds of speech, three
    seconds of silence. A real capture from the Linux box replaces this file;
    the ``synthetic`` flag in it says so.
    """
    samples = []

    def speech(index):
        # alternating sides, speech-like decay, deterministic
        near = -9.5 - (index % 7) * 1.1
        far = -19.0 - (index % 5) * 1.3
        if (index // 6) % 2:
            near, far = far, near
        return {"peak": [round(near, 1), round(far, 1)],
                "rms": [round(near - 8.5, 1), round(far - 7.5, 1)],
                "clipped": False}

    for index in range(50):
        samples.append(speech(index))
    for _ in range(30):
        samples.append({"peak": [FLOOR_DB, FLOOR_DB], "rms": [FLOOR_DB, FLOOR_DB], "clipped": False})
    for _ in range(3):
        samples.append({"peak": [0.0, -3.0], "rms": [-0.4, -6.2], "clipped": True})
    for index in range(20):
        samples.append(speech(index + 50))
    for _ in range(27):
        samples.append({"peak": [FLOOR_DB, FLOOR_DB], "rms": [FLOOR_DB, FLOOR_DB], "clipped": False})
    return samples


def write_fixture(path):
    samples = make_series()
    head = {
        "note": ("synthetic peak series for the two-channel meter; a real capture from the "
                 "Linux box (parec on the default sink monitor, 10 Hz) replaces it unchanged "
                 "in shape. Regenerate: level.py --make-fixture PATH"),
        "synthetic": True,
        "channels": CHANNELS,
        "rate_hz": 10.0,
        "floor_db": FLOOR_DB,
    }
    lines = ["{"]
    for key in ("note", "synthetic", "channels", "rate_hz", "floor_db"):
        lines.append("  %s: %s," % (json.dumps(key), json.dumps(head[key])))
    lines.append('  "samples": [')
    for index, sample in enumerate(samples):
        comma = "," if index < len(samples) - 1 else ""
        lines.append("    %s%s" % (json.dumps(sample, separators=(",", ":")), comma))
    lines.append("  ]")
    lines.append("}")
    target = os.path.expanduser(str(path))
    parent = os.path.dirname(target) or "."
    os.makedirs(parent, exist_ok=True)
    with open(target, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    return head


def sample_payload(sample, source, at=None, index=None):
    payload = envelope(
        source=source,
        channels=CHANNELS,
        peak=sample["peak"],
        rms=sample["rms"],
        clipped=sample["clipped"],
        at=iso_ms(at if at is not None else time.time()),
    )
    if index is not None:
        payload["index"] = index
    return payload


def live_sample(args, monitor):
    block = monitor.read(args.timeout)
    result = analyse(block)
    return sample_payload(result, "live")


# -------------------------------------------------------------------------- driver


def parse_rate(raw):
    value = number(raw)
    if value is None or value <= 0:
        raise Caller("--rate needs a positive number of samples per second, got %r" % raw)
    if value > MAX_RATE_HZ:
        raise Caller(
            "--rate %.2f is above the %g Hz HUD budget; the meter runs at 10 Hz or slower"
            % (value, MAX_RATE_HZ)
        )
    return value


def stream(args, rate):
    """One JSON object per line. Returns an exit code."""
    compact = True  # a stream is line-oriented by definition
    count = args.count
    index = 0
    start = 0

    if args.fixture:
        series, _ = load_series(args.fixture)
        start = args.index or 0
        if start < 0 or start >= len(series):
            raise Caller("--index %d is outside the fixture (%d samples)" % (start, len(series)))
        monitor = None
    else:
        series = None
        monitor = Monitor(resolve_source(args), block_bytes_for(rate))
        monitor.open()

    period = 1.0 / rate
    next_at = time.monotonic() + period
    try:
        while count is None or index < count:
            if series is not None:
                sample = series[(start + index) % len(series)]
                payload = sample_payload(sample, "fixture", index=start + index)
            else:
                payload = live_sample(args, monitor)
            emit(payload, compact)
            index += 1
            now = time.monotonic()
            if next_at > now:
                time.sleep(next_at - now)
                now = time.monotonic()
            # One period after the later of the scheduled target and the actual
            # wake-up. A loaded host can oversleep by 200 ms; the meter then runs
            # slow for a beat, and it never fires two samples back to back.
            next_at = max(next_at + period, now + period)
    except BrokenPipeError:
        return EXIT_OK
    finally:
        if monitor is not None:
            monitor.close()
    return EXIT_OK


def once(args):
    if args.fixture:
        series, _ = load_series(args.fixture)
        start = args.index or 0
        if start < 0 or start >= len(series):
            raise Caller("--index %d is outside the fixture (%d samples)" % (start, len(series)))
        return sample_payload(series[start], "fixture", index=start)
    monitor = Monitor(resolve_source(args), block_bytes_for(MAX_RATE_HZ))
    monitor.open()
    try:
        return live_sample(args, monitor)
    finally:
        monitor.close()


# ---------------------------------------------------------------------- self-check

_CHILD_ENV = None


def _run_child(argv, env=None, timeout=60):
    proc = subprocess.run(
        [sys.executable, os.path.abspath(__file__)] + argv,
        capture_output=True, text=True, timeout=timeout, check=False,
        env=env or _CHILD_ENV,
    )
    return proc.returncode, proc.stdout, proc.stderr


def _parse_lines(out):
    items = []
    for line in out.splitlines():
        if not line.strip():
            continue
        items.append(json.loads(line))
    return items


def _stamp_epoch(value):
    try:
        base, _, millis = str(value).rstrip("Z").partition(".")
        stamp = datetime.datetime.strptime(base, "%Y-%m-%dT%H:%M:%S")
        return stamp.replace(tzinfo=datetime.timezone.utc).timestamp() + (int(millis or 0) / 1000.0)
    except (TypeError, ValueError):
        return None


def _gaps_ms(items):
    stamps = [_stamp_epoch(item.get("at")) for item in items if isinstance(item, dict)]
    stamps = [stamp for stamp in stamps if stamp is not None]
    return [round((later - earlier) * 1000.0, 1) for earlier, later in zip(stamps, stamps[1:])]


def self_check(args):
    checks = []

    def check(name, ok, detail=""):
        checks.append({"check": name, "ok": bool(ok), "detail": detail})
        sys.stderr.write("%-4s %s%s\n" % ("ok" if ok else "FAIL", name, ("  " + detail) if detail and not ok else ""))
        sys.stderr.flush()

    root = tempfile.mkdtemp(prefix="f7-level-")
    fixture = os.path.join(root, "level.json")
    twice = os.path.join(root, "level-again.json")

    write_fixture(fixture)
    write_fixture(twice)
    first = open(fixture, encoding="utf-8").read()
    second = open(twice, encoding="utf-8").read()
    check("--make-fixture is deterministic", first == second, "lengths %d/%d" % (len(first), len(second)))

    shipped_ok = os.path.isfile(SHIPPED_FIXTURE)
    shipped_same = False
    shipped_synthetic = None
    if shipped_ok:
        shipped_raw = open(SHIPPED_FIXTURE, encoding="utf-8").read()
        shipped_data = json.loads(shipped_raw)
        shipped_synthetic = shipped_data.get("synthetic")
        # A synthetic series must be exactly what the generator writes. A real
        # capture from the Linux box replaces it with the same shape and its own
        # numbers, and then only the shape is asserted.
        shipped_same = (shipped_raw == first) if shipped_synthetic else (
            shipped_data.get("channels") == CHANNELS
            and shipped_data.get("floor_db") == FLOOR_DB
            and isinstance(shipped_data.get("samples"), list) and len(shipped_data["samples"]) >= 100
        )
    check(
        "shipped fixture matches its generator (or a real capture of the same shape)",
        shipped_ok and shipped_same,
        "shipped=%s synthetic=%s same=%s" % (shipped_ok, shipped_synthetic, shipped_same),
    )

    # shape
    rc, out, err = _run_child(["--once", "--fixture", fixture, "--json"])
    payload = json.loads(out) if out.strip() else None
    ok = (
        rc == 0 and isinstance(payload, dict) and payload.get("ok") is True
        and payload.get("source") == "fixture"
        and payload.get("channels") == 2
        and isinstance(payload.get("peak"), list) and len(payload["peak"]) == 2
        and all(isinstance(value, float) for value in payload["peak"])
        and isinstance(payload.get("rms"), list) and len(payload["rms"]) == 2
        and isinstance(payload.get("clipped"), bool)
        and isinstance(payload.get("at"), str) and payload["at"].endswith("Z")
        and "." in payload["at"]
    )
    check("--once fixture shape", ok, "rc=%s out=%r err=%r" % (rc, out[:200], err[-200:]))

    # silence is the floor, not zero
    rc, out, _ = _run_child(["--once", "--fixture", fixture, "--json", "--index", "60"])
    payload = json.loads(out) if out.strip() else None
    check(
        "silence reports the floor, not zero",
        rc == 0 and isinstance(payload, dict) and payload.get("peak") == [FLOOR_DB, FLOOR_DB]
        and payload.get("rms") == [FLOOR_DB, FLOOR_DB] and payload.get("clipped") is False,
        "payload=%r" % (payload,),
    )

    # clipping is detected
    rc, out, _ = _run_child(["--once", "--fixture", fixture, "--json", "--index", "81"])
    payload = json.loads(out) if out.strip() else None
    check(
        "clipped burst reports clipped:true",
        rc == 0 and isinstance(payload, dict) and payload.get("clipped") is True
        and payload.get("peak", [None])[0] == 0.0,
        "payload=%r" % (payload,),
    )

    # parity: --once is the first streamed line
    rc_once, out_once, _ = _run_child(["--once", "--fixture", fixture, "--json"])
    started = time.monotonic()
    rc, out, err = _run_child(["--rate", "10", "--count", "20", "--fixture", fixture, "--json"])
    elapsed = time.monotonic() - started
    try:
        lines = _parse_lines(out)
    except ValueError as exc:
        lines = []
        err = "%s | %s" % (err, exc)
    once_payload = json.loads(out_once) if out_once.strip() else {}
    drop = {"at", "generated_at"}
    parity = bool(lines) and {k: v for k, v in lines[0].items() if k not in drop} == \
        {k: v for k, v in once_payload.items() if k not in drop}
    check(
        "20 lines at 10 Hz, first line equals --once",
        rc == 0 and len(lines) == 20 and parity,
        "rc=%s lines=%d parity=%s err=%r" % (rc, len(lines), parity, err[-200:]),
    )
    check(
        "10 Hz pacing is real (20 lines ~1.9 s)",
        1.6 <= elapsed <= 6.0,
        "elapsed=%.2fs" % elapsed,
    )
    gaps = _gaps_ms(lines)
    check(
        "no two samples closer than 50 ms (never faster than the budget)",
        bool(gaps) and min(gaps) >= 50,
        "min gap %sms of %d" % (min(gaps) if gaps else None, len(gaps)),
    )

    # rate limit and bad rates
    for bad_rate, label in (("11", "above 10 Hz"), ("0", "zero"), ("-1", "negative"), ("abc", "not a number")):
        rc, out, _ = _run_child(["--rate", bad_rate, "--fixture", fixture, "--json", "--count", "1"])
        payload = json.loads(out) if out.strip() else None
        check(
            "--rate %s (%s) refused with exit 2" % (bad_rate, label),
            rc == 2 and isinstance(payload, dict) and payload.get("ok") is False,
            "rc=%s payload=%r" % (rc, payload),
        )

    # missing / malformed / unknown flag
    rc, out, _ = _run_child(["--once", "--fixture", os.path.join(root, "nope.json"), "--json"])
    payload = json.loads(out) if out.strip() else None
    check("missing named fixture -> exit 2", rc == 2 and isinstance(payload, dict) and payload.get("ok") is False, "rc=%s" % rc)

    bad = os.path.join(root, "bad.json")
    with open(bad, "w", encoding="utf-8") as handle:
        handle.write("{oops")
    rc, out, _ = _run_child(["--once", "--fixture", bad, "--json"])
    payload = json.loads(out) if out.strip() else None
    check("malformed fixture -> ok:false exit 0", rc == 0 and isinstance(payload, dict) and payload.get("ok") is False, "rc=%s" % rc)

    empty = os.path.join(root, "empty.json")
    with open(empty, "w", encoding="utf-8") as handle:
        json.dump({"samples": []}, handle)
    rc, out, _ = _run_child(["--once", "--fixture", empty, "--json"])
    payload = json.loads(out) if out.strip() else None
    check("empty series -> ok:false exit 0", rc == 0 and isinstance(payload, dict) and payload.get("ok") is False, "rc=%s" % rc)

    rc, _, err = _run_child(["--bogus-flag"])
    check("unknown flag -> exit 2, no traceback", rc == 2 and "Traceback" not in err, "rc=%s" % rc)

    # live absence: no PipeWire on this host -> ok:false, exit 0
    bare = dict(os.environ)
    bare["PATH"] = root  # nothing in here
    rc, out, _ = _run_child(["--once", "--json"], env=bare)
    payload = json.loads(out) if out.strip() else None
    check(
        "no PipeWire on this host -> ok:false exit 0",
        rc == 0 and isinstance(payload, dict) and payload.get("ok") is False
        and ("PipeWire" in str(payload.get("reason", "")) or "pactl" in str(payload.get("reason", ""))),
        "rc=%s payload=%r" % (rc, payload),
    )

    shutil.rmtree(root, ignore_errors=True)
    failed = [item for item in checks if not item["ok"]]
    emit({"ok": not failed, "source": SOURCE, "self_check": True, "checks": checks},
         bool(getattr(args, "json", False)))
    return 0 if not failed else 1


# ---------------------------------------------------------------------------- cli


def build_parser():
    parser = argparse.ArgumentParser(
        description="two-channel peak level source for the v5 HUD meter (10 Hz max)"
    )
    parser.add_argument("--once", action="store_true", help="print one sample and exit")
    parser.add_argument("--rate", metavar="HZ", default=None,
                        help="stream one JSON object per line at HZ samples per second (max 10)")
    parser.add_argument("--count", type=int, default=None, metavar="N",
                        help="stop after N samples (default: until the reader is killed)")
    parser.add_argument("--index", type=int, default=None, metavar="I",
                        help="fixture mode: start at sample I")
    parser.add_argument("--fixture", metavar="PATH", help="replay a recorded series instead of the host")
    parser.add_argument("--source", metavar="NODE", default=None,
                        help="PipeWire monitor node (default: the default sink's .monitor)")
    parser.add_argument("--json", action="store_true", help="one compact JSON line per sample")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S, metavar="S",
                        help="seconds to wait for a block of audio (default %g)" % DEFAULT_TIMEOUT_S)
    parser.add_argument("--make-fixture", metavar="PATH", default=None,
                        help="write the synthetic fixture series and exit")
    parser.add_argument("--self-check", action="store_true", help="run the built-in checks and exit")
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.make_fixture:
        try:
            write_fixture(args.make_fixture)
        except OSError as exc:
            emit({"ok": False, "source": SOURCE, "generated_at": iso_ms(time.time()),
                  "reason": tilde_text("cannot write %s: %s" % (args.make_fixture, exc)),
                  "kind": "caller"}, True)
            return EXIT_PROGRAMMING
        emit({"ok": True, "source": SOURCE, "generated_at": iso_ms(time.time()),
              "written": tilde(args.make_fixture), "samples": len(make_series()),
              "synthetic": True}, args.json)
        return EXIT_OK

    if args.self_check:
        return self_check(args)

    try:
        if args.once == (args.rate is not None):
            raise Caller("choose one of --once or --rate HZ")
        if args.count is not None and args.count < 1:
            raise Caller("--count must be at least 1")
        if args.rate is not None:
            rate = parse_rate(args.rate)
            return stream(args, rate)
        payload = once(args)
    except Caller as exc:
        emit(failure(exc), bool(args.json))
        return EXIT_PROGRAMMING
    except DataProblem as exc:
        emit(failure(exc), bool(args.json))
        return EXIT_OK
    except (KeyboardInterrupt, SystemExit):
        raise
    except BaseException as exc:  # noqa: BLE001
        emit({"ok": False, "source": SOURCE, "generated_at": iso_ms(time.time()),
              "reason": tilde_text("programming error: %s: %s" % (type(exc).__name__, exc)),
              "kind": "programming"}, bool(args.json))
        return EXIT_PROGRAMMING

    emit(payload, bool(args.json))
    return EXIT_OK


def _terminate(signum, frame):  # pragma: no cover - signal path
    raise SystemExit(EXIT_OK)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _terminate)
    sys.exit(main())
