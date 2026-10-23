#!/usr/bin/env python3
"""hudfix LOCAL AI actions: status, unload, clear-slot, VRAM, installed models.

Card F8d of the HUD v5 maintenance engine. This module owns one slice of the
``hudfix`` CLI: the LOCAL AI utility view (``MAIN-SCREEN-BUILD.md``, "UTILITY
VIEWS": "Local AI (unload model, clear slot cache, VRAM)"). It imports nothing
out of ``hudfix.py``; it stands alone and exports a registry that F8a's entry
point merges:

    ACTIONS = {"<name>": {"class": ..., "doc": ..., "plan": callable,
                          "run": callable, "linux_only": bool}}

``plan(ctx=None)`` is side-effect free: it reads state, writes nothing, spawns
nothing that changes anything, and makes no network call. ``run(ctx, confirm)``
performs the action; ``confirm`` must be the action name for every
``reversible`` action. ``ctx`` is an ``argparse.Namespace`` or a plain dict;
missing keys fall back to the defaults below. This module also has its own CLI
(``list`` / ``plan`` / ``run`` / ``--self-check``) so it is testable with no
hudfix.py present.

HOST REALITY (checked 2026-10-23, ``recon/05-local-ai.md``): local inference
runs on the Linux box (chief), never on this Mac. The live sources are
``/run/user/1000/chief/metrics.json``, llama-swap on ``127.0.0.1:18080`` and
``nvidia-smi``. On this Mac every one of those is absent, so:

* ``localai.status`` is a ``read`` that works anywhere: a fixture on the Mac,
  the real metrics file on Linux. A missing file is honest absence
  (``ok:false`` plus a reason, exit 0), the same answer F7's ``chief.py`` gives.
* ``localai.vram``, ``localai.models``, ``localai.unload`` and
  ``localai.clear-slot`` are ``linux_only``: ``plan`` refuses on this Mac with
  ``{"ok": false, "reason": "not this host: ..."}`` and ``run`` exits 2. That is
  the correct behaviour, not a gap. ``--fixture`` still produces the full plan
  here, because the plan is what Linux pre-flights and what the UI renders; the
  fixture path never acts.

LIVE MECHANISMS (both are upstream-documented, nothing is invented):

* unload: ``POST http://127.0.0.1:18080/api/models/unload/<model_id>`` on
  llama-swap (README, "manually unload models"; the lab runs it on 18080).
  llama-swap stops the llama-server child; the next request reloads it.
* clear-slot: ``POST http://127.0.0.1:18080/slots/<id>?action=erase`` on
  llama.cpp's server API (``POST /slots/{id_slot}?action=erase`` in
  ``tools/server/README.md``). llama-swap forwards the request to the active
  backend; if the live box does not, point ``--slot-url`` at the llama-server
  port instead.

KEY PARITY WITH F7 ``chief.py`` (branch ``v5/f7-callcap-chief``, head 5d7c2e5):
the dock and this utility view must not describe the same VRAM differently, so
the status payload reuses F7's key names and semantics exactly:

    running, model, vram_gb, tokens_per_s, metrics_age_s, stale,
    metrics_age_reason, snapshot_ts,
    vram_total_gb (when the file has a total), queue (when present)

``vram_gb`` is ``round(vram_used_mib / 1024.0, 2)`` in both modules and
``stale`` is ``age > 5.0 s`` in both (the writer ticks at 1 Hz). Fixture mode
is F7's fixture mode: no clock is read, ``metrics_age_s`` and ``stale`` are
null with a ``metrics_age_reason``, and ``snapshot_ts`` carries the snapshot's
own ``ts`` as UTC ISO. This module adds the keys the card requires, ``slots``
and ``slot_occupancy``, plus ``action`` and ``class`` so a log row can name the
read, and never renames an F7 key. One deliberate difference remains: F7's
``generated_at`` is the host clock even in ``--fixture`` mode, which the feeds
brief forbids ("a fixture run must produce byte-identical output"); here a
fixture payload takes ``generated_at`` from the fixture's ``ts`` (or null with
``generated_at_reason``). On the live path the age is the metrics file's mtime
age, as in F7.

EXIT CODES follow the feeds brief: 0 for data and honest absence, including a
``linux_only`` read action refused on the wrong host, and 2 only for a
programming error or a refusal to act (no ``--confirm``, in flight or unknown
in flight, fixture mode, wrong host for a reversible run).

SAFETY. ``localai.unload`` is the one action that can interrupt someone else's
work. Its plan names the model, the VRAM it frees, the reload cost, and every
busy slot with its request id and session. ``run`` refuses without
``--confirm localai.unload``, refuses while a request is in flight, and refuses
when the metrics cannot say whether a request is in flight, unless ``--force``
is given too. A slot row with no ``busy`` key counts as unknown, never as
idle, so an incomplete metrics file fails closed. A POST that cannot reach the
host is reported as an unknown outcome and exits 2, because the request may
have been sent. ``localai.clear-slot`` applies the same in-flight guard to the
slot it is about to erase. Nothing here deletes a file. The self-check never
unloads a model, never opens a socket and never touches a process.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from contextlib import redirect_stdout

EXIT_OK = 0
EXIT_PROGRAMMING = 2

HOME = os.path.expanduser("~")
MODULE = "hudfix_localai"
# The envelope allows fixture or live only (feeds brief, output shape).
SOURCE = "live"

DEFAULT_METRICS = "/run/user/1000/chief/metrics.json"
DEFAULT_CACHE = "~/.local/state/nexuslink/localai.json"
DEFAULT_LOG = "~/.local/state/nexuslink/hudfix.log"
DEFAULT_LLAMA_SWAP_URL = "http://127.0.0.1:18080"

CACHE_TTL_S = 10.0
MIB_PER_GB = 1024.0
STALE_AFTER_S = 5.0  # the writer runs at 1 Hz; five missed ticks is stale
VRAM_TIMEOUT_S = 4.0
HTTP_TIMEOUT_S = 10.0
MAX_SCAN_DEPTH = 3

VRAM_COMMAND = [
    "nvidia-smi",
    "--query-compute-apps=pid,process_name,used_memory",
    "--format=csv,noheader,nounits",
]

RELOAD_KEYS = ("model_load_s", "load_time_s", "last_load_s")


# --------------------------------------------------------------- shared plumbing
# The same generic half as F7's chief.py, so each reader stands alone from a
# bare checkout and the two files describe numbers the same way.


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
    """The caller named a file that is not there. Exit 2, per the feed contract."""

    kind = "caller"


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc)


def iso(epoch):
    if epoch is None or isinstance(epoch, bool):
        return None
    try:
        value = float(epoch)
    except (TypeError, ValueError):
        return None
    if value != value or value in (float("inf"), float("-inf")):
        return None
    try:
        stamp = datetime.datetime.fromtimestamp(value, datetime.timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None
    return stamp.strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_now():
    return iso(time.time())


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


def integer(value):
    out = number(value)
    return int(out) if out is not None else None


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


def pick(mapping, *keys):
    """First present, non-null value among keys (a partial object is normal)."""
    for key in keys:
        if key in mapping and mapping[key] is not None:
            return mapping[key]
    return None


def emit(payload, compact):
    if compact:
        line = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    else:
        line = json.dumps(payload, ensure_ascii=False, indent=2)
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


def write_json(path, payload):
    target = os.path.expanduser(str(path))
    parent = os.path.dirname(target) or "."
    os.makedirs(parent, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=parent, prefix=".tmp-", suffix=".json", delete=False
    )
    try:
        with handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(handle.name, target)
    except BaseException:
        try:
            os.unlink(handle.name)
        except OSError:
            pass
        raise


def cache_get(path, key, mtime_ns=None):
    try:
        with open(os.path.expanduser(path), "r", encoding="utf-8") as handle:
            blob = json.load(handle)
    except (OSError, ValueError):
        return None
    if not isinstance(blob, dict) or blob.get("key") != key:
        return None
    payload = blob.get("payload")
    if not isinstance(payload, dict):
        return None
    stamp = number(blob.get("at"))
    if stamp is None:
        return None
    age = time.time() - stamp
    if not (0 <= age < CACHE_TTL_S):
        return None
    if mtime_ns is not None and blob.get("mtime_ns") != mtime_ns:
        return None
    return payload, age


def cache_put(path, key, payload, mtime_ns=None):
    try:
        write_json(path, {
            "key": key,
            "at": time.time(),
            "mtime_ns": mtime_ns,
            "payload": payload,
        })
    except OSError:
        pass


def shell(argv, timeout):
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)
        return proc.returncode, proc.stdout or "", proc.stderr or ""
    except FileNotFoundError:
        return 127, "", "not found: %s" % argv[0]
    except subprocess.TimeoutExpired:
        return 124, "", "timed out after %.1fs: %s" % (timeout, " ".join(argv))
    except OSError as exc:
        return 126, "", str(exc)


def host_is_linux():
    return sys.platform.startswith("linux")


# ------------------------------------------------------------- action metadata
# Single source of truth for the registry and for refusal reasons. The card's
# four classes: read, safe, reversible, destructive. Nothing here is
# destructive: unload and clear-slot are both reversible (a reload costs the
# time named in the plan, nothing is deleted).

ORDER = ["localai.status", "localai.unload", "localai.clear-slot", "localai.vram", "localai.models"]

CLASSES = {
    "localai.status": "read",
    "localai.unload": "reversible",
    "localai.clear-slot": "reversible",
    "localai.vram": "read",
    "localai.models": "read",
}

LINUX_ONLY = {
    "localai.status": False,
    "localai.unload": True,
    "localai.clear-slot": True,
    "localai.vram": True,
    "localai.models": True,
}

DOCS = {
    "localai.status": (
        "Read the chief metrics file and report the loaded model, VRAM, tokens/s, "
        "slot occupancy and metrics age. Read only; no model is touched."
    ),
    "localai.unload": (
        "Unload the loaded model through llama-swap so its VRAM is freed. Reversible: "
        "the next request reloads the model at the cost named in the plan. Refuses "
        "without --confirm and, unless --force, while a request is in flight."
    ),
    "localai.clear-slot": (
        "Erase one llama.cpp slot's cached prompt (POST /slots/<id>?action=erase). "
        "Reversible: the slot stays usable and the caller re-prefills. Names the "
        "request and session that lose their cache; refuses on a busy slot without --force."
    ),
    "localai.vram": (
        "Report VRAM by process from nvidia-smi on the Linux box. Read only."
    ),
    "localai.models": (
        "List installed model files with their exact size on disk, so the utility view "
        "can show the disk cost beside the unload action. Read only, never deletes."
    ),
}


# ------------------------------------------------------------------- selection


def opt(ctx, name, default=None):
    """Read one option from a dict or an argparse.Namespace, defaulting cleanly."""
    if ctx is None:
        return default
    if isinstance(ctx, dict):
        value = ctx.get(name, default)
    else:
        value = getattr(ctx, name, default)
    return default if value is None else value


def action_source(ctx):
    return "fixture" if opt(ctx, "fixture") else "live"


def metrics_path(ctx):
    raw = opt(ctx, "metrics") or DEFAULT_METRICS
    return os.path.abspath(os.path.expanduser(str(raw)))


def cache_path(ctx):
    raw = opt(ctx, "cache") or DEFAULT_CACHE
    return os.path.abspath(os.path.expanduser(str(raw)))


def cache_file(ctx, name):
    """A per-read cache beside the status cache: localai-vram.json, localai-models.json."""
    base = cache_path(ctx)
    directory = os.path.dirname(base) or "."
    stem = os.path.splitext(os.path.basename(base))[0] or "localai"
    return os.path.join(directory, "%s-%s.json" % (stem, name))


def cached_read(ctx, name, builder, identity=""):
    """Reads are cached, never faster than 10 s; a fixture never touches the cache.

    The key carries the identity of the source as well as the action name, so a
    different models directory (or another fixture) is never served the other
    source's answer inside the TTL.
    """
    if opt(ctx, "fixture") or opt(ctx, "no_cache", False):
        return builder(ctx)
    path = cache_file(ctx, name)
    key = "%s|%s" % (name, identity)
    hit = cache_get(path, key)
    if hit is not None:
        payload, age = hit
        fresh = dict(payload)
        fresh["cached"] = True
        fresh["cache_age_s"] = round(age, 1)
        return fresh
    payload = builder(ctx)
    payload["cached"] = False
    cache_put(path, key, payload)
    return payload


def read_identity(ctx, name):
    """What a cached read actually read: the fixture, the VRAM tool or the model sources."""
    if opt(ctx, "fixture"):
        return os.path.abspath(os.path.expanduser(str(opt(ctx, "fixture"))))
    if name == "vram":
        return opt(ctx, "nvidia_smi") or VRAM_COMMAND[0]
    return "%s|%s" % (models_dir(ctx) or "-", metrics_path(ctx))


def log_path(ctx):
    raw = opt(ctx, "log") or DEFAULT_LOG
    return os.path.abspath(os.path.expanduser(str(raw)))


def llama_swap_url(ctx):
    raw = opt(ctx, "llama_swap_url") or DEFAULT_LLAMA_SWAP_URL
    return str(raw).rstrip("/")


def slot_base_url(ctx):
    raw = opt(ctx, "slot_url") or llama_swap_url(ctx)
    return str(raw).rstrip("/")


def models_dir(ctx):
    raw = opt(ctx, "models_dir") or os.environ.get("CHIEF_MODELS_DIR") or ""
    return os.path.abspath(os.path.expanduser(str(raw))) if raw else ""


def fixture_json(ctx):
    raw = opt(ctx, "fixture")
    if not raw:
        raise Missing("no fixture path given")
    target = os.path.expanduser(str(raw))
    if not os.path.isfile(target):
        raise Caller("no local-ai fixture at %s" % tilde(raw))
    return read_json(target, "local-ai fixture")


def fixture_metrics(ctx):
    data = fixture_json(ctx)
    if isinstance(data, dict) and isinstance(data.get("metrics"), dict):
        data = data["metrics"]
    if not isinstance(data, dict):
        raise Malformed("local-ai fixture at %s is not a metrics object" % tilde(opt(ctx, "fixture")))
    return data


# --------------------------------------------------------------------- metrics


def parse_slots(data):
    """metrics.json -> (slots, reason). Tolerates a missing or partial array."""
    raw = data.get("slots")
    if not isinstance(raw, list):
        return None, "metrics.json carries no slots array"
    rows = []
    for index, entry in enumerate(raw):
        if not isinstance(entry, dict):
            continue
        busy = pick(entry, "busy", "is_processing")
        slot_id = integer(pick(entry, "slot", "id_slot"))
        rows.append({
            "slot": slot_id if slot_id is not None else index,
            "busy": bool(busy) if busy is not None else None,
            "request_id": text(pick(entry, "request_id", "id_task")),
            "session": text(pick(entry, "session", "session_id", "caller")),
            "model": text(entry.get("model")),
            "tokens_cached": integer(pick(entry, "tokens_cached", "n_past")),
        })
    return rows, None


def slot_occupancy(data, slots):
    total = integer(data.get("slot_count"))
    if total is None or total < 0:
        total = len(slots)
    used = len([row for row in slots if row.get("busy") is True])
    unknown = len([row for row in slots if row.get("busy") is None])
    occupancy: dict = {"used": used, "total": total}
    if unknown:
        # A row with no busy key is not idle: say so instead of reporting zero.
        occupancy["unknown"] = unknown
        occupancy["reason"] = "metrics.json gives no busy flag for %d slot(s)" % unknown
    return occupancy


def metrics_payload(data, age_s, source, generated_at):
    """metrics.json shape -> the status payload. Never invents a number."""
    model = text(data.get("model"))
    used = number(data.get("vram_used_mib"))
    total = number(data.get("vram_total_mib"))
    payload = {
        "ok": True,
        "source": source,
        "generated_at": generated_at,
        "action": "localai.status",
        "class": CLASSES["localai.status"],
        "running": bool(model),
        "model": model,
        "vram_gb": round(used / MIB_PER_GB, 2) if used is not None else None,
        "tokens_per_s": number(data.get("tokens_per_s")),
        "metrics_age_s": round(age_s, 1) if age_s is not None else None,
    }
    if "model" not in data:
        payload["running_reason"] = (
            "metrics carries no model key; the snapshot does not say what is loaded"
        )
    if total is not None:
        payload["vram_total_gb"] = round(total / MIB_PER_GB, 2)
    queue = number(data.get("queue"))
    if queue is not None:
        payload["queue"] = int(queue)
    payload["stale"] = (age_s > STALE_AFTER_S) if age_s is not None else None
    snapshot_ts = iso(number(data.get("ts")))
    payload["snapshot_ts"] = snapshot_ts
    if snapshot_ts is None:
        payload["snapshot_ts_reason"] = "metrics carries no ts"
    slots, slots_reason = parse_slots(data)
    payload["slots"] = slots
    if slots is None:
        payload["slots_reason"] = slots_reason
        payload["slot_occupancy"] = None
    else:
        payload["slot_occupancy"] = slot_occupancy(data, slots)
    if age_s is None:
        if source == "fixture":
            payload["metrics_age_reason"] = (
                "fixture mode reads no clock; age and stale are not measured"
            )
        else:
            payload["metrics_age_reason"] = (
                "cannot read the metrics file's mtime; age and stale are not measured"
            )
    if generated_at is None:
        payload["generated_at_reason"] = "metrics carries no ts"
    return payload


def load_metrics(ctx):
    """-> (raw metrics dict, age_s, source, generated_at). Reads only.

    Fixture mode reads no clock at all: the age is None and the payload says
    why. On the live path the age is the metrics file's mtime age, as in F7.
    """
    if opt(ctx, "fixture"):
        data = fixture_metrics(ctx)
        return data, None, "fixture", iso(number(data.get("ts"))), None
    path = metrics_path(ctx)
    data = read_json(path, "chief metrics file")
    if not isinstance(data, dict):
        raise Malformed("chief metrics at %s is not a JSON object" % tilde(path))
    mtime_ns, age = None, None
    try:
        info = os.stat(path)
        mtime_ns = int(info.st_mtime_ns)
        age = max(0.0, time.time() - info.st_mtime)
    except OSError:
        pass
    return data, age, "live", iso_now(), mtime_ns


def age_payload(payload, mtime_ns):
    """Re-derive the age from the file's mtime; a cache hit must not freeze it."""
    fresh = dict(payload)
    if mtime_ns is None:
        return fresh
    age = max(0.0, time.time() - (mtime_ns / 1000000000.0))
    fresh["metrics_age_s"] = round(age, 1)
    fresh["stale"] = age > STALE_AFTER_S
    return fresh


