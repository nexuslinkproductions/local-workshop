#!/usr/bin/env python3
"""Storage view actions for the hudfix engine (v5 F8a).

The Storage widget's expanded view is where the deck stops being a dashboard and
starts fixing things. This module owns the disk half of that: the caches that
grow back on their own, the trees nobody misses, the read-only health probes, and
the two tools whose own delete path has no way back.

Everything here is an ACTIONS entry for the spine in ``hudfix.py``:

    ACTIONS = {"<name>": {"class", "doc", "plan", "run", "linux_only", "requires"}}

Class policy (MAIN-SCREEN-BUILD.md, "Safety model"):
    read         probes only. ``run`` is the same observation and reports
                 ``changed: false``. Nothing on disk is written.
    reversible  every deletion is a move into quarantine, so the MANIFEST row
                 is a restore instruction. Requires ``--confirm <action>``.
    destructive only ``journal-vacuum`` and ``docker-prune``: journald rewrites
                 its own segment files and a docker builder cache or dangling
                 layer has no copy anywhere, so neither can be quarantined. The
                 ``doc`` on each says that in one sentence.

Root overrides (``--root KEY=PATH``, used by tests and by another host)
    npm      default ~/.npm                                    cache-npm
    uv       default ~/.cache/uv                               cache-uv
    pip      default ~/.cache/pip                              cache-pip
    cargo    default ~/.cargo                                  cache-cargo
    cache    default ~/.cache                                  cache-top, cache-evict, cache-yay
    hermes   default ~/.hermes                                 hermes-scratch
    trash    default ~/.local/share/Trash/files (Linux)
                     ~/.Trash (macOS)                          trash
    pacman   default /var/cache/pacman/pkg                      cache-pacman
    yay      default ~/.cache/yay                              cache-yay
    smart    a file holding a recorded ``smartctl -a`` dump     disk-health
    days     ``--param days=7`` looks back that far in MANIFEST.tsv  quarantine-list

Age thresholds (deliberately conservative, and stated in every plan)
    ~/.hermes/cache/scratch   7 days   (the system prompt's own prune is 24 h)
    ~/.hermes/logs/*.log      14 days
    trash                     30 days

What this module will not do
    * clear a ``~/.cache`` child it cannot attribute to a known owner
      (``cache-top`` reports the top 10 and marks them; ``cache-evict`` takes one
      direct child only and refuses a name it cannot attribute, so a deeper path
      under an unattributed directory is refused before anything is measured);
    * delete a btrfs snapshot (there is no delete action at all - only a listing);
    * remove a package (``orphans-list`` lists orphans and prints no command that
      would remove them);
    * run ``sudo``. A probe that needs root reports that it needs root.

Self-check: ``python3 hudfix_storage.py --self-check`` builds a fake home under
$TMPDIR, points every root at it, and drives ``hudfix.py`` as a subprocess. It
never reads or writes a real cache, a real snapshot, or the real quarantine.
"""

from __future__ import annotations

import datetime
import functools
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import hudfix  # noqa: E402  (the spine: Context, quarantine, MANIFEST reader)

tilde = hudfix.tilde
expand = hudfix.expand

DAY = 86400
SCRATCH_AGE_S = 7 * DAY
HERMES_LOG_AGE_S = 14 * DAY
TRASH_AGE_S = 30 * DAY
TOP_CONSUMERS = 10

# A ~/.cache child is only clearable when it matches one of these owners. The
# rule from the card: "never clear a path you cannot attribute".
ATTRIBUTION = (
    ("uv", "uv"),
    ("pip", "pip"),
    ("npm", "npm"),
    ("yarn", "yarn"),
    ("pnpm", "pnpm"),
    ("cargo", "cargo"),
    ("yay", "yay"),
    ("paru", "paru"),
    ("huggingface", "huggingface"),
    ("torch", "torch"),
    ("whisper", "openai-whisper"),
    ("ms-playwright", "playwright"),
    ("playwright", "playwright"),
    ("puppeteer", "puppeteer"),
    ("chromium", "chromium"),
    ("google-chrome", "chrome"),
    ("node-gyp", "node-gyp"),
    ("go-build", "go"),
    ("hermes", "hermes"),
    ("claude", "claude"),
    ("fontconfig", "fontconfig"),
    ("mesa_shader_cache", "mesa"),
    ("sccache", "sccache"),
    ("electron", "electron"),
    ("typescript", "typescript"),
    ("vite", "vite"),
    ("deno", "deno"),
    ("bun", "bun"),
    ("prisma", "prisma"),
    ("devin", "devin"),
    ("gh", "github-cli"),
    ("go/pkg", "go"),
    ("pip-tools", "pip-tools"),
)

# Patterns that only ever match a name exactly. The GitHub CLI's cache is the
# one case where a shared prefix is a trap: ghostty is a terminal emulator, not
# a GitHub CLI cache, and no continuation of "gh" is the CLI either.
EXACT_ONLY = ("gh",)


def attribute(name):
    """Known owner for a cache directory name, else None. Exact; case-sensitive.

    A name carries an owner when it equals a pattern or continues that pattern
    after ``-``, ``_`` or ``.``: ``uv`` and ``uv-3`` are uv, while ``ghostty`` is
    not ``gh`` and ``pipenv`` is not ``pip``. The longest matching pattern wins,
    so ``pip-tools`` beats ``pip``.

    The comparison is byte-for-byte: no case folding and no whitespace trimming.
    ``GH``, ``gh `` and `` gh`` are three names that are not ``gh``, so on a
    case-sensitive filesystem they stay unattributed and cannot be evicted. On
    APFS ``GH`` and ``gh`` normally resolve to the same directory, whose stored
    name is whatever was created first; keeping the rule exact means a spelling
    the engine does not know is never cleared, which is the safe direction. See
    HUDFIX.md, "Attribution".
    """
    if not name:
        return None
    for pattern, owner in ATTRIBUTION:
        if name == pattern:
            return owner
    best = None
    for pattern, owner in ATTRIBUTION:
        if pattern in EXACT_ONLY:
            continue
        following = name[len(pattern):len(pattern) + 1]
        if name.startswith(pattern) and following in ("-", "_", "."):
            if best is None or len(pattern) > len(best[0]):
                best = (pattern, owner)
    return best[1] if best else None


# --------------------------------------------------------------------- helpers


def _run(argv, timeout=10.0):
    """(rc, stdout, stderr). A missing command is rc None, never an exception."""
    try:
        proc = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=timeout)
    except (OSError, subprocess.SubprocessError) as exc:
        return None, "", "%s: %s" % (type(exc).__name__, exc)
    return (proc.returncode,
            proc.stdout.decode("utf-8", "replace"),
            proc.stderr.decode("utf-8", "replace"))


def _first_line(text, limit=200):
    for line in (text or "").splitlines():
        line = line.strip()
        if line:
            return line[:limit]
    return ""


def _plan_reversible(ctx, action, candidates, notes=None, skipped=None, extra=None):
    """Enumerate existing paths into the spine's plan shape. Nothing is touched."""
    items, missing = [], list(skipped or [])
    for spec in candidates:
        target = spec["path"]
        measured = ctx.measure(target)
        if measured["kind"] == "missing":
            missing.append({"path": tilde(target), "reason": "absent"})
            continue
        item = {
            "path": tilde(target),
            "bytes": measured["bytes"],
            "files": measured["files"],
            "kind": measured["kind"],
        }
        for key, value in spec.items():
            if key not in item:
                item[key] = value
        items.append(item)
    total = sum(int(item["bytes"]) for item in items)
    plan = {
        "ok": True,
        "items": items,
        "count": len(items),
        "bytes": total,
        "would": {
            "verb": "move",
            "count": len(items),
            "bytes": total,
            "to": tilde(ctx.quarantine_dir(action)),
        },
        "notes": list(notes or []),
        "skipped": missing,
    }
    if extra:
        plan.update(extra)
    return plan


def _run_clear(ctx, action, plan):
    """Move exactly the plan's items. Re-enumerated by the caller at run time."""
    if not plan.get("items"):
        return {"ok": True, "changed": False, "count": 0, "bytes": 0, "moved": [],
                "reason": "nothing to clear"}
    result = ctx.quarantine(action, plan["items"])
    out = {
        "ok": result["ok"],
        "changed": result["count"] > 0,
        "count": result["count"],
        "bytes": result["bytes"],
        "moved": result["moved"],
        "quarantine": {"dir": result["dir"], "manifest": result["manifest"]},
    }
    if result["errors"]:
        out["errors"] = result["errors"]
        out["reason"] = "%d item(s) could not be moved" % len(result["errors"])
    return out


def _read_run():
    return {"ok": True, "changed": False, "count": 0, "bytes": 0}


def _parse_size(text):
    """'1.2G', '512M', '4,096 B' -> bytes. None when unparseable."""
    if not text:
        return None
    match = re.search(r"([\d.,]+)\s*([KMGTPE]?)i?B?", text.strip(), re.IGNORECASE)
    if not match:
        return None
    try:
        value = float(match.group(1).replace(",", ""))
    except ValueError:
        return None
    unit = (match.group(2) or "").upper()
    scale = {"": 1, "K": 1024, "M": 1024 ** 2, "G": 1024 ** 3,
             "T": 1024 ** 4, "P": 1024 ** 5, "E": 1024 ** 6}[unit]
    return int(value * scale)


# ------------------------------------------------------------------- cache-npm


def _npm_plan(ctx):
    root = ctx.root("npm", "~/.npm")
    return _plan_reversible(ctx, "cache-npm", [
        {"path": os.path.join(root, "_cacache"), "owner": "npm",
         "note": "content-addressed package cache"},
        {"path": os.path.join(root, "_logs"), "owner": "npm",
         "note": "npm debug logs"},
    ], notes=["npm recreates _cacache on the next install; a restore is a move back "
              "from the quarantine path in the MANIFEST row"])


