#!/usr/bin/env python3
"""hudfix - the HUD maintenance engine (v5 F8a spine).

Every "useful action" in a v5 utility view goes through this one CLI so the deck
never grows a second safety model:

    hudfix.py list   [--json]                      every action, its class, whether this host can run it
    hudfix.py plan   ACTION [--path P] [--json]     dry run: exact items, exact bytes, what run would do
    hudfix.py run    ACTION --confirm ACTION        perform it; reversible/destructive need the exact name
    hudfix.py status [--json]                      host, action census, quarantine and log state
    hudfix.py --self-check                         prove the above on a throwaway tree, exit 1 on failure

One JSON object on stdout, nothing else. ``--json`` is one compact line, the
default is the same object pretty printed.

Classes (the safety model from MAIN-SCREEN-BUILD.md)
    read         never changes anything. ``run`` is allowed and asserts no change.
    safe         runs without confirmation, but the plan is printed first (it
                 rides in the run object under ``plan``).
    reversible  requires ``--confirm <action>``; the change can be undone by hand
                 (everything this engine deletes is moved to quarantine).
    destructive requires ``--confirm <action>``; the underlying tool has no
                 recovery path. A module must say why in ``doc``.

Exit codes
    0   data, a plan, a completed run, honest absence (``{"ok": false,
        "reason": "..."}``), and a Linux-only action refused by ``plan``.
    1   ``--self-check`` only: an assertion failed.
    2   caller or programming error, and ``run`` refusals: unknown action, bad
        arguments, a named ``--fixture`` that does not exist, a missing or
        mismatched ``--confirm``, a Linux-only action run on this host, a module
        that raised, a ``read`` action that reported a change.

The module contract (how F8b to F8f plug in)
    Put ``hudfix_<domain>.py`` next to this file. It exports one dict:

        ACTIONS = {
            "<name>": {
                "class": "read|safe|reversible|destructive",
                "doc": "one sentence, shown in the UI and in ``list``",
                "plan": callable,     # plan(ctx) or plan() -> dry-run dict
                "run": callable,      # run(ctx, confirm) or run(ctx) or run()
                "linux_only": bool,   # optional, default False
                "requires": ["pacman"],   # optional commands that must exist
            },
        }

    ``plan`` should return ``{"items": [...], "bytes": N, "count": N,
    "would": {...}, "notes": [...], "skipped": [...]}``; the spine fills
    ``count``/``bytes`` from ``items`` when the module leaves them out, so a
    small action only has to return what it enumerated. ``items`` are dicts with
    ``path`` (home-tilde is fine) and, where known, ``bytes``/``kind``/``owner``;
    an item may carry ``rel`` to keep its relative path inside the quarantine
    (that is how scratch trees restore cleanly).

    ``run(ctx, confirm)`` returns ``{"ok": true, "changed": true, "moved": [...],
    "count": N, "bytes": N}``. Anything with ``ok: false`` means "could not do
    it" and the spine exits 2; "there was nothing to do" is ``ok: true,
    changed: false``.

    A module may return ``{"ok": false, "reason": "...", "usage": true}`` (or
    raise ``hudfix.UsageError``) to mean "the caller asked wrong" -> exit 2; a
    plain ``{"ok": false, "reason": "..."}`` is honest absence -> exit 0 from
    ``plan``, exit 2 from ``run``.

    Callables are dispatched by arity, so a module written against the card
    text (``plan()`` with no arguments, ``run(ctx, confirm)``) works unchanged.

Context (what a module gets)
    ctx.quarantine(action, items)   move the enumerated items, append MANIFEST.tsv
                                    rows, return {"ok", "moved", "count", "bytes",
                                    "dir", "manifest", "errors"}
    ctx.measure(path)               {"path", "kind", "bytes", "files"} - never raises
    ctx.root(key, default)          a path, honouring ``--root key=PATH`` (a test or
                                    another host points the action somewhere else)
    ctx.params                      {"paths": [--path ...], "options": {--param k=v}}
    ctx.host()                      {"system", "linux", "release", "machine"}
    ctx.which(name)                 is that command on PATH
    ctx.quarantine_dir(action)      <root>/<local date>/<action>
    ctx.log(record)                 append one JSONL record (the spine calls it)
    ctx.now() / ctx.iso_now() / ctx.day

Quarantine and log
    Moves go to ``~/NEXUS_AI_CENTER/_QUARANTINE/<YYYY-MM-DD>/<action>/`` and every
    item appends a row to that day's ``MANIFEST.tsv``:
    ``iso_utc  action  original_path  bytes  destination``. Nothing is ever
    ``rm -rf``-ed; only paths the action enumerated itself are moved, and the
    helper refuses ``/``, ``$HOME``, the quarantine root and anything that would
    move the quarantine root itself. Fragment folders are named by local date
    (what a human sees in Finder); manifest timestamps are UTC ISO-8601.
    ``~/.local/state/nexuslink/hudfix.log`` gets one JSON line per ``plan`` and
    per ``run`` (refusals included), with action, class, items, bytes, result and
    exit. ``--log PATH`` overrides for a test. ``list`` and ``status`` are not
    logged: they change nothing.

Host capability
    A ``linux_only`` action, or one whose ``requires`` command is absent, refuses
    with ``{"ok": false, "reason": "not this host"}``: exit 0 from ``plan``,
    exit 2 from ``run``. The detail (which command, which OS) rides alongside in
    ``detail``/``host`` so the UI can grey the tile out instead of guessing.

Self-check: ``python3 hudfix.py --self-check`` - builds a throwaway tree, a fake
quarantine root and a probe module exporting one action per class, then drives
this CLI as a subprocess. It never touches a real cache, a real quota or the real
quarantine directory.

Stdlib only, Python 3.9+.
"""

from __future__ import annotations

import argparse
import datetime
import glob
import hashlib
import importlib.util
import inspect
import json
import os
import platform
import re
import shutil
import sys
import tempfile
import time

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_PROGRAMMING = 2

VERSION = "1"

CLASSES = ("read", "safe", "reversible", "destructive")
CONFIRM_CLASSES = ("reversible", "destructive")

HERE = os.path.dirname(os.path.abspath(__file__))
THIS = os.path.abspath(__file__)
HOME = os.path.expanduser("~")

DEFAULT_QUARANTINE_ROOT = os.path.join(HOME, "NEXUS_AI_CENTER", "_QUARANTINE")
DEFAULT_LOG = os.path.join(HOME, ".local", "state", "nexuslink", "hudfix.log")

TRACKED_COMMANDS = (
    "pacman", "yay", "paru", "expac", "btrfs", "journalctl", "systemctl",
    "docker", "nvme", "smartctl", "npm", "uv", "pip", "pip3", "cargo", "du",
)

MANIFEST_NAME = "MANIFEST.tsv"
MANIFEST_HEADER = "iso_utc\taction\toriginal_path\tbytes\tdestination\n"


# --------------------------------------------------------------------- helpers


def utc_now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def local_day():
    return datetime.date.today().isoformat()


def tilde(path):
    """Home-relative display form. Output never carries an absolute home path."""
    if not path:
        return ""
    path = os.path.abspath(os.path.expanduser(str(path)))
    if path == HOME:
        return "~"
    if path.startswith(HOME + os.sep):
        return "~" + path[len(HOME):]
    return path


def expand(path):
    return os.path.abspath(os.path.expanduser(str(path)))


def tilde_text(message):
    for base in (HOME, os.path.realpath(HOME)):
        if base and base != "/" and base in message:
            message = message.replace(base + os.sep, "~" + os.sep).replace(base, "~")
    return message


def short_error(exc):
    return tilde_text("%s: %s" % (type(exc).__name__, exc))