def status_payload(ctx=None, use_cache=None):
    if opt(ctx, "fixture"):
        data, age, source, generated_at, _mtime = load_metrics(ctx)
        return metrics_payload(data, age, source, generated_at)

    path = metrics_path(ctx)
    want_cache = (not opt(ctx, "no_cache", False)) if use_cache is None else bool(use_cache)
    key = "status|%s" % path
    mtime_ns = None
    try:
        mtime_ns = int(os.stat(path).st_mtime_ns)
    except OSError:
        pass
    if want_cache and mtime_ns is not None:
        hit = cache_get(cache_path(ctx), key, mtime_ns)
        if hit is not None:
            cached, age = hit
            fresh = age_payload(cached, mtime_ns)
            fresh["cached"] = True
            fresh["cache_age_s"] = round(age, 1)
            return fresh
    data, age, source, generated_at, mtime_ns = load_metrics(ctx)
    payload = metrics_payload(data, age, source, generated_at)
    payload["cached"] = False
    if want_cache:
        cache_put(cache_path(ctx), key, payload, mtime_ns)
    return payload


def inflight_rows(payload):
    """Busy slots, or None when the metrics cannot say. Never invents zero."""
    slots = payload.get("slots")
    if slots is None:
        return None
    return [row for row in slots if row.get("busy") is True]


def unknown_slots(payload):
    """Slot rows whose busy flag is absent: the metrics cannot say. Unknown counts as unknown."""
    slots = payload.get("slots")
    if slots is None:
        return []
    return [row for row in slots if row.get("busy") is None]


def slot_label(row):
    """One slot in a sentence: 'slot 1 request req_7f3a (session chief-voice/...)'."""
    label = "slot %s" % row.get("slot")
    if row.get("request_id"):
        label += " request %s" % row["request_id"]
    if row.get("session"):
        label += " (session %s)" % row["session"]
    return label


def reload_cost(data):
    for key in RELOAD_KEYS:
        value = number(data.get(key))
        if value is not None:
            return value, "metrics.%s" % key
    return None, None


# ------------------------------------------------------------------------ vram


def parse_vram_row(entry):
    used_mib = number(pick(entry, "used_mib", "used_memory", "memory"))
    if used_mib is not None and used_mib == int(used_mib):
        used_mib = int(used_mib)
    return {
        "pid": integer(pick(entry, "pid")),
        "process": text(pick(entry, "process", "process_name", "name")),
        "used_mib": used_mib,
        "used_gb": round(used_mib / MIB_PER_GB, 2) if used_mib is not None else None,
    }


def parse_vram_csv(output):
    rows = []
    for line in output.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = [part.strip() for part in line.split(",")]
        if len(parts) < 3:
            continue
        rows.append(parse_vram_row({
            "pid": parts[0],
            "process_name": parts[1],
            "used_memory": parts[2],
        }))
    return rows