def plan_cache_npm(ctx):
    return _npm_plan(ctx)


def run_cache_npm(ctx, confirm):
    return _run_clear(ctx, "cache-npm", _npm_plan(ctx))


# -------------------------------------------------------------------- cache-uv


def _uv_plan(ctx):
    root = ctx.root("uv", "~/.cache/uv")
    return _plan_reversible(ctx, "cache-uv", [
        {"path": root, "owner": "uv", "note": "uv's package and wheel cache"},
    ], notes=["equivalent to `uv cache clean`; uv rebuilds what it needs"])


def plan_cache_uv(ctx):
    return _uv_plan(ctx)


def run_cache_uv(ctx, confirm):
    return _run_clear(ctx, "cache-uv", _uv_plan(ctx))


# ------------------------------------------------------------------- cache-pip


def _pip_plan(ctx):
    root = ctx.root("pip", "~/.cache/pip")
    notes = ["equivalent to `pip cache purge`"]
    return _plan_reversible(ctx, "cache-pip", [
        {"path": root, "owner": "pip", "note": "pip's http and wheel cache"},
    ], notes=notes)


def plan_cache_pip(ctx):
    return _pip_plan(ctx)


def run_cache_pip(ctx, confirm):
    return _run_clear(ctx, "cache-pip", _pip_plan(ctx))


# ----------------------------------------------------------------- cache-cargo


def _cargo_plan(ctx):
    root = ctx.root("cargo", "~/.cargo")
    return _plan_reversible(ctx, "cache-cargo", [
        {"path": os.path.join(root, "registry", "cache"), "owner": "cargo",
         "note": "downloaded .crate files"},
        {"path": os.path.join(root, "registry", "src"), "owner": "cargo",
         "note": "unpacked crate sources (regenerated from cache on build)"},
        {"path": os.path.join(root, "git", "db"), "owner": "cargo",
         "note": "git dependency checkouts"},
    ], notes=["cargo re-downloads on the next build; bin/ and the registry index stay"])


def plan_cache_cargo(ctx):
    return _cargo_plan(ctx)


def run_cache_cargo(ctx, confirm):
    return _run_clear(ctx, "cache-cargo", _cargo_plan(ctx))


# ------------------------------------------------------------------ cache-yay


def _yay_plan(ctx):
    root = ctx.root("yay", "~/.cache/yay")
    return _plan_reversible(ctx, "cache-yay", [
        {"path": root, "owner": "yay", "note": "yay's AUR build cache"},
    ], notes=["yay rebuilds from the PKGBUILD next time; built packages are re-downloaded"])


def plan_cache_yay(ctx):
    if not ctx.host()["linux"]:
        return {"ok": False, "reason": "not this host", "items": [], "count": 0, "bytes": 0}
    return _yay_plan(ctx)


def run_cache_yay(ctx, confirm):
    return _run_clear(ctx, "cache-yay", _yay_plan(ctx))


# ---------------------------------------------------------------- cache-pacman


def _rpmvercmp(left, right):
    """One pair of version strings, compared the way alpm's rpmvercmp does.

    Numeric segments compare by value (``1.10`` > ``1.9``), alpha segments as
    text, a run of separators by its length, and a remaining alpha segment never
    beats an exhausted string.
    """
    if left == right:
        return 0
    i = j = 0
    len_left, len_right = len(left), len(right)
    while i < len_left and j < len_right:
        separator_start_left, separator_start_right = i, j
        while i < len_left and not left[i].isalnum():
            i += 1
        while j < len_right and not right[j].isalnum():
            j += 1
        if not (i < len_left and j < len_right):
            break
        separators_left = i - separator_start_left
        separators_right = j - separator_start_right
        if separators_left != separators_right:
            return -1 if separators_left < separators_right else 1
        segment_start_left, segment_start_right = i, j
        if left[i].isdigit():
            while i < len_left and left[i].isdigit():
                i += 1
            while j < len_right and right[j].isdigit():
                j += 1
            numeric = True
        else:
            while i < len_left and left[i].isalpha():
                i += 1
            while j < len_right and right[j].isalpha():
                j += 1
            numeric = False
        segment_left = left[segment_start_left:i]
        segment_right = right[segment_start_right:j]
        if not segment_left:
            return -1
        if not segment_right:
            return 1 if numeric else -1
        if numeric:
            segment_left = segment_left.lstrip("0")
            segment_right = segment_right.lstrip("0")
            if len(segment_left) != len(segment_right):
                return 1 if len(segment_left) > len(segment_right) else -1
        if segment_left != segment_right:
            return 1 if segment_left > segment_right else -1
    left_done = i >= len_left
    right_done = j >= len_right
    if left_done and right_done:
        return 0
    # The final showdown: a remaining alpha segment loses to an exhausted
    # string; anything else that remains wins.
    if left_done and not (not right_done and right[j].isalpha()):
        return -1
    if not left_done and left[i].isalpha():
        return -1
    return 1


def _split_evr(full):
    """``1:2.0-3`` -> ``("1", "2.0", "3")``. No epoch is 0, no release is ""."""
    epoch, version = "0", full
    head, sep, tail = full.partition(":")
    if sep and head.isdigit():
        epoch, version = head, tail
    pkgver, sep, pkgrel = version.rpartition("-")
    if not sep:
        return epoch, version, ""
    return epoch, pkgver, pkgrel


def _vercmp(left, right):
    """Order two pacman versions (``[epoch:]pkgver[-pkgrel]``), <0, 0 or >0."""
    epoch_left, ver_left, rel_left = _split_evr(left)
    epoch_right, ver_right, rel_right = _split_evr(right)
    order = _rpmvercmp(epoch_left, epoch_right)
    if order:
        return order
    order = _rpmvercmp(ver_left, ver_right)
    if order:
        return order
    if rel_left and rel_right:
        return _rpmvercmp(rel_left, rel_right)
    if rel_left or rel_right:
        return 1 if rel_left else -1
    return 0


def _pacman_plan(ctx):
    """pacman/yay's package cache. Linux only: the tool itself has to exist."""
    root = ctx.root("pacman", "/var/cache/pacman/pkg")
    notes = ["equivalent to `paccache -r -k 1`; keep the newest copy of each package",
             "versions are ordered by pacman's own vercmp, so 1.10 is newer than 1.9"]
    if not ctx.which("pacman"):
        return {"ok": False, "reason": "not this host", "detail": "no pacman",
                "items": [], "count": 0, "bytes": 0}
    # Newest version of each package stays: that is what a reinstall needs.
    kept, candidates = {}, []
    try:
        names = sorted(os.listdir(root))
    except OSError as exc:
        return {"ok": False, "reason": "cannot read %s: %s" % (tilde(root), exc.strerror or exc),
                "items": [], "count": 0, "bytes": 0}
    for name in names:
        # pkgname-pkgver-pkgrel-arch.pkg.tar.(xz|zst|gz), the pacman filename form
        match = re.match(r"^(.+)-([^-]+)-([^-]+)-([^-]+)\.pkg\.tar\.(?:xz|zst|gz)$", name)
        if not match:
            continue
        kept.setdefault(match.group(1), []).append(
            (name, "%s-%s" % (match.group(2), match.group(3))))
    for package in sorted(kept):
        newest_first = sorted(kept[package],
                              key=functools.cmp_to_key(
                                  lambda left, right: _vercmp(left[1], right[1])),
                              reverse=True)
        for name, _version in newest_first[1:]:
            candidates.append({"path": os.path.join(root, name), "owner": "pacman",
                               "note": "superseded version of %s" % package})
    plan = _plan_reversible(ctx, "cache-pacman", candidates, notes=notes)
    plan["kept_newest"] = len(kept)
    return plan


def plan_cache_pacman(ctx):
    return _pacman_plan(ctx)


def run_cache_pacman(ctx, confirm):
    return _run_clear(ctx, "cache-pacman", _pacman_plan(ctx))


# ------------------------------------------------------------------ cache-top


def _scan_cache_root(ctx):
    root = ctx.root("cache", "~/.cache")
    if not os.path.isdir(root):
        return None, None
    children, total, files = [], 0, 0
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return root, []
    for name in names:
        path = os.path.join(root, name)
        if os.path.islink(path) or not os.path.isdir(path):
            continue
        measured = ctx.measure(path)
        total += measured["bytes"]
        files += measured["files"]
        owner = attribute(name)
        children.append({
            "name": name,
            "path": tilde(path),
            "bytes": measured["bytes"],
            "files": measured["files"],
            "attributed": owner is not None,
            "owner": owner,
        })
    children.sort(key=lambda row: (-row["bytes"], row["name"]))
    return root, {"children": children, "total": total, "files": files}


def plan_cache_top(ctx):
    root, scanned = _scan_cache_root(ctx)
    if root is None:
        return {"ok": False, "reason": "no cache directory at %s" % tilde(
            ctx.root("cache", "~/.cache")), "items": [], "count": 0, "bytes": 0}
    top = scanned["children"][:TOP_CONSUMERS]
    unattributed = [row["name"] for row in scanned["children"] if not row["attributed"]]
    return {
        "ok": True,
        "items": top,
        "count": len(top),
        "bytes": sum(row["bytes"] for row in top),
        "would": {"verb": "read", "count": 0, "bytes": 0,
                  "detail": "sizes only; nothing is cleared and no path is touched"},
        "cache_root": tilde(root),
        "cache_total_bytes": scanned["total"],
        "cache_total_files": scanned["files"],
        "entries": len(scanned["children"]),
        "unattributed": unattributed[:20],
        "notes": ["top %d children of ~/.cache by size" % TOP_CONSUMERS,
                  "attributed=false means the owner is unknown, so it is never cleared"],
    }