def arity(fn):
    """How many positional arguments a callable takes. 99 = accepts anything."""
    try:
        signature = inspect.signature(fn)
    except (TypeError, ValueError):
        return 0
    count = 0
    for param in signature.parameters.values():
        if param.kind in (param.POSITIONAL_ONLY, param.POSITIONAL_OR_KEYWORD):
            count += 1
        elif param.kind is param.VAR_POSITIONAL:
            return 99
    return count


def inside(path, root):
    path = os.path.abspath(path)
    root = os.path.abspath(root)
    return path == root or path.startswith(root + os.sep)


class UsageError(Exception):
    """A module says the caller asked wrong. The spine turns this into exit 2."""


# --------------------------------------------------------------------- context


class Context(object):
    """Everything a module needs, and the only writer of quarantine and log."""

    def __init__(self, quarantine_root=DEFAULT_QUARANTINE_ROOT, log_path=DEFAULT_LOG,
                 overrides=None, params=None, day=None, host=None):
        self.quarantine_root = expand(quarantine_root)
        self.log_path = expand(log_path)
        self.overrides = dict(overrides or {})
        self.params = {"paths": [], "options": {}}
        if params:
            self.params["paths"] = list(params.get("paths") or [])
            self.params["options"] = dict(params.get("options") or {})
        self.day = day or local_day()
        self._host = host
        self.action = None
        self.class_ = None

    # -- paths -------------------------------------------------------------
    def root(self, key, default):
        if key in self.overrides:
            return expand(self.overrides[key])
        return expand(default)

    def path_arg(self, index=0):
        paths = self.params.get("paths") or []
        return paths[index] if len(paths) > index else None

    def option(self, key, default=None):
        return self.params.get("options", {}).get(key, default)

    # -- host --------------------------------------------------------------
    def host(self):
        if self._host is None:
            system = platform.system() or "unknown"
            self._host = {
                "system": system,
                "release": platform.release(),
                "machine": platform.machine(),
                "linux": system == "Linux",
            }
        return self._host

    def which(self, name):
        return shutil.which(name) is not None

    # -- time --------------------------------------------------------------
    def now(self):
        return datetime.datetime.now(datetime.timezone.utc)

    def iso_now(self):
        return utc_now_iso()

    # -- measuring ---------------------------------------------------------
    def measure(self, path):
        """Size a file or directory without following symlinks. Never raises."""
        target = expand(path)
        out = {"path": tilde(target), "kind": "missing", "bytes": 0, "files": 0}
        try:
            info = os.lstat(target)
        except OSError:
            return out
        if os.path.islink(target):
            out["kind"] = "symlink"
            out["bytes"] = info.st_size
            out["files"] = 1
            return out
        if os.path.isfile(target):
            out["kind"] = "file"
            out["bytes"] = info.st_size
            out["files"] = 1
            return out
        if not os.path.isdir(target):
            out["kind"] = "other"
            return out
        out["kind"] = "dir"
        total, files = 0, 0
        for dirpath, dirnames, filenames in os.walk(target, followlinks=False):
            for name in filenames:
                try:
                    stat = os.lstat(os.path.join(dirpath, name))
                except OSError:
                    continue
                total += stat.st_size
                files += 1
            for name in list(dirnames):
                candidate = os.path.join(dirpath, name)
                if os.path.islink(candidate):
                    try:
                        total += os.lstat(candidate).st_size
                    except OSError:
                        pass
                    files += 1
                    dirnames.remove(name)
        out["bytes"] = total
        out["files"] = files
        return out

    # -- quarantine --------------------------------------------------------
    def quarantine_dir(self, action=None):
        parts = [self.quarantine_root, self.day]
        if action:
            parts.append(action)
        return os.path.join(*parts)

    def _refuse_reason(self, path):
        if path in ("/", HOME, self.quarantine_root):
            return "refusing to move %s" % tilde(path)
        if len([part for part in path.split(os.sep) if part]) < 2:
            return "refusing to move %s: too close to the filesystem root" % path
        if inside(path, self.quarantine_root) or inside(self.quarantine_root, path):
            return "refusing to move %s: quarantine root is inside it" % tilde(path)
        return None

    def _destination(self, base, source, rel=None):
        if rel:
            rel = os.path.normpath(str(rel)).lstrip(os.sep)
            if rel.startswith(".."):
                rel = os.path.basename(source)
        else:
            rel = os.path.basename(source)
        candidate = os.path.join(base, rel)
        if not os.path.lexists(candidate):
            return candidate
        stem, suffix = os.path.splitext(candidate)
        index = 1
        while os.path.lexists("%s.%d%s" % (stem, index, suffix)):
            index += 1
        return "%s.%d%s" % (stem, index, suffix)

    def quarantine(self, action, items):
        """Move enumerated items into quarantine and append their MANIFEST rows."""
        rows, errors = [], []
        base = self.quarantine_dir(action)      # <root>/<day>/<action>/<item>
        day_dir = self.quarantine_dir()         # <root>/<day>/MANIFEST.tsv
        for item in items or []:
            source = expand(item.get("path", ""))
            reason = self._refuse_reason(source)
            if reason is None and not os.path.lexists(source):
                reason = "vanished before the move: %s" % tilde(source)
            if reason is not None:
                errors.append({"path": tilde(source), "error": reason})
                continue
            measured = self.measure(source)
            destination = self._destination(base, source, item.get("rel"))
            try:
                os.makedirs(os.path.dirname(destination), exist_ok=True)
                shutil.move(source, destination)
            except OSError as exc:
                errors.append({"path": tilde(source), "error": short_error(exc)})
                continue
            rows.append({
                "ts": utc_now_iso(),
                "action": action,
                "source": source,
                "bytes": measured["bytes"],
                "destination": destination,
            })
        manifest = None
        if rows:
            manifest = os.path.join(day_dir, MANIFEST_NAME)
            problem = self._append_manifest(manifest, rows)
            if problem:
                errors.append({"path": tilde(manifest), "error": problem})
        moved = [{
            "path": tilde(row["source"]),
            "destination": tilde(row["destination"]),
            "bytes": row["bytes"],
        } for row in rows]
        return {
            "ok": not errors,
            "moved": moved,
            "count": len(rows),
            "bytes": sum(row["bytes"] for row in rows),
            "dir": tilde(base) if rows else None,
            "manifest": tilde(manifest) if manifest else None,
            "errors": errors,
        }

    def _append_manifest(self, manifest, rows):
        try:
            os.makedirs(os.path.dirname(manifest), exist_ok=True)
            fresh = not os.path.exists(manifest)
            with open(manifest, "a", encoding="utf-8") as handle:
                if fresh:
                    handle.write(MANIFEST_HEADER)
                for row in rows:
                    handle.write("%s\t%s\t%s\t%d\t%s\n" % (
                        row["ts"], row["action"], row["source"],
                        row["bytes"], row["destination"],
                    ))
                handle.flush()
                os.fsync(handle.fileno())
        except OSError as exc:
            return short_error(exc)
        return None

    # -- log ---------------------------------------------------------------
    def log(self, record):
        """Append one JSONL line. A log failure never fails the command."""
        try:
            parent = os.path.dirname(self.log_path)
            if parent:
                os.makedirs(parent, mode=0o700, exist_ok=True)
            with open(self.log_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(record, ensure_ascii=False,
                                        separators=(",", ":")) + "\n")
                handle.flush()
                os.fsync(handle.fileno())
        except OSError as exc:
            sys.stderr.write("hudfix: log write failed: %s\n" % short_error(exc))
            return short_error(exc)
        return None


# -------------------------------------------------------------------- registry