def vram_payload(ctx=None):
    rows = None
    if opt(ctx, "fixture"):
        data = fixture_json(ctx)
        if isinstance(data, list):
            rows = data
        elif isinstance(data, dict):
            for key in ("vram_processes", "vram", "processes"):
                if isinstance(data.get(key), list):
                    rows = data[key]
                    break
        if rows is None:
            raise Missing("local-ai fixture carries no vram_processes array")
        source, generated_at = "fixture", iso(number(data.get("ts"))) if isinstance(data, dict) else None
    else:
        exe = opt(ctx, "nvidia_smi") or "nvidia-smi"
        resolved = shutil.which(exe) if not os.path.isabs(exe) else (exe if os.path.exists(exe) else None)
        if not resolved:
            raise Missing("nvidia-smi not on this host; VRAM by process is a Linux read")
        rc, out, err = shell([resolved] + VRAM_COMMAND[1:], VRAM_TIMEOUT_S)
        if rc != 0:
            raise DataProblem(
                "nvidia-smi failed (exit %d): %s" % (rc, text(err) or text(out) or "no output")
            )
        rows = parse_vram_csv(out)
        source, generated_at = "live", iso_now()

    parsed = [parse_vram_row(row) if isinstance(row, dict) else None for row in rows]
    parsed = [row for row in parsed if row is not None]
    known = [row["used_mib"] for row in parsed if row["used_mib"] is not None]
    total = sum(known) if known else 0
    total_mib = int(total) if float(total) == int(total) else round(total, 1)
    complete = len(known) == len(parsed)
    payload = {
        "ok": True,
        "source": source,
        "generated_at": generated_at,
        "action": "localai.vram",
        "class": CLASSES["localai.vram"],
        "processes": parsed,
        "count": len(parsed),
        "total_mib": total_mib,
        "total_gb": round(total_mib / MIB_PER_GB, 2),
        "total_bytes": int(total_mib * 1024 * 1024) if complete else None,
        "bytes_complete": complete,
    }
    if not complete:
        payload["total_reason"] = "one or more processes report no VRAM figure"
    return payload


# ---------------------------------------------------------------------- models


def parse_model_row(entry):
    size = number(pick(entry, "bytes", "size_bytes", "size"))
    loaded = entry.get("loaded") if isinstance(entry.get("loaded"), bool) else None
    return {
        "name": text(pick(entry, "name", "file", "path")),
        "model_id": text(pick(entry, "model_id", "id")),
        "file": text(pick(entry, "file", "path")),
        "bytes": int(size) if size is not None else None,
        "size_gb": round(size / (1024.0 ** 3), 2) if size is not None else None,
        "loaded": loaded,
    }


def scan_models(root):
    rows = []
    root = os.path.abspath(root)
    for base, dirs, files in os.walk(root):
        depth = base[len(root):].count(os.sep)
        if depth >= MAX_SCAN_DEPTH:
            dirs[:] = []
        dirs[:] = sorted([name for name in dirs if not name.startswith(".")])
        for name in sorted(files):
            if not name.lower().endswith(".gguf"):
                continue
            full = os.path.join(base, name)
            try:
                size = os.stat(full).st_size
            except OSError:
                continue
            rows.append({
                "name": name[:-len(".gguf")],
                "model_id": None,
                "file": os.path.relpath(full, root),
                "bytes": size,
                "loaded": None,
            })
    return rows


def models_payload(ctx=None):
    rows = None
    source, generated_at, detail = "fixture", None, "fixture"

    if opt(ctx, "fixture"):
        data = fixture_json(ctx)
        if isinstance(data, list):
            rows = data
        elif isinstance(data, dict) and isinstance(data.get("models"), list):
            rows = data["models"]
        if rows is None:
            raise Missing("local-ai fixture carries no models array")
        if isinstance(data, dict):
            generated_at = iso(number(data.get("ts")))
    else:
        generated_at = iso_now()
        try:
            data, _age, _source, _gen, _mtime = load_metrics(ctx)
            if isinstance(data.get("models"), list):
                rows = data["models"]
                detail = "metrics"
        except DataProblem:
            rows = None
        if rows is None:
            root = models_dir(ctx)
            if not root:
                raise Missing(
                    "no models directory configured (--models-dir or CHIEF_MODELS_DIR) "
                    "and metrics.json carries no models array"
                )
            if not os.path.isdir(root):
                raise Missing("no models directory at %s" % tilde(root))
            rows = scan_models(root)
            detail = "directory"

    parsed = [parse_model_row(row) if isinstance(row, dict) else None for row in rows]
    parsed = [row for row in parsed if row is not None]
    known = [row["bytes"] for row in parsed if row["bytes"] is not None]
    total_bytes = sum(known)
    payload = {
        "ok": True,
        "source": source,
        "generated_at": generated_at,
        "action": "localai.models",
        "class": CLASSES["localai.models"],
        "models": parsed,
        "count": len(parsed),
        "bytes": total_bytes,
        "bytes_complete": len(known) == len(parsed),
        "source_detail": detail,
    }
    if payload["bytes_complete"] is not True:
        payload["bytes_reason"] = "one or more model files have no size on disk"
    if not opt(ctx, "fixture"):
        payload["models_dir"] = tilde(models_dir(ctx)) or None
    loaded = [row["model_id"] or row["name"] for row in parsed if row.get("loaded") is True]
    payload["loaded_models"] = loaded
    return payload


# ----------------------------------------------------------------------- plans


def generated_at(ctx):
    """The stamp a payload carries: now on the live path, the fixture's own ts in fixture mode.

    The feeds brief forbids reading host state in fixture mode, so a fixture
    without a ts gets null and a reason rather than a plausible-looking clock.
    """
    if not opt(ctx, "fixture"):
        return iso_now()
    try:
        data = fixture_json(ctx)
    except DataProblem:
        return None
    return iso(number(data.get("ts"))) if isinstance(data, dict) else None


def add_generated_at(payload, ctx):
    """Put generated_at on a payload, with a reason when a fixture cannot supply one."""
    payload["generated_at"] = generated_at(ctx)
    if payload["generated_at"] is None:
        payload["generated_at_reason"] = (
            "no fixture ts: fixture mode never reads the host clock"
        )
    return payload


def base_plan(action, ctx, items, would, bytes_total=None, bytes_reason=None, **extra):
    payload = {
        "ok": True,
        "source": action_source(ctx),
        "action": action,
        "class": CLASSES[action],
        "linux_only": LINUX_ONLY[action],
        "doc": DOCS[action],
        "items": items,
        "count": len(items),
        "bytes": bytes_total,
    }
    add_generated_at(payload, ctx)
    if bytes_total is None and bytes_reason:
        payload["bytes_reason"] = bytes_reason
    payload["would"] = would
    payload.update(extra)
    return payload


def plan_failure(action, ctx, reason, kind="data"):
    payload = {
        "ok": False,
        "source": action_source(ctx),
        "action": action,
        "class": CLASSES[action],
        "linux_only": LINUX_ONLY[action],
        "doc": DOCS[action],
        "kind": kind,
        "reason": tilde_text(reason),
        "items": [],
        "count": 0,
        "bytes": None,
    }
    return add_generated_at(payload, ctx)


def host_refusal(action):
    reason = (
        "not this host: local inference runs on Linux only (chief, metrics at "
        "/run/user/1000/chief/metrics.json); this Mac has no llama-swap, no llama-server "
        "and no nvidia-smi, so %s cannot run here. Use --fixture to read the documented "
        "plan from a snapshot." % action
    )
    return {
        "ok": False,
        "source": "live",
        "generated_at": iso_now(),
        "action": action,
        "class": CLASSES[action],
        "linux_only": True,
        "kind": "host",
        "reason": tilde_text(reason),
        "would_run": False,
    }


def host_guard(action, ctx):
    """Live-only refusal for actions whose source is another host."""
    if LINUX_ONLY.get(action) and not host_is_linux() and not opt(ctx, "fixture"):
        return host_refusal(action)
    return None


def plan_status(ctx=None):
    action = "localai.status"
    try:
        snap = status_payload(ctx, use_cache=False)
    except DataProblem as exc:
        return plan_failure(action, ctx, exc.reason, kind=exc.kind)
    if not snap.get("ok"):
        return plan_failure(action, ctx, snap.get("reason") or "no status", kind=snap.get("kind", "data"))
    occupancy = snap.get("slot_occupancy") or {}
    item = {
        "what": "metrics",
        "model": snap.get("model"),
        "running": snap.get("running"),
        "vram_gb": snap.get("vram_gb"),
        "tokens_per_s": snap.get("tokens_per_s"),
        "metrics_age_s": snap.get("metrics_age_s"),
        "slots_used": occupancy.get("used"),
        "slots_total": occupancy.get("total"),
    }
    return base_plan(
        action, ctx, [item],
        "read the chief metrics file and print the status payload; read only, no writes",
        bytes_total=None,
        bytes_reason="a read moves no bytes",
    )


def plan_unload(ctx=None):
    action = "localai.unload"
    guard = host_guard(action, ctx)
    if guard:
        return guard
    try:
        data, age, source, generated_at, _mtime = load_metrics(ctx)
    except DataProblem as exc:
        return plan_failure(action, ctx, exc.reason, kind=exc.kind)
    snap = metrics_payload(data, age, source, generated_at)
    model = snap.get("model")
    reload_s, reload_source = reload_cost(data)

    if not snap.get("running"):
        return base_plan(
            action, ctx, [],
            "nothing to unload: no model is loaded",
            bytes_total=None,
            bytes_reason="no model is loaded",
            noop=True,
        )

    inflight = inflight_rows(snap)
    unknown = unknown_slots(snap)
    used_mib = number(data.get("vram_used_mib"))
    file_bytes = None
    try:
        models = models_payload(ctx)
        for row in models.get("models", []):
            if row.get("model_id") == model or row.get("name") == model:
                file_bytes = row.get("bytes")
                break
    except DataProblem:
        file_bytes = None

    # Name the caller in the way: the first busy row, else the first row whose
    # state is unknown (an unknown row is never treated as idle).
    first = inflight[0] if inflight else (unknown[0] if unknown else None)
    item = {
        "model": model,
        "vram_freed_mib": int(used_mib) if used_mib is not None else None,
        "vram_freed_gb": snap.get("vram_gb"),
        "vram_freed_bytes": int(used_mib * 1024 * 1024) if used_mib is not None else None,
        "reload_cost_s": reload_s,
        "reload_cost_source": reload_source,
        "model_file_bytes": file_bytes,
        "session": first.get("session") if first else None,
        "request_id": first.get("request_id") if first else None,
        "sessions": sorted({row["session"] for row in (inflight or []) if row.get("session")}),
        "slots_busy": len(inflight) if inflight is not None else None,
        "slots_unknown": len(unknown),
    }
    if reload_s is None:
        item["reload_cost_reason"] = "metrics carries no model_load_s"

    if inflight is None:
        requires_force, force_reason = True, "metrics.json carries no slots array: cannot tell whether a request is in flight"
    elif inflight:
        requires_force = True
        force_reason = "%d request(s) in flight: %s" % (
            len(inflight),
            ", ".join(slot_label(row) for row in inflight),
        )
        if unknown:
            force_reason += "; %s carries no busy flag, so more may be in flight" % ", ".join(
                "slot %s" % row.get("slot") for row in unknown
            )
    elif unknown:
        requires_force = True
        force_reason = (
            "%d slot(s) carry no busy flag (%s): unknown counts as unknown, so a request "
            "may be in flight" % (
                len(unknown),
                ", ".join(slot_label(row) for row in unknown),
            )
        )
    else:
        requires_force, force_reason = False, None

    if reload_s is None:
        reload_text = "the next request reloads the model (load time not in metrics)"
    else:
        reload_text = "the next request reloads it in about %.1f s (%s)" % (reload_s, reload_source)
    url = "%s/api/models/unload/%s" % (llama_swap_url(ctx), str(model).replace("/", "%2F"))
    extra = {
        "in_flight": inflight,
        "requires_force": requires_force,
        "model_url": url,
    }
    if force_reason:
        extra["force_reason"] = force_reason
    if unknown:
        extra["in_flight_unknown"] = unknown
    if inflight is None:
        extra["in_flight_reason"] = "metrics.json carries no slots array"
    return base_plan(
        action, ctx, [item],
        "POST %s; llama-swap stops the llama-server child holding %s and %s"
        % (url, model, reload_text),
        bytes_total=None,
        bytes_reason="unload frees VRAM, not disk: the model file stays (bytes on disk are unchanged)",
        **extra
    )