def run_cache_top(ctx, confirm):
    return _read_run()


# ---------------------------------------------------------------- cache-evict


def _evict_target(ctx):
    """(path, name, owner) for --path, or raise UsageError for a bad invocation."""
    raw = ctx.path_arg(0)
    if not raw:
        raise hudfix.UsageError(
            "cache-evict needs --path NAME (a direct child of the cache root) or "
            "--path /abs/path inside it")
    root = ctx.root("cache", "~/.cache")
    root_abs = expand(root)
    if os.path.isabs(os.path.expanduser(raw)):
        target = expand(raw)
    else:
        target = expand(os.path.join(root, raw))
    # Both forms land on one rule: one direct child of the cache root, no depth,
    # no traversal and not the root itself. A deeper path is refused even when
    # its own name carries an owner, because the owner has to come from a name
    # that is really a child of the cache root.
    if os.path.dirname(target) != root_abs:
        raise hudfix.UsageError(
            "--path %r must be one direct child of %s" % (raw, tilde(root)))
    name = os.path.basename(target)
    return target, name, attribute(name)


def _evict_plan(ctx):
    target, name, owner = _evict_target(ctx)
    if owner is None:
        return {
            "ok": False,
            "reason": "cannot attribute %r: no known cache owner, so it is not cleared"
                      % name,
            "items": [], "count": 0, "bytes": 0,
            "would": {"verb": "none", "detail": "an unattributed path is never cleared"},
            "notes": ["cache-top lists this path as attributed=false",
                      "if it is really a cache, teach hudfix_storage.ATTRIBUTION its owner"],
        }
    return _plan_reversible(ctx, "cache-evict", [
        {"path": target, "owner": owner, "note": "explicit --path target"},
    ], notes=["one path only, named by the caller"])


def plan_cache_evict(ctx):
    return _evict_plan(ctx)


def run_cache_evict(ctx, confirm):
    return _run_clear(ctx, "cache-evict", _evict_plan(ctx))


# --------------------------------------------------------------- hermes-scratch


def _aged_entries(root, max_age_s, now, suffix=None):
    """Entries under root older than max_age_s. Directories are measured whole."""
    out, fresh = [], 0
    if not os.path.isdir(root):
        return out, fresh
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return out, fresh
    for name in names:
        if name.startswith("."):
            continue
        path = os.path.join(root, name)
        if suffix and not name.endswith(suffix):
            continue
        try:
            stat = os.lstat(path)
        except OSError:
            continue
        age = int(now - stat.st_mtime)
        if age < max_age_s:
            fresh += 1
            continue
        is_dir = os.path.isdir(path) and not os.path.islink(path)
        out.append({"path": path, "rel": name, "age_s": age,
                    "kind": "dir" if is_dir else "file"})
    return out, fresh