def _normalise(name, entry, module, errors):
    record = {
        "name": name,
        "module": module,
        "doc": "",
        "class": "invalid",
        "linux_only": False,
        "requires": [],
        "plan": None,
        "run": None,
        "plan_arity": 0,
        "run_arity": 0,
        "error": None,
    }
    if not isinstance(entry, dict):
        record["error"] = "entry is not a dict"
        errors.append({"module": module, "action": name, "error": record["error"]})
        return record
    cls = entry.get("class")
    if cls in CLASSES:
        record["class"] = cls
    else:
        record["error"] = "no valid class (got %r); the action is listed but cannot run" % (cls,)
        errors.append({"module": module, "action": name, "error": record["error"]})
    doc = entry.get("doc")
    record["doc"] = " ".join(str(doc).split()) if doc else ""
    record["linux_only"] = bool(entry.get("linux_only", False))
    requires = entry.get("requires") or []
    if isinstance(requires, str):
        requires = [requires]
    record["requires"] = [str(item) for item in requires if item]
    for key in ("plan", "run"):
        fn = entry.get(key)
        if not callable(fn):
            record["error"] = (record["error"] + "; " if record["error"] else "") + \
                "%s is not callable" % key
            errors.append({"module": module, "action": name,
                           "error": "%s is not callable" % key})
            continue
        record[key] = fn
        record["%s_arity" % key] = arity(fn)
    return record


def discover(module_dir):
    """Import every ``hudfix_*.py`` next to the spine. A missing module is fine."""
    actions, errors = {}, []
    module_dir = expand(module_dir)
    if not os.path.isdir(module_dir):
        return actions, errors
    if module_dir not in sys.path:
        sys.path.insert(0, module_dir)
    for path in sorted(glob.glob(os.path.join(module_dir, "hudfix_*.py"))):
        base = os.path.basename(path)
        module_name = "hudfix_mod_" + os.path.splitext(base)[0]
        try:
            spec = importlib.util.spec_from_file_location(module_name, path)
            if spec is None or spec.loader is None:
                raise ImportError("no loader for %s" % base)
            module = importlib.util.module_from_spec(spec)
            sys.modules[module_name] = module
            spec.loader.exec_module(module)
        except BaseException as exc:  # a broken sibling must not take the spine down
            errors.append({"module": base, "error": short_error(exc)})
            continue
        table = getattr(module, "ACTIONS", None)
        if not isinstance(table, dict):
            errors.append({"module": base, "error": "no ACTIONS dict"})
            continue
        for name in table:
            record = _normalise(name, table[name], base, errors)
            if name in actions:
                errors.append({
                    "module": base, "action": name,
                    "error": "duplicate action; kept the one from %s" % actions[name]["module"],
                })
                continue
            actions[name] = record
    return actions, errors


def call_plan(entry, ctx):
    fn = entry["plan"]
    if fn is None:
        raise UsageError("action %r declares no plan" % entry["name"])
    if entry.get("plan_arity", 0) >= 1:
        return fn(ctx)
    return fn()


def call_run(entry, ctx, confirm):
    fn = entry["run"]
    if fn is None:
        raise UsageError("action %r declares no run" % entry["name"])
    count = entry.get("run_arity", 0)
    if count >= 2:
        return fn(ctx, confirm)
    if count == 1:
        return fn(ctx)
    return fn()


def unavailable(entry, ctx):
    """(reason, detail) when this host cannot run the action, else None."""
    if entry["linux_only"] and not ctx.host()["linux"]:
        return "not this host", "linux only, this is %s" % ctx.host()["system"]
    missing = [name for name in entry["requires"] if not ctx.which(name)]
    if missing:
        return "not this host", "no %s" % ", ".join(missing)
    return None


# ------------------------------------------------------------------- envelopes


def _items(raw):
    items = raw.get("items")
    if not isinstance(items, list):
        return []
    out = []
    for item in items:
        if isinstance(item, dict) and item.get("path"):
            cleaned = dict(item)
            cleaned["path"] = tilde(cleaned["path"])
            out.append(cleaned)
    return out


def plan_payload(entry, ctx):
    """Run the module's plan and normalise it into the contract object."""
    raw = call_plan(entry, ctx)
    if not isinstance(raw, dict):
        raise TypeError("plan() must return a dict, got %s" % type(raw).__name__)
    items = _items(raw)
    count = raw.get("count")
    if not isinstance(count, int) or isinstance(count, bool):
        count = len(items)
    total = raw.get("bytes")
    if not isinstance(total, int) or isinstance(total, bool):
        total = sum(int(item.get("bytes") or 0) for item in items
                    if isinstance(item.get("bytes"), int))
    if entry["class"] == "read":
        default_would = {"verb": "read", "count": count, "bytes": total,
                         "detail": "reads only, no change"}
    else:
        default_would = {"verb": "change", "count": count, "bytes": total,
                         "to": tilde(ctx.quarantine_dir(entry["name"]))}
    payload = {
        "ok": bool(raw.get("ok", True)),
        "action": entry["name"],
        "class": entry["class"],
        "generated_at": utc_now_iso(),
        "source": "live",
        "would": raw.get("would") if isinstance(raw.get("would"), dict) else default_would,
        "items": items,
        "count": count,
        "bytes": total,
        "requires_confirmation": entry["class"] in CONFIRM_CLASSES,
    }
    for key, value in raw.items():
        if key in payload or key in ("items", "count", "bytes", "would"):
            continue
        payload[key] = value
    if ctx.overrides:
        payload["roots_overridden"] = sorted(ctx.overrides)
    if payload["ok"] is False:
        payload.setdefault("reason", "the action reported no plan")
        if payload.get("usage"):
            payload["kind"] = "usage"
    return payload


def run_payload(entry, ctx, confirm):
    """Plan first, then perform. The returned object carries both halves."""
    plan = plan_payload(entry, ctx)
    if plan["ok"] is False:
        return plan, None
    raw = call_run(entry, ctx, confirm)
    if not isinstance(raw, dict):
        raise TypeError("run() must return a dict, got %s" % type(raw).__name__)
    moved_raw = raw.get("moved")
    moved = moved_raw if isinstance(moved_raw, list) else []
    result = {
        "ok": bool(raw.get("ok", True)),
        "changed": bool(raw.get("changed", bool(moved) or plan["count"] > 0)),
        "count": raw.get("count", len(moved)),
        "bytes": raw.get("bytes", sum(int(row.get("bytes") or 0) for row in moved
                                      if isinstance(row.get("bytes"), int))),
        "moved": moved,
    }
    for key, value in raw.items():
        if key not in result:
            result[key] = value
    return plan, result


def emit(payload, compact):
    if compact:
        text = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    else:
        text = json.dumps(payload, ensure_ascii=False, indent=2)
    sys.stdout.write(text + "\n")
    sys.stdout.flush()


def log_record(ctx, event, entry, items, byte_count, result, exit_code, name=None, **extra):
    record = {
        "ts": utc_now_iso(),
        "event": event,
        "action": name or (entry["name"] if entry else None),
        "class": entry["class"] if entry else None,
        "items": items,
        "bytes": byte_count,
        "result": result,
        "exit": exit_code,
        "host": ctx.host()["system"],
    }
    record.update(extra)
    ctx.log(record)


# ------------------------------------------------------------------- commands


def summarise(entry, ctx):
    blocked = unavailable(entry, ctx) if entry["class"] != "invalid" else None
    out = {
        "name": entry["name"],
        "class": entry["class"],
        "doc": entry["doc"],
        "linux_only": entry["linux_only"],
        "module": entry["module"],
        "available": blocked is None and entry["class"] != "invalid",
    }
    if entry["requires"]:
        out["requires"] = entry["requires"]
    if blocked is not None:
        out["unavailable_reason"] = blocked[0]
        out["unavailable_detail"] = blocked[1]
    if entry.get("error"):
        out["error"] = entry["error"]
    return out


def cmd_list(args, ctx, actions, errors):
    payload = {
        "ok": True,
        "generated_at": utc_now_iso(),
        "source": "live",
        "count": len(actions),
        "host": ctx.host(),
        "quarantine_root": tilde(ctx.quarantine_root),
        "log": tilde(ctx.log_path),
        "actions": [summarise(actions[name], ctx) for name in sorted(actions)],
    }
    if errors:
        payload["module_errors"] = errors
    return payload, EXIT_OK