def select_slot(ctx, slots):
    wanted = opt(ctx, "slot")
    if wanted is not None:
        wanted_int = integer(wanted)
        for row in slots:
            if row.get("slot") == wanted_int:
                return row
        return None
    for row in slots:
        if row.get("busy") is True:
            return row
    return slots[0] if slots else None


def plan_clear_slot(ctx=None):
    action = "localai.clear-slot"
    guard = host_guard(action, ctx)
    if guard:
        return guard
    try:
        data, age, source, generated_at, _mtime = load_metrics(ctx)
    except DataProblem as exc:
        return plan_failure(action, ctx, exc.reason, kind=exc.kind)
    snap = metrics_payload(data, age, source, generated_at)
    slots = snap.get("slots")
    if slots is None:
        return plan_failure(
            action, ctx,
            "metrics.json carries no slots array, so no slot can be named; %s" % snap.get("slots_reason", ""),
            kind="data",
        )
    if not slots:
        return plan_failure(action, ctx, "metrics.json lists no slots", kind="data")
    target = select_slot(ctx, slots)
    if target is None:
        return plan_failure(
            action, ctx, "no slot %r in metrics.json" % opt(ctx, "slot"), kind="caller"
        )

    busy = target.get("busy")
    tokens = target.get("tokens_cached")
    if busy is True:
        loses = (
            "the cached prompt for request %s (session %s, %s tokens); the caller stays "
            "connected and its next turn re-prefills from scratch"
            % (
                target.get("request_id") or "unknown",
                target.get("session") or "unknown",
                tokens if tokens is not None else "an unknown number of",
            )
        )
    elif busy is False:
        loses = "nothing in flight: the slot is idle, only its cached prompt (%s tokens) is discarded" % (
            tokens if tokens is not None else "an unknown number of"
        )
    else:
        loses = "unknown: metrics.json does not say whether this slot is busy; the cached prompt is discarded"

    url = "%s/slots/%s?action=erase" % (slot_base_url(ctx), target.get("slot"))
    item = {
        "slot": target.get("slot"),
        "busy": busy,
        "request_id": target.get("request_id"),
        "session": target.get("session"),
        "model": target.get("model") or snap.get("model"),
        "tokens_cached": tokens,
        "caller_loses": loses,
    }
    extra = {
        "slot_url": url,
        "requires_force": busy is not False,
    }
    if busy is True:
        extra["force_reason"] = "request %s is in flight in that slot" % (target.get("request_id") or "unknown")
    elif busy is None:
        extra["force_reason"] = (
            "metrics.json gives no busy flag for slot %s: unknown counts as unknown, so a "
            "request may be in flight" % target.get("slot")
        )
    return base_plan(
        action, ctx, [item],
        "POST %s; the slot keeps its place and the model stays loaded, only the cached prompt goes"
        % url,
        bytes_total=None,
        bytes_reason="the slot cache is VRAM, not a file; erasing it frees no disk",
        **extra
    )


def plan_vram(ctx=None):
    action = "localai.vram"
    guard = host_guard(action, ctx)
    if guard:
        return guard
    try:
        data = vram_payload(ctx)
    except DataProblem as exc:
        return plan_failure(action, ctx, exc.reason, kind=exc.kind)
    return base_plan(
        action, ctx, data["processes"],
        "run nvidia-smi --query-compute-apps=pid,process_name,used_memory and report VRAM "
        "per process; read only, nothing is unloaded",
        bytes_total=None,
        bytes_reason="VRAM, not disk: the GPU figure is not a file size (see total_mib and total_gb)",
        total_mib=data.get("total_mib"),
        total_gb=data.get("total_gb"),
    )


def plan_models(ctx=None):
    action = "localai.models"
    guard = host_guard(action, ctx)
    if guard:
        return guard
    try:
        data = models_payload(ctx)
    except DataProblem as exc:
        return plan_failure(action, ctx, exc.reason, kind=exc.kind)
    return base_plan(
        action, ctx, data["models"],
        "list the installed model files and their exact size on disk; read only, nothing is deleted",
        bytes_total=data.get("bytes") if data.get("bytes_complete") else None,
        bytes_reason=None if data.get("bytes_complete") else data.get("bytes_reason"),
        models_count=data.get("count"),
    )


# ------------------------------------------------------------------- run paths


def refusal(ctx, action, reason, kind="data", **extra):
    payload = {
        "ok": False,
        "source": action_source(ctx),
        "action": action,
        "class": CLASSES[action],
        "linux_only": LINUX_ONLY[action],
        "kind": kind,
        "reason": tilde_text(reason),
        "changed": False,
    }
    payload.update(extra)
    return add_generated_at(payload, ctx)


def run_refusal(ctx, action, reason, kind="data", **extra):
    return refusal(ctx, action, reason, kind, **extra)


def done(ctx, action, **fields):
    payload = {
        "ok": True,
        "source": action_source(ctx),
        "action": action,
        "class": CLASSES[action],
        "changed": True,
    }
    payload.update(fields)
    return add_generated_at(payload, ctx)


def confirm_guard(action, confirm, ctx=None):
    if CLASSES[action] == "read":
        return None
    if confirm == action:
        return None
    return run_refusal(
        ctx, action,
        "%s is %s and needs --confirm %s exactly (got %r); nothing ran"
        % (action, CLASSES[action], action, confirm),
        kind="confirm",
        needed="--confirm %s" % action,
    )


def _http_post(url, timeout=HTTP_TIMEOUT_S):
    """POST with no body. Imported here so a fixture run cannot reach the network."""
    import urllib.error
    import urllib.request

    request = urllib.request.Request(url, data=b"", method="POST")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read(65536).decode("utf-8", "replace")
            return int(getattr(response, "status", 0) or 0), body
    except urllib.error.HTTPError as exc:
        try:
            body = exc.read(4096).decode("utf-8", "replace")
        except Exception:  # noqa: BLE001 - an HTTP error body is never worth a crash
            body = ""
        return int(exc.code), body
    except (urllib.error.URLError, OSError) as exc:
        raise Missing("cannot reach %s: %s" % (url, exc))


def run_status(ctx=None, confirm=None):
    try:
        return status_payload(ctx)
    except DataProblem as exc:
        return refusal(ctx, "localai.status", exc.reason, kind=exc.kind)


def run_unload(ctx=None, confirm=None):
    action = "localai.unload"
    blocked = confirm_guard(action, confirm, ctx)
    if blocked:
        return blocked
    guard = host_guard(action, ctx)
    if guard:
        return guard
    try:
        data, age, source, generated_at, _mtime = load_metrics(ctx)
    except DataProblem as exc:
        return run_refusal(ctx, action, exc.reason, kind=exc.kind)
    snap = metrics_payload(data, age, source, generated_at)
    model = snap.get("model")
    reload_s, reload_source = reload_cost(data)
    if not snap.get("running"):
        return done(
            ctx, action, changed=False, model=None,
            reason="no model is loaded; nothing to unload",
        )

    inflight = inflight_rows(snap)
    unknown = unknown_slots(snap)
    force = bool(opt(ctx, "force", False))
    if inflight is None and not force:
        return run_refusal(
            ctx, action,
            "cannot tell whether a request is in flight: metrics.json carries no slots array; "
            "pass --force to unload %s anyway" % model,
            kind="inflight",
            model=model,
            in_flight=None,
        )
    if inflight and not force:
        more = ""
        if unknown:
            more = "; %s carries no busy flag, so more may be in flight" % ", ".join(
                "slot %s" % row.get("slot") for row in unknown
            )
        return run_refusal(
            ctx, action,
            "refusing to unload %s while %d request(s) are in flight (%s)%s; pass --force to "
            "unload anyway" % (
                model,
                len(inflight),
                ", ".join(slot_label(row) for row in inflight),
                more,
            ),
            kind="inflight",
            model=model,
            in_flight=inflight,
            in_flight_unknown=unknown or None,
        )
    if unknown and not force:
        return run_refusal(
            ctx, action,
            "refusing to unload %s: metrics.json gives no busy flag for %s, so a request may "
            "be in flight (unknown counts as unknown); pass --force to unload anyway" % (
                model,
                ", ".join(slot_label(row) for row in unknown),
            ),
            kind="inflight",
            model=model,
            in_flight=[],
            in_flight_unknown=unknown,
        )
    if opt(ctx, "fixture"):
        return run_refusal(
            ctx, action,
            "fixture mode never acts: the plan was built from a snapshot and no request was sent",
            kind="fixture",
            model=model,
        )

    url = "%s/api/models/unload/%s" % (llama_swap_url(ctx), str(model).replace("/", "%2F"))
    try:
        status, body = _http_post(url)
    except DataProblem as exc:
        # The request may have reached llama-swap before the transport failed:
        # an unload that cannot be confirmed is never reported as a clean no-op.
        return run_refusal(
            ctx, action,
            "outcome unknown: the request may have been sent; %s" % exc.reason,
            kind="unreachable",
            model=model,
            url=url,
        )
    if not 200 <= status < 300:
        return run_refusal(
            ctx, action,
            "llama-swap refused the unload (HTTP %d): %s" % (status, text(body, 300) or "no body"),
            kind="http",
            model=model,
            http_status=status,
        )
    return done(
        ctx,
        action,
        model=model,
        url=url,
        http_status=status,
        response=text(body, 300),
        vram_freed_gb=snap.get("vram_gb"),
        reload_cost_s=reload_s,
        reload_cost_source=reload_source,
        forced=force,
    )


