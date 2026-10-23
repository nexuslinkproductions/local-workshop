#!/usr/bin/env python3
"""recent.py - F6 RECENT AND PINNED feed for the v5 HUD deck.

Emits the latest downloads, screenshots and recent files, the pinned folders,
and a type census, from a paths config. Stdlib only, no network, no daemon:
the HUD polls this script and a live read is cached for 10 s. A fixture is
never cached and never reads the host: a fixture file carries the tree as data,
and --fixture DIR stands in for the whole machine, so ~ is that directory,
relative roots resolve inside it, and a root outside it is refused, not read.

    recent.py --json
    recent.py --config ./hud_paths.json --limit 4 --json
    recent.py --fixture nexuslink.hud/v5/fixtures/recent.json --json
    recent.py --fixture ./snapshot-dir --json     # a dir standing in for the machine
    recent.py --self-check

Exit codes: 0 for data and honest absence ({"ok": false, "reason": ...}),
2 only for a caller error (bad arguments, a named file that does not exist)
or an unexpected bug. Missing or malformed *content* is an answer, not a crash.

Contract: cards/feeds-brief.md. Docs, example config and the extension table:
nexuslink.hud/v5/feeds/README-recent.md.
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

EXIT_OK = 0
EXIT_CALLER = 2

SCHEMA = "nexuslink.hud/v5/feeds/recent"
DEFAULT_CONFIG = "~/.config/nexuslink/hud_paths.json"
DEFAULT_LIMIT = 8
MAX_LIMIT = 1000
CACHE_TTL_S = 10.0
LISTS = ("downloads", "screenshots", "recent_files")
BUCKETS = ("image", "document", "archive", "code", "audio", "video", "other")

# Extension -> bucket. The one place the mapping lives; README-recent.md keeps
# a copy for humans and --self-check asserts every bucket is reachable.
EXTENSIONS = {
    "image": "png jpg jpeg jpe gif webp avif heic heif bmp tif tiff svg ico icns",
    "document": "pdf doc docx xls xlsx ppt pptx odt ods odp rtf txt md markdown csv tsv epub pages numbers key log tex",
    "archive": "zip tar gz tgz bz2 tbz xz txz 7z rar dmg iso pkg deb rpm zst lz4",
    "code": "py js mjs cjs ts tsx jsx qml sh bash zsh fish rb go rs c h cc cpp hpp java kt swift php lua sql json yaml yml toml ini cfg conf xml html htm css scss sass vue svelte",
    "audio": "mp3 wav flac m4a aac ogg oga opus aiff aif alac wma",
    "video": "mp4 mov mkv avi webm m4v mpg mpeg wmv flv",
}
# Two-part extensions win over the last part alone (a .tar.gz is an archive,
# not a gz; a .d.ts is code, not a TypeScript text).
COMPOUND = {
    "tar.gz": "archive",
    "tar.bz2": "archive",
    "tar.xz": "archive",
    "tar.zst": "archive",
    "tar.lz4": "archive",
    "d.ts": "code",
}

EXT = {}
for _bucket, _words in EXTENSIONS.items():
    for _word in _words.split():
        EXT[_word] = _bucket

ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


class Problem(Exception):
    """Absence or malformed data. Always an answer, never a crash. Exit 0."""

    kind = "data"

    def __init__(self, reason):
        Exception.__init__(self, reason)
        self.reason = str(reason)


class Missing(Problem):
    kind = "missing"


class Malformed(Problem):
    kind = "malformed"


class CallerError(Exception):
    """The caller asked for something impossible. Exit 2."""

    def __init__(self, reason):
        Exception.__init__(self, reason)
        self.reason = str(reason)


# --------------------------------------------------------------------------
# small helpers


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc)


def iso(epoch):
    """Epoch seconds -> 2026-10-22T21:07:02Z. Unusable input -> None."""
    if epoch is None or isinstance(epoch, bool):
        return None
    try:
        value = float(epoch)
    except (TypeError, ValueError, OverflowError):
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


def parse_iso(text):
    """2026-10-22T21:07:02Z -> epoch. Anything else -> None."""
    if not isinstance(text, str):
        return None
    try:
        stamp = datetime.datetime.strptime(text.strip(), "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return None
    return stamp.replace(tzinfo=datetime.timezone.utc).timestamp()


def finite(value):
    """True for a real, finite int or float. Bools are not numbers here."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    return value == value and value not in (float("inf"), float("-inf"))