def cmd_status(args, ctx, actions, errors):
    by_class = {name: 0 for name in CLASSES}
    by_class["invalid"] = 0
    available = 0
    for entry in actions.values():
        by_class[entry["class"]] = by_class.get(entry["class"], 0) + 1
        if entry["class"] != "invalid" and unavailable(entry, ctx) is None:
            available += 1
    quarantine = {"root": tilde(ctx.quarantine_root), "day": ctx.day,
                  "exists": os.path.isdir(ctx.quarantine_root),
                  "items_today": 0, "bytes_today": 0, "manifest": None}
    manifest = os.path.join(ctx.quarantine_dir(), MANIFEST_NAME)
    if os.path.isfile(manifest):
        rows = read_manifest(manifest)
        quarantine["manifest"] = tilde(manifest)
        quarantine["items_today"] = len(rows)
        quarantine["bytes_today"] = sum(row["bytes"] or 0 for row in rows)
        if any(row["bytes"] is None or not row["bytes_exact"] for row in rows):
            quarantine["bytes_note"] = "some rows carry a KB figure or no size at all"
    log = {"path": tilde(ctx.log_path), "exists": os.path.isfile(ctx.log_path),
           "bytes": 0, "lines": 0, "last": None}
    if log["exists"]:
        try:
            with open(ctx.log_path, "r", encoding="utf-8") as handle:
                lines = [line for line in handle if line.strip()]
            log["lines"] = len(lines)
            log["bytes"] = os.path.getsize(ctx.log_path)
            if lines:
                try:
                    log["last"] = json.loads(lines[-1])
                except ValueError:
                    log["last"] = None
        except OSError as exc:
            log["error"] = short_error(exc)
    payload = {
        "ok": True,
        "generated_at": utc_now_iso(),
        "source": "live",
        "host": ctx.host(),
        "tools": {name: ctx.which(name) for name in TRACKED_COMMANDS},
        "actions": {
            "total": len(actions),
            "available": available,
            "by_class": by_class,
            "modules": sorted({entry["module"] for entry in actions.values()}),
        },
        "quarantine": quarantine,
        "log": log,
    }
    if errors:
        payload["module_errors"] = errors
    if not actions:
        payload["reason"] = "no hudfix_* module found next to %s" % tilde(THIS)
    return payload, EXIT_OK


def read_manifest(path):
    """Tolerant MANIFEST reader across the layouts that exist in the quarantine.

    Three dialects live on this box:

        iso_utc  action  original_path  bytes  destination      this engine
        orig_path  new_path  size_kb  reason  date               2026-10 legacy
        date  name  reason                                        write-off

    A row this reader cannot map keeps ``None`` where a fact is missing - no
    invented byte count, no invented original path - and a ``bytes_exact`` flag
    says whether the number came from a real byte count or a KB figure.
    """
    rows = []
    try:
        with open(path, "r", encoding="utf-8") as handle:
            lines = [line.rstrip("\n") for line in handle if line.strip()]
    except OSError:
        return rows
    if not lines:
        return rows
    header = [part.strip().lower() for part in lines[0].split("\t")]
    if header and header[0] in ("iso_utc", "orig_path") or "new_path" in header:
        layout = "hudfix" if header[:1] == ["iso_utc"] else "legacy5"
        body = lines[1:]
    else:
        layout = None
        body = lines
    for line in body:
        row = _manifest_row(line.split("\t"), layout)
        if row is not None:
            rows.append(row)
    return rows


def _is_iso_stamp(text):
    return bool(re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}", text or ""))


def _is_day_stamp(text):
    return bool(re.match(r"^\d{4}-\d{2}-\d{2}$", text or ""))


def _manifest_row(parts, layout):
    if layout == "hudfix" or (layout is None and len(parts) >= 5 and _is_iso_stamp(parts[0])):
        if len(parts) < 5:
            return None
        raw = parts[3].strip()
        return {"ts": parts[0], "action": parts[1], "source": parts[2] or None,
                "bytes": int(raw) if raw.isdigit() else None,
                "destination": parts[4] or None, "format": "hudfix",
                "bytes_exact": raw.isdigit(), "reason": None}
    if layout == "legacy5" or (layout is None and len(parts) >= 5
                               and parts[0].startswith("/")):
        if len(parts) < 5:
            return None
        raw = parts[2].strip()
        size = None
        try:
            size = int(round(float(raw) * 1024))
        except ValueError:
            size = None
        return {"ts": parts[4], "action": "quarantine", "source": parts[0] or None,
                "bytes": size, "destination": parts[1] or None, "format": "legacy5",
                "bytes_exact": False, "reason": parts[3] or None}
    if layout is None and len(parts) == 3 and _is_day_stamp(parts[0]):
        return {"ts": parts[0], "action": "quarantine", "source": None, "bytes": None,
                "destination": None, "format": "legacy3", "bytes_exact": False,
                "reason": parts[2] or None, "name": parts[1] or None}
    return None


def cmd_plan(args, ctx, actions, errors):
    started = time.time()
    entry = actions.get(args.action)
    if entry is None:
        log_record(ctx, "plan", None, 0, 0, "refused", EXIT_PROGRAMMING,
                   name=args.action, detail="no such action")
        return unknown_action(args.action, actions), EXIT_PROGRAMMING
    if entry["class"] == "invalid":
        log_record(ctx, "plan", entry, 0, 0, "refused", EXIT_OK,
                   error=entry.get("error"))
        return action_invalid(entry), EXIT_OK
    ctx.action, ctx.class_ = entry["name"], entry["class"]
    blocked = unavailable(entry, ctx)
    if blocked is not None:
        payload = not_this_host(entry, ctx, blocked)
        log_record(ctx, "plan", entry, 0, 0, "refused", EXIT_OK,
                   duration_ms=int((time.time() - started) * 1000), detail=blocked[1])
        return payload, EXIT_OK
    try:
        payload = plan_payload(entry, ctx)
    except (UsageError, BadArguments) as exc:
        payload = {"ok": False, "action": entry["name"], "class": entry["class"],
                   "generated_at": utc_now_iso(), "source": "live",
                   "reason": tilde_text(str(exc)), "kind": "usage"}
        log_record(ctx, "plan", entry, 0, 0, "refused", EXIT_PROGRAMMING,
                   error=payload["reason"])
        return payload, EXIT_PROGRAMMING
    except BaseException as exc:
        payload = {"ok": False, "action": entry["name"], "class": entry["class"],
                   "generated_at": utc_now_iso(), "source": "live",
                   "reason": "action failed: %s" % short_error(exc), "kind": "programming"}
        log_record(ctx, "plan", entry, 0, 0, "error", EXIT_PROGRAMMING,
                   error=payload["reason"])
        return payload, EXIT_PROGRAMMING
    exit_code = EXIT_OK
    if payload.get("ok") is False:
        exit_code = EXIT_PROGRAMMING if payload.get("usage") else EXIT_OK
    log_record(ctx, "plan", entry, payload.get("count", 0), payload.get("bytes", 0),
               "planned" if payload.get("ok") else "absent", exit_code,
               duration_ms=int((time.time() - started) * 1000))
    return payload, exit_code


