#!/usr/bin/env python3
"""Host metrics reader: ``metrics.json`` -> the numbers behind the gauge row.

Live source: ``~/.local/state/nexuslink/metrics.json`` (written by the Linux-side
collector). ``--fixture v5/fixtures/metrics.json`` reads the shipped snapshot.
The reader is a normaliser, not a collector: it never runs a command, never
probes the host, and never writes a file.

The whole point of this reader is that the HUD keeps breathing when the payload
is thin. A block that is absent, the wrong type, or half-filled becomes ``null``
or a partial object plus a entry in ``missing`` / ``warnings``; it never raises,
and the caller sees ``ok: true`` as long as at least one block parses. Only
"this file is not a metrics object at all" produces ``ok: false``.

Blocks, all optional:

    host          {name, cores, loadavg[3], load1_frac}
    local_ai      {model, quant, size_gb, budget_scale_gb, budget_note,
                   activity_cpu_s, breath_period_s}
    tokens_today  {<provider>: int}       + derived total / top
    screens       [{id, workspaces[], windows}] + derived count
    windows       [<app id>]              + derived count
    kanban        {<board>: {<status>: int}} + derived totals

Derived values this reader adds (all named, all optional in the source):
``host.load1_frac`` from ``loadavg[0] / cores``, ``tokens_today.total`` and
``.top``, ``screens_count``, ``windows_count``, ``kanban.total``, and
``snapshot_age_s`` when the payload carries a ``ts``.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as common  # noqa: E402

SOURCE = "metrics"
DEFAULT_METRICS = "~/.local/state/nexuslink/metrics.json"

BLOCKS = ("host", "local_ai", "tokens_today", "screens", "windows", "kanban")


# --------------------------------------------------------------------- helpers


def floats(value, limit=None):
    """Coerce a list or a whitespace-separated string into floats.

    All or nothing: one non-finite element (NaN, Infinity, a string that is not
    a number) makes the whole value ``None``. ``loadavg`` is a 1/5/15 minute
    triple, so a dropped element would slide the 5 or 15 minute value into the
    1 minute slot and ``load1_frac`` would report the wrong ratio. ``limit``
    still trims a finite list to its first values.
    """
    if isinstance(value, str):
        value = value.replace(",", " ").split()
    if not isinstance(value, (list, tuple)):
        return None
    out = []
    for item in value:
        number = common.number(item)
        if number is None:
            return None
        out.append(round(number, 3))
    if limit is not None:
        out = out[:limit]
    return out or None


def counts_map(value):
    """{key: positive int} with unusable entries dropped."""
    if not isinstance(value, dict):
        return None, 0
    out, dropped = {}, 0
    for key, raw in value.items():
        label = common.text(key)
        number = common.integer(raw)
        if label is None or number is None:
            dropped += 1
            continue
        out[label] = number
    return (out or None), dropped


# ---------------------------------------------------------------------- blocks


def host_block(value, warnings):
    if value is None:
        return None
    if not isinstance(value, dict):
        warnings.append("host block is not an object")
        return None
    raw_avg = value.get("loadavg")
    block = {
        "name": common.text(value.get("name")) or common.text(value.get("hostname")),
        "cores": common.integer(value.get("cores")),
        "loadavg": floats(raw_avg, limit=3),
        "load1_frac": common.number(value.get("load1_frac")),
    }
    if block["loadavg"] is None and raw_avg is not None:
        # The triple was present and rejected: any stated ratio belongs to it.
        block["load1_frac"] = None
    if block["load1_frac"] is None and block["loadavg"] and block["cores"]:
        block["load1_frac"] = round(block["loadavg"][0] / float(block["cores"]), 4)
    return block if any(item is not None for item in block.values()) else None


def local_ai_block(value, warnings):
    if value is None:
        return None
    if not isinstance(value, dict):
        warnings.append("local_ai block is not an object")
        return None
    block = {
        "model": common.text(value.get("model")),
        "quant": common.text(value.get("quant")),
        "size_gb": common.number(value.get("size_gb")),
        "budget_scale_gb": common.number(value.get("budget_scale_gb")),
        "budget_note": common.text(value.get("budget_note")),
        "activity_cpu_s": common.number(value.get("activity_cpu_s")),
        "breath_period_s": common.number(value.get("breath_period_s")),
    }
    return block if any(item is not None for item in block.values()) else None


def tokens_block(value, warnings):
    if value is None:
        return None
    if not isinstance(value, dict):
        warnings.append("tokens_today block is not an object")
        return None
    providers, dropped = counts_map(value)
    if dropped:
        warnings.append("tokens_today dropped %d unusable provider counts" % dropped)
    if not providers:
        return None
    total = sum(providers.values())
    top = sorted(providers.items(), key=lambda item: (-item[1], item[0]))[:5]
    return {
        "total": total,
        "providers": providers,
        "top": [{"provider": name, "tokens": count} for name, count in top],
    }


def screens_block(value, warnings):
    if value is None:
        return None
    if not isinstance(value, list):
        warnings.append("screens block is not an array")
        return None
    screens = []
    for index, item in enumerate(value):
        if not isinstance(item, dict):
            warnings.append("screens[%d] is not an object, dropped" % index)
            continue
        ident = common.text(item.get("id")) or common.text(item.get("name"))
        if ident is None:
            warnings.append("screens[%d] has no id, dropped" % index)
            continue
        raw_workspaces = item.get("workspaces")
        workspaces = []
        if isinstance(raw_workspaces, list):
            for raw in raw_workspaces:
                number = common.integer(raw)
                if number is not None:
                    workspaces.append(number)
        elif raw_workspaces is not None:
            warnings.append(
                "screens[%d].workspaces is not an array, dropped" % index
            )
        screens.append(
            {
                "id": ident,
                "workspaces": workspaces,
                "windows": common.integer(item.get("windows")),
            }
        )
    return screens or None


def windows_block(value, warnings):
    if value is None:
        return None
    if not isinstance(value, list):
        warnings.append("windows block is not an array")
        return None
    names = []
    for index, item in enumerate(value):
        if not isinstance(item, str):
            warnings.append("windows[%d] is not a string, dropped" % index)
            continue
        name = common.text(item)
        if name is None:
            warnings.append("windows[%d] is empty, dropped" % index)
            continue
        names.append(name)
    return names or None


def kanban_block(value, warnings):
    if value is None:
        return None
    if not isinstance(value, dict):
        warnings.append("kanban block is not an object")
        return None
    boards = {}
    for name, board in value.items():
        label = common.text(name)
        if label is None:
            continue
        if not isinstance(board, dict):
            warnings.append("kanban.%s is not an object, dropped" % label)
            continue
        counts, dropped = counts_map(board)
        if dropped:
            warnings.append("kanban.%s dropped %d unusable counts" % (label, dropped))
        if counts:
            boards[label] = counts
    if not boards:
        return None
    boards["total"] = {
        status: sum(board.get(status, 0) for key, board in boards.items() if key != "total")
        for status in sorted({status for key, board in boards.items() if key != "total" for status in board})
    }
    return boards


BLOCK_READERS = {
    "host": host_block,
    "local_ai": local_ai_block,
    "tokens_today": tokens_block,
    "screens": screens_block,
    "windows": windows_block,
    "kanban": kanban_block,
}


# ------------------------------------------------------------------ collection


def load_source(args):
    if args.fixture:
        return common.read_json(args.fixture, "metrics fixture")
    return common.read_json(args.metrics, "metrics state file")


def collect(args):
    root = load_source(args)
    if not isinstance(root, dict):
        raise common.Malformed(
            "metrics payload must be an object (got %s)" % type(root).__name__
        )

    warnings = []
    metrics = {}
    missing = []
    for name in BLOCKS:
        reader = BLOCK_READERS[name]
        block = reader(root.get(name), warnings)
        if block is None:
            missing.append(name)
        metrics[name] = block

    if all(metrics[name] is None for name in BLOCKS):
        raise common.Malformed(
            "metrics payload has none of the expected blocks: %s" % ", ".join(BLOCKS)
        )

    ts = common.number(root.get("ts"))
    if ts is None:
        ts = common.epoch_from_iso(root.get("ts_iso"))
    metrics["ts"] = int(ts) if ts is not None else None
    metrics["ts_iso"] = common.iso(ts)
    metrics["snapshot_age_s"] = (
        max(0, common.utc_now_epoch() - int(ts)) if ts is not None else None
    )
    metrics["screens_count"] = len(metrics["screens"] or []) or None
    metrics["windows_count"] = len(metrics["windows"] or []) or None
    metrics["tokens_today"] = metrics["tokens_today"] or None

    out = common.envelope(
        SOURCE,
        "fixture" if args.fixture else "live",
        count=len(BLOCKS) - len(missing),
        missing=missing,
        metrics=metrics,
        source_file=common.tilde(args.fixture or args.metrics),
    )
    if warnings:
        out["warnings"] = warnings
    return out


# ------------------------------------------------------------------- self-check


def _cli(argv):
    import subprocess

    proc = subprocess.run(
        [sys.executable, os.path.abspath(__file__)] + argv, capture_output=True, text=True
    )
    try:
        parsed = json.loads(proc.stdout) if proc.stdout.strip() else None
    except ValueError:
        parsed = None
    return proc.returncode, parsed, proc.stdout, proc.stderr


def self_check(args):
    import json
    import tempfile

    ok, bad = [], []

    def check(name, condition, detail=""):
        if condition:
            ok.append(name)
            print("PASS %s" % name)
        else:
            bad.append(name)
            print("FAIL %s %s" % (name, detail))

    def reject_constant(token):
        raise ValueError("non-JSON constant %s" % token)

    def strict(text):
        try:
            json.loads(text, parse_constant=reject_constant)
            return True
        except ValueError:
            return False

    shipped = os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", "fixtures", "metrics.json")
    )

    # --- the shipped snapshot ---------------------------------------------
    code, parsed, stdout, stderr = _cli(["--fixture", shipped, "--json"])
    check("fixture-exit-0", code == 0, "exit=%s %s" % (code, stderr.strip()[:200]))
    payload = parsed or {}
    check("fixture-ok-true", payload.get("ok") is True, str(payload)[:300])
    check("json-is-one-line", len(stdout.strip().splitlines()) == 1, "%d lines" % len(stdout.strip().splitlines()))
    metrics = payload.get("metrics") or {}
    check("fixture-missing-none", payload.get("missing") == [], str(payload.get("missing")))
    host = metrics.get("host") or {}
    check("host-name", host.get("name") == "omarchylink", str(host.get("name")))
    check("host-loadavg", host.get("loadavg") == [9.14, 11.6, 14.14], str(host.get("loadavg")))
    check("host-load1-frac", host.get("load1_frac") == 0.7617, str(host.get("load1_frac")))
    ai = metrics.get("local_ai") or {}
    check("ai-model", ai.get("model") == "embeddinggemma", str(ai.get("model")))
    check("ai-size", ai.get("size_gb") == 0.33, str(ai.get("size_gb")))
    check("ai-breath", ai.get("breath_period_s") == 6.0, str(ai.get("breath_period_s")))
    tokens = metrics.get("tokens_today") or {}
    expected_total = 351652507 + 1015672 + 0 + 27810998 + 0 + 180094595 + 1061494844
    check("tokens-total", tokens.get("total") == expected_total, "%s vs %s" % (tokens.get("total"), expected_total))
    check("tokens-top-first", (tokens.get("top") or [{}])[0].get("provider") == "opencode-go@mac", str(tokens.get("top")))
    check("tokens-providers-kept", len(tokens.get("providers") or {}) == 7, str(tokens.get("providers")))
    check("screens-count", metrics.get("screens_count") == 4, str(metrics.get("screens_count")))
    check("windows-count", metrics.get("windows_count") == 5, str(metrics.get("windows_count")))
    kanban = metrics.get("kanban") or {}
    check("kanban-mac", (kanban.get("mac") or {}).get("done") == 47, str(kanban.get("mac")))
    check("kanban-total", (kanban.get("total") or {}).get("done") == 64, str(kanban.get("total")))
    check("fixture-ts", isinstance(metrics.get("ts"), int), str(metrics.get("ts")))
    check("fixture-ts-iso", metrics.get("ts_iso") == "2026-10-22T21:07:02Z", str(metrics.get("ts_iso")))
    check("fixture-mode", payload.get("mode") == "fixture", str(payload.get("mode")))
    check("no-home-path", common.HOME not in json.dumps(payload), "absolute home path in payload")

    # --- partial objects are the normal case -------------------------------
    root = tempfile.mkdtemp(prefix="w8-metrics-", dir=os.environ.get("TMPDIR"))

    def run(obj, name="case.json"):
        path = os.path.join(root, name)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(obj, handle)
        return _cli(["--fixture", path, "--json"])

    code, parsed, _, _ = run({"host": {"loadavg": [1.5], "cores": 4}})
    payload = parsed or {}
    check("partial-ok-true", payload.get("ok") is True, str(payload)[:300])
    check("partial-loadavg-kept", ((payload.get("metrics") or {}).get("host") or {}).get("loadavg") == [1.5], str(payload.get("metrics")))
    check(
        "partial-load1-derived",
        ((payload.get("metrics") or {}).get("host") or {}).get("load1_frac") == 0.375,
        str((payload.get("metrics") or {}).get("host")),
    )
    check(
        "partial-missing-listed",
        set(payload.get("missing") or []) == {"local_ai", "tokens_today", "screens", "windows", "kanban"},
        str(payload.get("missing")),
    )

    # --- a non-finite element nulls the whole loadavg triple (R6) -----------
    # Slot position is the meaning: [Infinity, 4.45, 4.81] must never become
    # [4.45, 4.81], where the 5 minute value would be reported as the 1 minute
    # ratio. Same rule as the live path, which drops the whole triple.
    def host_of(stdout_text):
        parsed = json.loads(stdout_text) if stdout_text.strip() else None
        return ((parsed or {}).get("metrics") or {}).get("host") or {}

    def run_raw(name, body):
        path = os.path.join(root, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(body)
        return _cli(["--fixture", path, "--json"])

    code, parsed, stdout, stderr = run_raw(
        "loadavg-first-inf.json",
        '{"host": {"name": "box", "cores": 12, "loadavg": [Infinity, 4.45, 4.81]}}',
    )
    host = host_of(stdout)
    check("loadavg-first-inf-exit-0", code == 0, "exit=%s %s" % (code, stderr.strip()[:200]))
    check("loadavg-first-inf-strict-json", strict(stdout), stdout.strip()[:200])
    check("loadavg-first-inf-list-null", host.get("loadavg") is None, str(host))
    check("loadavg-first-inf-no-frac", host.get("load1_frac") is None, str(host))
    check(
        "loadavg-first-inf-keeps-counters",
        host.get("name") == "box" and host.get("cores") == 12,
        str(host),
    )

    # A stated ratio cannot outlive the triple it describes.
    code, parsed, stdout, stderr = run_raw(
        "loadavg-stated-frac.json",
        '{"host": {"name": "box", "cores": 12,'
        ' "loadavg": [Infinity, 4.45, 4.81], "load1_frac": 0.9}}',
    )
    host = host_of(stdout)
    check("loadavg-stated-frac-exit-0", code == 0, "exit=%s %s" % (code, stderr.strip()[:200]))
    check(
        "loadavg-stated-frac-null",
        host.get("loadavg") is None and host.get("load1_frac") is None,
        str(host),
    )

    code, parsed, stdout, stderr = run_raw(
        "loadavg-mid-inf.json",
        '{"host": {"name": "box", "cores": 12, "loadavg": [1.5, Infinity, 4.81]}}',
    )
    host = host_of(stdout)
    check("loadavg-mid-inf-exit-0", code == 0, "exit=%s %s" % (code, stderr.strip()[:200]))
    check("loadavg-mid-inf-list-null", host.get("loadavg") is None, str(host))
    check("loadavg-mid-inf-no-frac", host.get("load1_frac") is None, str(host))

    code, parsed, stdout, stderr = run_raw(
        "loadavg-string.json",
        '{"host": {"name": "box", "cores": 12, "loadavg": [1.5, "fast", 4.81]}}',
    )
    host = host_of(stdout)
    check("loadavg-string-exit-0", code == 0, "exit=%s %s" % (code, stderr.strip()[:200]))
    check("loadavg-string-list-null", host.get("loadavg") is None, str(host))
    check("loadavg-string-no-frac", host.get("load1_frac") is None, str(host))

    # The whole list is validated, not just the first three slots.
    code, parsed, stdout, stderr = run_raw(
        "loadavg-tail-inf.json",
        '{"host": {"name": "box", "cores": 12, "loadavg": [1.5, 2.5, 3.5, Infinity]}}',
    )
    host = host_of(stdout)
    check("loadavg-tail-inf-exit-0", code == 0, "exit=%s %s" % (code, stderr.strip()[:200]))
    check("loadavg-tail-inf-list-null", host.get("loadavg") is None, str(host))

    # The fix is narrow: finite lists are kept, with the limit still applied.
    code, parsed, stdout, stderr = run_raw(
        "loadavg-finite-three.json",
        '{"host": {"name": "box", "cores": 12, "loadavg": [3.94, 4.45, 4.81]}}',
    )
    host = host_of(stdout)
    check("loadavg-finite-three-exit-0", code == 0, "exit=%s %s" % (code, stderr.strip()[:200]))
    check("loadavg-finite-three-kept", host.get("loadavg") == [3.94, 4.45, 4.81], str(host))
    check("loadavg-finite-three-frac", host.get("load1_frac") == 0.3283, str(host))

    code, parsed, stdout, stderr = run_raw(
        "loadavg-limit.json",
        '{"host": {"name": "box", "cores": 12, "loadavg": [1.5, 2.5, 3.5, 4.5]}}',
    )
    host = host_of(stdout)
    check("loadavg-limit-exit-0", code == 0, "exit=%s %s" % (code, stderr.strip()[:200]))
    check("loadavg-limit-trims", host.get("loadavg") == [1.5, 2.5, 3.5], str(host))

    code, parsed, _, _ = run({"host": "not an object", "local_ai": {"model": "qwen"}})
    payload = parsed or {}
    check("bad-block-ok-true", payload.get("ok") is True, str(payload))
    check("bad-block-null", (payload.get("metrics") or {}).get("host") is None, str((payload.get("metrics") or {}).get("host")))
    check("bad-block-warns", any("host" in str(w) for w in payload.get("warnings") or []), str(payload.get("warnings")))
    check("bad-block-keeps-good", ((payload.get("metrics") or {}).get("local_ai") or {}).get("model") == "qwen", str(payload.get("metrics")))

    code, parsed, _, _ = run({"screens": [{"id": "DP-2", "workspaces": [4, "x", 7], "windows": 2}, "junk", {"windows": 1}], "windows": ["a", 5, None]})
    payload = parsed or {}
    metrics = payload.get("metrics") or {}
    check("screens-drop-junk", len(metrics.get("screens") or []) == 1, str(metrics.get("screens")))
    check("screens-workspaces-kept", (metrics.get("screens") or [{}])[0].get("workspaces") == [4, 7], str(metrics.get("screens")))
    check("windows-drop-junk", metrics.get("windows") == ["a"], str(metrics.get("windows")))
    check("junk-warns", len(payload.get("warnings") or []) >= 2, str(payload.get("warnings")))

    # --- a non-list workspaces value warns, it does not crash (R1) ----------
    for label, bad_ws in (
        ("int", 4),
        ("bool", True),
        ("negative", -5),
        ("float", 3.5),
        ("string", "4"),
        ("object", {"a": 1}),
    ):
        code, parsed, _, _ = run(
            {"screens": [{"id": "DP-2", "workspaces": bad_ws, "windows": 2}]},
            name="ws-%s.json" % label,
        )
        payload = parsed or {}
        screens = (payload.get("metrics") or {}).get("screens") or []
        check(
            "workspaces-%s-exit-0" % label,
            code == 0 and payload.get("ok") is True,
            "exit=%s %s" % (code, str(payload)[:200]),
        )
        check(
            "workspaces-%s-warns" % label,
            any("workspaces" in str(w) for w in payload.get("warnings") or []),
            str(payload.get("warnings")),
        )
        check(
            "workspaces-%s-screen-kept" % label,
            len(screens) == 1 and screens[0].get("workspaces") == [] and screens[0].get("windows") == 2,
            str(screens),
        )

    code, parsed, _, _ = run({"tokens_today": {"a": 10, "b": "many", "c": 5}})
    payload = parsed or {}
    tokens = (payload.get("metrics") or {}).get("tokens_today") or {}
    check("tokens-drop-junk", tokens.get("providers") == {"a": 10, "c": 5}, str(tokens.get("providers")))
    check("tokens-junk-warns", any("tokens" in str(w) for w in payload.get("warnings") or []), str(payload.get("warnings")))

    code, parsed, _, _ = run({"ts_iso": "2026-10-22T21:07:02Z", "host": {"name": "box"}})
    payload = parsed or {}
    metrics = payload.get("metrics") or {}
    check("iso-only-ts", isinstance(metrics.get("ts"), int), str(metrics.get("ts")))
    check("iso-only-age", isinstance(metrics.get("snapshot_age_s"), int), str(metrics.get("snapshot_age_s")))

    # --- every emitted stamp is UTC Z, never the raw input string (R3) ------
    code, parsed, _, _ = run({"ts_iso": "2026-10-22T23:07:02+02:00", "host": {"name": "box"}}, name="tz.json")
    payload = parsed or {}
    metrics = payload.get("metrics") or {}
    check("ts-iso-normalised-z", metrics.get("ts_iso") == "2026-10-22T21:07:02Z", str(metrics.get("ts_iso")))
    check("ts-iso-normalised-epoch", metrics.get("ts") == 1792703222, str(metrics.get("ts")))
    check("ts-iso-not-raw-input", metrics.get("ts_iso") != "2026-10-22T23:07:02+02:00", str(metrics.get("ts_iso")))

    code, parsed, _, _ = run({"ts_iso": "not a timestamp", "host": {"name": "box"}}, name="bad-ts.json")
    payload = parsed or {}
    metrics = payload.get("metrics") or {}
    check(
        "ts-iso-unusable-is-null",
        payload.get("ok") is True and metrics.get("ts") is None and metrics.get("ts_iso") is None,
        str(metrics),
    )

    # --- dead inputs -------------------------------------------------------
    empty = os.path.join(root, "empty.json")
    with open(empty, "w", encoding="utf-8") as handle:
        json.dump({}, handle)
    code, parsed, _, _ = _cli(["--fixture", empty, "--json"])
    check("no-blocks-ok-false", (parsed or {}).get("ok") is False, str(parsed))
    check("no-blocks-kind", (parsed or {}).get("kind") == "malformed", str((parsed or {}).get("kind")))
    check("no-blocks-reason", "host" in str((parsed or {}).get("reason")), str((parsed or {}).get("reason")))

    broken = os.path.join(root, "broken.json")
    with open(broken, "w", encoding="utf-8") as handle:
        handle.write("{oops")
    code, parsed, _, _ = _cli(["--fixture", broken, "--json"])
    check("bad-json-exit-0", code == 0, "exit=%s" % code)
    check("bad-json-ok-false", (parsed or {}).get("ok") is False, str(parsed))
    check("bad-json-kind", (parsed or {}).get("kind") == "malformed", str((parsed or {}).get("kind")))

    wrong = os.path.join(root, "wrong.json")
    with open(wrong, "w", encoding="utf-8") as handle:
        json.dump([1, 2, 3], handle)
    code, parsed, _, _ = _cli(["--fixture", wrong, "--json"])
    check("wrong-shape-ok-false", (parsed or {}).get("ok") is False, str(parsed))

    code, parsed, _, _ = _cli(["--fixture", os.path.join(root, "nope.json"), "--json"])
    check("missing-exit-0", code == 0, "exit=%s" % code)
    check("missing-kind", (parsed or {}).get("kind") == "missing", str(parsed))
    check("missing-reason", bool((parsed or {}).get("reason")), str(parsed))

    # --- fixture mode writes nothing --------------------------------------
    before = sorted(os.listdir(root))
    _cli(["--fixture", shipped, "--json"])
    check("fixture-writes-nothing", sorted(os.listdir(root)) == before, str(os.listdir(root)))
    check("fixture-dir-empty-of-state", not any(name.endswith(".state") for name in os.listdir(root)), "")

    print("\nself-check %s: %d passed, %d failed" % ("ok" if not bad else "FAILED", len(ok), len(bad)))
    if bad:
        print("failed: %s" % ", ".join(bad))
    return 0 if not bad else 1


# --------------------------------------------------------------------------- cli


def parse(argv):
    parser = argparse.ArgumentParser(description="Host metrics feed for the v5 HUD.")
    common.add_common_args(parser)
    parser.add_argument("--metrics", default=DEFAULT_METRICS, help="live metrics state file (default %s)" % DEFAULT_METRICS)
    parser.add_argument("--self-check", action="store_true", help="run the built-in checks and exit")
    return parser.parse_args(argv)


def build(args):
    return collect(args)


def main(argv=None):
    args = parse(argv)
    if args.self_check:
        return self_check(args)
    return common.run(SOURCE, build, args)


if __name__ == "__main__":
    sys.exit(main())