def run_clear_slot(ctx=None, confirm=None):
    action = "localai.clear-slot"
    blocked = confirm_guard(action, confirm, ctx)
    if blocked:
        return blocked
    guard = host_guard(action, ctx)
    if guard:
        return guard
    try:
        data, age, source, generated_at, _mtime = load_metrics(ctx)
    except DataProblem as exc:
        return run_refusal(ctx, action, exc.reason, kind=exc.kind)
    snap = metrics_payload(data, age, source, generated_at)
    slots = snap.get("slots")
    if slots is None:
        return run_refusal(
            ctx, action,
            "metrics.json carries no slots array, so no slot can be named; nothing was cleared",
            kind="data",
            slots=None,
        )
    if not slots:
        return run_refusal(ctx, action, "metrics.json lists no slots; nothing was cleared", kind="data")
    target = select_slot(ctx, slots)
    if target is None:
        return run_refusal(
            ctx, action,
            "no slot %r in metrics.json; nothing was cleared" % opt(ctx, "slot"),
            kind="caller",
        )
    force = bool(opt(ctx, "force", False))
    busy = target.get("busy")
    if busy is True and not force:
        return run_refusal(
            ctx, action,
            "refusing to erase slot %s while request %s is in flight (%s); pass --force to "
            "erase anyway" % (
                target.get("slot"),
                target.get("request_id") or "unknown",
                target.get("session") or "unknown session",
            ),
            kind="inflight",
            slot=target,
        )
    if busy is None and not force:
        return run_refusal(
            ctx, action,
            "refusing to erase slot %s: metrics.json gives no busy flag for it%s, so a request "
            "may be in flight (unknown counts as unknown); pass --force to erase anyway" % (
                target.get("slot"),
                (" (request %s)" % target["request_id"]) if target.get("request_id") else "",
            ),
            kind="inflight",
            slot=target,
        )
    if opt(ctx, "fixture"):
        return run_refusal(
            ctx, action,
            "fixture mode never acts: the plan was built from a snapshot and no request was sent",
            kind="fixture",
            slot=target.get("slot"),
        )

    url = "%s/slots/%s?action=erase" % (slot_base_url(ctx), target.get("slot"))
    try:
        status, body = _http_post(url)
    except DataProblem as exc:
        # Same rule as unload: the erase may have landed before the transport
        # failed, so the answer is "unknown", never "nothing happened".
        return run_refusal(
            ctx, action,
            "outcome unknown: the request may have been sent; %s" % exc.reason,
            kind="unreachable",
            slot=target.get("slot"),
            url=url,
        )
    if not 200 <= status < 300:
        return run_refusal(
            ctx, action,
            "llama-server refused the erase (HTTP %d): %s" % (status, text(body, 300) or "no body"),
            kind="http",
            slot=target.get("slot"),
            http_status=status,
        )
    erased = None
    try:
        parsed = json.loads(body) if body.strip() else None
        if isinstance(parsed, dict):
            erased = integer(parsed.get("n_erased"))
    except ValueError:
        erased = None
    return done(
        action,
        slot=target.get("slot"),
        url=url,
        http_status=status,
        n_erased=erased,
        request_id=target.get("request_id"),
        session=target.get("session"),
        forced=force,
    )


def run_vram(ctx=None, confirm=None):
    action = "localai.vram"
    guard = host_guard(action, ctx)
    if guard:
        return guard
    try:
        return cached_read(ctx, "vram", vram_payload, read_identity(ctx, "vram"))
    except DataProblem as exc:
        return run_refusal(ctx, action, exc.reason, kind=exc.kind)


def run_models(ctx=None, confirm=None):
    action = "localai.models"
    guard = host_guard(action, ctx)
    if guard:
        return guard
    try:
        return cached_read(ctx, "models", models_payload, read_identity(ctx, "models"))
    except DataProblem as exc:
        return run_refusal(ctx, action, exc.reason, kind=exc.kind)


# -------------------------------------------------------------------- registry

ACTIONS = {
    "localai.status": {
        "class": CLASSES["localai.status"],
        "doc": DOCS["localai.status"],
        "plan": plan_status,
        "run": run_status,
        "linux_only": LINUX_ONLY["localai.status"],
    },
    "localai.unload": {
        "class": CLASSES["localai.unload"],
        "doc": DOCS["localai.unload"],
        "plan": plan_unload,
        "run": run_unload,
        "linux_only": LINUX_ONLY["localai.unload"],
    },
    "localai.clear-slot": {
        "class": CLASSES["localai.clear-slot"],
        "doc": DOCS["localai.clear-slot"],
        "plan": plan_clear_slot,
        "run": run_clear_slot,
        "linux_only": LINUX_ONLY["localai.clear-slot"],
    },
    "localai.vram": {
        "class": CLASSES["localai.vram"],
        "doc": DOCS["localai.vram"],
        "plan": plan_vram,
        "run": run_vram,
        "linux_only": LINUX_ONLY["localai.vram"],
    },
    "localai.models": {
        "class": CLASSES["localai.models"],
        "doc": DOCS["localai.models"],
        "plan": plan_models,
        "run": run_models,
        "linux_only": LINUX_ONLY["localai.models"],
    },
}


def list_payload():
    return {
        "ok": True,
        "source": SOURCE,
        "generated_at": iso_now(),
        "module": MODULE,
        "actions": {
            name: {
                "class": CLASSES[name],
                "doc": DOCS[name],
                "linux_only": LINUX_ONLY[name],
            }
            for name in ORDER
        },
    }


# ------------------------------------------------------------------- log line