def cmd_run(args, ctx, actions, errors):
    started = time.time()
    entry = actions.get(args.action)
    if entry is None:
        log_record(ctx, "run", None, 0, 0, "refused", EXIT_PROGRAMMING,
                   name=args.action, detail="no such action")
        return unknown_action(args.action, actions), EXIT_PROGRAMMING
    if entry["class"] == "invalid":
        log_record(ctx, "run", entry, 0, 0, "refused", EXIT_PROGRAMMING,
                   error=entry.get("error"))
        return action_invalid(entry), EXIT_PROGRAMMING
    ctx.action, ctx.class_ = entry["name"], entry["class"]
    confirm = args.confirm
    ctx.params["confirm"] = confirm
    blocked = unavailable(entry, ctx)

    def finish(payload, exit_code, items, byte_count, result, **extra):
        log_record(ctx, "run", entry, items, byte_count, result, exit_code,
                   duration_ms=int((time.time() - started) * 1000),
                   confirmed=confirm is not None, **extra)
        return payload, exit_code

    if blocked is not None:
        return finish(not_this_host(entry, ctx, blocked), EXIT_PROGRAMMING, 0, 0,
                      "refused", detail=blocked[1])

    if entry["class"] in CONFIRM_CLASSES:
        if not confirm:
            payload = refuse(entry, ctx, "confirmation required: run %s --confirm %s"
                             % (entry["name"], entry["name"]))
            return finish(payload, EXIT_PROGRAMMING,
                          payload.get("plan", {}).get("count", 0),
                          payload.get("plan", {}).get("bytes", 0), "refused")
        if confirm != entry["name"]:
            payload = refuse(entry, ctx, "--confirm %s does not match action %s"
                             % (confirm, entry["name"]))
            return finish(payload, EXIT_PROGRAMMING,
                          payload.get("plan", {}).get("count", 0),
                          payload.get("plan", {}).get("bytes", 0), "refused")

    try:
        plan, result = run_payload(entry, ctx, confirm)
    except (UsageError, BadArguments) as exc:
        payload = {"ok": False, "action": entry["name"], "class": entry["class"],
                   "generated_at": utc_now_iso(), "source": "live",
                   "reason": tilde_text(str(exc)), "kind": "usage", "exit": EXIT_PROGRAMMING}
        return finish(payload, EXIT_PROGRAMMING, 0, 0, "refused", error=payload["reason"])
    except BaseException as exc:
        payload = {"ok": False, "action": entry["name"], "class": entry["class"],
                   "generated_at": utc_now_iso(), "source": "live",
                   "reason": "action failed: %s" % short_error(exc),
                   "kind": "programming", "exit": EXIT_PROGRAMMING}
        return finish(payload, EXIT_PROGRAMMING, 0, 0, "error", error=payload["reason"])

    if result is None:
        # the plan itself refused (honest absence, usage error or a policy
        # refusal): a run was asked for and nothing happened, so exit 2.
        plan = dict(plan)
        plan["exit"] = EXIT_PROGRAMMING
        return finish(plan, EXIT_PROGRAMMING, 0, 0, "refused")

    if entry["class"] == "read" and result.get("changed"):
        payload = {
            "ok": False, "action": entry["name"], "class": "read",
            "generated_at": utc_now_iso(), "source": "live",
            "reason": "read action reported a change; refusing to call that a read",
            "plan": plan, "result": result, "changed": True, "exit": EXIT_PROGRAMMING,
        }
        return finish(payload, EXIT_PROGRAMMING, plan.get("count", 0),
                      plan.get("bytes", 0), "error")

    ok = bool(result.get("ok"))
    exit_code = EXIT_OK if ok else EXIT_PROGRAMMING
    payload = {
        "ok": ok,
        "action": entry["name"],
        "class": entry["class"],
        "generated_at": utc_now_iso(),
        "source": "live",
        "confirmed": bool(confirm),
        "plan": plan,
        "result": result,
        "changed": bool(result.get("changed")),
        "exit": exit_code,
    }
    if not ok:
        payload["reason"] = result.get("reason") or "the action could not complete"
    return finish(payload, exit_code, result.get("count", plan.get("count", 0)),
                  result.get("bytes", plan.get("bytes", 0)),
                  "ran" if ok else "failed")


class BadArguments(Exception):
    """Bad CLI input. Same handling as UsageError, kept distinct for clarity."""


def unknown_action(name, actions):
    return {
        "ok": False,
        "generated_at": utc_now_iso(),
        "source": "live",
        "action": name,
        "reason": "no action named %r" % name,
        "kind": "usage",
        "known": sorted(actions),
    }


def action_invalid(entry):
    return {
        "ok": False,
        "generated_at": utc_now_iso(),
        "source": "live",
        "action": entry["name"],
        "class": "invalid",
        "reason": "action %r cannot run: %s" % (entry["name"], entry.get("error") or "broken module"),
        "kind": "programming",
    }


def not_this_host(entry, ctx, blocked):
    return {
        "ok": False,
        "generated_at": utc_now_iso(),
        "source": "live",
        "action": entry["name"],
        "class": entry["class"],
        "reason": blocked[0],
        "detail": blocked[1],
        "host": ctx.host()["system"],
        "linux_only": entry["linux_only"],
    }


def refuse(entry, ctx, reason):
    """A ``run`` that was not confirmed. The plan still rides along for the UI."""
    payload = {
        "ok": False,
        "generated_at": utc_now_iso(),
        "source": "live",
        "action": entry["name"],
        "class": entry["class"],
        "reason": reason,
        "kind": "confirm",
        "requires_confirmation": True,
        "exit": EXIT_PROGRAMMING,
    }
    try:
        payload["plan"] = plan_payload(entry, ctx)
    except BaseException as exc:
        payload["plan_error"] = short_error(exc)
    return payload


# -------------------------------------------------------------------- fixture


def cmd_fixture(path):
    """Replay a recorded object for UI work. Never touches the host."""
    if not os.path.isfile(path):
        payload = {"ok": False, "generated_at": utc_now_iso(), "source": "fixture",
                   "reason": "no fixture at %s" % tilde(path), "kind": "usage"}
        return payload, EXIT_PROGRAMMING
    try:
        with open(path, "r", encoding="utf-8") as handle:
            recorded = json.load(handle)
    except (OSError, ValueError) as exc:
        payload = {"ok": False, "generated_at": utc_now_iso(), "source": "fixture",
                   "reason": "cannot read fixture %s: %s" % (tilde(path), short_error(exc)),
                   "kind": "usage"}
        return payload, EXIT_PROGRAMMING
    if not isinstance(recorded, dict):
        payload = {"ok": False, "generated_at": utc_now_iso(), "source": "fixture",
                   "reason": "fixture is not one JSON object", "kind": "usage"}
        return payload, EXIT_PROGRAMMING
    payload = dict(recorded)
    payload["source"] = "fixture"
    payload["fixture"] = tilde(path)
    return payload, EXIT_OK


# ---------------------------------------------------------------------- parser


def build_parser():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", default=argparse.SUPPRESS,
                        help="one compact JSON line instead of the pretty object")
    common.add_argument("--quarantine-root", metavar="PATH",
                        default=argparse.SUPPRESS,
                        help="quarantine root (default %s)" % tilde(DEFAULT_QUARANTINE_ROOT))
    common.add_argument("--log", metavar="PATH", default=argparse.SUPPRESS,
                        help="JSONL log (default %s)" % tilde(DEFAULT_LOG))
    common.add_argument("--module-dir", metavar="PATH", default=argparse.SUPPRESS,
                        help="where to look for hudfix_*.py (default: next to this file)")
    common.add_argument("--root", metavar="KEY=PATH", action="append",
                        default=argparse.SUPPRESS,
                        help="point a logical root at another path (repeatable)")
    common.add_argument("--path", metavar="PATH", action="append",
                        default=argparse.SUPPRESS,
                        help="an action-specific target path (repeatable)")
    common.add_argument("--param", metavar="KEY=VALUE", action="append",
                        default=argparse.SUPPRESS,
                        help="an action-specific option (repeatable)")
    common.add_argument("--fixture", metavar="PATH", default=argparse.SUPPRESS,
                        help="replay a recorded object instead of touching the host")

    parser = argparse.ArgumentParser(
        prog="hudfix.py",
        description="HUD maintenance engine: typed actions with a plan, a class and a log.",
    )
    parser.add_argument("--version", action="version", version="hudfix " + VERSION)
    parser.add_argument("--self-check", action="store_true",
                        help="prove the engine on a throwaway tree and exit")
    for action in common._actions:
        if action.dest == "help":
            continue
        parser._add_action(action)

    subs = parser.add_subparsers(dest="command")
    for name, help_text in (
        ("list", "every action, its class and whether this host can run it"),
        ("plan", "dry run one action: exact items, exact bytes"),
        ("run", "perform one action"),
        ("status", "host, action census, quarantine and log state"),
    ):
        sub = subs.add_parser(name, parents=[common], help=help_text)
        if name in ("plan", "run"):
            sub.add_argument("action", help="action name from list")
        if name == "run":
            sub.add_argument("--confirm", metavar="ACTION", default=None,
                             help="must equal the action name for reversible/destructive")
    return parser


