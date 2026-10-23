"""Shared plumbing for the v5 HUD feed readers. Stdlib only, Python 3.9+.

The contract every reader in this directory keeps:

  * exactly one JSON object on stdout, and nothing else;
  * ``--json`` = one compact line (for a Process/FileView consumer), default =
    the same object pretty printed (for a human reading a terminal);
  * ``--fixture PATH`` reads a snapshot with the same shape as the live payload
    and never touches the real source, the network, or the filesystem outside
    the fixture;
  * ``generated_at`` and every time value is UTC ISO-8601 with a ``Z`` suffix;
  * data absence and malformed data are *answers*, not failures: the reader
    prints ``{"ok": false, "reason": "..."}`` and exits 0, so a HUD tick never
    sees a broken process;
  * exit 2 is reserved for a programming error (an unexpected exception) or a
    caller error (bad arguments). Data problems never reach it;
  * no secrets and no absolute home paths in the payload (``~`` stands in).

``DataProblem`` is how a reader reports an absence: raise it (or a subclass)
and the runner in each reader turns it into the ``ok: false`` object.
"""

from __future__ import annotations

import datetime
import json
import os
import sys
import tempfile

EXIT_OK = 0
EXIT_PROGRAMMING = 2

HOME = os.path.expanduser("~")


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


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc)


def utc_now_epoch():
    """Whole-second epoch. Enough for a HUD tick, and stable across readers."""
    return int(utc_now().timestamp())


def iso(epoch):
    """Epoch seconds -> ``2026-10-22T21:07:02Z``. Anything unusable -> None."""
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
    return iso(utc_now_epoch())


def tilde(path):
    """Home-relative display form. Output must never carry an absolute home path."""
    if not path:
        return ""
    path = os.path.abspath(os.path.expanduser(str(path)))
    if path == HOME:
        return "~"
    if path.startswith(HOME + os.sep):
        return "~" + path[len(HOME):]
    return path


def number(value):
    """Finite float or None. Accepts numeric strings, rejects bools and NaN."""
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
    num = number(value)
    return None if num is None else int(num)


def text(value, limit=None):
    """Trimmed string or None. Never returns a non-string."""
    if value is None:
        return None
    if not isinstance(value, str):
        value = str(value)
    value = " ".join(value.split())
    if not value:
        return None
    if limit is not None and len(value) > limit:
        cut = value[:limit]
        if " " in cut:
            cut = cut.rsplit(" ", 1)[0]
        value = cut.rstrip(" ,;:-") + "\u2026"
    return value


def epoch_from_iso(value):
    """Tolerant ISO-8601 -> epoch seconds. Naive stamps are read as UTC."""
    if not isinstance(value, str) or not value.strip():
        return None
    raw = value.strip().replace("Z", "+00:00").replace("z", "+00:00")
    try:
        parsed = datetime.datetime.fromisoformat(raw)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.timezone.utc)
    return parsed.timestamp()


def wrap_reason(exc):
    """Exception -> one short reason line, home paths shortened."""
    name = type(exc).__name__
    message = str(exc).strip() or name
    return tilde_text(message)


def tilde_text(message):
    for root in (HOME, os.path.realpath(HOME)):
        if root and root != "/" and root in message:
            message = message.replace(root + os.sep, "~" + os.sep).replace(root, "~")
    return message


def envelope(source, mode, **fields):
    """Success payload. Keys keep insertion order for a readable pretty print."""
    payload = {
        "ok": True,
        "source": source,
        "mode": mode,
        "generated_at": iso_now(),
    }
    payload.update(fields)
    return payload


def failure(source, mode, problem):
    kind = getattr(problem, "kind", "data")
    reason = getattr(problem, "reason", None) or wrap_reason(problem)
    return {
        "ok": False,
        "source": source,
        "mode": mode,
        "generated_at": iso_now(),
        "reason": tilde_text(reason),
        "kind": kind,
    }


def emit(payload, compact):
    """One JSON object on stdout, newline terminated."""
    if compact:
        line = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=False)
    else:
        line = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=False)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def read_json(path, what):
    """Load JSON from ``path`` or raise Missing/Malformed with a human reason."""
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
        raise Missing("cannot read %s at %s: %s" % (what, shown, exc.strerror or exc))
    if not raw.strip():
        raise Missing("%s at %s is empty" % (what, shown))
    try:
        return json.loads(raw)
    except ValueError as exc:
        raise Malformed("%s at %s is not valid JSON: %s" % (what, shown, exc))


def write_json(path, payload):
    """Atomic write: temp file in the same directory, then os.replace."""
    target = os.path.expanduser(str(path))
    parent = os.path.dirname(target) or "."
    os.makedirs(parent, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=parent, prefix=".tmp-", suffix=".json", delete=False
    )
    try:
        with handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=False)
            handle.write("\n")
        os.replace(handle.name, target)
    except BaseException:
        try:
            os.unlink(handle.name)
        except OSError:
            pass
        raise


def add_common_args(parser):
    """The three flags every reader shares."""
    parser.add_argument(
        "--fixture",
        metavar="PATH",
        help="read a snapshot with the live payload shape instead of the live source",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="emit one compact JSON line instead of the pretty-printed object",
    )
    return parser


def mode_of(args):
    return "fixture" if getattr(args, "fixture", None) else "live"


def run(source, build, args):
    """Execute ``build(args)`` under the exit-code contract and print its result."""
    compact = bool(getattr(args, "json", False))
    mode = mode_of(args)
    try:
        payload = build(args)
    except DataProblem as exc:
        emit(failure(source, mode, exc), compact)
        return EXIT_OK
    except (KeyboardInterrupt, SystemExit):
        raise
    except BaseException as exc:  # noqa: BLE001 - a bug is a bug, report and exit 2
        emit(
            {
                "ok": False,
                "source": source,
                "mode": mode,
                "generated_at": iso_now(),
                "reason": tilde_text("programming error: %s: %s" % (type(exc).__name__, exc)),
                "kind": "programming",
            },
            compact,
        )
        return EXIT_PROGRAMMING
    emit(payload, compact)
    return EXIT_OK