def _hermes_plan(ctx):
    now = ctx.now().timestamp()
    hermes = ctx.root("hermes", "~/.hermes")
    scratch = os.path.join(hermes, "cache", "scratch")
    logs = os.path.join(hermes, "logs")
    candidates, notes, skipped = [], [], []
    scratch_items, fresh_scratch = _aged_entries(scratch, SCRATCH_AGE_S, now)
    candidates.extend(scratch_items)
    if not os.path.isdir(scratch):
        skipped.append({"path": tilde(scratch), "reason": "absent"})
    else:
        notes.append("scratch: %d entr%s older than %d d, %d younger kept"
                     % (len(scratch_items), "y" if len(scratch_items) == 1 else "ies",
                        SCRATCH_AGE_S // DAY, fresh_scratch))
    # Old log files: only *.log, only files, only past the window.
    if os.path.isdir(logs):
        log_items = []
        for name in sorted(os.listdir(logs)):
            if not name.endswith(".log"):
                continue
            path = os.path.join(logs, name)
            try:
                stat = os.lstat(path)
            except OSError:
                continue
            if os.path.isdir(path) or int(now - stat.st_mtime) < HERMES_LOG_AGE_S:
                continue
            log_items.append({"path": path, "rel": name, "kind": "file",
                              "age_s": int(now - stat.st_mtime), "bytes": stat.st_size})
        candidates.extend(log_items)
        notes.append("logs: %d file(s) older than %d d" % (len(log_items),
                                                           HERMES_LOG_AGE_S // DAY))
    else:
        skipped.append({"path": tilde(logs), "reason": "absent"})
    notes.append("Hermes itself prunes scratch after 24 h; this engine waits %d d"
                 % (SCRATCH_AGE_S // DAY))
    # Only regular files here: a directory is left for its own action to handle.
    return _plan_reversible(ctx, "hermes-scratch", candidates, notes=notes,
                            skipped=skipped)


def plan_hermes_scratch(ctx):
    return _hermes_plan(ctx)


def run_hermes_scratch(ctx, confirm):
    return _run_clear(ctx, "hermes-scratch", _hermes_plan(ctx))


# ----------------------------------------------------------------------- trash


def _trash_files_dir(ctx):
    default = "~/.local/share/Trash/files"
    if ctx.host()["system"] == "Darwin":
        default = "~/.Trash"
    return ctx.root("trash", default)


def _trash_plan(ctx):
    root = _trash_files_dir(ctx)
    now = ctx.now().timestamp()
    items, fresh = _aged_entries(root, TRASH_AGE_S, now)
    skipped = []
    if not os.path.isdir(root):
        skipped.append({"path": tilde(root), "reason": "absent"})
    return _plan_reversible(ctx, "trash", items, skipped=skipped, notes=[
        "only items older than %d d" % (TRASH_AGE_S // DAY),
        "%d newer item(s) kept" % fresh,
    ])


def plan_trash(ctx):
    return _trash_plan(ctx)


def run_trash(ctx, confirm):
    return _run_clear(ctx, "trash", _trash_plan(ctx))


# --------------------------------------------------------------- journal-vacuum


def _journal_usage(ctx):
    rc, out, err = _run(["journalctl", "--disk-usage"], timeout=10.0)
    if rc != 0:
        return None, _first_line(err or out) or "journalctl --disk-usage failed"
    text = out.strip()
    match = re.search(r"take up\s+([\d.,]+\s*[KMGTPE]?i?B?)", text, re.IGNORECASE)
    size = _parse_size(match.group(1)) if match else None
    return {"text": _first_line(text), "bytes": size}, None


def _journal_plan(ctx):
    usage, problem = _journal_usage(ctx)
    if problem:
        return {"ok": False, "reason": problem, "items": [], "count": 0, "bytes": 0}
    return {
        "ok": True,
        "items": [],
        "count": 0,
        "bytes": usage["bytes"] or 0,
        "would": {
            "verb": "vacuum",
            "command": "journalctl --vacuum-time=14d",
            "bytes": usage["bytes"],
            "detail": "delete journal entries older than 14 days; journald rewrites "
                      "its own segment files, so they cannot be quarantined",
        },
        "journal": usage,
        "notes": ["destructive: there is no recovery path for a vacuumed journal entry",
                  "read `journalctl -b -p err` first if the errors matter"],
    }


def plan_journal_vacuum(ctx):
    return _journal_plan(ctx)


def run_journal_vacuum(ctx, confirm):
    if not ctx.which("journalctl"):
        return {"ok": False, "changed": False, "reason": "no journalctl on this host"}
    rc, out, err = _run(["journalctl", "--vacuum-time=14d"], timeout=60.0)
    if rc != 0:
        return {"ok": False, "changed": False,
                "reason": _first_line(err or out) or "journalctl --vacuum-time failed"}
    freed = None
    match = re.search(r"freed\s+([\d.,]+\s*[KMGTPE]?i?B?)", out, re.IGNORECASE)
    if match:
        freed = _parse_size(match.group(1))
    return {"ok": True, "changed": True, "count": 0, "bytes": freed or 0,
            "freed_bytes": freed, "output": _first_line(out)}


# --------------------------------------------------------------- orphans-list


def _orphans_plan(ctx):
    if not ctx.which("pacman"):
        return {"ok": False, "reason": "not this host", "detail": "no pacman",
                "items": [], "count": 0, "bytes": 0}
    rc, out, err = _run(["pacman", "-Qtdq"], timeout=15.0)
    if rc != 0:
        return {"ok": False, "reason": "pacman -Qtdq failed: %s"
                % (_first_line(err or out) or "exit %s" % rc),
                "items": [], "count": 0, "bytes": 0}
    names = [line.strip() for line in out.splitlines() if line.strip()]
    total = None
    counted = False
    if names and ctx.which("expac"):
        rc2, out2, _err2 = _run(["expac", "-Q", "%n %m"] + names, timeout=20.0)
        if rc2 == 0:
            total, counted = 0, True
            for line in out2.splitlines():
                parts = line.split()
                if len(parts) >= 2 and parts[-1].isdigit():
                    total += int(parts[-1])
    plan = {
        "ok": True,
        "items": [],
        "count": len(names),
        "bytes": total or 0,
        "would": {"verb": "read", "count": 0, "bytes": 0,
                  "detail": "listing only; this engine has no package-removal action"},
        "packages": names[:200],
        "notes": ["orphans are a guess about intent, so nothing is removed",
                  "removal stays a deliberate `pacman -Rns` in a terminal"],
    }
    if not counted:
        plan["bytes_reason"] = "pacman does not report installed size here (no expac)"
    return plan


def plan_orphans_list(ctx):
    return _orphans_plan(ctx)


def run_orphans_list(ctx, confirm):
    return _read_run()


# -------------------------------------------------------------- snapshots-list


def _snapshots_plan(ctx):
    if not ctx.which("btrfs"):
        return {"ok": False, "reason": "not this host", "detail": "no btrfs",
                "items": [], "count": 0, "bytes": 0}
    rc, out, err = _run(["btrfs", "subvolume", "list", "-s", "/"], timeout=20.0)
    if rc != 0:
        return {"ok": False, "reason": "btrfs subvolume list failed: %s"
                % (_first_line(err or out) or "exit %s" % rc),
                "items": [], "count": 0, "bytes": 0}
    snapshots = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        match = re.search(r"\bID\s+(\d+).*?\bpath\s+(.+)$", line)
        if match:
            snapshots.append({"id": int(match.group(1)), "path": match.group(2)})
        else:
            snapshots.append({"id": None, "path": line})
    return {
        "ok": True,
        "items": [],
        "count": len(snapshots),
        "bytes": 0,
        "would": {"verb": "read", "count": 0, "bytes": 0,
                  "detail": "listing only; this engine has no snapshot delete action"},
        "snapshots": snapshots[:200],
        "notes": ["a snapshot is listed, never deleted",
                  "per-snapshot exclusive size is not reported by this command"],
    }


def plan_snapshots_list(ctx):
    return _snapshots_plan(ctx)


def run_snapshots_list(ctx, confirm):
    return _read_run()


# --------------------------------------------------------------- disk-health


SMARTCTL_PATTERNS = (
    ("wear_pct", r"Percentage Used:\s*([\d.]+)%"),
    ("power_on_hours", r"Power On Hours:\s*([\d,]+)"),
    ("temp_c", r"Temperature:\s*([\d.]+)\s*Celsius"),
    ("available_spare_pct", r"Available Spare:\s*([\d.]+)%"),
    ("media_errors", r"Media and Data Integrity Errors:\s*([\d,]+)"),
    ("critical_warning", r"Critical Warning:\s*(0x[0-9a-fA-F]+|\d+)"),
    ("model", r"Model Number:\s*(.+)$"),
    ("serial", r"Serial Number:\s*(.+)$"),
)


def _parse_smartctl(text):
    """Parse the text form of ``smartctl -a``. Missing keys stay None."""
    device = {"wear_pct": None, "power_on_hours": None, "temp_c": None,
              "available_spare_pct": None, "media_errors": None,
              "critical_warning": None, "model": None, "serial": None,
              "source": "smartctl"}
    for key, pattern in SMARTCTL_PATTERNS:
        match = re.search(pattern, text, re.MULTILINE)
        if not match:
            continue
        raw = match.group(1).strip()
        if key in ("model", "serial", "critical_warning"):
            device[key] = raw
        else:
            try:
                device[key] = float(raw.replace(",", ""))
            except ValueError:
                continue
    if device["power_on_hours"] is not None:
        device["power_on_hours"] = int(device["power_on_hours"])
    if device["media_errors"] is not None:
        device["media_errors"] = int(device["media_errors"])
    return device


def _smart_live(ctx):
    if ctx.which("smartctl"):
        if ctx.host()["system"] == "Darwin":
            device = "/dev/disk0"
        else:
            rc, out, _err = _run(["smartctl", "--scan", "-j"], timeout=10.0)
            device = None
            if rc == 0:
                try:
                    scan = json.loads(out)
                except ValueError:
                    scan = {}
                for row in scan.get("devices") or []:
                    if row.get("name"):
                        device = row["name"]
                        break
            device = device or "/dev/sda"
        rc, out, err = _run(["smartctl", "-a", device], timeout=15.0)
        text = out + "\n" + err
        if "Permission denied" in text or "requires root" in text.lower() \
                or "Operation not permitted" in text:
            return {"ok": False,
                    "reason": "smartctl needs root for %s; hudfix never runs sudo" % device,
                    "items": [], "count": 0, "bytes": 0,
                    "command": "sudo smartctl -a %s" % device}
        if rc not in (0, 4) or "Percentage Used" not in out:
            return {"ok": False,
                    "reason": "smartctl could not read %s: %s"
                              % (device, _first_line(err or out) or "exit %s" % rc),
                    "items": [], "count": 0, "bytes": 0}
        parsed = _parse_smartctl(out)
        parsed["device"] = device
        return {"ok": True, "items": [], "count": 1, "bytes": 0,
                "would": {"verb": "read", "count": 0, "bytes": 0},
                "devices": [parsed],
                "notes": ["wear and hours come from the drive's own SMART log"]}
    if ctx.which("nvme"):
        rc, out, err = _run(["nvme", "smart-log", "-o", "json", "/dev/nvme0"], timeout=15.0)
        if rc == 0:
            try:
                data = json.loads(out)
            except ValueError:
                data = None
            if isinstance(data, dict):
                device = {
                    "device": "/dev/nvme0",
                    "source": "nvme",
                    "wear_pct": data.get("percent_used"),
                    "power_on_hours": data.get("power_on_hours"),
                    "temp_c": (data.get("temperature") or 0) - 273 if data.get("temperature") else None,
                    "media_errors": data.get("media_errors"),
                    "available_spare_pct": data.get("avail_spare"),
                    "critical_warning": data.get("critical_warning"),
                }
                return {"ok": True, "items": [], "count": 1, "bytes": 0,
                        "would": {"verb": "read", "count": 0, "bytes": 0},
                        "devices": [device]}
        return {"ok": False, "reason": "nvme smart-log failed: %s"
                % (_first_line(err or out) or "exit %s" % rc),
                "items": [], "count": 0, "bytes": 0}
    return {"ok": False,
            "reason": "no smartctl or nvme on this host, so wear and hours are unknown",
            "items": [], "count": 0, "bytes": 0}


def _disk_health_plan(ctx):
    recorded = ctx.overrides.get("smart")
    if recorded:
        try:
            with open(expand(recorded), "r", encoding="utf-8") as handle:
                text = handle.read()
        except OSError as exc:
            return {"ok": False, "reason": "cannot read recorded smart dump: %s"
                    % (exc.strerror or exc), "items": [], "count": 0, "bytes": 0}
        device = _parse_smartctl(text)
        device["device"] = os.path.basename(expand(recorded))
        device["source"] = "recorded"
        return {"ok": True, "items": [], "count": 1, "bytes": 0,
                "would": {"verb": "read", "count": 0, "bytes": 0,
                          "detail": "parses a recorded dump; no command runs"},
                "devices": [device],
                "notes": ["--root smart=FILE replays a recorded smartctl -a dump"]}
    return _smart_live(ctx)


def plan_disk_health(ctx):
    return _disk_health_plan(ctx)


def run_disk_health(ctx, confirm):
    return _read_run()


# ------------------------------------------------------------------ disk-btrfs


def _btrfs_plan(ctx):
    if not ctx.which("btrfs"):
        return {"ok": False, "reason": "not this host", "detail": "no btrfs",
                "items": [], "count": 0, "bytes": 0}
    rc, out, err = _run(["btrfs", "scrub", "status", "/"], timeout=20.0)
    scrub = {"status": "unknown", "errors": None, "text": _first_line(out or err)}
    if rc == 0:
        match = re.search(r"Status:\s*(.+)", out)
        errors = re.search(r"Error summary:\s*(.+)", out)
        scrub["status"] = match.group(1).strip() if match else "unknown"
        scrub["errors"] = errors.group(1).strip() if errors else None
    rc2, out2, err2 = _run(["btrfs", "balance", "status", "/"], timeout=20.0)
    balance = {"running": None, "text": _first_line(out2 or err2)}
    if rc2 == 0:
        balance["running"] = not out2.strip().lower().startswith("no balance found")
    return {
        "ok": True,
        "items": [],
        "count": 0,
        "bytes": 0,
        "would": {"verb": "read", "count": 0, "bytes": 0,
                  "detail": "scrub and balance status only; no command changes anything"},
        "scrub": scrub,
        "balance": balance,
        "notes": ["read only: no scrub start, no balance start, no snapshot delete"],
    }


def plan_disk_btrfs(ctx):
    return _btrfs_plan(ctx)


def run_disk_btrfs(ctx, confirm):
    return _read_run()


# -------------------------------------------------------------------- docker


def _docker_df(ctx):
    rc, out, err = _run(["docker", "system", "df", "--format", "{{json .}}"], timeout=20.0)
    if rc != 0:
        text = (err or out).strip()
        if "Cannot connect to the Docker daemon" in text or "docker.sock" in text:
            return None, "no docker daemon: %s" % _first_line(text)
        return None, "docker system df failed: %s" % (_first_line(text) or "exit %s" % rc)
    rows = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except ValueError:
            continue
    if not rows:
        # older docker: parse the aligned text table instead
        rc2, out2, err2 = _run(["docker", "system", "df"], timeout=20.0)
        if rc2 != 0:
            return None, "docker system df failed: %s" % (_first_line(err2 or out2))
        for line in out2.splitlines():
            parts = line.split()
            if len(parts) >= 5 and parts[0].lower() in ("images", "containers", "volumes",
                                                        "build cache"):
                rows.append({"Type": parts[0], "TotalCount": parts[1], "Size": parts[3],
                             "Reclaimable": parts[4]})
    return rows, None


def _docker_plan(ctx):
    rows, problem = _docker_df(ctx)
    if problem:
        return {"ok": False, "reason": problem, "items": [], "count": 0, "bytes": 0}
    reclaimable = 0
    for row in rows:
        size = _parse_size(str(row.get("Reclaimable") or row.get("ReclaimableSize") or ""))
        if size:
            reclaimable += size
    return {
        "ok": True,
        "items": [],
        "count": len(rows),
        "bytes": reclaimable,
        "would": {"verb": "read", "count": 0, "bytes": 0,
                  "detail": "docker system df only"},
        "types": rows,
        "notes": ["reclaimable is docker's own estimate"],
    }


def plan_docker_df(ctx):
    return _docker_plan(ctx)


def run_docker_df(ctx, confirm):
    return _read_run()


def _docker_prune_plan(ctx):
    rows, problem = _docker_df(ctx)
    if problem:
        return {"ok": False, "reason": problem, "items": [], "count": 0, "bytes": 0}
    builder = 0
    dangling = 0
    for row in rows:
        kind = str(row.get("Type") or "").lower()
        size = _parse_size(str(row.get("Reclaimable") or row.get("ReclaimableSize") or "")) or 0
        if "build" in kind:
            builder += size
        elif "image" in kind:
            dangling += size
    return {
        "ok": True,
        "items": [],
        "count": 2,
        "bytes": builder + dangling,
        "would": {
            "verb": "prune",
            "commands": ["docker builder prune -f", "docker image prune -f"],
            "bytes": builder + dangling,
            "detail": "build cache and dangling images only; named images and volumes stay",
        },
        "build_cache_reclaimable": builder,
        "dangling_image_reclaimable": dangling,
        "bytes_reason": "docker's own reclaimable estimate, not a measured size",
        "notes": ["destructive: a pruned builder cache or dangling layer has no copy "
                  "anywhere, so it cannot be quarantined",
                  "dangling images are the untagged ones; a named image is never touched"],
    }


def plan_docker_prune(ctx):
    return _docker_prune_plan(ctx)


def run_docker_prune(ctx, confirm):
    freed = 0
    outputs = []
    for command in (["docker", "builder", "prune", "-f"],
                    ["docker", "image", "prune", "-f"]):
        rc, out, err = _run(command, timeout=180.0)
        outputs.append({"command": " ".join(command), "exit": rc,
                        "output": _first_line(out or err)})
        if rc != 0:
            return {"ok": False, "changed": freed > 0, "bytes": freed,
                    "reason": "%s failed: %s" % (" ".join(command),
                                                 _first_line(err or out)),
                    "commands": outputs}
        match = re.search(r"Total reclaimed space:\s*([\d.,]+\s*[KMGTPE]?i?B?)",
                          out, re.IGNORECASE)
        if match:
            freed += _parse_size(match.group(1)) or 0
    return {"ok": True, "changed": True, "count": 2, "bytes": freed,
            "commands": outputs}


# ------------------------------------------------------------- quarantine-list


def _quarantine_plan(ctx):
    days = 7
    raw = ctx.option("days")
    if raw:
        try:
            days = max(1, min(90, int(raw)))
        except ValueError:
            raise hudfix.UsageError("--param days wants an integer, got %r" % raw)
    root = ctx.quarantine_root
    today = datetime.date.today()
    rows = []
    for offset in range(days):
        day = (today - datetime.timedelta(days=offset)).isoformat()
        manifest = os.path.join(root, day, hudfix.MANIFEST_NAME)
        if not os.path.isfile(manifest):
            continue
        for row in hudfix.read_manifest(manifest):
            row["day"] = day
            rows.append(row)
    rows.sort(key=lambda row: (row["ts"] or "", row.get("source") or ""), reverse=True)
    items, by_action, formats, without_source = [], {}, {}, 0
    for row in rows:
        formats[row["format"]] = formats.get(row["format"], 0) + 1
        by_action[row["action"]] = by_action.get(row["action"], 0) + 1
        if not row["source"]:
            without_source += 1
            continue
        items.append({
            "path": tilde(row["source"]),
            "bytes": row["bytes"] or 0,
            "destination": tilde(row["destination"]) if row["destination"] else None,
            "action": row["action"],
            "ts": row["ts"],
            "format": row["format"],
        })
    plan = {
        "ok": True,
        "items": items[:200],
        "count": len(rows),
        "bytes": sum(row["bytes"] or 0 for row in rows),
        "would": {"verb": "read", "count": 0, "bytes": 0,
                  "detail": "the MANIFEST rows are the restore instructions"},
        "quarantine_root": tilde(root),
        "days": days,
        "by_action": by_action,
        "formats": formats,
        "rows_without_source": without_source,
        "bytes_exact": all(row["bytes_exact"] for row in rows if row["bytes"] is not None),
        "notes": ["restore = move the destination back to the original path",
                  "rows older than %d d are not read" % days],
    }
    if without_source or not plan["bytes_exact"]:
        plan["notes"].append("older manifests here use other columns; a row without "
                             "an exact byte count or a source path stays unreported, "
                             "never guessed")
    return plan


def plan_quarantine_list(ctx):
    return _quarantine_plan(ctx)


def run_quarantine_list(ctx, confirm):
    return _read_run()


# ---------------------------------------------------------------------- table


ACTIONS = {
    "cache-npm": {
        "class": "reversible",
        "doc": "Clear npm's _cacache and _logs into quarantine; npm rebuilds them "
               "on the next install.",
        "plan": plan_cache_npm,
        "run": run_cache_npm,
    },
    "cache-uv": {
        "class": "reversible",
        "doc": "Clear uv's package and wheel cache into quarantine, like "
               "`uv cache clean`.",
        "plan": plan_cache_uv,
        "run": run_cache_uv,
    },
    "cache-pip": {
        "class": "reversible",
        "doc": "Clear pip's http and wheel cache into quarantine, like "
               "`pip cache purge`.",
        "plan": plan_cache_pip,
        "run": run_cache_pip,
    },
    "cache-cargo": {
        "class": "reversible",
        "doc": "Clear cargo's crate cache, registry sources and git checkouts into "
               "quarantine; bin/ and the index stay.",
        "plan": plan_cache_cargo,
        "run": run_cache_cargo,
    },
    "cache-yay": {
        "class": "reversible",
        "doc": "Clear yay's AUR build cache into quarantine; Linux only.",
        "plan": plan_cache_yay,
        "run": run_cache_yay,
        "linux_only": True,
        "requires": ["yay"],
    },
    "cache-pacman": {
        "class": "reversible",
        "doc": "Move superseded pacman package files to quarantine, newest version "
               "of each package kept; Linux only.",
        "plan": plan_cache_pacman,
        "run": run_cache_pacman,
        "linux_only": True,
        "requires": ["pacman"],
    },
    "cache-top": {
        "class": "read",
        "doc": "Report the ten largest children of ~/.cache with their known owner; "
               "sizes only, nothing is cleared.",
        "plan": plan_cache_top,
        "run": run_cache_top,
    },
    "cache-evict": {
        "class": "reversible",
        "doc": "Move one named child of ~/.cache to quarantine; refuses a path it "
               "cannot attribute to a known owner.",
        "plan": plan_cache_evict,
        "run": run_cache_evict,
    },
    "hermes-scratch": {
        "class": "reversible",
        "doc": "Move Hermes scratch entries older than 7 d and logs older than 14 d "
               "to quarantine.",
        "plan": plan_hermes_scratch,
        "run": run_hermes_scratch,
    },
    "trash": {
        "class": "reversible",
        "doc": "Move trash items older than 30 d to quarantine, where the MANIFEST "
               "row is still a way back.",
        "plan": plan_trash,
        "run": run_trash,
    },
    "journal-vacuum": {
        "class": "destructive",
        "doc": "Vacuum journal entries older than 14 d; destructive because journald "
               "rewrites its own segments and a vacuumed entry cannot be quarantined.",
        "plan": plan_journal_vacuum,
        "run": run_journal_vacuum,
        "linux_only": True,
        "requires": ["journalctl"],
    },
    "orphans-list": {
        "class": "read",
        "doc": "List pacman orphans with their count; listing only, this engine has "
               "no package-removal action.",
        "plan": plan_orphans_list,
        "run": run_orphans_list,
        "linux_only": True,
        "requires": ["pacman"],
    },
    "snapshots-list": {
        "class": "read",
        "doc": "List btrfs snapshots; listing only, this engine never deletes a "
               "snapshot.",
        "plan": plan_snapshots_list,
        "run": run_snapshots_list,
        "linux_only": True,
        "requires": ["btrfs"],
    },
    "disk-health": {
        "class": "read",
        "doc": "Read NVMe wear, power-on hours, temperature and media errors through "
               "smartctl or nvme; never runs sudo.",
        "plan": plan_disk_health,
        "run": run_disk_health,
    },
    "disk-btrfs": {
        "class": "read",
        "doc": "Read btrfs scrub and balance status; Linux only, and it starts "
               "neither.",
        "plan": plan_disk_btrfs,
        "run": run_disk_btrfs,
        "linux_only": True,
        "requires": ["btrfs"],
    },
    "docker-df": {
        "class": "read",
        "doc": "Report docker's own disk usage and reclaimable estimate; requires a "
               "reachable daemon.",
        "plan": plan_docker_df,
        "run": run_docker_df,
        "requires": ["docker"],
    },
    "docker-prune": {
        "class": "destructive",
        "doc": "Prune the docker builder cache and dangling images; destructive "
               "because a pruned layer has no copy anywhere to quarantine.",
        "plan": plan_docker_prune,
        "run": run_docker_prune,
        "requires": ["docker"],
    },
    "quarantine-list": {
        "class": "read",
        "doc": "Read the last 7 days of quarantine MANIFEST rows, the restore "
               "instructions for everything cleared.",
        "plan": plan_quarantine_list,
        "run": run_quarantine_list,
    },
}


# ------------------------------------------------------------------- self-check


def _write(path, payload):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(payload)
    return path


def _touch_old(path, age_s, payload="x"):
    _write(path, payload)
    stamp = time.time() - age_s
    os.utime(path, (stamp, stamp))
    return path


def _age_dir(path, age_s):
    stamp = time.time() - age_s
    os.utime(path, (stamp, stamp))
    return path


SMART_SAMPLE = """smartctl 7.4 2023-08-01 r5530 [Darwin 26.4.1 arm64] (local build)
Copyright (C) 2002-23, Bruce Allen, Christian Franke, www.smartmontools.org

=== START OF INFORMATION SECTION ===
Model Number:                       APPLE SSD AP0512Z
Serial Number:                      C0271234567890
NVMe Version:                       1.3
=== START OF SMART DATA SECTION ===
SMART overall-health self-assessment test result: PASSED

NVMe SMART/Health Information (NVMe Log 0x02)
Critical Warning:                   0x00
Temperature:                        34 Celsius
Available Spare:                    100%
Available Spare Threshold:          10%
Percentage Used:                    3%
Media and Data Integrity Errors:    0
Power On Hours:                     1,234
"""


def _build_fake_home(base):
    home = os.path.join(base, "home")
    files = {
        "home/.npm/_cacache/content-v2/aa/bb": "A" * 4096,
        "home/.npm/_logs/old.log": "L" * 100,
        "home/.cache/uv/archive-v0/item": "U" * 2048,
        "home/.cache/pip/http/item": "P" * 1024,
        "home/.cache/huggingface/hub/model": "H" * 8192,
        "home/.cache/mystery-thing/blob": "M" * 4096,
        "home/.cache/mystery-thing/uv-stuff/x": "D" * 300,
        "home/.cache/ghostty/blob": "G" * 500,
        "home/.cache/pipenv/blob": "I" * 200,
        # Exact-or-separator means exact: a padded name is a different name and
        # must never be attributed, so these three are never clearable.
        "home/.cache/gh /payload.bin": "S" * 150,
        "home/.cache/ gh/payload.bin": "L" * 150,
        "home/.cache/uv /payload.bin": "W" * 150,
        "home/.cache/yay/pkg/PKGBUILD": "Y" * 128,
        "home/.cargo/registry/cache/pkg.crate": "C" * 512,
        "home/.cargo/registry/src/s/lib.rs": "S" * 256,
        "home/.local/share/Trash/files/old-junk": "T" * 700,
        "home/.local/share/Trash/files/new-junk": "T" * 70,
    }
    for relative, payload in files.items():
        _write(os.path.join(base, relative), payload)
    _touch_old(os.path.join(home, ".hermes/cache/scratch/old/thing"), 10 * DAY, "Z" * 300)
    _age_dir(os.path.join(home, ".hermes/cache/scratch/old"), 10 * DAY)
    _write(os.path.join(home, ".hermes/cache/scratch/new/thing"), "N" * 50)
    _age_dir(os.path.join(home, ".hermes/cache/scratch/new"), 0)
    _touch_old(os.path.join(home, ".hermes/logs/hudfix.log"), 30 * DAY, "G" * 400)
    _touch_old(os.path.join(home, ".npm/_logs/old.log"), 30 * DAY, "L" * 100)
    _touch_old(os.path.join(home, ".local/share/Trash/files/old-junk"), 40 * DAY, "T" * 700)
    return home


def _run_cli(base_args, argv, timeout=180):
    return hudfix.run_cli(base_args, argv, timeout=timeout)


def self_check():  # noqa: C901 - one linear proof, on purpose
    base = tempfile.mkdtemp(prefix="hudfix-storage-selfcheck-")
    checks = hudfix.Checks()
    summary = {"ok": False, "self_check": "hudfix_storage", "version": hudfix.VERSION,
               "generated_at": hudfix.utc_now_iso(), "workdir": hudfix.tilde(base)}
    try:
        home = _build_fake_home(base)
        quarantine = os.path.join(base, "quarantine")
        log_path = os.path.join(base, "hudfix.log")
        smart_file = _write(os.path.join(base, "smart-dump.txt"), SMART_SAMPLE)
        feeds_dir = os.path.dirname(os.path.abspath(__file__))

        roots = {
            "npm": os.path.join(home, ".npm"),
            "uv": os.path.join(home, ".cache/uv"),
            "pip": os.path.join(home, ".cache/pip"),
            "cargo": os.path.join(home, ".cargo"),
            "cache": os.path.join(home, ".cache"),
            "hermes": os.path.join(home, ".hermes"),
            "trash": os.path.join(home, ".local/share/Trash/files"),
            "yay": os.path.join(home, ".cache/yay"),
            "pacman": os.path.join(base, "var-cache-pacman"),
            "smart": smart_file,
        }
        base_args = ["--module-dir", feeds_dir, "--quarantine-root", quarantine,
                     "--log", log_path]
        for key in roots:
            base_args += ["--root", "%s=%s" % (key, roots[key])]

        # Two older manifest dialects live in the real quarantine, so prove the
        # reader handles them instead of guessing: a 2026-10 five-column file
        # (size in KB) and a three-column write-off (no path, no size).
        older5 = (datetime.date.today() - datetime.timedelta(days=2)).isoformat()
        older3 = (datetime.date.today() - datetime.timedelta(days=3)).isoformat()
        _write(os.path.join(quarantine, older5, hudfix.MANIFEST_NAME),
               "orig_path\tnew_path\tsize_kb\treason\tdate\n"
               "/Users/old/.cache/a\t%s/old5/a\t2\tlegacy entry\t%s\n"
               "/Users/old/.cache/b\t%s/old5/b\t1\tlegacy entry\t%s\n"
               % (quarantine, older5, quarantine, older5))
        _write(os.path.join(quarantine, older3, hudfix.MANIFEST_NAME),
               "%s\tstale-shot.png\tstale screenshot\n"
               "%s\tnotes.md\twrite-off\n" % (older3, older3))
        counts = {"plan": 0, "run": 0}

        def cli(argv, timeout=180):
            if argv and argv[0] in counts:
                counts[argv[0]] += 1
            return _run_cli(base_args, argv, timeout=timeout)

        def inside_fake(paths):
            return all(os.path.abspath(p).startswith(base) for p in paths)

        home_digest = _digest(os.path.join(base, "home"))

        # ---- list: every action, class and host gate ---------------------
        code, out, err = cli(["list", "--json"])
        checks.eq("list.exit", code, hudfix.EXIT_OK)
        listing = hudfix.one_object(out)
        checks.ok("list.object", listing is not None, out or err)
        names = sorted(row["name"] for row in listing.get("actions", [])) if listing else []
        # hudfix.py lists every module's actions, so the storage table must be
        # a subset of the listing, not the whole listing.
        checks.ok("list.count", bool(listing) and listing.get("count") == len(names)
                  and len(names) >= len(ACTIONS), "count %s" % (listing or {}).get("count"))
        checks.ok("list.names", set(ACTIONS) <= set(names), "storage table missing from listing")
        classes = {row["name"]: row["class"] for row in listing.get("actions", [])} \
            if listing else {}
        for name in ("cache-top", "disk-health", "orphans-list", "snapshots-list",
                     "docker-df", "quarantine-list"):
            checks.eq("list.class.%s" % name, classes.get(name), "read")
        for name in ("cache-npm", "cache-uv", "hermes-scratch", "trash", "cache-evict"):
            checks.eq("list.class.%s" % name, classes.get(name), "reversible")
        for name in ("journal-vacuum", "docker-prune"):
            checks.eq("list.class.%s" % name, classes.get(name), "destructive")
        available = {row["name"]: row["available"] for row in listing.get("actions", [])} \
            if listing else {}
        if platform.system() != "Linux":
            for name in ("journal-vacuum", "orphans-list", "snapshots-list",
                         "disk-btrfs", "cache-pacman", "cache-yay"):
                checks.eq("list.unavailable.%s" % name, available.get(name), False)
        checks.ok("list.docs_present",
                  all(row.get("doc") for row in listing.get("actions", [])) if listing else False)
        checks.eq("list.nothing_written", _digest(os.path.join(base, "home")), home_digest)

        # ---- plan cache-npm: exact bytes, no change ----------------------
        code, out, err = cli(["plan", "cache-npm", "--json"])
        plan = hudfix.one_object(out)
        checks.eq("plan.npm.exit", code, hudfix.EXIT_OK)
        checks.ok("plan.npm.object", plan is not None, out or err)
        checks.eq("plan.npm.count", (plan or {}).get("count"), 2)
        checks.eq("plan.npm.bytes", (plan or {}).get("bytes"), 4096 + 100)
        checks.eq("plan.npm.class", (plan or {}).get("class"), "reversible")
        checks.eq("plan.npm.confirm", (plan or {}).get("requires_confirmation"), True)
        checks.ok("plan.npm.would_move",
                  ((plan or {}).get("would") or {}).get("verb") == "move")
        checks.ok("plan.npm.inside_fake",
                  inside_fake(row["path"].replace("~", home) for row in plan.get("items", []))
                  if plan else False)
        checks.eq("plan.npm.tree_unchanged", _digest(os.path.join(base, "home")), home_digest)

        # ---- run without confirm refuses, with confirm quarantines --------
        code, out, _err = cli(["run", "cache-npm", "--json"])
        checks.eq("run.npm.unconfirmed.exit", code, hudfix.EXIT_PROGRAMMING)
        checks.ok("run.npm.unconfirmed.reason",
                  "confirmation required" in ((hudfix.one_object(out) or {}).get("reason") or ""))
        checks.eq("run.npm.unconfirmed.no_change",
                  _digest(os.path.join(base, "home")), home_digest)

        code, out, err = cli(["run", "cache-npm", "--confirm", "cache-npm", "--json"])
        ran = hudfix.one_object(out)
        checks.eq("run.npm.exit", code, hudfix.EXIT_OK)
        checks.ok("run.npm.object", ran is not None, out or err)
        checks.eq("run.npm.count", (ran or {}).get("result", {}).get("count"), 2)
        checks.eq("run.npm.bytes", (ran or {}).get("result", {}).get("bytes"), 4096 + 100)
        checks.ok("run.npm.gone",
                  not os.path.exists(os.path.join(home, ".npm/_cacache"))
                  and not os.path.exists(os.path.join(home, ".npm/_logs")))
        manifest = os.path.join(quarantine, hudfix.local_day(), hudfix.MANIFEST_NAME)
        rows = hudfix.read_manifest(manifest) if os.path.isfile(manifest) else []
        checks.eq("run.npm.manifest_rows", len(rows), 2)
        checks.ok("run.npm.manifest_action",
                  all(row["action"] == "cache-npm" for row in rows))
        checks.ok("run.npm.destinations_exist",
                  all(os.path.exists(row["destination"]) for row in rows))
        checks.ok("run.npm.destinations_inside_quarantine",
                  all(os.path.abspath(row["destination"]).startswith(quarantine)
                      for row in rows))
        checks.ok("run.npm.source_recorded_absolute",
                  all(os.path.isabs(row["source"]) for row in rows))

        # ---- cache-top attributes only what it knows ---------------------
        code, out, _err = cli(["plan", "cache-top", "--json"])
        top = hudfix.one_object(out)
        checks.eq("plan.top.exit", code, hudfix.EXIT_OK)
        checks.eq("plan.top.class", (top or {}).get("class"), "read")
        top_names = [row["name"] for row in (top or {}).get("items", [])]
        checks.ok("plan.top.has_uv", "uv" in top_names, repr(top_names))
        checks.ok("plan.top.has_mystery", "mystery-thing" in top_names, repr(top_names))
        owners = {row["name"]: (row["attributed"], row["owner"])
                  for row in (top or {}).get("items", [])}
        checks.eq("plan.top.huggingface_attributed", owners.get("huggingface"), (True, "huggingface"))
        checks.eq("plan.top.mystery_unattributed", owners.get("mystery-thing"), (False, None))
        # A shared prefix is not an owner: ghostty is not the GitHub CLI, pipenv
        # is not pip. Attribution continues a pattern only after - _ or .
        checks.eq("plan.top.ghostty_unattributed", owners.get("ghostty"), (False, None))
        checks.eq("plan.top.pipenv_unattributed", owners.get("pipenv"), (False, None))
        checks.eq("plan.top.gh_trailing_space_unattributed", owners.get("gh "), (False, None))
        checks.eq("plan.top.gh_leading_space_unattributed", owners.get(" gh"), (False, None))
        checks.eq("plan.top.uv_trailing_space_unattributed", owners.get("uv "), (False, None))
        for name, want in (("ghostty", None), ("pipenv", None), ("gh", "github-cli"),
                           ("uv", "uv"), ("uv-3", "uv"), ("pip-tools", "pip-tools"),
                           ("ms-playwright", "playwright"), ("PLAYWRIGHT", None),
                           ("GH", None), ("Gh-x", None),
                           ("gh ", None), (" gh", None), ("uv ", None),
                           ("mystery-thing", None), ("", None)):
            checks.eq("attribute.%s" % (name or "empty"), attribute(name), want)
        checks.ok("plan.top.total_bytes", ((top or {}).get("cache_total_bytes") or 0) >= 15488)
        checks.ok("plan.top.cap", len(top_names) <= TOP_CONSUMERS if top else False)

        # ---- cache-evict refuses an unattributed path --------------------
        code, out, _err = cli(["plan", "cache-evict", "--path", "mystery-thing", "--json"])
        evict = hudfix.one_object(out)
        checks.eq("evict.unattributed.exit", code, hudfix.EXIT_OK)
        checks.eq("evict.unattributed.ok", (evict or {}).get("ok"), False)
        checks.ok("evict.unattributed.reason",
                  "cannot attribute" in ((evict or {}).get("reason") or ""))
        code, _out, _err = cli(["run", "cache-evict", "--path", "mystery-thing",
                                "--confirm", "cache-evict", "--json"])
        checks.eq("evict.unattributed.run_exit", code, hudfix.EXIT_PROGRAMMING)
        checks.ok("evict.unattributed.still_there",
                  os.path.exists(os.path.join(home, ".cache/mystery-thing/blob")))

        code, out, _err = cli(["plan", "cache-evict", "--path", "huggingface", "--json"])
        evict_ok = hudfix.one_object(out)
        checks.eq("evict.attributed.exit", code, hudfix.EXIT_OK)
        checks.eq("evict.attributed.bytes", (evict_ok or {}).get("bytes"), 8192)
        checks.eq("evict.attributed.owner",
                  ((evict_ok or {}).get("items") or [{}])[0].get("owner"), "huggingface")
        code, _out, _err = cli(["plan", "cache-evict", "--json"])
        checks.eq("evict.no_path.exit", code, hudfix.EXIT_PROGRAMMING)
        code, _out, _err = cli(["plan", "cache-evict", "--path", "../escape", "--json"])
        checks.eq("evict.traversal.exit", code, hudfix.EXIT_PROGRAMMING)

        # A prefix match must not open a cache the engine cannot attribute, and a
        # deep path under an unattributed child must never be cleared.
        for name in ("ghostty", "pipenv"):
            code, out, _err = cli(["plan", "cache-evict", "--path", name, "--json"])
            blocked = hudfix.one_object(out)
            checks.eq("evict.%s.exit" % name, code, hudfix.EXIT_OK)
            checks.eq("evict.%s.ok" % name, (blocked or {}).get("ok"), False)
            checks.eq("evict.%s.bytes" % name, (blocked or {}).get("bytes"), 0)
        deep_abs = os.path.join(home, ".cache", "mystery-thing", "uv-stuff")
        code, out, _err = cli(["plan", "cache-evict", "--path", deep_abs, "--json"])
        checks.eq("evict.deep.exit", code, hudfix.EXIT_PROGRAMMING)
        checks.eq("evict.deep.ok", (hudfix.one_object(out) or {}).get("ok"), False)
        code, _out, _err = cli(["plan", "cache-evict", "--path",
                                "mystery-thing/uv-stuff", "--json"])
        checks.eq("evict.deep_relative.exit", code, hudfix.EXIT_PROGRAMMING)
        code, _out, _err = cli(["run", "cache-evict", "--path", deep_abs,
                                "--confirm", "cache-evict", "--json"])
        checks.eq("evict.deep.run_exit", code, hudfix.EXIT_PROGRAMMING)
        checks.ok("evict.deep.still_there",
                  os.path.exists(os.path.join(deep_abs, "x")))

        # ---- a padded name is not the pattern: never attributed, never cleared
        padded_cases = (("gh_trailing", "gh "), ("gh_leading", " gh"),
                        ("uv_trailing", "uv "))
        for label, padded in padded_cases:
            code, out, _err = cli(["plan", "cache-evict", "--path", padded, "--json"])
            blocked = hudfix.one_object(out)
            checks.eq("evict.padded.%s.exit" % label, code, hudfix.EXIT_OK)
            checks.eq("evict.padded.%s.ok" % label, (blocked or {}).get("ok"), False)
            checks.eq("evict.padded.%s.bytes" % label, (blocked or {}).get("bytes"), 0)
            checks.ok("evict.padded.%s.reason" % label,
                      "cannot attribute" in ((blocked or {}).get("reason") or ""))
            code, _out, _err = cli(["run", "cache-evict", "--path", padded,
                                    "--confirm", "cache-evict", "--json"])
            checks.eq("evict.padded.%s.run_exit" % label, code, hudfix.EXIT_PROGRAMMING)
            checks.ok("evict.padded.%s.still_there" % label,
                      os.path.exists(os.path.join(home, ".cache", padded, "payload.bin")))
        checks.ok("evict.padded.no_quarantine",
                  not os.path.exists(os.path.join(quarantine, hudfix.local_day(),
                                                  "cache-evict")))

        # ---- hermes scratch: age threshold, structure kept ---------------
        code, out, _err = cli(["plan", "hermes-scratch", "--json"])
        scratch = hudfix.one_object(out)
        checks.eq("scratch.exit", code, hudfix.EXIT_OK)
        scratch_items = (scratch or {}).get("items", [])
        checks.eq("scratch.count", len(scratch_items), 2)
        checks.ok("scratch.old_only",
                  any(path.endswith("/scratch/old") for path in
                      [row["path"] for row in scratch_items])
                  and not any("scratch/new" in row["path"] for row in scratch_items),
                  repr([row["path"] for row in scratch_items]))
        checks.ok("scratch.rel_kept",
                  all(row.get("rel") for row in scratch_items))
        code, out, _err = cli(["run", "hermes-scratch", "--confirm", "hermes-scratch",
                               "--json"])
        checks.eq("scratch.run.exit", code, hudfix.EXIT_OK)
        checks.ok("scratch.fresh_kept",
                  os.path.exists(os.path.join(home, ".hermes/cache/scratch/new/thing")))
        checks.ok("scratch.old_gone",
                  not os.path.exists(os.path.join(home, ".hermes/cache/scratch/old")))
        scratch_rows = hudfix.read_manifest(
            os.path.join(quarantine, hudfix.local_day(), hudfix.MANIFEST_NAME))
        scratch_dest = [row["destination"] for row in scratch_rows
                        if row["action"] == "hermes-scratch"]
        checks.eq("scratch.destinations", len(scratch_dest), 2)
        checks.ok("scratch.structure_preserved",
                  any(row.endswith("/old") or row.endswith("/old/thing")
                      for row in scratch_dest), repr(scratch_dest))

        # ---- trash: window respected -------------------------------------
        code, out, _err = cli(["plan", "trash", "--json"])
        trash = hudfix.one_object(out)
        checks.eq("trash.exit", code, hudfix.EXIT_OK)
        trash_items = [row["path"] for row in (trash or {}).get("items", [])]
        checks.ok("trash.old_only",
                  any("old-junk" in path for path in trash_items)
                  and not any("new-junk" in path for path in trash_items),
                  repr(trash_items))
        code, _out, _err = cli(["run", "trash", "--confirm", "trash", "--json"])
        checks.eq("trash.run.exit", code, hudfix.EXIT_OK)
        checks.ok("trash.new_kept",
                  os.path.exists(os.path.join(home, ".local/share/Trash/files/new-junk")))

        # ---- the other cache actions enumerate, not clear ----------------
        for name, expected in (("cache-uv", 2048), ("cache-pip", 1024),
                               ("cache-cargo", 512 + 256)):
            before = _digest(os.path.join(base, "home"))
            code, out, _err = cli(["plan", name, "--json"])
            payload = hudfix.one_object(out)
            checks.eq("plan.%s.exit" % name, code, hudfix.EXIT_OK)
            checks.eq("plan.%s.bytes" % name, (payload or {}).get("bytes"), expected)
            checks.eq("plan.%s.unchanged" % name,
                      _digest(os.path.join(base, "home")), before)
        code, out, _err = cli(["plan", "cache-yay", "--json"])
        yay = hudfix.one_object(out)
        checks.eq("plan.cache-yay.exit", code, hudfix.EXIT_OK)
        if platform.system() == "Linux":
            checks.eq("plan.cache-yay.bytes", (yay or {}).get("bytes"), 128)
        else:
            checks.eq("plan.cache-yay.reason", (yay or {}).get("reason"), "not this host")

        # ---- cache-pacman orders versions the way pacman does -------------
        # The action itself is Linux only, so prove the ordering through the
        # patched call: 1.10 is newer than 1.9, and the newest copy stays.
        packages = os.path.join(base, "pacman-pkgs")
        for name in ("foo-1.9-1-x86_64.pkg.tar.zst", "foo-1.10-1-x86_64.pkg.tar.zst",
                     "bar-1.0-1-any.pkg.tar.xz", "bar-1.0-2-any.pkg.tar.xz"):
            _write(os.path.join(packages, name), "P" * 10)
        patched = hudfix.Context(overrides={"pacman": packages})
        patched.which = lambda name: True
        pacman_plan = _pacman_plan(patched)
        superseded = sorted(os.path.basename(row["path"])
                            for row in pacman_plan.get("items", []))
        checks.eq("pacman.superseded", superseded,
                  ["bar-1.0-1-any.pkg.tar.xz", "foo-1.9-1-x86_64.pkg.tar.zst"])
        checks.ok("pacman.newest_kept",
                  "foo-1.10-1-x86_64.pkg.tar.zst" not in superseded, repr(superseded))
        checks.eq("pacman.kept_newest", pacman_plan.get("kept_newest"), 2)
        for left, right, want in (("1.9-1", "1.10-1", -1), ("1.10-1", "1.9-1", 1),
                                  ("1.0-2", "1.0-10", -1), ("1:0.1-1", "2.0-1", 1),
                                  ("2.0", "2.0-1", -1), ("1.0a-1", "1.0b-1", -1),
                                  ("1.0_1-1", "1.0.1-1", 0), ("1.0-1", "1.0-1", 0)):
            checks.eq("vercmp.%s_vs_%s" % (left, right), _vercmp(left, right), want)

        # ---- linux-only and daemon-gated actions refuse ------------------
        before = _digest(os.path.join(base, "home"))
        code, out, _err = cli(["plan", "journal-vacuum", "--json"])
        journal = hudfix.one_object(out)
        checks.eq("journal.plan.exit", code, hudfix.EXIT_OK)
        if platform.system() != "Linux":
            checks.eq("journal.plan.reason", (journal or {}).get("reason"), "not this host")
            code, out, _err = cli(["run", "journal-vacuum",
                                   "--confirm", "journal-vacuum", "--json"])
            checks.eq("journal.run.exit", code, hudfix.EXIT_PROGRAMMING)
            checks.eq("journal.run.reason",
                      (hudfix.one_object(out) or {}).get("reason"), "not this host")
        checks.eq("journal.plan.never_writes", _digest(os.path.join(base, "home")), before)
        for name in ("orphans-list", "snapshots-list", "disk-btrfs"):
            code, out, _err = cli(["plan", name, "--json"])
            payload = hudfix.one_object(out)
            checks.eq("plan.%s.exit" % name, code, hudfix.EXIT_OK)
            if platform.system() != "Linux":
                checks.eq("plan.%s.reason" % name, (payload or {}).get("reason"),
                          "not this host")

        # ---- disk-health parses a recorded dump --------------------------
        code, out, _err = cli(["plan", "disk-health", "--json"])
        health = hudfix.one_object(out)
        checks.eq("health.exit", code, hudfix.EXIT_OK)
        checks.eq("health.class", (health or {}).get("class"), "read")
        device = ((health or {}).get("devices") or [{}])[0]
        checks.eq("health.ok", (health or {}).get("ok"), True)
        checks.eq("health.wear", device.get("wear_pct"), 3.0)
        checks.eq("health.hours", device.get("power_on_hours"), 1234)
        checks.eq("health.temp", device.get("temp_c"), 34.0)
        checks.eq("health.media_errors", device.get("media_errors"), 0)
        checks.ok("health.model", device.get("model") == "APPLE SSD AP0512Z")
        checks.eq("health.source", device.get("source"), "recorded")

        # ---- docker without a daemon is an honest absence ---------------
        code, out, _err = cli(["plan", "docker-df", "--json"])
        docker = hudfix.one_object(out)
        checks.eq("docker.plan.exit", code, hudfix.EXIT_OK)
        checks.ok("docker.plan.answers",
                  isinstance(docker, dict) and ("ok" in docker), repr(docker))
        if not docker.get("ok"):
            checks.ok("docker.plan.no_daemon_reason",
                      "docker" in (docker.get("reason") or "").lower(),
                      repr(docker.get("reason")))

        # ---- quarantine-list reads back what was moved -------------------
        code, out, _err = cli(["plan", "quarantine-list", "--json"])
        qued = hudfix.one_object(out)
        checks.eq("quarantine.exit", code, hudfix.EXIT_OK)
        checks.ok("quarantine.rows", (qued or {}).get("count", 0) == 9,
                  repr((qued or {}).get("count")))
        checks.eq("quarantine.bytes_matches",
                  (qued or {}).get("bytes"),
                  sum(row["bytes"] for row in (qued or {}).get("items", [])))
        checks.eq("quarantine.bytes_total", (qued or {}).get("bytes"), 8668)
        checks.eq("quarantine.by_action", (qued or {}).get("by_action"),
                  {"cache-npm": 2, "hermes-scratch": 2, "trash": 1, "quarantine": 4})
        checks.eq("quarantine.formats", (qued or {}).get("formats"),
                  {"hudfix": 5, "legacy5": 2, "legacy3": 2})
        checks.eq("quarantine.without_source", (qued or {}).get("rows_without_source"), 2)
        checks.eq("quarantine.bytes_not_claimed_exact", (qued or {}).get("bytes_exact"),
                  False)
        checks.ok("quarantine.legacy_rows_in_items",
                  sum(1 for row in (qued or {}).get("items", [])
                      if row.get("format") == "legacy5") == 2)

        # ---- log: one line per plan and per run -------------------------
        with open(log_path, "r", encoding="utf-8") as handle:
            lines = [json.loads(line) for line in handle if line.strip()]
        required = ("ts", "event", "action", "class", "items", "bytes", "result", "exit")
        checks.ok("log.fields", all(all(key in row for key in required) for row in lines))
        events = [row["event"] for row in lines]
        checks.eq("log.plan_lines", events.count("plan"), counts["plan"])
        checks.eq("log.run_lines", events.count("run"), counts["run"])
        checks.ok("log.no_list_line",
                  not any(row["event"] in ("list", "status") for row in lines))
        checks.ok("log.plan_floor", events.count("plan") >= 12, repr(counts))
        checks.ok("log.run_floor", events.count("run") >= 6, repr(counts))
        checks.ok("log.timestamps_utc", all(row["ts"].endswith("Z") for row in lines))
        checks.ok("log.moved_bytes_gt_zero", any(row["bytes"] > 0 for row in lines))

        # ---- the fake home stayed fake: nothing was moved out of the base --
        checks.ok("purity.everything_under_base",
                  all(os.path.abspath(row["destination"]).startswith(base)
                      for row in hudfix.read_manifest(
                          os.path.join(quarantine, hudfix.local_day(),
                                       hudfix.MANIFEST_NAME))))
        checks.ok("purity.fake_home_still_has_mystery",
                  os.path.exists(os.path.join(home, ".cache/mystery-thing/blob")))
        checks.ok("purity.real_quarantine_root_used_never",
                  os.path.abspath(quarantine).startswith(base)
                  and os.path.abspath(quarantine) != hudfix.expand(
                      hudfix.DEFAULT_QUARANTINE_ROOT))
    except BaseException as exc:
        checks.ok("self_check.completed", False, "%s: %s" % (type(exc).__name__, exc))
    summary["passed"] = checks.passed
    summary["failed"] = checks.failed
    summary["checks"] = checks.rows
    summary["ok"] = checks.failed == 0
    if checks.failed:
        summary["reason"] = "%d of %d checks failed; the tree is left at %s" % (
            checks.failed, checks.passed + checks.failed, hudfix.tilde(base))
    else:
        shutil.rmtree(base, ignore_errors=True)
    hudfix.emit(summary, True)
    return hudfix.EXIT_OK if checks.failed == 0 else hudfix.EXIT_FAILED


def _digest(root):
    return hudfix.tree_digest(root)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--self-check" in argv:
        return self_check()
    if argv and argv[0] in ("--version",):
        sys.stdout.write("hudfix_storage 1 (module for hudfix.py)\n")
        return 0
    sys.stderr.write("hudfix_storage.py is a module for hudfix.py; run "
                     "`hudfix.py list` or `hudfix_storage.py --self-check`\n")
    return hudfix.EXIT_PROGRAMMING


if __name__ == "__main__":
    sys.exit(main())