def context_from(args):
    overrides = {}
    for spec in getattr(args, "root", []) or []:
        if "=" not in spec:
            raise BadArguments("--root wants KEY=PATH, got %r" % spec)
        key, value = spec.split("=", 1)
        if not key or not value:
            raise BadArguments("--root wants KEY=PATH, got %r" % spec)
        overrides[key] = value
    options = {}
    for spec in getattr(args, "param", []) or []:
        if "=" not in spec:
            raise BadArguments("--param wants KEY=VALUE, got %r" % spec)
        key, value = spec.split("=", 1)
        options[key] = value
    ctx = Context(
        quarantine_root=getattr(args, "quarantine_root", DEFAULT_QUARANTINE_ROOT),
        log_path=getattr(args, "log", DEFAULT_LOG),
        overrides=overrides,
        params={"paths": list(getattr(args, "path", []) or []), "options": options},
    )
    return ctx


# ------------------------------------------------------------------------ main


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if __name__ == "__main__":
        # A sibling module does ``import hudfix``; give it this exact instance so
        # the Context class and the helper functions are the same objects.
        sys.modules.setdefault("hudfix", sys.modules["__main__"])
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.self_check:
        return self_check()
    if not args.command:
        parser.print_usage(sys.stderr)
        sys.stderr.write("hudfix: a command is required: list, plan, run, status\n")
        return EXIT_PROGRAMMING
    compact = bool(getattr(args, "json", False))
    try:
        ctx = context_from(args)
    except BadArguments as exc:
        emit({"ok": False, "generated_at": utc_now_iso(), "source": "live",
              "reason": str(exc), "kind": "usage"}, compact)
        return EXIT_PROGRAMMING
    module_dir = getattr(args, "module_dir", HERE)
    actions, errors = discover(module_dir)
    if args.command == "list" and getattr(args, "fixture", None):
        payload, code = cmd_fixture(args.fixture)
    elif args.command == "plan" and getattr(args, "fixture", None):
        payload, code = cmd_fixture(args.fixture)
    elif args.command == "status" and getattr(args, "fixture", None):
        payload, code = cmd_fixture(args.fixture)
    elif args.command == "run" and getattr(args, "fixture", None):
        payload, code = ({"ok": False, "generated_at": utc_now_iso(), "source": "fixture",
                          "reason": "run does not accept --fixture: a recorded object "
                                    "cannot be executed", "kind": "usage"},
                         EXIT_PROGRAMMING)
    elif args.command == "list":
        payload, code = cmd_list(args, ctx, actions, errors)
    elif args.command == "status":
        payload, code = cmd_status(args, ctx, actions, errors)
    elif args.command == "plan":
        payload, code = cmd_plan(args, ctx, actions, errors)
    else:
        payload, code = cmd_run(args, ctx, actions, errors)
    emit(payload, compact)
    return code


# ------------------------------------------------------------------- self-check


PROBE_SOURCE = '''"""Probe module written by ``hudfix.py --self-check``. Throwaway."""
import os

TREE = %(tree)r
MARKS = %(marks)r


def _files(sub):
    root = os.path.join(TREE, sub)
    out = []
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name)
        out.append({"path": path, "bytes": os.path.getsize(path)})
    return out


def plan_read():
    return {"items": _files("keep"), "would": {"verb": "read", "count": 1, "bytes": 7}}


def run_read(ctx, confirm):
    return {"ok": True, "changed": False, "count": 0, "bytes": 0}


def plan_safe(ctx):
    return {"items": [{"path": os.path.join(MARKS, "safe.marker"), "bytes": 0}],
            "would": {"verb": "write", "count": 1, "bytes": 0},
            "notes": ["safe actions do not ask for confirmation"]}


def run_safe(ctx, confirm):
    with open(os.path.join(MARKS, "safe.marker"), "w", encoding="utf-8") as handle:
        handle.write("safe")
    return {"ok": True, "changed": True, "count": 1, "bytes": 0}


def plan_move(ctx):
    return {"items": _files("move"),
            "would": {"verb": "move", "count": len(_files("move")),
                      "bytes": sum(item["bytes"] for item in _files("move")),
                      "to": ctx.quarantine_dir("probe-move")}}


def run_move(ctx, confirm):
    result = ctx.quarantine("probe-move", _files("move"))
    return {"ok": result["ok"], "changed": result["count"] > 0,
            "moved": result["moved"], "count": result["count"],
            "bytes": result["bytes"]}


def plan_nuke():
    return {"items": [{"path": os.path.join(MARKS, "nuke.marker"), "bytes": 0}],
            "would": {"verb": "write", "count": 1, "bytes": 0}}


def run_nuke(ctx, confirm):
    with open(os.path.join(MARKS, "nuke.marker"), "w", encoding="utf-8") as handle:
        handle.write("nuked")
    return {"ok": True, "changed": True, "count": 1, "bytes": 0}


def plan_linux():
    return {"items": [], "would": {"verb": "read"}}


def run_linux(ctx, confirm):
    with open(os.path.join(MARKS, "linux.marker"), "w", encoding="utf-8") as handle:
        handle.write("linux")
    return {"ok": True, "changed": True, "count": 0, "bytes": 0}


def plan_usage():
    return {"ok": False, "reason": "probe-usage needs --path", "usage": True}


ACTIONS = {
    "probe-read": {"class": "read", "doc": "lists the tree, changes nothing",
                   "plan": plan_read, "run": run_read},
    "probe-safe": {"class": "safe", "doc": "writes a marker without confirmation",
                   "plan": plan_safe, "run": run_safe},
    "probe-move": {"class": "reversible", "doc": "moves the tree's move/ files to quarantine",
                   "plan": plan_move, "run": run_move},
    "probe-nuke": {"class": "destructive", "doc": "writes a marker, unrecoverable on purpose",
                   "plan": plan_nuke, "run": run_nuke},
    "probe-linux": {"class": "safe", "doc": "linux only, must refuse on this host",
                    "plan": plan_linux, "run": run_linux, "linux_only": True},
    "probe-tool": {"class": "safe", "doc": "needs a command this host lacks",
                   "plan": plan_linux, "run": run_linux,
                   "requires": ["no-such-command-hopefully"]},
    "probe-usage": {"class": "safe", "doc": "reports a usage error",
                    "plan": plan_usage, "run": run_linux},
    "probe-invalid": {"doc": "declares no class", "plan": plan_read, "run": run_read},
}
'''


class Checks(object):
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.rows = []

    def ok(self, name, condition, detail=""):
        if condition:
            self.passed += 1
            self.rows.append({"check": name, "ok": True})
        else:
            self.failed += 1
            self.rows.append({"check": name, "ok": False, "detail": tilde_text(str(detail))})

    def eq(self, name, got, want):
        self.ok(name, got == want, "got %r want %r" % (got, want))