def finite_float(value):
    """A number we can print as a float, or None. Huge ints and NaN -> None."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        number = float(value)
    except (OverflowError, TypeError, ValueError):
        return None
    return number if number == number and number not in (float("inf"), float("-inf")) else None


# A JSON field is only a boolean when it is one. `true` and the string "true"
# are true; `false`, the string "false", "" (an empty string), 0 and "0" are
# false; null, a list, an object or any other string is not a boolean at all,
# so the caller treats the field as absent and records a reason instead of
# guessing what the author meant. Read strictly: "FALSE" and " true " are not
# booleans, because a near miss is the bug this rule exists for.
NOT_A_BOOLEAN = object()


def strict_bool(value):
    """JSON value -> True, False, or NOT_A_BOOLEAN. See the rule above."""
    if value is True or value is False:
        return value
    if isinstance(value, str):
        if value == "true":
            return True
        if value in ("false", ""):
            return False
        if value == "0":
            return False
        return NOT_A_BOOLEAN
    if isinstance(value, (int, float)):
        try:
            return False if float(value) == 0.0 else NOT_A_BOOLEAN
        except (OverflowError, TypeError, ValueError):
            return NOT_A_BOOLEAN
    return NOT_A_BOOLEAN


def boolean_note(field, value):
    """A field that is not a boolean -> the one-line reason we print for it."""
    try:
        shown = json.dumps(value, ensure_ascii=True, default=repr)
    except (TypeError, ValueError):
        shown = repr(value)
    if len(shown) > 60:
        shown = shown[:57] + "..."
    return "%s is not a boolean (%s), treated as absent" % (field, shown)


def home():
    return os.path.expanduser("~")


def abs_path(value, base=None):
    """Config path -> absolute path. Relative values resolve against `base`."""
    text = os.path.expanduser(str(value).strip())
    if not os.path.isabs(text):
        text = os.path.join(base or os.getcwd(), text)
    return os.path.abspath(text)


# A fixture file must print the same paths on any machine, so its ~ is not the
# running user's home. HOST_HOME marks the modes that expand ~ against the host;
# a fixture passes the home it declares, or None to keep the ~ form verbatim.
HOST_HOME = object()


def fixture_path(value, base=None, home_dir=None):
    """Fixture path -> the string fixture mode prints. Pure string work:
    no cwd, no host home, no filesystem."""
    text = str(value).strip()
    if home_dir is not None:
        if text == "~":
            text = home_dir
        elif text.startswith("~" + os.sep):
            text = home_dir + text[1:]
    if not text:
        return text
    if os.path.isabs(text) or text.startswith("~"):
        return os.path.normpath(text)
    return os.path.normpath(os.path.join(base, text)) if base else os.path.normpath(text)


def path_for(value, base=None, home_dir=HOST_HOME):
    """One configured path, resolved the way the reading mode needs it."""
    if home_dir is HOST_HOME:
        return abs_path(value, base)
    return fixture_path(value, base, home_dir)


def tilde(path, home_dir=HOST_HOME):
    """Display form. Home is shortened; nothing else is."""
    if not path:
        return ""
    if home_dir is HOST_HOME:
        root = home().rstrip(os.sep)
    elif home_dir:
        root = str(home_dir).rstrip(os.sep)
    else:
        return path
    if path == root:
        return "~"
    if root and path.startswith(root + os.sep):
        return "~" + path[len(root):]
    return path


def within(path, roots):
    """True when `path` is one of `roots` or sits under one of them."""
    for root in roots:
        if path == root:
            return True
        if path.startswith(root.rstrip(os.sep) + os.sep):
            return True
    return False


def classify(name):
    """Extension -> one of BUCKETS, case-insensitive. Unknown -> 'other'."""
    base = os.path.basename(str(name)).lower()
    if "." not in base.strip("."):
        return "other"
    parts = base.split(".")
    if len(parts) >= 3:
        tail2 = ".".join(parts[-2:])
        if tail2 in COMPOUND:
            return COMPOUND[tail2]
    return EXT.get(parts[-1], "other")


def state_dir():
    """Cache directory. NEXUSLINK_STATE_DIR exists for tests only."""
    override = os.environ.get("NEXUSLINK_STATE_DIR")
    if override:
        return os.path.abspath(os.path.expanduser(override))
    return os.path.join(home(), ".local", "state", "nexuslink")


def cache_file():
    """Live cache path. A fixture run keeps no cache file at all."""
    return os.path.join(state_dir(), "recent.json")


# --------------------------------------------------------------------------
# config


def _int_or(value, default, low, high):
    if isinstance(value, bool):
        return default
    if isinstance(value, float) and not finite(value):
        return default
    try:
        number = int(value)
    except (TypeError, ValueError, OverflowError):
        return default
    if number < low or number > high:
        return default
    return number


def _root_entry(item):
    """Config list item -> {"path": str, "depth": int} or None."""
    if isinstance(item, str):
        text = item.strip()
        return {"path": text, "depth": 1} if text else None
    if isinstance(item, dict):
        for key in ("path", "root", "dir"):
            value = item.get(key)
            if isinstance(value, str) and value.strip():
                return {
                    "path": value.strip(),
                    "depth": _int_or(item.get("depth"), 1, 0, 32),
                }
    return None


def _pin_entry(item):
    """Config pinned item -> {"name": str|None, "path": str} or None."""
    if isinstance(item, str):
        text = item.strip()
        if not text:
            return None
        return {"name": None, "path": text}
    if isinstance(item, dict):
        value = item.get("path") or item.get("root") or item.get("dir")
        if not isinstance(value, str) or not value.strip():
            return None
        name = item.get("name")
        if not isinstance(name, str) or not name.strip():
            name = None
        return {"name": name, "path": value.strip()}
    return None


def parse_config(raw, shown, base, home_dir=HOST_HOME):
    """JSON object -> normalised config. Tolerates partial and odd shapes."""
    if not isinstance(raw, dict):
        raise Malformed("config at %s is not a JSON object" % shown)
    config = {"limit": DEFAULT_LIMIT, "roots": {}, "pinned": []}
    config["limit"] = _int_or(raw.get("limit"), DEFAULT_LIMIT, 1, MAX_LIMIT)
    for key in LISTS:
        value = raw.get(key)
        if value is None:
            config["roots"][key] = []
            continue
        if isinstance(value, (str, dict)):
            value = [value]
        if not isinstance(value, list):
            config["roots"][key] = []
            continue
        roots = []
        for item in value:
            entry = _root_entry(item)
            if entry is None:
                continue
            entry["path"] = path_for(entry["path"], base, home_dir)
            roots.append(entry)
        config["roots"][key] = roots
    value = raw.get("pinned")
    if isinstance(value, (str, dict)):
        value = [value]
    if isinstance(value, list):
        for item in value:
            entry = _pin_entry(item)
            if entry is None:
                continue
            entry["path"] = path_for(entry["path"], base, home_dir)
            config["pinned"].append(entry)
    if not any(config["roots"][key] for key in LISTS) and not config["pinned"]:
        raise Malformed("config at %s names no usable roots" % shown)
    return config


class _NonFinite(ValueError):
    """A JSON number that is NaN or out of float range. Bad content, not a bug."""

    def __init__(self, text):
        ValueError.__init__(self, text)
        self.text = str(text)


def _json_float(text):
    """json.loads parse_float hook: reject NaN and overflowed literals."""
    value = float(text)
    if not finite(value):
        raise _NonFinite(text)
    return value


def _json_constant(text):
    """json.loads parse_constant hook: NaN, Infinity and -Infinity."""
    raise _NonFinite(text)


def _no_broken_utf8(raw, what, shown):
    """Reject a document holding a string UTF-8 cannot encode.

    A lone surrogate is half a UTF-16 pair: `"\\ud800"` is legal JSON and
    parses into a Python string, then dies the moment the answer is printed.
    That makes it bad content, so it gets the malformed answer instead of a
    traceback. The walk is iterative because a parseable document can nest
    deeper than a recursive walk may go.
    """
    stack = [raw]
    while stack:
        item = stack.pop()
        if isinstance(item, str):
            try:
                item.encode("utf-8")
            except UnicodeEncodeError:
                quoted = json.dumps(item, ensure_ascii=True)
                if len(quoted) > 60:
                    quoted = quoted[:57] + "..."
                raise Malformed(
                    "%s at %s holds a string UTF-8 cannot encode: %s" % (what, shown, quoted)
                )
        elif isinstance(item, dict):
            for key, value in item.items():
                stack.append(key)
                stack.append(value)
        elif isinstance(item, list):
            stack.extend(item)


def read_json_file(path, what, shown=None):
    """Read one JSON file. Bad bytes and bad content are answers, not crashes.

    `shown` is the path as it should appear in a reason. Live mode leaves it
    out and gets the host `~` form; fixture mode passes the path exactly as the
    caller gave it, so the bytes never depend on the host HOME.
    """
    display = tilde(path) if shown is None else shown
    try:
        with open(path, "rb") as handle:
            body = handle.read()
    except OSError as exc:
        raise Missing("cannot read %s at %s: %s" % (what, display, exc.strerror or exc))
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise Malformed("%s at %s is not valid UTF-8: %s" % (what, display, exc))
    if not text.strip():
        raise Missing("%s at %s is empty" % (what, display))
    try:
        parsed = json.loads(text, parse_float=_json_float, parse_constant=_json_constant)
    except _NonFinite as exc:
        raise Malformed("%s at %s has a non-finite number: %s" % (what, display, exc.text))
    except RecursionError:
        raise Malformed("%s at %s nests deeper than this reader allows" % (what, display))
    except ValueError as exc:
        raise Malformed("%s at %s is not valid JSON: %s" % (what, display, exc))
    _no_broken_utf8(parsed, what, display)
    return parsed


# --------------------------------------------------------------------------
# live scan


def scan_root(root, depth, allowed_roots, confined=None, home_dir=HOST_HOME):
    """Walk one root. Returns (entries, stats). Raises Problem when unreadable.

    Each entry carries its display name, absolute path, size, mtime and type,
    plus a private identity key. Symlinks are resolved before stat, broken
    ones are counted and skipped, and a link whose target leaves every
    configured root is counted and skipped, never followed out. `confined` is
    the fixture directory in DIR mode: a link that leaves it is judged on its
    target string alone, so no host path is ever stat'ed from there.
    """
    entries = []
    stats = {"broken": 0, "outside": 0}
    root = os.path.abspath(root)
    if not os.path.exists(root):
        raise Missing("no such directory: %s" % tilde(root, home_dir))
    if not os.path.isdir(root):
        raise Missing("not a directory: %s" % tilde(root, home_dir))
    single_level = depth == 1

    def consider(path):
        name = os.path.basename(path)
        is_link = os.path.islink(path)
        if is_link:
            outside = not within(os.path.realpath(path), allowed_roots)
            if outside and confined is not None:
                stats["outside"] += 1
                return
            if not os.path.exists(path):
                stats["broken"] += 1
                return
            if outside:
                stats["outside"] += 1
                return
        try:
            info = os.stat(path)
        except OSError:
            stats["broken"] += 1 if is_link else 0
            return
        if not stat.S_ISREG(info.st_mode):
            return
        entries.append(
            {
                "name": name,
                "path": os.path.abspath(path),
                "size": info.st_size,
                "mtime": info.st_mtime,
                "type": classify(name),
                "_key": ("inode", info.st_dev, info.st_ino),
            }
        )

    try:
        if single_level:
            for name in sorted(os.listdir(root)):
                if name.startswith("."):
                    continue
                consider(os.path.join(root, name))
        else:
            base_depth = root.rstrip(os.sep).count(os.sep)
            for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
                here = dirpath.rstrip(os.sep).count(os.sep) - base_depth + 1
                dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
                kept = []
                for name in dirnames:
                    child = os.path.join(dirpath, name)
                    if os.path.islink(child):
                        # A linked directory is never followed; count it the
                        # same way a linked file is counted.
                        outside = not within(os.path.realpath(child), allowed_roots)
                        if outside and confined is not None:
                            stats["outside"] += 1
                        elif not os.path.exists(child):
                            stats["broken"] += 1
                        elif outside:
                            stats["outside"] += 1
                        continue
                    kept.append(name)
                dirnames[:] = kept
                if depth > 0 and here >= depth:
                    dirnames[:] = []
                for name in sorted(filenames):
                    if name.startswith("."):
                        continue
                    consider(os.path.join(dirpath, name))
    except PermissionError:
        raise Missing("permission denied: %s" % tilde(root, home_dir))
    except OSError as exc:
        raise Missing("cannot read %s: %s" % (tilde(root, home_dir), exc.strerror or exc))
    return entries, stats


def pin_rows(pins, home_dir=HOST_HOME, confined=None):
    rows = []
    for pin in pins:
        path = pin["path"]
        name = pin["name"] or os.path.basename(path.rstrip(os.sep)) or tilde(path, home_dir)
        if confined is not None and not within(os.path.abspath(path), [confined]):
            # Same rule as a root: a pin outside the fixture directory is
            # reported missing, never stat'ed on the host.
            rows.append({"name": name, "path": path, "exists": False, "kind": None})
            continue
        exists = os.path.isdir(path)
        kind = "dir" if exists else None
        if not exists:
            exists = os.path.isfile(path)
            kind = "file" if exists else None
        rows.append({"name": name, "path": path, "exists": exists, "kind": kind})
    return rows


# --------------------------------------------------------------------------
# fixture scan


def fixture_name(name):
    """A fixture file row's name -> the bare name to print, or None to skip.

    A name is one file inside the root. `.`, `..` and anything holding a path
    separator could climb out of that root (or reach another directory on a
    different machine), so those rows are skipped, not resolved.
    """
    text = name.strip()
    if not text or text in (".", ".."):
        return None
    for sep in (os.sep, os.altsep, "/", "\\"):
        if sep and sep in text:
            return None
    return text


def _fixture_entry(raw, root, allowed_roots, stats, home_dir, notes):
    """One fixture file row -> entry or None (mirrors the live rules)."""
    if not isinstance(raw, dict):
        return None
    name = raw.get("name")
    if not isinstance(name, str):
        return None
    name = fixture_name(name)
    if name is None:
        return None
    path = os.path.join(root, name)
    link = raw.get("link")
    # A boolean field is read strictly: "false" is false, and null or "no" is
    # not a boolean at all, so it counts as absent and is named in the reason.
    raw_broken = raw.get("broken", False)
    broken = strict_bool(raw_broken)
    if broken is NOT_A_BOOLEAN:
        notes.append(boolean_note("broken for %s" % name, raw_broken))
        broken = False
    if isinstance(link, str) and link.strip():
        target = path_for(link, root, home_dir)
        if broken:
            stats["broken"] += 1
            return None
        if not within(target, allowed_roots):
            stats["outside"] += 1
            return None
        key = ("path", target)
    elif broken:
        stats["broken"] += 1
        return None
    else:
        key = ("path", os.path.normpath(path))
    mtime = raw.get("mtime")
    if mtime is None:
        mtime = parse_iso(raw.get("mtime_iso"))
    size = raw.get("size")
    if not finite(size):
        size = None
    return {
        "name": name,
        "path": path,
        "size": int(size) if size is not None else None,
        "mtime": finite_float(mtime),
        "type": classify(name),
        "_key": key,
    }


def fixture_config(raw, shown, base, home_dir):
    """A fixture file carries its own config; a fixture dir points at one."""
    if not isinstance(raw, dict):
        # null, a number or a boolean has no keys, so the membership tests
        # below would raise TypeError. Bad content is an answer, not a bug.
        raise Malformed("fixture at %s has neither a config block nor roots" % shown)
    if "config" in raw:
        return parse_config(raw["config"], shown, base, home_dir)
    if "roots" in raw or "pinned" in raw:
        return parse_config(raw, shown, base, home_dir)
    raise Malformed("fixture at %s has neither a config block nor roots" % shown)


def fixture_home(raw, shown):
    """The home a fixture declares for ~, or None to keep the ~ form."""
    value = raw.get("home")
    if value is None:
        return None
    if not isinstance(value, str) or not value.strip().startswith(os.sep):
        raise Malformed("fixture at %s declares home %r, which is not an absolute path" % (shown, value))
    return os.path.normpath(value.strip())


# --------------------------------------------------------------------------
# payload


def public_entry(entry):
    return {
        "name": entry["name"],
        "path": entry["path"],
        "size": entry["size"],
        "mtime": iso(entry["mtime"]),
        "type": entry["type"],
    }


def select(entries, limit, claimed):
    """Newest first, name as the tiebreak, one appearance per real file."""
    if limit <= 0:
        return []
    ordered = sorted(
        entries,
        key=lambda item: (
            -(item["mtime"] if item["mtime"] is not None else 0.0),
            item["name"].lower(),
            item["name"],
        ),
    )
    rows = []
    for entry in ordered:
        if entry["_key"] in claimed:
            continue
        claimed.add(entry["_key"])
        rows.append(public_entry(entry))
        if len(rows) >= limit:
            break
    return rows


def type_census(lists):
    counts = dict((bucket, 0) for bucket in BUCKETS)
    for key in LISTS:
        for item in lists[key]:
            bucket = item["type"]
            counts[bucket] = counts.get(bucket, 0) + 1
    return counts


def envelope(mode, limit, lists, pinned, roots, broken, outside):
    return {
        "ok": True,
        "generated_at": iso_now(),
        "source": mode,
        "schema": SCHEMA,
        "limit": limit,
        "downloads": lists["downloads"],
        "screenshots": lists["screenshots"],
        "recent_files": lists["recent_files"],
        "pinned": pinned,
        "types": type_census(lists),
        "broken": broken,
        "outside": outside,
        "roots": roots,
        "cached": False,
        "age_s": 0,
    }


def build_live(config, limit, mode="live", home_dir=HOST_HOME, confined=None):
    """Scan the configured roots. Live mode reads the host; --fixture DIR mode
    passes its own directory as home_dir and confined, so every read lands in
    that directory and a root outside it is refused instead of read."""
    lists = dict((key, []) for key in LISTS)
    roots = []
    broken = 0
    outside = 0

    def inside(path):
        return confined is None or within(os.path.abspath(path), [confined])

    allowed = []
    for key in LISTS:
        for root in config["roots"][key]:
            if inside(root["path"]):
                allowed.append(os.path.realpath(root["path"]))
    for pin in config["pinned"]:
        if inside(pin["path"]):
            allowed.append(os.path.realpath(pin["path"]))

    for key in LISTS:
        for root in config["roots"][key]:
            row = {
                "list": key,
                "path": tilde(root["path"], home_dir),
                "depth": root["depth"],
                "exists": os.path.isdir(root["path"]) if inside(root["path"]) else False,
                "files": 0,
                "broken": 0,
                "outside": 0,
                "reason": None,
            }
            if not inside(root["path"]):
                # A fixture directory is the whole machine: outside it there is
                # no data to read, only the host this mode must not touch.
                row["reason"] = "root is outside the fixture directory"
                roots.append(row)
                continue
            try:
                entries, stats = scan_root(root["path"], root["depth"], allowed, confined, home_dir)
            except Problem as problem:
                row["reason"] = problem.reason
                roots.append(row)
                continue
            row["files"] = len(entries)
            row["broken"] = stats["broken"]
            row["outside"] = stats["outside"]
            broken += stats["broken"]
            outside += stats["outside"]
            lists[key].extend(entries)
            roots.append(row)

    pinned = pin_rows(config["pinned"], home_dir, confined)
    claimed = set()
    selected = {}
    for key in LISTS:
        selected[key] = select(lists[key], limit, claimed)
    return envelope(mode, limit, selected, pinned, roots, broken, outside)


def build_fixture(raw, shown, limit):
    """Read a fixture file. Pure: no host home, no cwd, no stat, no cache."""
    if not isinstance(raw, dict):
        raise Malformed("fixture at %s has neither a config block nor roots" % shown)
    home_dir = fixture_home(raw, shown)
    # No base for the config: a relative fixture root stays relative, so the
    # output never picks up the directory the fixture happens to sit in.
    config = fixture_config(raw, shown, None, home_dir)
    tree = raw.get("roots")
    if not isinstance(tree, dict):
        raise Malformed("fixture at %s has no roots object" % shown)

    allowed = []
    for key in LISTS:
        for root in config["roots"][key]:
            allowed.append(os.path.normpath(root["path"]))
    for pin in config["pinned"]:
        allowed.append(os.path.normpath(pin["path"]))

    lists = dict((key, []) for key in LISTS)
    roots = []
    broken = 0
    outside = 0
    for key in LISTS:
        for root in config["roots"][key]:
            display = tilde(root["path"], home_dir)
            node = tree.get(display)
            # Strict boolean: a root's `exists` defaults to true when the key is
            # absent, and a value that is not a boolean counts as absent.
            notes = []
            raw_exists = node.get("exists", True) if isinstance(node, dict) else True
            exists = strict_bool(raw_exists)
            if exists is NOT_A_BOOLEAN:
                notes.append(boolean_note("exists for %s" % display, raw_exists))
                exists = True
            row = {
                "list": key,
                "path": display,
                "depth": root["depth"],
                "exists": exists,
                "files": 0,
                "broken": 0,
                "outside": 0,
                "reason": None,
            }
            if not isinstance(node, dict):
                row["reason"] = "root not present in fixture"
                roots.append(row)
                continue
            if not exists:
                reason = node.get("reason")
                row["reason"] = reason if isinstance(reason, str) and reason.strip() else "no such directory"
                roots.append(row)
                continue
            stats = {"broken": 0, "outside": 0}
            rows = node.get("files")
            claimed_here = 0
            if isinstance(rows, list):
                for item in rows:
                    entry = _fixture_entry(item, root["path"], allowed, stats, home_dir, notes)
                    if entry is not None:
                        lists[key].append(entry)
                        claimed_here += 1
            row["files"] = claimed_here
            row["broken"] = stats["broken"]
            row["outside"] = stats["outside"]
            broken += stats["broken"]
            outside += stats["outside"]
            if notes:
                row["reason"] = "; ".join(notes)
            roots.append(row)

    pinned = []
    for pin in config["pinned"]:
        display = tilde(pin["path"], home_dir)
        node = tree.get(display)
        name = pin["name"] or os.path.basename(pin["path"].rstrip(os.sep)) or display
        raw_exists = node.get("exists", False) if isinstance(node, dict) else False
        exists = strict_bool(raw_exists)
        notes = []
        if exists is NOT_A_BOOLEAN:
            notes.append(boolean_note("exists for %s" % display, raw_exists))
            exists = False
        kind = node.get("kind") if isinstance(node, dict) else None
        if not isinstance(kind, str) or kind not in ("dir", "file"):
            kind = None
        if exists and kind is None:
            kind = "dir"
        row = {"name": name, "path": pin["path"], "exists": bool(exists), "kind": kind if exists else None}
        if notes:
            row["reason"] = "; ".join(notes)
        pinned.append(row)

    claimed = set()
    selected = {}
    for key in LISTS:
        selected[key] = select(lists[key], limit, claimed)
    return envelope("fixture", limit, selected, pinned, roots, broken, outside)


# --------------------------------------------------------------------------
# cache


def cache_key(identity, limit):
    digest = hashlib.sha1()
    digest.update(b"live")
    digest.update(b"\0%d" % limit)
    digest.update(b"\0" + SCHEMA.encode("utf-8"))
    for path in identity:
        digest.update(b"\0")
        if not path:
            digest.update(b"-")
            continue
        try:
            info = os.stat(path)
            digest.update(
                ("%s|%d|%d|%d" % (os.path.abspath(path), info.st_mtime_ns, info.st_size, info.st_ino)).encode("utf-8")
            )
        except OSError:
            digest.update(("%s|missing" % os.path.abspath(path)).encode("utf-8"))
    return digest.hexdigest()


def cache_read(key):
    """Cached payload inside the TTL, else None. Never raises."""
    if os.environ.get("NEXUSLINK_NO_CACHE"):
        return None
    try:
        with open(cache_file(), "r", encoding="utf-8") as handle:
            record = json.load(handle)
    except (OSError, ValueError):
        return None
    if not isinstance(record, dict) or record.get("key") != key:
        return None
    built_at = record.get("built_at")
    payload = record.get("payload")
    if not isinstance(built_at, (int, float)) or not isinstance(payload, dict):
        return None
    if not payload.get("ok"):
        return None
    age = time.time() - float(built_at)
    if age < 0 or age >= CACHE_TTL_S:
        return None
    served = json.loads(json.dumps(payload))
    served["cached"] = True
    served["age_s"] = int(round(age))
    return served


def cache_write(key, payload, built_at):
    """Atomic write: temp file in the same directory, then os.replace."""
    if os.environ.get("NEXUSLINK_NO_CACHE"):
        return
    target = cache_file()
    parent = os.path.dirname(target)
    try:
        os.makedirs(parent, exist_ok=True)
        handle = tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=parent, prefix=".tmp-", suffix=".json", delete=False
        )
        try:
            with handle:
                # ASCII-safe: a cache file must never fail to write because a
                # path holds a byte UTF-8 cannot carry (json.load reads it back
                # to the same value).
                json.dump({"key": key, "built_at": built_at, "payload": payload}, handle, ensure_ascii=True, indent=1)
                handle.write("\n")
            os.replace(handle.name, target)
        except BaseException:
            try:
                os.unlink(handle.name)
            except OSError:
                pass
            raise
    except (OSError, ValueError):
        # A cache we cannot write is a slower HUD, never a broken feed.
        return


# --------------------------------------------------------------------------
# entry points


def run(args):
    if args.fixture is not None:
        given = args.fixture
        if not given.strip():
            raise CallerError("--fixture needs a path")
        target = abs_path(given)
        # Fixture reasons print the path exactly as given: expanding a host ~
        # here would put this machine's home into otherwise pure output.
        shown = given
        if not os.path.exists(target):
            raise CallerError("no fixture at %s" % shown)
        if os.path.isdir(target):
            # DIR is fixture mode as well: the directory stands in for the
            # machine, so ~ is the directory itself, a relative root resolves
            # inside it, and a root that resolves outside it is refused instead
            # of read. Nothing outside DIR is stat'ed, and no cache is touched.
            root_dir = os.path.abspath(target)
            config_path = os.path.join(root_dir, "hud_paths.json")
            shown_config = os.path.join(shown, "hud_paths.json")
            if not os.path.isfile(config_path):
                raise CallerError("fixture dir %s has no hud_paths.json" % shown)
            raw = read_json_file(config_path, "fixture config", shown_config)
            limit = args.limit
            if limit is None:
                limit = DEFAULT_LIMIT
                if isinstance(raw, dict):
                    limit = _int_or(raw.get("limit"), DEFAULT_LIMIT, 1, MAX_LIMIT)
            config = parse_config(raw, shown_config, root_dir, home_dir=root_dir)
            payload = build_live(config, limit, mode="fixture", home_dir=root_dir, confined=root_dir)
        else:
            raw = read_json_file(target, "fixture", shown)
            limit = args.limit
            if limit is None:
                limit = DEFAULT_LIMIT
                if isinstance(raw, dict) and isinstance(raw.get("config"), dict):
                    limit = _int_or(raw["config"].get("limit"), DEFAULT_LIMIT, 1, MAX_LIMIT)
            payload = build_fixture(raw, shown, limit)
        # Fixture purity: no cache read, no cache write, no state file. Two
        # runs give the same bytes apart from generated_at, cached false.
        return payload
    else:
        explicit = args.config is not None
        if explicit and not args.config.strip():
            raise CallerError("--config needs a path")
        config_path = abs_path(args.config) if explicit else abs_path(DEFAULT_CONFIG)
        if explicit:
            if not os.path.exists(config_path):
                raise CallerError("no config at %s" % tilde(config_path))
            if not os.path.isfile(config_path):
                raise CallerError("config is not a file: %s" % tilde(config_path))
        elif not os.path.isfile(config_path):
            raise Missing("no config at %s" % tilde(config_path))
        raw = read_json_file(config_path, "config")
        base = os.path.dirname(config_path)
        config = parse_config(raw, tilde(config_path), base)
        limit = args.limit if args.limit is not None else config["limit"]
        key = cache_key([config_path], limit)
        cached = cache_read(key)
        if cached is not None:
            return cached
        payload = build_live(config, limit)

    cache_write(key, payload, time.time())
    return payload


def render(payload, compact, ascii_only=False):
    if compact:
        return json.dumps(payload, ensure_ascii=ascii_only, separators=(",", ":"))
    return json.dumps(payload, ensure_ascii=ascii_only, indent=2)


def write_line(line):
    """One line, UTF-8 bytes, so the answer does not depend on the locale."""
    data = (line + "\n").encode("utf-8")
    stream = getattr(sys.stdout, "buffer", None)
    if stream is None:
        sys.stdout.write(data.decode("utf-8"))
        sys.stdout.flush()
        return
    stream.write(data)
    stream.flush()


def emit(payload, compact):
    write_line(render(payload, compact))


def emit_ascii(payload, compact):
    """The fallback: escape anything UTF-8 cannot carry, so it always prints."""
    write_line(render(payload, compact, True))


def failure(mode, exc, kind):
    return {
        "ok": False,
        "generated_at": iso_now(),
        "source": mode,
        "schema": SCHEMA,
        "reason": str(exc).strip(),
        "kind": kind,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="recent.py",
        description="F6 recent and pinned feed: downloads, screenshots, recent files, pins and a type census.",
    )
    parser.add_argument("--config", metavar="PATH", help="paths config (default %s)" % DEFAULT_CONFIG)
    parser.add_argument("--fixture", metavar="PATH", help="read a fixture file, or a dir holding hud_paths.json")
    parser.add_argument("--limit", type=int, metavar="N", help="items per list (default %d)" % DEFAULT_LIMIT)
    parser.add_argument("--json", action="store_true", help="one compact JSON line instead of pretty output")
    parser.add_argument("--self-check", action="store_true", help="run the built-in checks against a temp tree")
    args = parser.parse_args(argv)

    if args.self_check:
        return self_check()
    if args.limit is not None and not (0 <= args.limit <= MAX_LIMIT):
        parser.error("--limit must be between 0 and %d" % MAX_LIMIT)

    mode = "fixture" if args.fixture is not None else "live"
    try:
        payload = run(args)
    except CallerError as exc:
        emit_ascii(failure(mode, exc, "caller"), args.json)
        return EXIT_CALLER
    except Problem as exc:
        emit_ascii(failure(mode, exc, exc.kind), args.json)
        return EXIT_OK
    except (KeyboardInterrupt, SystemExit):
        raise
    except BaseException as exc:  # noqa: BLE001 - a bug is a bug
        emit_ascii(failure(mode, "programming error: %s: %s" % (type(exc).__name__, exc), "programming"), args.json)
        return EXIT_CALLER
    try:
        emit(payload, args.json)
    except UnicodeEncodeError:
        # A value the answer cannot carry as UTF-8 (a lone surrogate in a path)
        # is bad content, not a bug: one ASCII-safe line, exit 0, no traceback.
        emit_ascii(failure(mode, "the answer holds a string UTF-8 cannot carry", "malformed"), True)
        return EXIT_OK
    return EXIT_OK


# --------------------------------------------------------------------------
# self-check

SELF_CHECK_MT0 = 1792700000


def _touch(path, offset, payload=b"x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(payload)
    os.utime(path, (SELF_CHECK_MT0 + offset, SELF_CHECK_MT0 + offset))


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def _names(payload, key):
    return [item["name"] for item in payload.get(key, [])]


def self_check():
    failures = []

    def check(label, condition, detail=None):
        if not condition:
            failures.append("%s%s" % (label, (": " + str(detail)) if detail is not None else ""))

    tmp = tempfile.mkdtemp(prefix="f6-recent-selfcheck-")
    state = os.path.join(tmp, "state")
    tree = os.path.join(tmp, "roots")
    config_path = os.path.join(tmp, "hud_paths.json")
    script = os.path.abspath(__file__)

    downloads = os.path.join(tree, "downloads")
    shots = os.path.join(tree, "shots")
    recent = os.path.join(tree, "recent")
    pinned = os.path.join(tree, "pinned-hud")

    try:
        # --- a small tree with known names, sizes, mtimes and extensions ---
        _touch(os.path.join(downloads, "i-latest.txt"), 300)
        _touch(os.path.join(downloads, "b-photo.JPG"), 200)
        _touch(os.path.join(downloads, "a-report.pdf"), 100)
        _touch(os.path.join(downloads, "c-archive.zip"), 95)
        _touch(os.path.join(downloads, "d-script.py"), 90)
        _touch(os.path.join(downloads, "e-track.flac"), 85)
        _touch(os.path.join(downloads, "f-clip.mp4"), 80)
        _touch(os.path.join(downloads, "g-blob.xyz"), 75)
        _touch(os.path.join(downloads, "h-notes.md"), 70)
        _touch(os.path.join(downloads, "z-late.TAR.GZ"), 10)
        _touch(os.path.join(downloads, ".DS_Store"), 400)
        _touch(os.path.join(shots, "shot-1.png"), 150)
        _touch(os.path.join(shots, "shot-2.png"), 150)
        os.symlink(os.path.join(downloads, "a-report.pdf"), os.path.join(shots, "copy.pdf"))
        os.symlink(os.path.join(tree, "nope.png"), os.path.join(shots, "broken.png"))
        os.symlink("/etc/hosts", os.path.join(shots, "escape.png"))
        _touch(os.path.join(recent, "sub", "deep.log"), 250)
        _touch(os.path.join(recent, "chain", "one", "two", "three.md"), 220)
        os.makedirs(os.path.join(pinned, "inner"), exist_ok=True)

        config = {
            "limit": 8,
            "downloads": ["roots/downloads"],
            "screenshots": ["roots/shots", "roots/absent-shots"],
            "recent_files": [{"path": "roots/recent", "depth": 2}, {"path": "roots/recent/chain", "depth": 0}],
            "pinned": [
                {"name": "HUD", "path": "roots/pinned-hud"},
                {"name": "Report", "path": "roots/downloads/a-report.pdf"},
                {"name": "Gone", "path": "roots/absent-pin"},
            ],
        }
        _write(config_path, json.dumps(config, indent=2))

        def run_cli(argv, home=None, state_path=None):
            env = os.environ.copy()
            env["NEXUSLINK_STATE_DIR"] = state_path or state
            env.pop("NEXUSLINK_NO_CACHE", None)
            if home:
                env["HOME"] = home
            proc = subprocess.run(
                [sys.executable, script] + list(argv),
                capture_output=True,
                text=True,
                env=env,
                cwd=tmp,
            )
            return proc

        def as_json(proc):
            try:
                return json.loads(proc.stdout)
            except ValueError:
                return None

        # --- live run over the temp tree ---
        first = run_cli(["--config", config_path, "--json"])
        payload = as_json(first)
        check("live exit 0", first.returncode == 0, first.returncode)
        check("live one json line", first.stdout.strip().count("\n") == 0, repr(first.stdout[:120]))
        check("live stderr empty", first.stderr == "", repr(first.stderr[:200]))
        check("live ok", isinstance(payload, dict) and payload.get("ok") is True, payload and payload.get("reason"))
        if not isinstance(payload, dict):
            raise SystemExit("self-check cannot continue without a payload")
        check("source live", payload.get("source") == "live", payload.get("source"))
        check("schema", payload.get("schema") == SCHEMA, payload.get("schema"))
        check("generated_at utc iso", bool(ISO_RE.match(payload.get("generated_at") or "")), payload.get("generated_at"))
        check("limit echoed", payload.get("limit") == 8, payload.get("limit"))

        # ordering by mtime desc, name asc on the tie, hidden and over-limit out
        check(
            "downloads order",
            _names(payload, "downloads")
            == ["i-latest.txt", "b-photo.JPG", "a-report.pdf", "c-archive.zip", "d-script.py", "e-track.flac", "f-clip.mp4", "g-blob.xyz"],
            _names(payload, "downloads"),
        )
        check("limit cuts the tail", "h-notes.md" not in _names(payload, "downloads"), _names(payload, "downloads"))
        check("hidden skipped", ".DS_Store" not in _names(payload, "downloads"), _names(payload, "downloads"))
        check("tie broken by name", _names(payload, "screenshots") == ["shot-1.png", "shot-2.png"], _names(payload, "screenshots"))
        check("recent depth 2", "deep.log" in _names(payload, "recent_files"), _names(payload, "recent_files"))
        check("recent depth 0 unlimited", _names(payload, "recent_files") == ["deep.log", "three.md"], _names(payload, "recent_files"))
        check("no duplicate across lists", "copy.pdf" not in _names(payload, "screenshots"), _names(payload, "screenshots"))
        all_names = _names(payload, "downloads") + _names(payload, "screenshots") + _names(payload, "recent_files")
        check("a-report once", all_names.count("a-report.pdf") == 1, all_names)

        # every bucket, and the exact census
        types = payload.get("types") or {}
        check("types keys", tuple(types.keys()) == BUCKETS, list(types.keys()))
        check(
            "types census",
            types
            == {"image": 3, "document": 4, "archive": 1, "code": 1, "audio": 1, "video": 1, "other": 1},
            types,
        )
        check("every bucket used", all(types.get(bucket, 0) > 0 for bucket in BUCKETS), types)
        item = payload["downloads"][0]
        check("item shape", set(item.keys()) == {"name", "path", "size", "mtime", "type"}, sorted(item.keys()))
        check("item mtime iso", bool(ISO_RE.match(item.get("mtime") or "")), item.get("mtime"))
        check(
            "compound extension",
            payload["downloads"][0]["type"] == "document"
            and classify("z-late.TAR.GZ") == "archive"
            and classify("types.d.ts") == "code"
            and classify("noext") == "other"
            and classify("UPPER.PNG") == "image",
            [classify(x) for x in ("z-late.TAR.GZ", "types.d.ts", "noext", "UPPER.PNG")],
        )

        # broken symlinks and links that leave the configured roots
        check("broken counted", payload.get("broken") == 1, payload.get("broken"))
        check("outside counted", payload.get("outside") == 1, payload.get("outside"))

        # missing root: honest reason, list still populated, ok stays true
        roots = payload.get("roots") or []
        missing = [row for row in roots if row.get("exists") is False]
        check("missing root row", len(missing) == 1 and missing[0]["path"].endswith("absent-shots"), missing)
        check("missing root reason", bool(missing and missing[0].get("reason")), missing)
        check("ok with a missing root", payload.get("ok") is True)

        # pins
        pins = payload.get("pinned") or []
        check("pin count", len(pins) == 3, len(pins))
        check("pin dir", pins[0] == {"name": "HUD", "path": pins[0]["path"], "exists": True, "kind": "dir"}, pins[0])
        check("pin file", pins[1]["exists"] is True and pins[1]["kind"] == "file", pins[1])
        check("pin missing", pins[2]["exists"] is False and pins[2]["kind"] is None, pins[2])

        # --- the same tree read through a fixture dir ---
        fixture_dir = run_cli(["--fixture", tmp, "--json"])
        fixture_payload = as_json(fixture_dir)
        check("fixture dir exit 0", fixture_dir.returncode == 0, fixture_dir.returncode)
        check("fixture dir same lists", isinstance(fixture_payload, dict) and _names(fixture_payload, "downloads") == _names(payload, "downloads"), _names(fixture_payload or {}, "downloads"))
        check("fixture dir same pins", isinstance(fixture_payload, dict) and [p["exists"] for p in fixture_payload.get("pinned", [])] == [True, True, False], fixture_payload and fixture_payload.get("pinned"))
        check("fixture source", isinstance(fixture_payload, dict) and fixture_payload.get("source") == "fixture", fixture_payload and fixture_payload.get("source"))

        # --- a fixture dir stands in for the machine: no host read at all ---
        for fake in ("dir-home-a", "dir-home-b"):
            _touch(os.path.join(tmp, fake, "Downloads", "host-only.png"), 500)
        dir_fixture = os.path.join(tmp, "dir-fixture")
        _write(
            os.path.join(dir_fixture, "hud_paths.json"),
            '{"limit": 8, "downloads": ["~/Downloads"], "screenshots": ["%s"],'
            ' "pinned": [{"name": "Home", "path": "~/Downloads"}]}'
            % os.path.join(tmp, "dir-home-a", "Downloads"),
        )
        _touch(os.path.join(dir_fixture, "Downloads", "inside.png"), 600)
        dir_state_a = os.path.join(tmp, "dir-state-a")
        dir_state_b = os.path.join(tmp, "dir-state-b")
        dir_a = run_cli(["--fixture", dir_fixture, "--json"], home=os.path.join(tmp, "dir-home-a"), state_path=dir_state_a)
        dir_b = run_cli(["--fixture", dir_fixture, "--json"], home=os.path.join(tmp, "dir-home-b"), state_path=dir_state_b)
        payload_dir_a = as_json(dir_a)
        payload_dir_b = as_json(dir_b)
        check("dir fixture exit 0", dir_a.returncode == 0 and dir_b.returncode == 0, [dir_a.returncode, dir_a.stderr[:200]])
        check(
            "dir fixture lists only what is inside it",
            isinstance(payload_dir_a, dict) and _names(payload_dir_a, "downloads") == ["inside.png"],
            _names(payload_dir_a or {}, "downloads"),
        )
        check(
            "dir fixture ~ is the directory",
            isinstance(payload_dir_a, dict)
            and payload_dir_a["downloads"][0]["path"] == os.path.join(os.path.abspath(dir_fixture), "Downloads", "inside.png"),
            (payload_dir_a or {}).get("downloads"),
        )
        dir_rows = (payload_dir_a or {}).get("roots") or []
        check(
            "dir fixture refuses a root outside it",
            [row.get("reason") for row in dir_rows] == [None, "root is outside the fixture directory"],
            dir_rows,
        )
        check("dir fixture ~ pin found inside it", [p["exists"] for p in (payload_dir_a or {}).get("pinned") or []] == [True], (payload_dir_a or {}).get("pinned"))
        stable_dir_a = dict(payload_dir_a) if isinstance(payload_dir_a, dict) else {}
        stable_dir_b = dict(payload_dir_b) if isinstance(payload_dir_b, dict) else {}
        stable_dir_a.pop("generated_at", None)
        stable_dir_b.pop("generated_at", None)
        check(
            "dir fixture identical under two HOMEs",
            isinstance(payload_dir_a, dict) and stable_dir_a == stable_dir_b,
            "DIR output depends on HOME",
        )
        check("dir fixture writes no state", not os.path.exists(dir_state_a) and not os.path.exists(dir_state_b))
        _touch(os.path.join(tmp, "dir-home-a", "Downloads", "host-only.png"), 700)
        dir_touched = as_json(
            run_cli(["--fixture", dir_fixture, "--json"], home=os.path.join(tmp, "dir-home-a"), state_path=os.path.join(tmp, "dir-state-c"))
        )
        stable_touched = dict(dir_touched) if isinstance(dir_touched, dict) else {}
        stable_touched.pop("generated_at", None)
        check("dir fixture ignores a host mtime change", stable_touched == stable_dir_a, stable_touched)

        # --- the shipped fixture file ---
        shipped = os.path.join(os.path.dirname(os.path.dirname(script)), "fixtures", "recent.json")
        # A state dir of its own, so this also proves a fixture run writes none.
        fixture_state = os.path.join(tmp, "fixture-state")
        fixture_run = run_cli(["--fixture", shipped, "--json"], state_path=fixture_state)
        shipped_payload = as_json(fixture_run)
        check("shipped fixture exit 0", fixture_run.returncode == 0, fixture_run.stderr or fixture_run.stdout[:200])
        check("shipped fixture ok", isinstance(shipped_payload, dict) and shipped_payload.get("ok") is True, shipped_payload and shipped_payload.get("reason"))
        check("shipped fixture cached false", isinstance(shipped_payload, dict) and shipped_payload.get("cached") is False, shipped_payload and shipped_payload.get("cached"))
        check("shipped fixture age 0", isinstance(shipped_payload, dict) and shipped_payload.get("age_s") == 0, shipped_payload and shipped_payload.get("age_s"))
        check("shipped fixture writes no state", not os.path.exists(fixture_state), os.path.exists(fixture_state))
        again = run_cli(["--fixture", shipped, "--json"], state_path=fixture_state)
        again_payload = as_json(again)
        check("shipped fixture still cached false", isinstance(again_payload, dict) and again_payload.get("cached") is False, again_payload and again_payload.get("cached"))
        check("shipped fixture still writes no state", not os.path.exists(fixture_state), os.path.exists(fixture_state))
        if isinstance(shipped_payload, dict) and shipped_payload.get("ok"):
            check("shipped four lists", all(len(shipped_payload.get(k) or []) > 0 for k in LISTS), {k: len(shipped_payload.get(k) or []) for k in LISTS})
            check(
                "shipped every bucket",
                all((shipped_payload.get("types") or {}).get(b) for b in BUCKETS),
                shipped_payload.get("types"),
            )
            check("shipped broken", shipped_payload.get("broken") == 1, shipped_payload.get("broken"))
            check("shipped outside", shipped_payload.get("outside") == 1, shipped_payload.get("outside"))
            shipped_missing = [row for row in shipped_payload.get("roots") or [] if row.get("exists") is False]
            check(
                "shipped missing root keeps ok true with the documented reason",
                [row.get("reason") for row in shipped_missing] == ["no such directory"],
                shipped_missing,
            )
            shipped_names = _names(shipped_payload, "downloads") + _names(shipped_payload, "screenshots") + _names(shipped_payload, "recent_files")
            check("shipped dedupe", "hud-review.mp4" not in _names(shipped_payload, "recent_files"), _names(shipped_payload, "recent_files"))
            check("shipped pin missing", any(p["exists"] is False for p in shipped_payload.get("pinned") or []), shipped_payload.get("pinned"))
            check("shipped newest first", shipped_payload["downloads"][0]["name"] == "Satoshi_Complete.zip", _names(shipped_payload, "downloads")[:3])

        # --- cache: a second call inside 10 s must not need the tree ---
        cache_path = os.path.join(state, "recent.json")
        check("cache written", os.path.isfile(cache_path), cache_path)
        check("cache atomic leftovers", not [n for n in os.listdir(state) if n.startswith(".tmp-")], os.listdir(state))
        shutil.rmtree(tree)
        second = run_cli(["--config", config_path, "--json"])
        cached_payload = as_json(second)
        check("cached exit 0", second.returncode == 0, second.returncode)
        check("cached flag", isinstance(cached_payload, dict) and cached_payload.get("cached") is True, cached_payload and cached_payload.get("cached"))
        check("cached lists survive a deleted tree", isinstance(cached_payload, dict) and _names(cached_payload, "downloads") == _names(payload, "downloads"), cached_payload and _names(cached_payload, "downloads"))
        check("cached payload identical", isinstance(cached_payload, dict) and cached_payload.get("types") == payload.get("types"), cached_payload and cached_payload.get("types"))
        check("cached generated_at kept", isinstance(cached_payload, dict) and cached_payload.get("generated_at") == payload.get("generated_at"), cached_payload and cached_payload.get("generated_at"))
        shutil.rmtree(state)
        third = run_cli(["--config", config_path, "--json"])
        fresh_payload = as_json(third)
        check("rebuild after cache removed", isinstance(fresh_payload, dict) and fresh_payload.get("cached") is False, fresh_payload and fresh_payload.get("cached"))
        check("rebuild sees the missing tree", isinstance(fresh_payload, dict) and fresh_payload.get("downloads") == [] and fresh_payload.get("ok") is True, fresh_payload and fresh_payload.get("downloads"))
        check("rebuild roots report missing", isinstance(fresh_payload, dict) and all(row.get("exists") is False for row in fresh_payload.get("roots") or []), fresh_payload and fresh_payload.get("roots"))

        # --- error paths ---
        absent = run_cli(["--config", os.path.join(tmp, "nope.json"), "--json"])
        absent_payload = as_json(absent)
        check("named missing config exits 2", absent.returncode == 2, absent.returncode)
        check("named missing config json", isinstance(absent_payload, dict) and absent_payload.get("ok") is False and absent_payload.get("kind") == "caller", absent_payload)

        bad_config = os.path.join(tmp, "bad.json")
        _write(bad_config, "{not json")
        bad = run_cli(["--config", bad_config, "--json"])
        bad_payload = as_json(bad)
        check("malformed config exits 0", bad.returncode == 0, bad.returncode)
        check("malformed config ok false", isinstance(bad_payload, dict) and bad_payload.get("ok") is False and bad_payload.get("kind") == "malformed", bad_payload)

        no_roots = os.path.join(tmp, "empty.json")
        _write(no_roots, "{}")
        empty = run_cli(["--config", no_roots, "--json"])
        empty_payload = as_json(empty)
        check("config without roots exits 0", empty.returncode == 0, empty.returncode)
        check("config without roots ok false", isinstance(empty_payload, dict) and empty_payload.get("ok") is False, empty_payload)

        no_fixture = run_cli(["--fixture", os.path.join(tmp, "absent-fixture.json"), "--json"])
        check("named missing fixture exits 2", no_fixture.returncode == 2, no_fixture.returncode)

        bad_limit = run_cli(["--limit", "nope", "--json"])
        check("bad limit exits 2", bad_limit.returncode == 2, bad_limit.returncode)

        fake_home = os.path.join(tmp, "home")
        os.makedirs(fake_home, exist_ok=True)
        default_config = run_cli(["--json"], home=fake_home)
        default_payload = as_json(default_config)
        check("default config absence exits 0", default_config.returncode == 0, default_config.returncode)
        check(
            "default config absence reason",
            isinstance(default_payload, dict)
            and default_payload.get("ok") is False
            and "hud_paths.json" in (default_payload.get("reason") or ""),
            default_payload,
        )

        # --- fixture purity: same bytes whatever the host HOME is ---
        home_a = os.path.join(tmp, "home-a")
        home_b = os.path.join(tmp, "home-b")
        os.makedirs(home_a, exist_ok=True)
        os.makedirs(home_b, exist_ok=True)
        run_a = run_cli(["--fixture", shipped, "--json"], home=home_a, state_path=os.path.join(tmp, "state-a"))
        run_b = run_cli(["--fixture", shipped, "--json"], home=home_b, state_path=os.path.join(tmp, "state-b"))
        payload_a = as_json(run_a)
        payload_b = as_json(run_b)
        check("two homes exit 0", run_a.returncode == 0 and run_b.returncode == 0, [run_a.returncode, run_b.returncode, run_a.stderr[:200], run_b.stderr[:200]])
        stable_a = dict(payload_a) if isinstance(payload_a, dict) else {}
        stable_b = dict(payload_b) if isinstance(payload_b, dict) else {}
        stable_a.pop("generated_at", None)
        stable_b.pop("generated_at", None)
        check(
            "two homes identical",
            isinstance(payload_a, dict) and isinstance(payload_b, dict) and stable_a == stable_b,
            "output depends on HOME (%s vs %s)" % (home_a, home_b),
        )
        check("no state under either home", not os.path.exists(os.path.join(home_a, ".local")) and not os.path.exists(os.path.join(home_b, ".local")))

        # --- a fixture that is not an object is bad content, not a bug ---
        for literal in ("null", "5", "true", "1.5", "[]"):
            scalar = os.path.join(tmp, "scalar-%s.json" % literal.replace(".", "-"))
            _write(scalar, literal)
            proc = run_cli(["--fixture", scalar, "--json"])
            scalar_payload = as_json(proc)
            check("fixture %s exits 0" % literal, proc.returncode == 0, proc.returncode)
            check(
                "fixture %s is malformed" % literal,
                isinstance(scalar_payload, dict) and scalar_payload.get("ok") is False and scalar_payload.get("kind") == "malformed",
                scalar_payload,
            )

        # --- malformed bytes and numbers are answers, never a crash ---
        bad_bytes = os.path.join(tmp, "bad-bytes.json")
        with open(bad_bytes, "wb") as handle:
            handle.write(b"\xff\xfe\x00{")
        proc = run_cli(["--fixture", bad_bytes, "--json"])
        answer = as_json(proc)
        check("non-UTF-8 fixture exits 0", proc.returncode == 0, proc.returncode)
        check(
            "non-UTF-8 fixture is malformed",
            isinstance(answer, dict) and answer.get("ok") is False and answer.get("kind") == "malformed",
            answer,
        )

        # A lone surrogate is half a UTF-16 pair: legal JSON, unprintable string.
        # It is bad content, so the answer is an envelope, never a traceback.
        for label, body in (
            (
                "name",
                '{"config":{"downloads":["~/Downloads"]},"roots":{"~/Downloads":{"exists":true,'
                '"files":[{"name":"\\ud800.png","size":1,"mtime":1792703402}]}}}',
            ),
            ("home", '{"home":"/Users/\\ud800","config":{"downloads":["~/Downloads"]},"roots":{}}'),
            (
                "key",
                '{"config":{"downloads":["~/Downloads"]},"roots":{"~/Down\\ud800loads":{"exists":true,"files":[]}}}',
            ),
            (
                "reason",
                '{"config":{"downloads":["~/Downloads"]},"roots":{"~/Downloads":{"exists":false,'
                '"reason":"gone \\ud800"}}}',
            ),
        ):
            path = os.path.join(tmp, "surrogate-%s.json" % label)
            _write(path, body)
            proc = run_cli(["--fixture", path, "--json"])
            answer = as_json(proc)
            check("surrogate %s exits 0" % label, proc.returncode == 0, proc.returncode)
            check("surrogate %s stderr empty" % label, proc.stderr == "", proc.stderr[:300])
            check("surrogate %s one line" % label, proc.stdout.strip().count("\n") == 0, proc.stdout[:120])
            check(
                "surrogate %s is malformed" % label,
                isinstance(answer, dict) and answer.get("ok") is False and answer.get("kind") == "malformed",
                answer,
            )
            check(
                "surrogate %s reason is ASCII" % label,
                isinstance(answer, dict) and all(ord(ch) < 128 for ch in answer.get("reason") or ""),
                answer and answer.get("reason"),
            )

        deep = os.path.join(tmp, "deep.json")
        _write(deep, "[" * 200000 + "]" * 200000)
        proc = run_cli(["--fixture", deep, "--json"])
        answer = as_json(proc)
        check("deep fixture exits 0", proc.returncode == 0, proc.returncode)
        check(
            "deep fixture is malformed",
            isinstance(answer, dict) and answer.get("ok") is False and answer.get("kind") == "malformed",
            answer,
        )

        nonfinite_fixture = (
            '{"home": "/Users/x", "config": {"downloads": ["~/Downloads"]},'
            ' "roots": {"~/Downloads": {"exists": true, "files":'
            ' [{"name": "a.png", "size": %s, "mtime": 1792703000}]}}}'
        )
        for label, literal in (("NaN", "NaN"), ("Infinity", "Infinity"), ("1e400", "1e400")):
            path = os.path.join(tmp, "size-%s.json" % label.lower())
            _write(path, nonfinite_fixture % literal)
            proc = run_cli(["--fixture", path, "--json"])
            answer = as_json(proc)
            check("size %s exits 0" % label, proc.returncode == 0, proc.returncode)
            check(
                "size %s is malformed" % label,
                isinstance(answer, dict) and answer.get("ok") is False and answer.get("kind") == "malformed",
                answer,
            )

        for label, body in (
            ("limit 1e400", '{"limit": 1e400, "downloads": ["~/Downloads"]}'),
            ("root depth 1e400", '{"downloads": [{"path": "~/Downloads", "depth": 1e400}]}'),
        ):
            path = os.path.join(tmp, "number-%s.json" % label.replace(" ", "-"))
            _write(path, body)
            proc = run_cli(["--config", path, "--json"])
            answer = as_json(proc)
            check("config %s exits 0" % label, proc.returncode == 0, proc.returncode)
            check(
                "config %s is malformed" % label,
                isinstance(answer, dict) and answer.get("ok") is False and answer.get("kind") == "malformed",
                answer,
            )

        # --- an empty path is a caller error, never a silent live read ---
        for flag in ("--fixture", "--config"):
            proc = run_cli([flag, "", "--json"])
            answer = as_json(proc)
            check("%s empty exits 2" % flag, proc.returncode == 2, proc.returncode)
            check(
                "%s empty is caller" % flag,
                isinstance(answer, dict) and answer.get("ok") is False and answer.get("kind") == "caller",
                answer,
            )

        # --- a fixture name may not climb out of its root ---
        escape = os.path.join(tmp, "escape.json")
        _write(
            escape,
            '{"home": "/Users/x", "config": {"downloads": ["~/Downloads"]},'
            ' "roots": {"~/Downloads": {"exists": true, "files": ['
            '{"name": "../escape.png", "size": 1, "mtime": 1792703000},'
            '{"name": ".", "size": 1, "mtime": 1792703000},'
            '{"name": "..", "size": 1, "mtime": 1792703000},'
            '{"name": "sub/nested.png", "size": 1, "mtime": 1792703000},'
            '{"name": "kept.png", "size": 1, "mtime": 1792703000}]}}}',
        )
        proc = run_cli(["--fixture", escape, "--json"])
        answer = as_json(proc)
        check("escape fixture exits 0", proc.returncode == 0, proc.returncode)
        check("escape names skipped", _names(answer or {}, "downloads") == ["kept.png"], _names(answer or {}, "downloads"))
        check(
            "escape path stays inside the root",
            isinstance(answer, dict)
            and answer["downloads"][0]["path"] == "/Users/x/Downloads/kept.png"
            and answer["roots"][0]["files"] == 1,
            (answer or {}).get("downloads"),
        )

        # --- booleans are read strictly, never by truthiness ---
        def bool_case(label, document):
            path = os.path.join(tmp, "bool-%s.json" % label)
            _write(path, document)
            proc = run_cli(["--fixture", path, "--json"])
            return proc, as_json(proc)

        root_exists = (
            '{"home":"/Users/x","config":{"downloads":["~/Downloads"]},"roots":{"~/Downloads":'
            '{"exists":%s,"files":[{"name":"a.png","size":1,"mtime":1792703402}]}}}'
        )
        for literal, want in (
            ("true", True),
            ('"true"', True),
            ("false", False),
            ('"false"', False),
            ('""', False),
            ("0", False),
            ('"0"', False),
        ):
            proc, answer = bool_case("exists-%s" % literal.replace('"', "q"), root_exists % literal)
            rows = (answer or {}).get("roots") or [{}]
            names = _names(answer or {}, "downloads")
            check("exists %s exits 0" % literal, proc.returncode == 0, proc.returncode)
            check("exists %s reads as %s" % (literal, want), rows[0].get("exists") is want, rows[0])
            check(
                "exists %s lists %d file(s)" % (literal, 1 if want else 0),
                len(names) == (1 if want else 0),
                names,
            )

        root_broken = (
            '{"home":"/Users/x","config":{"downloads":["~/Downloads"]},"roots":{"~/Downloads":{"exists":true,'
            '"files":[{"name":"link.png","link":"~/Downloads/target.png","broken":%s,"mtime":1792703402},'
            '{"name":"kept.png","size":2,"mtime":1792703401}]}}}'
        )
        for literal, want_broken, want_files in (
            ("true", 1, 1),
            ('"true"', 1, 1),
            ("false", 0, 2),
            ('"false"', 0, 2),
            ('""', 0, 2),
            ("0", 0, 2),
            ('"0"', 0, 2),
        ):
            proc, answer = bool_case("broken-%s" % literal.replace('"', "q"), root_broken % literal)
            check("broken %s exits 0" % literal, proc.returncode == 0, proc.returncode)
            check("broken %s counts %d" % (literal, want_broken), (answer or {}).get("broken") == want_broken, (answer or {}).get("broken"))
            check(
                "broken %s keeps %d file(s)" % (literal, want_files),
                len(_names(answer or {}, "downloads")) == want_files,
                _names(answer or {}, "downloads"),
            )

        for literal in ("null", "[]", "{}", '"no"'):
            label = literal.replace('"', "q").replace("[", "l").replace("]", "r").replace("{", "b").replace("}", "b")
            proc, answer = bool_case("absent-%s" % label, root_exists % literal)
            row = ((answer or {}).get("roots") or [{}])[0]
            check("exists %s exits 0" % literal, proc.returncode == 0, proc.returncode)
            check(
                "exists %s is absent, not coerced" % literal,
                row.get("exists") is True and len(_names(answer or {}, "downloads")) == 1,
                row,
            )
            check("exists %s names the field" % literal, "is not a boolean" in (row.get("reason") or ""), row.get("reason"))

        proc, answer = bool_case(
            "pin",
            '{"home":"/Users/x","config":{"downloads":["~/Downloads"],"pinned":[{"name":"P","path":"~/P"}]},'
            '"roots":{"~/Downloads":{"exists":true,"files":[]},"~/P":{"exists":"maybe"}}}',
        )
        pin = ((answer or {}).get("pinned") or [{}])[0]
        check("pin exists is not truthy-read", pin.get("exists") is False and pin.get("kind") is None, pin)
        check("pin exists names the field", "is not a boolean" in (pin.get("reason") or ""), pin.get("reason"))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        sys.stderr.write("self-check FAILED (%d)\n" % len(failures))
        for line in failures:
            sys.stderr.write("  - %s\n" % line)
        return 1
    sys.stdout.write("recent.py self-check OK\n")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