def append_log(path, payload):
    """One JSONL row per run. Never raises; a log failure is not an action failure.

    The cache file is written temp-plus-``os.replace``; this log is the one
    deliberate exception, appended with ``open(..., "a")``. A run log is an
    append-only history: each row is one short line written in a single call,
    so rows cannot interleave with themselves, and rewriting the whole file to
    add a line would risk losing rows a concurrent run just wrote.
    """
    row = {
        "ts": iso_now(),
        "action": payload.get("action"),
        "class": payload.get("class"),
        "ok": payload.get("ok"),
        "changed": payload.get("changed"),
        "reason": payload.get("reason"),
        "items": payload.get("count"),
        "bytes": payload.get("bytes"),
        "forced": payload.get("forced"),
    }
    target = os.path.expanduser(str(path))
    try:
        os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
        with open(target, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    except OSError:
        pass


# ---------------------------------------------------------------------- self-check

_CHILD_ENV = None


def _run_child(argv, env=None):
    proc = subprocess.run(
        [sys.executable, os.path.abspath(__file__)] + argv,
        capture_output=True, text=True, timeout=120, check=False,
        env=env or _CHILD_ENV,
    )
    payload = None
    if proc.stdout.strip():
        try:
            payload = json.loads(proc.stdout)
        except ValueError:
            payload = None
    return proc.returncode, payload, proc.stdout, proc.stderr


F7_STATUS_KEYS = (
    "running", "model", "vram_gb", "tokens_per_s", "metrics_age_s", "stale",
    "metrics_age_reason", "snapshot_ts",
)


def file_digest(path):
    """sha256 of a file, or None when it is absent (used to prove a log was untouched)."""
    try:
        with open(path, "rb") as handle:
            return hashlib.sha256(handle.read()).hexdigest()
    except FileNotFoundError:
        return None
    except OSError:
        return "unreadable"


def real_home():
    """The account's home directory, even when the caller sandboxed $HOME."""
    try:
        import pwd

        return pwd.getpwuid(os.getuid()).pw_dir
    except (ImportError, KeyError, OSError):
        return HOME


def check_log_path():
    """The live audit log the self-check must never write to."""
    return os.path.join(real_home(), ".local", "state", "nexuslink", "hudfix.log")


def self_check(args):
    checks = []

    def check(name, ok, detail=""):
        checks.append({"check": name, "ok": bool(ok), "detail": detail})
        sys.stderr.write(
            "%-4s %s%s\n" % ("ok" if ok else "FAIL", name, ("  " + detail) if detail and not ok else "")
        )
        sys.stderr.flush()

    root = tempfile.mkdtemp(prefix="f8d-localai-")
    here = os.path.dirname(os.path.abspath(__file__))
    shipped = os.path.join(here, "..", "fixtures", "localai.json")
    shipped = os.path.abspath(shipped)
    idle_fixture = os.path.abspath(os.path.join(here, "..", "fixtures", "localai-idle.json"))
    sandbox_cache = os.path.join(root, "sandbox-cache.json")
    sandbox_log = os.path.join(root, "sandbox-hudfix.log")

    # Nothing a test does may land in the live audit log. Two locks: every
    # child runs with HOME pointed at this temp root (so the default log and
    # cache expand inside it), and the real default log is hashed before and
    # after the run so the claim is measured, not assumed.
    live_log = os.path.abspath(check_log_path())
    live_log_before = file_digest(live_log)
    child_home = os.path.join(root, "home")
    os.makedirs(child_home, exist_ok=True)
    global _CHILD_ENV, _http_post, host_is_linux
    _CHILD_ENV = dict(os.environ, HOME=child_home)
    sandbox_default_log = os.path.join(child_home, ".local", "state", "nexuslink", "hudfix.log")

    # 1. registry shape, exactly the five keys the contract names
    shape_ok = True
    detail = ""
    if set(ACTIONS) != set(ORDER):
        shape_ok, detail = False, "names %r" % sorted(ACTIONS)
    for name, entry in ACTIONS.items():
        if set(entry) != {"class", "doc", "plan", "run", "linux_only"}:
            shape_ok, detail = False, "%s keys %r" % (name, sorted(entry))
        elif entry["class"] not in ("read", "safe", "reversible", "destructive"):
            shape_ok, detail = False, "%s class %r" % (name, entry["class"])
        elif not (callable(entry["plan"]) and callable(entry["run"])):
            shape_ok, detail = False, "%s plan/run not callable" % name
        elif not (isinstance(entry["doc"], str) and entry["doc"].strip()):
            shape_ok, detail = False, "%s has no doc" % name
        elif not isinstance(entry["linux_only"], bool):
            shape_ok, detail = False, "%s linux_only is not a bool" % name
    check("ACTIONS: five actions, exact shape, classes from the four", shape_ok, detail)

    # 1b. a slot row with no busy key counts as unknown, never as idle: the
    #     in-flight guard fails closed for unload and clear-slot both
    nobusy = os.path.join(root, "nobusy.json")
    try:
        with open(shipped, encoding="utf-8") as handle:
            snapshot = json.load(handle)
        for row in snapshot.get("slots") or []:
            row.pop("busy", None)
        with open(nobusy, "w", encoding="utf-8") as handle:
            json.dump(snapshot, handle)
        nobusy_ok = True
    except (OSError, ValueError, TypeError):
        nobusy_ok = False
    plan_rc, unknown_plan, _, _ = _run_child([
        "--json", "plan", "localai.unload", "--fixture", nobusy,
    ])
    unload_rc, unknown_unload, _, _ = _run_child([
        "--json", "run", "localai.unload", "--confirm", "localai.unload", "--fixture", nobusy,
    ])
    slot_rc, unknown_slot, _, _ = _run_child([
        "--json", "run", "localai.clear-slot", "--slot", "1", "--confirm", "localai.clear-slot",
        "--fixture", nobusy,
    ])
    check(
        "a slot with no busy key is unknown: plan needs --force, unload and clear-slot refuse kind inflight",
        nobusy_ok
        and plan_rc == 0 and isinstance(unknown_plan, dict)
        and unknown_plan.get("requires_force") is True
        and unknown_plan.get("in_flight") == []
        and len(unknown_plan.get("in_flight_unknown") or []) == 2
        and unload_rc == 2 and isinstance(unknown_unload, dict)
        and unknown_unload.get("kind") == "inflight"
        and "no busy flag" in str(unknown_unload.get("reason", ""))
        and "req_7f3a" in str(unknown_unload.get("reason", ""))
        and slot_rc == 2 and isinstance(unknown_slot, dict)
        and unknown_slot.get("kind") == "inflight"
        and "no busy flag" in str(unknown_slot.get("reason", "")),
        "plan=%r unload=%r slot=%r" % (unknown_plan, unknown_unload, unknown_slot),
    )

    # 2. shipped fixture status shape and F7 key parity
    rc, payload, _, err = _run_child(["--json", "run", "localai.status", "--fixture", shipped])
    try:
        shipped_ts = iso(number(json.load(open(shipped, encoding="utf-8")).get("ts")))
    except (OSError, ValueError, TypeError):
        shipped_ts = None
    ok = (
        rc == 0 and isinstance(payload, dict) and payload.get("ok") is True
        and payload.get("source") == "fixture"
        and all(key in payload for key in F7_STATUS_KEYS)
        and payload.get("model") == "ornith-chief-v3"
        and payload.get("running") is True
        and payload.get("metrics_age_s") is None
        and payload.get("stale") is None
        and payload.get("metrics_age_reason") == "fixture mode reads no clock; age and stale are not measured"
        and payload.get("snapshot_ts") == shipped_ts
        and payload.get("slots") is not None
        and payload.get("slot_occupancy") == {"used": 1, "total": 2}
    )
    check("shipped fixture run localai.status: F7 keys, F7 fixture semantics, slots", ok, "rc=%s err=%r payload=%r" % (rc, err[-200:], payload))

    try:
        used_mib = float(json.load(open(shipped, encoding="utf-8")).get("vram_used_mib"))
    except (OSError, ValueError, TypeError):
        used_mib = None
    check(
        "vram_used_mib -> vram_gb with F7's 1024 divisor",
        isinstance(payload, dict) and used_mib is not None
        and payload.get("vram_gb") == round(used_mib / MIB_PER_GB, 2),
        "payload vram_gb=%r used=%r" % (payload.get("vram_gb") if isinstance(payload, dict) else None, used_mib),
    )

    # 3. fixture purity: byte-identical output, no cache file, no clock in the answer
    rc1, _, out1, _ = _run_child(["--json", "run", "localai.status", "--fixture", shipped,
                                  "--cache", sandbox_cache])
    rc2, _, out2, _ = _run_child(["--json", "run", "localai.status", "--fixture", shipped,
                                  "--cache", sandbox_cache])
    check(
        "fixture output is byte-identical across runs (no host clock)",
        rc1 == 0 and rc2 == 0 and out1 == out2 and '"source":"fixture"' in out1,
        "out1=%r out2=%r" % (out1[:160], out2[:160]),
    )
    check("fixture read writes no cache file", not os.path.exists(sandbox_cache), sandbox_cache)

    # 3b. a fixture refusal and a fixture no-op take generated_at from the
    #     fixture's ts, report source fixture, and are byte-identical; every
    #     envelope source is fixture or live, never "local" or "localai"
    rc1, ref1, ref_out1, _ = _run_child([
        "--json", "run", "localai.unload", "--confirm", "localai.unload",
        "--force", "--fixture", shipped,
    ])
    rc2, ref2, ref_out2, _ = _run_child([
        "--json", "run", "localai.unload", "--confirm", "localai.unload",
        "--force", "--fixture", shipped,
    ])
    idle1_rc, idle1, idle_out1, _ = _run_child([
        "--json", "run", "localai.unload", "--confirm", "localai.unload", "--fixture", idle_fixture,
    ])
    idle2_rc, idle2, idle_out2, _ = _run_child([
        "--json", "run", "localai.unload", "--confirm", "localai.unload", "--fixture", idle_fixture,
    ])
    try:
        idle_ts = iso(number(json.load(open(idle_fixture, encoding="utf-8")).get("ts")))
    except (OSError, ValueError, TypeError):
        idle_ts = None
    check(
        "fixture refusal and no-op: source fixture, generated_at from the fixture ts, byte-identical",
        rc1 == 2 and rc1 == rc2 and ref_out1 == ref_out2
        and isinstance(ref1, dict) and ref1.get("source") == "fixture"
        and ref1.get("generated_at") == shipped_ts
        and idle1_rc == 0 and idle1_rc == idle2_rc and idle_out1 == idle_out2
        and isinstance(idle1, dict) and idle1.get("source") == "fixture"
        and idle1.get("changed") is False and idle1.get("generated_at") == idle_ts
        and list_payload().get("source") == "live",
        "ref=%r idle=%r" % (ref1, idle1),
    )

    # 4. partial object, empty, malformed, missing
    partial = os.path.join(root, "partial.json")
    with open(partial, "w", encoding="utf-8") as handle:
        json.dump({"model": "ornith-chief-v3"}, handle)
    rc, payload, _, err = _run_child(["--json", "run", "localai.status", "--fixture", partial])
    check(
        "partial metrics object: ok:true, null VRAM, slots null with a reason, no crash",
        rc == 0 and isinstance(payload, dict) and payload.get("ok") is True
        and payload.get("running") is True
        and payload.get("vram_gb") is None
        and payload.get("tokens_per_s") is None
        and payload.get("metrics_age_s") is None
        and payload.get("stale") is None
        and payload.get("slots") is None
        and isinstance(payload.get("slots_reason"), str)
        and "Traceback" not in err,
        "rc=%s payload=%r" % (rc, payload),
    )

    empty = os.path.join(root, "empty.json")
    open(empty, "w").close()
    rc, payload, _, _ = _run_child(["--json", "run", "localai.status", "--fixture", empty])
    check("empty fixture is ok:false exit 0", rc == 0 and isinstance(payload, dict) and payload.get("ok") is False, "rc=%s" % rc)

    bad = os.path.join(root, "bad.json")
    with open(bad, "w", encoding="utf-8") as handle:
        handle.write("[")
    rc, payload, _, _ = _run_child(["--json", "run", "localai.status", "--fixture", bad])
    check("malformed fixture is ok:false exit 0", rc == 0 and isinstance(payload, dict) and payload.get("ok") is False, "rc=%s" % rc)

    rc, payload, _, _ = _run_child(["--json", "run", "localai.status", "--fixture", os.path.join(root, "nope.json")])
    check("missing named fixture -> exit 2", rc == 2 and isinstance(payload, dict) and payload.get("ok") is False, "rc=%s" % rc)

    rc, _, out, err = _run_child(["--bogus-flag"])
    check("unknown flag -> exit 2, no traceback", rc == 2 and "Traceback" not in err, "rc=%s" % rc)

    # 5. live absence on this host: no metrics file -> ok:false exit 0
    rc, payload, _, _ = _run_child([
        "--json", "run", "localai.status",
        "--metrics", os.path.join(root, "no-metrics.json"),
        "--cache", sandbox_cache, "--no-cache",
    ])
    check(
        "missing metrics.json -> ok:false exit 0 with a reason",
        rc == 0 and isinstance(payload, dict) and payload.get("ok") is False
        and "chief metrics" in str(payload.get("reason", "")),
        "rc=%s payload=%r" % (rc, payload),
    )

    # 6. cache: two live reads inside 10 s, the second served from the cache
    live_metrics = os.path.join(root, "metrics.json")
    with open(live_metrics, "w", encoding="utf-8") as handle:
        json.dump({"ts": time.time(), "model": "ornith-chief-v3", "tokens_per_s": 41.6,
                   "queue": 0, "vram_used_mib": 11012, "vram_total_mib": 12288,
                   "slot_count": 2, "slots": []}, handle)
    cache_file = os.path.join(root, "cache.json")
    _run_child(["--json", "run", "localai.status", "--metrics", live_metrics, "--cache", cache_file])
    rc, second, _, _ = _run_child(["--json", "run", "localai.status", "--metrics", live_metrics, "--cache", cache_file])
    check(
        "second live status inside 10 s is cached",
        rc == 0 and isinstance(second, dict) and second.get("cached") is True
        and isinstance(second.get("cache_age_s"), float),
        "second=%r" % (second,),
    )

    # 6b. the shared read cache that vram and models use: one build, then the cache
    probe_calls = []
    probe_cache = os.path.join(root, "probe-cache.json")

    def _probe_builder(_ctx):
        probe_calls.append(1)
        return {"ok": True, "source": "live", "generated_at": iso_now(), "count": 0}

    first_probe = cached_read({"cache": probe_cache}, "probe", _probe_builder)
    second_probe = cached_read({"cache": probe_cache}, "probe", _probe_builder)
    check(
        "vram/models read cache: one build, the second answer comes from disk",
        len(probe_calls) == 1 and first_probe.get("cached") is False
        and second_probe.get("cached") is True
        and isinstance(second_probe.get("cache_age_s"), float),
        "calls=%d first=%r second=%r" % (len(probe_calls), first_probe, second_probe),
    )

    # 6c. a metrics file that vanished is not served from the cache
    os.unlink(live_metrics)
    rc, gone, _, _ = _run_child([
        "--json", "run", "localai.status", "--metrics", live_metrics, "--cache", cache_file,
    ])
    check(
        "a vanished metrics file is re-read, not served from the cache",
        rc == 0 and isinstance(gone, dict) and gone.get("ok") is False
        and "chief metrics" in str(gone.get("reason", "")),
        "rc=%s payload=%r" % (rc, gone),
    )

    # 6d. the 10 s read cache expires: after the TTL the builder runs again
    ttl_calls = []
    ttl_cache = os.path.join(root, "ttl-cache.json")

    def _ttl_builder(_ctx):
        ttl_calls.append(1)
        return {"ok": True, "source": "live", "generated_at": iso_now(), "count": 0}

    cached_read({"cache": ttl_cache}, "ttl", _ttl_builder)
    time.sleep(CACHE_TTL_S + 0.4)
    expired = cached_read({"cache": ttl_cache}, "ttl", _ttl_builder)
    check(
        "the 10 s read cache expires: past the TTL the builder runs again",
        len(ttl_calls) == 2 and isinstance(expired, dict) and expired.get("cached") is False,
        "calls=%d payload=%r" % (len(ttl_calls), expired),
    )

    # 7. plan purity: every plan in fixture mode leaves the sandbox untouched
    def tree_hash(path):
        acc = []
        for base, dirs, files in os.walk(path):
            dirs.sort()
            for name in sorted(files):
                full = os.path.join(base, name)
                try:
                    with open(full, "rb") as handle:
                        acc.append((full, hash(handle.read())))
                except OSError:
                    acc.append((full, None))
        return acc

    before = tree_hash(root)
    plan_ctx = {"fixture": shipped, "cache": sandbox_cache, "log": sandbox_log, "no_cache": False}
    plans = {}
    plan_ok, plan_detail = True, ""
    for name in ORDER:
        try:
            first = ACTIONS[name]["plan"](dict(plan_ctx))
            again = ACTIONS[name]["plan"](dict(plan_ctx))
        except BaseException as exc:  # noqa: BLE001 - the check must report, not raise
            plan_ok, plan_detail = False, "%s raised %s: %s" % (name, type(exc).__name__, exc)
            continue
        plans[name] = first
        if json.dumps(first, sort_keys=True) != json.dumps(again, sort_keys=True):
            plan_ok, plan_detail = False, "%s plan is not deterministic" % name
        if not isinstance(first, dict) or "items" not in first or "would" not in first:
            plan_ok, plan_detail = False, "%s plan lacks items/would" % name
    after = tree_hash(root)
    check("plan is side-effect free: sandbox unchanged, no cache file", before == after and plan_ok, plan_detail)
    check("every plan is deterministic over the same fixture", plan_ok, plan_detail)

    # 8. every plan (fixture) carries the class, the count and what run would do
    expected = {
        "localai.status": ("read", False),
        "localai.unload": ("reversible", True),
        "localai.clear-slot": ("reversible", True),
        "localai.vram": ("read", True),
        "localai.models": ("read", True),
    }
    ok = True
    detail = ""
    for name, (klass, linux_only) in expected.items():
        plan = plans.get(name) or {}
        if plan.get("class") != klass or plan.get("linux_only") is not linux_only:
            ok, detail = False, "%s class/linux_only %r/%r" % (name, plan.get("class"), plan.get("linux_only"))
        elif not isinstance(plan.get("items"), list) or plan.get("count") != len(plan["items"]):
            ok, detail = False, "%s count mismatch" % name
        elif not isinstance(plan.get("would"), str) or not plan["would"]:
            ok, detail = False, "%s has no would" % name
    check("plan list: class, linux_only, items, count, would per action", ok, detail)

    # 8b. F8a calls plan() with no argument and run(ctx, confirm) positionally
    callable_ok, callable_detail = True, ""
    for name in ORDER:
        try:
            bare = ACTIONS[name]["plan"]()
            result = ACTIONS[name]["run"]({"fixture": shipped, "confirm": name, "force": True}, name)
        except BaseException as exc:  # noqa: BLE001 - the check must report, not raise
            callable_ok, callable_detail = False, "%s raised %s: %s" % (name, type(exc).__name__, exc)
            break
        if not isinstance(bare, dict) or not isinstance(result, dict):
            callable_ok, callable_detail = False, "%s did not return a dict" % name
            break
    check("ACTIONS entries are callable as plan() and run(ctx, confirm)", callable_ok, callable_detail)

    # 9. unload plan names model, VRAM, reload cost, session, in-flight
    unload_plan = plans.get("localai.unload") or {}
    item = (unload_plan.get("items") or [{}])[0]
    check(
        "unload plan names the model, freed VRAM, reload cost and the session in the way",
        unload_plan.get("ok") is True
        and item.get("model") == "ornith-chief-v3"
        and item.get("vram_freed_gb") == 10.75
        and item.get("reload_cost_s") == 3.8
        and item.get("session") == "chief-voice/2026-10-23T00:12Z"
        and item.get("request_id") == "req_7f3a"
        and unload_plan.get("requires_force") is True
        and len(unload_plan.get("in_flight") or []) == 1,
        "plan=%r" % (unload_plan,),
    )

    # 10. clear-slot plan names the slot, request id and what the caller loses
    clear_plan = plans.get("localai.clear-slot") or {}
    slot_item = (clear_plan.get("items") or [{}])[0]
    check(
        "clear-slot plan names slot 1, request id and the loss",
        clear_plan.get("ok") is True and slot_item.get("slot") == 1
        and slot_item.get("request_id") == "req_7f3a"
        and isinstance(slot_item.get("caller_loses"), str) and "re-prefill" in slot_item["caller_loses"],
        "plan=%r" % (clear_plan,),
    )

    # 11. vram and models plans: exact VRAM totals, but bytes is null (VRAM is not disk)
    vram_plan = plans.get("localai.vram") or {}
    check(
        "vram plan sums nvidia-smi rows exactly, bytes null with a reason",
        vram_plan.get("ok") is True and vram_plan.get("count") == 2
        and vram_plan.get("total_mib") == 11012.0
        and vram_plan.get("total_gb") == 10.75
        and vram_plan.get("bytes") is None
        and "VRAM, not disk" in str(vram_plan.get("bytes_reason", "")),
        "plan=%r" % (vram_plan,),
    )
    models_plan = plans.get("localai.models") or {}
    try:
        fixture_models = json.load(open(shipped, encoding="utf-8")).get("models") or []
        expected_bytes = sum(int(row["bytes"]) for row in fixture_models)
    except (OSError, ValueError, TypeError, KeyError):
        fixture_models, expected_bytes = [], None
    check(
        "models plan lists every file with exact bytes",
        models_plan.get("ok") is True and models_plan.get("count") == len(fixture_models)
        and models_plan.get("bytes") == expected_bytes,
        "plan bytes=%r expected=%r" % (models_plan.get("bytes"), expected_bytes),
    )

    # 12. confirm guard: unload without --confirm refuses exit 2
    rc, payload, _, err = _run_child(["--json", "run", "localai.unload", "--fixture", shipped])
    check(
        "unload without --confirm refuses exit 2",
        rc == 2 and isinstance(payload, dict) and payload.get("ok") is False
        and payload.get("kind") == "confirm"
        and "--confirm localai.unload" in str(payload.get("reason", "")),
        "rc=%s payload=%r" % (rc, payload),
    )

    # 13. in-flight guard: confirm given, request in flight, no --force
    rc, payload, _, _ = _run_child([
        "--json", "run", "localai.unload", "--confirm", "localai.unload", "--fixture", shipped,
    ])
    check(
        "unload with a request in flight refuses without --force (exit 2, names the request)",
        rc == 2 and isinstance(payload, dict) and payload.get("ok") is False
        and payload.get("kind") == "inflight"
        and "in flight" in str(payload.get("reason", ""))
        and "req_7f3a" in str(payload.get("reason", "")),
        "rc=%s payload=%r" % (rc, payload),
    )

    # 14. --force passes the guard, then fixture mode still refuses to act
    rc, payload, _, _ = _run_child([
        "--json", "run", "localai.unload", "--confirm", "localai.unload",
        "--force", "--fixture", shipped,
    ])
    check(
        "--force passes the in-flight guard, fixture mode still sends nothing",
        rc == 2 and isinstance(payload, dict) and payload.get("ok") is False
        and payload.get("kind") == "fixture",
        "rc=%s payload=%r" % (rc, payload),
    )

    # 15. idle fixture: status says not running, unload plan is a no-op
    rc, payload, _, _ = _run_child(["--json", "run", "localai.status", "--fixture", idle_fixture])
    check(
        "idle fixture: running false, occupancy 0/2, no invented numbers",
        rc == 0 and isinstance(payload, dict) and payload.get("running") is False
        and payload.get("model") is None and payload.get("vram_gb") == 0.0
        and payload.get("slot_occupancy") == {"used": 0, "total": 2},
        "payload=%r" % (payload,),
    )
    rc, payload, _, _ = _run_child(["--json", "plan", "localai.unload", "--fixture", idle_fixture])
    check(
        "unload plan on an idle box is a no-op, not a fake unload",
        rc == 0 and isinstance(payload, dict) and payload.get("ok") is True
        and payload.get("noop") is True and payload.get("count") == 0,
        "payload=%r" % (payload,),
    )

    # 16. partial metrics with no slots: unload cannot tell, so it refuses without force
    noslots = os.path.join(root, "noslots.json")
    with open(noslots, "w", encoding="utf-8") as handle:
        json.dump({"model": "ornith-chief-v3", "vram_used_mib": 2048}, handle)
    rc, payload, _, _ = _run_child([
        "--json", "run", "localai.unload", "--confirm", "localai.unload", "--fixture", noslots,
    ])
    check(
        "unload when the metrics cannot say who is in flight refuses without --force",
        rc == 2 and isinstance(payload, dict) and payload.get("kind") == "inflight"
        and "cannot tell" in str(payload.get("reason", "")),
        "rc=%s payload=%r" % (rc, payload),
    )

    # 17. clear-slot: busy slot refuses without --force, and fixture still refuses to act
    rc, payload, _, _ = _run_child([
        "--json", "run", "localai.clear-slot", "--confirm", "localai.clear-slot", "--fixture", shipped,
    ])
    check(
        "clear-slot on a busy slot refuses without --force",
        rc == 2 and isinstance(payload, dict) and payload.get("kind") == "inflight",
        "rc=%s payload=%r" % (rc, payload),
    )
    rc, payload, _, _ = _run_child([
        "--json", "run", "localai.clear-slot", "--confirm", "localai.clear-slot",
        "--force", "--fixture", shipped,
    ])
    check(
        "clear-slot with --force passes the guard, fixture mode sends nothing",
        rc == 2 and isinstance(payload, dict) and payload.get("kind") == "fixture",
        "rc=%s payload=%r" % (rc, payload),
    )

    # 18. linux_only refusals are honest on this Mac (skipped on the Linux box).
    #     A test never invokes the destructive form: `run <name>` goes out with
    #     NO confirm token, so a reversible action stops at the confirm guard and
    #     a read action stops at the host guard. Nothing here can reach a model.
    if not host_is_linux():
        refused = True
        detail = ""
        for name in ("localai.unload", "localai.clear-slot", "localai.vram", "localai.models"):
            rc, payload, _, _ = _run_child(["--json", "plan", name])
            if not (
                rc == 0 and isinstance(payload, dict) and payload.get("ok") is False
                and payload.get("kind") == "host" and "not this host" in str(payload.get("reason", ""))
                and "Linux only" in str(payload.get("reason", ""))
            ):
                refused, detail = False, "%s plan: rc=%s payload=%r" % (name, rc, payload)
                break
            rc, payload, _, _ = _run_child(["--json", "run", name])
            if CLASSES[name] == "read":
                # honest absence on the wrong host: ok:false, kind host, exit 0
                if not (
                    rc == 0 and isinstance(payload, dict) and payload.get("ok") is False
                    and payload.get("kind") == "host"
                ):
                    refused, detail = False, "%s read run: rc=%s payload=%r" % (name, rc, payload)
                    break
            elif not (
                rc == 2 and isinstance(payload, dict) and payload.get("kind") == "confirm"
            ):
                refused, detail = False, "%s run without confirm: rc=%s payload=%r" % (name, rc, payload)
                break
        check(
            "every linux_only action refuses honestly on this Mac (plan 0 kind host; "
            "read run 0 kind host; reversible run without confirm 2)",
            refused, detail,
        )
    else:
        check("linux_only host refusal (skipped: this host is Linux)", True, "running on Linux")

    # 19. no network: monkeypatch the poster, run every fixture path, expect zero calls
    real_post = _http_post
    calls = []

    def _spy(url, timeout=HTTP_TIMEOUT_S):
        calls.append(url)
        raise AssertionError("network call during self-check: %s" % url)

    network_ok = True
    detail = ""
    _http_post = _spy
    try:
        for name in ORDER:
            try:
                ACTIONS[name]["run"]({"fixture": shipped, "confirm": name, "force": True}, name)
            except BaseException as exc:  # noqa: BLE001
                network_ok, detail = False, "%s raised %s: %s" % (name, type(exc).__name__, exc)
                break
    finally:
        _http_post = real_post
    check("no network call from any fixture run", network_ok and calls == [], detail or "calls=%r" % (calls,))

    # 20. run of a read action with a fixture returns data (reads are not "acting")
    rc, payload, _, _ = _run_child(["--json", "run", "localai.vram", "--fixture", shipped])
    check(
        "read action run localai.vram returns the fixture rows",
        rc == 0 and isinstance(payload, dict) and payload.get("ok") is True
        and payload.get("count") == 2 and payload.get("total_mib") == 11012.0,
        "rc=%s payload=%r" % (rc, payload),
    )
    rc, payload, _, _ = _run_child(["--json", "run", "localai.models", "--fixture", shipped])
    check(
        "read action run localai.models returns exact sizes",
        rc == 0 and isinstance(payload, dict) and payload.get("ok") is True
        and payload.get("count") == len(fixture_models)
        and payload.get("bytes") == expected_bytes,
        "rc=%s payload=%r" % (rc, payload),
    )

    # 21. the run log gets one JSONL row per run, including a refusal
    log_file = os.path.join(root, "hudfix.log")
    _run_child([
        "--json", "run", "localai.unload", "--confirm", "localai.unload",
        "--fixture", shipped, "--log", log_file,
    ])
    rows = []
    try:
        with open(log_file, encoding="utf-8") as handle:
            rows = [json.loads(line) for line in handle if line.strip()]
    except (OSError, ValueError):
        rows = []
    check(
        "run appends one JSONL row to the hudfix log",
        len(rows) == 1 and rows[0].get("action") == "localai.unload"
        and rows[0].get("ok") is False and rows[0].get("class") == "reversible",
        "rows=%r" % (rows,),
    )

    # 22. a POST that cannot reach the host is "outcome unknown": exit 2, ok:false,
    #     and the run log still gets its row, because the request may have been sent
    dead_metrics = os.path.join(root, "dead-metrics.json")
    with open(dead_metrics, "w", encoding="utf-8") as handle:
        json.dump({"ts": time.time(), "model": "ornith-chief-v3", "vram_used_mib": 11012,
                   "slots": [{"slot": 0, "busy": False}]}, handle)
    dead_log = os.path.join(root, "dead.log")
    real_linux, real_poster = host_is_linux, _http_post

    def _dead_poster(url, timeout=HTTP_TIMEOUT_S):
        raise Missing("cannot reach %s: [Errno 61] Connection refused" % url)

    host_is_linux = lambda: True
    _http_post = _dead_poster
    buffer = io.StringIO()
    try:
        with redirect_stdout(buffer):
            dead_rc = main([
                "--json", "run", "localai.unload", "--confirm", "localai.unload",
                "--metrics", dead_metrics, "--log", dead_log,
                "--cache", os.path.join(root, "dead-cache.json"),
            ])
    finally:
        host_is_linux, _http_post = real_linux, real_poster
    try:
        dead_payload = json.loads(buffer.getvalue())
    except ValueError:
        dead_payload = None
    dead_rows = []
    try:
        with open(dead_log, encoding="utf-8") as handle:
            dead_rows = [json.loads(line) for line in handle if line.strip()]
    except (OSError, ValueError):
        dead_rows = []
    check(
        "an unreachable POST is outcome unknown: exit 2, ok:false, and a log row",
        dead_rc == 2 and isinstance(dead_payload, dict)
        and dead_payload.get("ok") is False and dead_payload.get("kind") == "unreachable"
        and "outcome unknown" in str(dead_payload.get("reason", ""))
        and len(dead_rows) == 1 and dead_rows[0].get("ok") is False,
        "rc=%s payload=%r rows=%r" % (dead_rc, dead_payload, dead_rows),
    )

    # 23. the read cache is keyed on the source, not just the action name: a
    #     models_dir change inside the TTL is re-read, never served the other
    #     directory's answer (2 files / 150 B, then 1 file / 7 B)
    dir_a = os.path.join(root, "models-a")
    dir_b = os.path.join(root, "models-b")
    os.makedirs(dir_a, exist_ok=True)
    os.makedirs(dir_b, exist_ok=True)
    for name, size in (("a-one.gguf", 150), ("a-two.gguf", 0)):
        with open(os.path.join(dir_a, name), "wb") as handle:
            handle.write(b"x" * size)
    with open(os.path.join(dir_b, "b-one.gguf"), "wb") as handle:
        handle.write(b"x" * 7)
    models_cache = os.path.join(root, "models-cache.json")
    missing_metrics = os.path.join(root, "no-metrics-for-models.json")
    real_linux_host = host_is_linux
    host_is_linux = lambda: True
    try:
        with redirect_stdout(io.StringIO()):
            models_a = run_models({"models_dir": dir_a, "cache": models_cache, "metrics": missing_metrics})
            models_b = run_models({"models_dir": dir_b, "cache": models_cache, "metrics": missing_metrics})
    finally:
        host_is_linux = real_linux_host
    check(
        "a models_dir change inside the 10 s TTL is re-read (cache key follows the source)",
        models_a.get("count") == 2 and models_a.get("bytes") == 150
        and models_a.get("cached") is False
        and models_b.get("count") == 1 and models_b.get("bytes") == 7
        and models_b.get("cached") is False,
        "a=%r b=%r" % (models_a, models_b),
    )

    # 24. the live audit log is exactly as it was: every child ran under the
    #     temp HOME above, so its default log went there instead
    live_log_after = file_digest(live_log)
    check(
        "the self-check writes to its temp HOME, never to the live audit log",
        live_log_before == live_log_after and os.path.exists(sandbox_default_log),
        "live_before=%r live_after=%r sandbox_log=%r path=%r" % (
            live_log_before, live_log_after, os.path.exists(sandbox_default_log), sandbox_default_log,
        ),
    )

    shutil.rmtree(root, ignore_errors=True)
    failed = [item for item in checks if not item["ok"]]
    emit({"ok": not failed, "source": SOURCE, "self_check": True,
          "checks": checks, "passed": len(checks) - len(failed), "total": len(checks)}, args.json)
    return 0 if not failed else 1


# ---------------------------------------------------------------------------- cli


def _add_common(parser):
    parser.add_argument("--fixture", metavar="PATH", help="read a local-ai fixture instead of the host")
    parser.add_argument("--metrics", metavar="PATH", default=DEFAULT_METRICS,
                        help="chief metrics file (default %s)" % DEFAULT_METRICS)
    parser.add_argument("--cache", metavar="PATH", default=DEFAULT_CACHE,
                        help="cache file (default %s)" % DEFAULT_CACHE)
    parser.add_argument("--no-cache", action="store_true", help="ignore and do not write the cache")
    parser.add_argument("--llama-swap-url", metavar="URL", default=DEFAULT_LLAMA_SWAP_URL,
                        help="llama-swap base URL (default %s)" % DEFAULT_LLAMA_SWAP_URL)
    parser.add_argument("--slot-url", metavar="URL", default=None,
                        help="llama-server base URL for /slots (default: the llama-swap URL)")
    parser.add_argument("--models-dir", metavar="DIR", default=None,
                        help="model directory for the live models read (default $CHIEF_MODELS_DIR)")
    parser.add_argument("--slot", metavar="N", default=None, help="slot id for clear-slot (default: first busy)")
    parser.add_argument("--log", metavar="PATH", default=DEFAULT_LOG,
                        help="run log (default %s)" % DEFAULT_LOG)
    parser.add_argument("--json", action="store_true", default=argparse.SUPPRESS,
                        help="one compact JSON line")


def build_parser():
    parser = argparse.ArgumentParser(
        description="hudfix LOCAL AI module for the v5 HUD (status, unload, clear-slot, vram, models)"
    )
    parser.add_argument("--self-check", action="store_true", help="run the built-in checks and exit")
    parser.add_argument("--json", action="store_true", help="one compact JSON line")
    sub = parser.add_subparsers(dest="command")

    list_parser = sub.add_parser("list", help="list this module's actions, classes and linux_only flags")
    list_parser.add_argument("--json", action="store_true", default=argparse.SUPPRESS,
                             help="one compact JSON line")

    plan = sub.add_parser("plan", help="dry-run one action; changes nothing")
    plan.add_argument("action")
    _add_common(plan)

    run = sub.add_parser("run", help="perform one action")
    run.add_argument("action")
    run.add_argument("--confirm", metavar="ACTION", default=None,
                     help="must match the action name for reversible/destructive actions")
    run.add_argument("--force", action="store_true",
                     help="unload or erase a slot even while a request is in flight")
    _add_common(run)
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.self_check:
        return self_check(args)

    if args.command == "list":
        emit(list_payload(), args.json)
        return EXIT_OK

    if args.command not in ("plan", "run"):
        emit(
            {"ok": False, "source": action_source(args), "generated_at": iso_now(),
             "reason": "choose one of: list, plan <action>, run <action>, --self-check"},
            getattr(args, "json", False),
        )
        return EXIT_PROGRAMMING

    action = args.action
    if action not in ACTIONS:
        emit(
            {"ok": False, "source": action_source(args), "generated_at": iso_now(), "action": action,
             "reason": "unknown action %r; known: %s" % (action, ", ".join(ORDER))},
            args.json,
        )
        return EXIT_PROGRAMMING

    try:
        if args.command == "plan":
            payload = ACTIONS[action]["plan"](args)
            emit(payload, args.json)
            return EXIT_PROGRAMMING if payload.get("kind") == "caller" else EXIT_OK

        payload = ACTIONS[action]["run"](args, args.confirm)
        append_log(args.log, payload)
        emit(payload, args.json)
        if CLASSES[action] == "read":
            # Honest absence is exit 0, including a linux_only read refused on
            # the wrong host; only a bad argument or a broken run is exit 2.
            return EXIT_PROGRAMMING if payload.get("kind") in ("caller", "programming") else EXIT_OK
        return EXIT_OK if payload.get("ok") else EXIT_PROGRAMMING
    except DataProblem as exc:
        payload = {
            "ok": False, "source": action_source(args),
            "action": action, "reason": tilde_text(exc.reason), "kind": exc.kind,
        }
        add_generated_at(payload, args)
        if args.command == "run":
            append_log(args.log, payload)
        emit(payload, args.json)
        return EXIT_PROGRAMMING if isinstance(exc, Caller) else EXIT_OK
    except (KeyboardInterrupt, SystemExit):
        raise
    except BaseException as exc:  # noqa: BLE001
        payload = {
            "ok": False, "source": action_source(args),
            "action": action, "kind": "programming",
            "reason": tilde_text("programming error: %s: %s" % (type(exc).__name__, exc)),
        }
        add_generated_at(payload, args)
        if args.command == "run":
            append_log(args.log, payload)
        emit(payload, args.json)
        return EXIT_PROGRAMMING


if __name__ == "__main__":
    sys.exit(main())