def _run_cli(base, args, timeout=120):
    import subprocess
    command = [sys.executable, THIS] + base + list(args)
    try:
        proc = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, "", "timeout"
    return (proc.returncode,
            proc.stdout.decode("utf-8", "replace"),
            proc.stderr.decode("utf-8", "replace"))


def _one_object(raw, single_line=True):
    """stdout parses as exactly one JSON object and carries nothing else."""
    text = raw.strip()
    if not text:
        return None
    if single_line and "\n" in text:
        return None
    try:
        value = json.loads(text)
    except ValueError:
        return None
    return value if isinstance(value, dict) else None


def _tree_digest(root):
    digest = hashlib.sha256()
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        filenames.sort()
        digest.update(b"dir:" + os.path.relpath(dirpath, root).encode())
        for name in filenames:
            path = os.path.join(dirpath, name)
            digest.update(b"file:" + os.path.relpath(path, root).encode())
            with open(path, "rb") as handle:
                digest.update(handle.read())
    return digest.hexdigest()


# Public aliases: a module's own self-check may reuse this harness.
run_cli = _run_cli
one_object = _one_object
tree_digest = _tree_digest


def _write_tree(base):
    tree = os.path.join(base, "tree")
    marks = os.path.join(base, "marks")
    for sub in ("keep", "move"):
        os.makedirs(os.path.join(tree, sub))
    os.makedirs(marks)
    with open(os.path.join(tree, "keep", "a.txt"), "wb") as handle:
        handle.write(b"A" * 1000)
    with open(os.path.join(tree, "move", "one.bin"), "wb") as handle:
        handle.write(b"1" * 300)
    with open(os.path.join(tree, "move", "two.bin"), "wb") as handle:
        handle.write(b"22" * 50)
    return tree, marks


def self_check():  # noqa: C901 - one linear proof, on purpose
    base = tempfile.mkdtemp(prefix="hudfix-selfcheck-")
    checks = Checks()
    summary = {"ok": False, "self_check": "hudfix", "version": VERSION,
               "generated_at": utc_now_iso(), "workdir": tilde(base)}
    try:
        tree, marks = _write_tree(base)
        mods = os.path.join(base, "mods")
        quarantine = os.path.join(base, "quarantine")
        log_path = os.path.join(base, "hudfix.log")
        os.makedirs(mods)
        with open(os.path.join(mods, "hudfix_probe.py"), "w", encoding="utf-8") as handle:
            handle.write(PROBE_SOURCE % {"tree": tree, "marks": marks})

        base_args = ["--module-dir", mods, "--quarantine-root", quarantine,
                     "--log", log_path]
        digest_before = _tree_digest(tree)
        counts = {"plan": 0, "run": 0}

        def cli(argv):
            if argv and argv[0] in counts and "--fixture" not in argv:
                counts[argv[0]] += 1
            return _run_cli(base_args, argv)

        # ---- list ---------------------------------------------------------
        code, out, err = cli(["list", "--json"])
        checks.eq("list.exit", code, EXIT_OK)
        listing = _one_object(out)
        checks.ok("list.one_object", listing is not None, out or err)
        names = [row["name"] for row in listing.get("actions", [])] if listing else []
        checks.eq("list.count", listing.get("count") if listing else None, 8)
        checks.eq("list.names", names, sorted([
            "probe-invalid", "probe-linux", "probe-move", "probe-nuke",
            "probe-read", "probe-safe", "probe-tool", "probe-usage"]))
        classes = {row["name"]: row["class"] for row in listing.get("actions", [])} \
            if listing else {}
        checks.eq("list.class.read", classes.get("probe-read"), "read")
        checks.eq("list.class.safe", classes.get("probe-safe"), "safe")
        checks.eq("list.class.reversible", classes.get("probe-move"), "reversible")
        checks.eq("list.class.destructive", classes.get("probe-nuke"), "destructive")
        checks.eq("list.class.invalid", classes.get("probe-invalid"), "invalid")
        checks.ok("list.invalid_surfaced",
                  any(row.get("error") for row in listing.get("actions", [])
                      if row["name"] == "probe-invalid") if listing else False)
        checks.ok("list.linux_only_unavailable",
                  any(row["name"] == "probe-linux" and row["available"] is False
                      for row in listing.get("actions", [])) if listing else False)
        checks.eq("list.pretty_default_ok",
                  _one_object(cli(["list"])[1], single_line=False) is not None, True)

        # ---- plan changes nothing ----------------------------------------
        code, out, err = cli(["plan", "probe-move", "--json"])
        plan = _one_object(out)
        checks.eq("plan.move.exit", code, EXIT_OK)
        checks.ok("plan.move.object", plan is not None, out or err)
        checks.eq("plan.move.count", plan.get("count") if plan else None, 2)
        checks.eq("plan.move.bytes", plan.get("bytes") if plan else None, 400)
        checks.eq("plan.move.would_verb", (plan.get("would") or {}).get("verb")
                  if plan else None, "move")
        checks.eq("plan.move.requires_confirmation",
                  plan.get("requires_confirmation") if plan else None, True)
        checks.eq("plan.move.class", plan.get("class") if plan else None, "reversible")
        checks.eq("plan.move.tree_unchanged", _tree_digest(tree), digest_before)

        # ---- run without confirm refuses ---------------------------------
        code, out, err = cli(["run", "probe-move", "--json"])
        refused = _one_object(out)
        checks.eq("run.unconfirmed.exit", code, EXIT_PROGRAMMING)
        checks.eq("run.unconfirmed.ok", refused.get("ok") if refused else None, False)
        checks.ok("run.unconfirmed.reason",
                  "confirmation required" in (refused or {}).get("reason", ""))
        checks.eq("run.unconfirmed.tree_unchanged", _tree_digest(tree), digest_before)
        checks.ok("run.unconfirmed.ships_plan",
                  isinstance((refused or {}).get("plan"), dict))

        # ---- a mismatched confirm is refused too -------------------------
        code, out, _err = cli(["run", "probe-nuke",
                                               "--confirm", "probe-move", "--json"])
        mismatch = _one_object(out)
        checks.eq("run.mismatch.exit", code, EXIT_PROGRAMMING)
        checks.ok("run.mismatch.reason",
                  "does not match" in (mismatch or {}).get("reason", ""))
        checks.ok("run.mismatch.no_change",
                  not os.path.exists(os.path.join(marks, "nuke.marker")))

        # ---- confirmed run quarantines and writes the manifest -----------
        code, out, err = cli(["run", "probe-move",
                                              "--confirm", "probe-move", "--json"])
        ran = _one_object(out)
        checks.eq("run.confirmed.exit", code, EXIT_OK)
        checks.ok("run.confirmed.object", ran is not None, out or err)
        checks.eq("run.confirmed.ok", ran.get("ok") if ran else None, True)
        checks.eq("run.confirmed.changed", ran.get("changed") if ran else None, True)
        checks.eq("run.confirmed.count", (ran or {}).get("result", {}).get("count"), 2)
        checks.ok("run.confirmed.tree_emptied",
                  os.listdir(os.path.join(tree, "move")) == [])
        manifest = os.path.join(quarantine, local_day(), MANIFEST_NAME)
        checks.ok("run.confirmed.manifest_exists", os.path.isfile(manifest), manifest)
        rows = read_manifest(manifest) if os.path.isfile(manifest) else []
        checks.eq("run.confirmed.manifest_rows", len(rows), 2)
        checks.eq("run.confirmed.manifest_bytes",
                  sum(row["bytes"] for row in rows), 400)
        checks.ok("run.confirmed.manifest_action",
                  all(row["action"] == "probe-move" for row in rows))
        checks.ok("run.confirmed.manifest_columns",
                  all(len(row["source"].split("\t")) == 1 and row["source"].startswith("/")
                      for row in rows))
        checks.ok("run.confirmed.manifest_destinations_exist",
                  all(os.path.exists(row["destination"]) for row in rows))
        checks.ok("run.confirmed.destinations_under_quarantine",
                  all(row["destination"].startswith(quarantine) for row in rows))

        # ---- a safe action runs with no confirm --------------------------
        code, out, _err = cli(["run", "probe-safe", "--json"])
        safe = _one_object(out)
        checks.eq("run.safe.exit", code, EXIT_OK)
        checks.eq("run.safe.changed", safe.get("changed") if safe else None, True)
        checks.ok("run.safe.marker", os.path.isfile(os.path.join(marks, "safe.marker")))
        checks.ok("run.safe.plan_first", isinstance((safe or {}).get("plan"), dict))

        # ---- a destructive action needs its exact name -------------------
        code, out, _err = cli(["run", "probe-nuke",
                                               "--confirm", "probe-nuke", "--json"])
        nuke = _one_object(out)
        checks.eq("run.destructive.exit", code, EXIT_OK)
        checks.eq("run.destructive.class", nuke.get("class") if nuke else None,
                  "destructive")
        checks.ok("run.destructive.marker", os.path.isfile(os.path.join(marks, "nuke.marker")))

        # ---- read actions never change anything --------------------------
        code, out, _err = cli(["run", "probe-read", "--json"])
        read_run = _one_object(out)
        checks.eq("run.read.exit", code, EXIT_OK)
        checks.eq("run.read.changed", read_run.get("changed") if read_run else None, False)

        # ---- linux-only and missing-command refusals ---------------------
        code, out, _err = cli(["plan", "probe-linux", "--json"])
        linux_plan = _one_object(out)
        if platform.system() == "Linux":
            checks.eq("plan.linux.exit", code, EXIT_OK)
            checks.eq("plan.linux.ran_here", (linux_plan or {}).get("ok"), True)
        else:
            checks.eq("plan.linux.exit", code, EXIT_OK)
            checks.eq("plan.linux.ok", (linux_plan or {}).get("ok"), False)
            checks.eq("plan.linux.reason", (linux_plan or {}).get("reason"), "not this host")
            checks.ok("plan.linux.detail",
                      "linux only" in (linux_plan or {}).get("detail", ""))
            code, out, _err = cli(["run", "probe-linux",
                                                   "--confirm", "probe-linux", "--json"])
            checks.eq("run.linux.exit", code, EXIT_PROGRAMMING)
            checks.eq("run.linux.reason",
                      (_one_object(out) or {}).get("reason"), "not this host")
            checks.ok("run.linux.no_marker",
                      not os.path.exists(os.path.join(marks, "linux.marker")))
        code, out, _err = cli(["plan", "probe-tool", "--json"])
        tool = _one_object(out)
        checks.eq("plan.requires.exit", code, EXIT_OK)
        checks.eq("plan.requires.reason", (tool or {}).get("reason"), "not this host")
        checks.ok("plan.requires.detail", "no-such-command" in (tool or {}).get("detail", ""))

        # ---- usage, unknown action, invalid class ------------------------
        code, out, _err = cli(["plan", "probe-usage", "--json"])
        checks.eq("plan.usage.exit", code, EXIT_PROGRAMMING)
        checks.eq("plan.usage.kind", (_one_object(out) or {}).get("kind"), "usage")
        code, out, _err = cli(["plan", "nope", "--json"])
        checks.eq("plan.unknown.exit", code, EXIT_PROGRAMMING)
        checks.ok("plan.unknown.reason",
                  "no action named" in ((_one_object(out) or {}).get("reason") or ""))
        code, out, _err = cli(["run", "probe-invalid",
                                               "--confirm", "probe-invalid", "--json"])
        checks.eq("run.invalid.exit", code, EXIT_PROGRAMMING)
        checks.eq("run.invalid.class", (_one_object(out) or {}).get("class"), "invalid")

        # ---- fixture replay and its missing-file exit --------------------
        recorded = os.path.join(base, "recorded.json")
        with open(recorded, "w", encoding="utf-8") as handle:
            json.dump({"ok": True, "count": 0, "actions": [], "generated_at": "x",
                       "source": "live"}, handle)
        code, out, _err = cli(["list", "--fixture", recorded, "--json"])
        replay = _one_object(out)
        checks.eq("fixture.exit", code, EXIT_OK)
        checks.eq("fixture.source", (replay or {}).get("source"), "fixture")
        checks.ok("fixture.path_recorded", "recorded.json" in (replay or {}).get("fixture", ""))
        code, out, _err = cli(["list", "--fixture",
                                               os.path.join(base, "nope.json"), "--json"])
        checks.eq("fixture.missing.exit", code, EXIT_PROGRAMMING)
        code, _out, _err = cli(["run", "probe-move",
                                                "--confirm", "probe-move",
                                                "--fixture", recorded, "--json"])
        checks.eq("fixture.run_refused", code, EXIT_PROGRAMMING)

        # ---- status ------------------------------------------------------
        code, out, err = cli(["status", "--json"])
        status = _one_object(out)
        checks.eq("status.exit", code, EXIT_OK)
        checks.ok("status.object", status is not None, out or err)
        checks.eq("status.actions.total", (status or {}).get("actions", {}).get("total"), 8)
        checks.ok("status.quarantine_rows",
                  (status or {}).get("quarantine", {}).get("items_today") == 2,
                  repr((status or {}).get("quarantine")))
        checks.ok("status.host_system", bool((status or {}).get("host", {}).get("system")))

        # ---- log: one line per plan and per run --------------------------
        with open(log_path, "r", encoding="utf-8") as handle:
            lines = [json.loads(line) for line in handle if line.strip()]
        checks.ok("log.parses", all(isinstance(row, dict) for row in lines))
        required = ("ts", "event", "action", "class", "items", "bytes", "result", "exit")
        checks.ok("log.fields", all(all(key in row for key in required) for row in lines),
                  repr([row.get("event") for row in lines]))
        events = [row["event"] for row in lines]
        plans = events.count("plan")
        runs = events.count("run")
        # one line per plan and per run that reached the engine (refusals included)
        checks.eq("log.plan_lines", plans, counts["plan"])
        checks.eq("log.run_lines", runs, counts["run"])
        checks.ok("log.plan_lines_floor", plans >= 5, repr(counts))
        checks.ok("log.run_lines_floor", runs >= 7, repr(counts))
        checks.eq("log.no_list_line", any(row["event"] in ("list", "status") for row in lines),
                  False)
        checks.ok("log.refusals_logged",
                  sum(1 for row in lines if row["result"] == "refused") >= 4,
                  repr([(row["event"], row["result"], row["exit"]) for row in lines]))
        checks.ok("log.has_bytes",
                  any(row["bytes"] > 0 for row in lines))
        checks.ok("log.timestamps_utc",
                  all(row["ts"].endswith("Z") for row in lines))

        # ---- the quarantine never leaks outside the fake root ------------
        checks.ok("quarantine.only_fake_root",
                  all(os.path.abspath(row["destination"]).startswith(quarantine)
                      for row in rows))
        checks.ok("quarantine.real_root_untouched",
                  not os.path.exists(os.path.join(DEFAULT_QUARANTINE_ROOT, local_day(),
                                                  "probe-move")))
    except BaseException as exc:  # the self-check itself must not traceback silently
        checks.ok("self_check.completed", False, "%s: %s" % (type(exc).__name__, exc))
    summary["passed"] = checks.passed
    summary["failed"] = checks.failed
    summary["checks"] = checks.rows
    summary["ok"] = checks.failed == 0
    if checks.failed:
        summary["reason"] = "%d of %d checks failed; the tree is left at %s" % (
            checks.failed, checks.passed + checks.failed, tilde(base))
    else:
        shutil.rmtree(base, ignore_errors=True)
    emit(summary, True)
    return EXIT_OK if checks.failed == 0 else EXIT_FAILED


if __name__ == "__main__":
    sys.exit(main())
