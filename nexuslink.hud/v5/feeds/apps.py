#!/usr/bin/env python3
"""Launcher apps reader: ranks ``apps.json`` by launch count and recency.

The launcher arc (W5) and the icon tiles (W4) are driven by this feed. The live
source is the launcher's own state file, ``~/.local/state/nexuslink/apps.json``
(written by the Linux-side app collector), and ``--fixture
v5/fixtures/apps.json`` reads the shipped snapshot of the same shape. This reader
never edits the fixture: it ranks whatever it is given.

Ranking rule, in order, for a normal tile:

  1. ``launches`` (integer, negative clamped to 0) is the base score;
  2. ``+3.0`` while the app is ``running``;
  3. a recency bonus from the last launch stamp (``last_launch``,
     ``last_launched_at``, ``last_used`` or ``last_launch_epoch``, epoch seconds
     or ISO-8601): ``+2.0`` under 6 h, ``+1.5`` under 24 h, ``+1.0`` under 72 h,
     ``+0.5`` under 7 d, else 0. A payload without a stamp simply scores 0;
  4. ties break by ``slot`` then ``id``, so the order is stable between runs.

Two kinds of entry are not ranked:

  * ``size: "feature"`` tiles (Arc Raiders). They have a fixed slot at the end of
    the arc, so they carry ``rank: null`` and ``fixed_slot: true``.
  * the automation denylist. Chromium's launch counter is dominated by headless
    agent runs (recon/03-feeds.md: about 6.7k ``app-*.scope`` instances, mostly
    automation), so its count does not mean Marcel uses it. A denylisted app
    keeps its arc slot (the tile is still drawn) but gets ``rank: null`` and an
    ``excluded`` reason. It rejoins the ranking only when the payload says the
    count is user-driven, i.e. ``"user_driven": true`` on the entry.

Payload: ``apps`` is the ranked list, unranked tiles last; ``arc`` is the tile
order for the launcher (sort key ``arc_index``, always 0..n-1).
"""

from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _common as common  # noqa: E402

SOURCE = "apps"
DEFAULT_APPS = "~/.local/state/nexuslink/apps.json"

RUNNING_BONUS = 3.0
RECENCY_TIERS = ((6 * 3600, 2.0), (24 * 3600, 1.5), (72 * 3600, 1.0), (7 * 86400, 0.5))
RECENCY_FIELDS = ("last_launch", "last_launched_at", "last_used", "last_launch_epoch", "last_used_at")

# Substring matched against id, glyph and desktop id, lowercased. Automation
# noise, not taste: see the module docstring and recon/03-feeds.md.
DENYLIST = {
    "chromium": "automation noise: launch counter dominated by headless agent runs",
}


# ----------------------------------------------------------------------- shaping


def matches_denylist(entry):
    haystack = " ".join(
        str(entry.get(key) or "") for key in ("id", "glyph", "desktop", "desktop_id")
    ).lower()
    for needle, reason in DENYLIST.items():
        if needle in haystack:
            return needle, reason
    return None, None


def user_driven(entry):
    for key in ("user_driven", "userDriven", "counts_user"):
        if entry.get(key) is True:
            return True
    counts = entry.get("counts")
    if isinstance(counts, dict) and counts.get("user_driven") is True:
        return True
    return False


def last_launch_epoch(entry):
    for key in RECENCY_FIELDS:
        value = entry.get(key)
        if value is None or value == "":
            continue
        number = common.number(value)
        if number is not None:
            return int(number)
        stamp = common.epoch_from_iso(value)
        if stamp is not None:
            return int(stamp)
    return None


def recency_bonus(epoch, now):
    if epoch is None:
        return 0.0
    age = max(0, now - epoch)
    for window, bonus in RECENCY_TIERS:
        if age < window:
            return bonus
    return 0.0


def slot_of(entry, fallback):
    slot = common.integer(entry.get("slot"))
    return fallback if slot is None else slot


def normalise(entry, index, now):
    """One apps.json entry -> payload tile. Returns None when unusable."""
    ident = common.text(entry.get("id"))
    name = common.text(entry.get("name"))
    if not ident or not name:
        return None
    launches = common.integer(entry.get("launches"))
    if launches is None:
        launches = common.integer(entry.get("launch_count")) or 0
    launches = max(0, launches)
    running = bool(entry.get("running"))
    size = common.text(entry.get("size")) or "tile"
    stamp = last_launch_epoch(entry)
    bonus = recency_bonus(stamp, now)
    needle, reason = matches_denylist(entry)

    tile = {
        "id": ident,
        "name": name,
        "glyph": common.text(entry.get("glyph")) or ident,
        "desktop": common.text(entry.get("desktop")) or common.text(entry.get("desktop_id")),
        "launches": launches,
        "running": running,
        "size": size,
        "slot": slot_of(entry, index),
        "last_launch": stamp,
        "last_launch_iso": common.iso(stamp),
        "recency_bonus": round(bonus, 2),
        "arc_index": None,
        "rank": None,
        "rank_score": None,
    }

    if size == "feature":
        tile["fixed_slot"] = True
    elif needle and not user_driven(entry):
        tile["excluded"] = "%s (%s)" % (reason, needle)
    else:
        tile["rank_score"] = round(launches + (RUNNING_BONUS if running else 0.0) + bonus, 3)
    return tile


def rank(tiles):
    """Assign arc_index in slot order, then rank and order the payload list."""
    arc = sorted(tiles, key=lambda tile: (tile["slot"], tile["id"]))
    for position, tile in enumerate(arc):
        tile["arc_index"] = position

    ranked = [tile for tile in arc if tile["rank_score"] is not None]
    ranked.sort(key=lambda tile: (-tile["rank_score"], tile["slot"], tile["id"]))
    for position, tile in enumerate(ranked):
        tile["rank"] = position + 1

    unranked = [tile for tile in arc if tile["rank_score"] is None]
    return ranked + unranked, [tile["id"] for tile in arc]


# ------------------------------------------------------------------------ input


def load_source(args):
    if args.fixture:
        root = common.read_json(args.fixture, "apps fixture")
    else:
        root = common.read_json(args.apps, "apps state file")
    if isinstance(root, dict):
        for key in ("apps", "items", "entries"):
            if isinstance(root.get(key), list):
                root = root[key]
                break
    if not isinstance(root, list):
        raise common.Malformed(
            "apps input must be an array of app entries (or an object with an apps array)"
        )
    return root


def collect(args):
    root = load_source(args)
    now = common.utc_now_epoch()
    tiles, warnings = [], []
    for index, entry in enumerate(root):
        if not isinstance(entry, dict):
            warnings.append("entry %d is not an object, skipped" % index)
            continue
        tile = normalise(entry, index, now)
        if tile is None:
            warnings.append("entry %d has no id or name, skipped" % index)
            continue
        tiles.append(tile)
    if root and not tiles:
        raise common.Malformed("apps input has no usable entries")
    if not root:
        warnings.append("apps input is empty")

    ordered, arc = rank(tiles)
    out = common.envelope(
        SOURCE,
        "fixture" if args.fixture else "live",
        count=len(ordered),
        ranked_count=sum(1 for tile in ordered if tile["rank"] is not None),
        apps=ordered,
        arc=arc,
        ranking={
            "base": "launches",
            "running_bonus": RUNNING_BONUS,
            "recency_tiers": [
                {"under_s": window, "bonus": bonus} for window, bonus in RECENCY_TIERS
            ],
            "tie_break": "slot, then id",
            "denylist": DENYLIST,
            "escape": "an entry re-enters the ranking when it carries user_driven: true",
        },
        source_file=common.tilde(args.fixture or args.apps),
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
    return proc.returncode, parsed, proc.stderr


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

    shipped = os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", "fixtures", "apps.json")
    )
    with open(shipped, "r", encoding="utf-8") as handle:
        snapshot = json.load(handle)

    # --- the shipped snapshot, ranked -------------------------------------
    code, parsed, stderr = _cli(["--fixture", shipped, "--json"])
    check("fixture-exit-0", code == 0, "exit=%s %s" % (code, stderr.strip()[:200]))
    check("fixture-ok-true", (parsed or {}).get("ok") is True, str(parsed)[:300])
    payload = parsed or {}
    apps = payload.get("apps") or []
    ids = [tile.get("id") for tile in apps]
    ranked = [tile for tile in apps if tile.get("rank") is not None]
    check("fixture-count", payload.get("count") == len(snapshot), "%s vs %s" % (payload.get("count"), len(snapshot)))
    check("fixture-ranked-8", payload.get("ranked_count") == 8, str(payload.get("ranked_count")))
    check(
        "rank-order",
        [tile["id"] for tile in ranked]
        == ["devin", "hermes", "spotify", "discord", "october", "files", "obs", "terminal"],
        str([tile["id"] for tile in ranked]),
    )
    check("rank-sequential", [tile["rank"] for tile in ranked] == list(range(1, len(ranked) + 1)), str([tile["rank"] for tile in ranked]))
    check(
        "rank-scores-descend",
        all(ranked[i]["rank_score"] >= ranked[i + 1]["rank_score"] for i in range(len(ranked) - 1)),
        str([tile["rank_score"] for tile in ranked]),
    )
    check("devin-top", ranked[0]["id"] == "devin" and ranked[0]["launches"] == 8, str(ranked[0]))
    check(
        "running-bonus",
        ranked[1]["id"] == "hermes" and ranked[1].get("recency_bonus") == 0.0,
        str(ranked[1]),
    )
    check("spotify-running", next(t for t in apps if t["id"] == "spotify")["running"] is True, "")

    # --- the automation denylist ------------------------------------------
    browser = next((tile for tile in apps if tile["id"] == "browser"), {})
    check("chromium-excluded", browser.get("rank") is None, str(browser))
    check("chromium-reason", "automation" in str(browser.get("excluded", "")), str(browser.get("excluded")))
    check("chromium-still-in-arc", "browser" in (payload.get("arc") or []), str(payload.get("arc")))
    check(
        "chromium-arc-slot",
        browser.get("arc_index") == 0,
        "arc_index=%s" % browser.get("arc_index"),
    )
    check("denylist-documented", "chromium" in (payload.get("ranking") or {}).get("denylist", {}), "")

    # --- feature tile is fixed, not ranked --------------------------------
    feature = next((tile for tile in apps if tile.get("size") == "feature"), {})
    check("feature-unranked", feature.get("rank") is None, str(feature))
    check("feature-fixed-slot", feature.get("fixed_slot") is True, str(feature))
    check("feature-last", (payload.get("arc") or [])[-1] == "arc-raiders", str(payload.get("arc")))
    check("arc-permutation", sorted(payload.get("arc") or []) == sorted(ids), "%s vs %s" % (payload.get("arc"), ids))

    # --- recency tiers, and the user_driven escape -------------------------
    root = tempfile.mkdtemp(prefix="w8-apps-", dir=os.environ.get("TMPDIR"))
    now = common.utc_now_epoch()
    synthetic = [
        {"id": "old", "name": "Old", "launches": 5, "slot": 0, "last_launch": now - 30 * 86400},
        {"id": "fresh", "name": "Fresh", "launches": 5, "slot": 1, "last_launch": now - 3600},
        {"id": "day", "name": "Day", "launches": 5, "slot": 2, "last_launched_at": common.iso(now - 20 * 3600)},
        {"id": "week", "name": "Week", "launches": 5, "slot": 3, "last_used": now - 5 * 86400},
        {"id": "never", "name": "Never", "launches": 5, "slot": 4},
        {"id": "browser", "name": "Browser", "glyph": "browser", "desktop": "chromium.desktop", "launches": 40, "slot": 5},
        {"id": "browser2", "name": "Browser driven", "desktop": "chromium.desktop", "launches": 40, "slot": 6, "user_driven": True},
        {"id": "arc", "name": "Arc", "launches": 0, "slot": 7, "size": "feature"},
    ]
    path = os.path.join(root, "apps.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(synthetic, handle)
    code, parsed, _ = _cli(["--fixture", path, "--json"])
    check("synthetic-exit-0", code == 0, "exit=%s" % code)
    by_id = {tile["id"]: tile for tile in (parsed or {}).get("apps", [])}
    check("recency-6h", by_id.get("fresh", {}).get("recency_bonus") == 2.0, str(by_id.get("fresh")))
    check("recency-24h", by_id.get("day", {}).get("recency_bonus") == 1.5, str(by_id.get("day")))
    check("recency-7d", by_id.get("week", {}).get("recency_bonus") == 0.5, str(by_id.get("week")))
    check("recency-none", by_id.get("old", {}).get("recency_bonus") == 0.0, str(by_id.get("old")))
    check("recency-missing-stamp", by_id.get("never", {}).get("recency_bonus") == 0.0, str(by_id.get("never")))
    check("recency-iso-parsed", by_id.get("day", {}).get("last_launch") is not None, str(by_id.get("day")))
    check("denylist-still-holds", by_id.get("browser", {}).get("rank") is None, str(by_id.get("browser")))
    check("user-driven-escapes", by_id.get("browser2", {}).get("rank") == 1, str(by_id.get("browser2")))
    check("tie-break-slot", [tile["id"] for tile in (parsed or {}).get("apps", []) if tile.get("rank")][:3] == ["browser2", "fresh", "day"], str([(t["id"], t.get("rank_score")) for t in (parsed or {}).get("apps", [])]))

    # --- dead inputs -------------------------------------------------------
    broken = os.path.join(root, "broken.json")
    with open(broken, "w", encoding="utf-8") as handle:
        handle.write("[{")
    code, parsed, _ = _cli(["--fixture", broken, "--json"])
    check("bad-json-exit-0", code == 0, "exit=%s" % code)
    check("bad-json-ok-false", (parsed or {}).get("ok") is False, str(parsed))
    check("bad-json-kind", (parsed or {}).get("kind") == "malformed", str((parsed or {}).get("kind")))

    wrong = os.path.join(root, "wrong.json")
    with open(wrong, "w", encoding="utf-8") as handle:
        json.dump({"nope": 1}, handle)
    code, parsed, _ = _cli(["--fixture", wrong, "--json"])
    check("wrong-shape-ok-false", (parsed or {}).get("ok") is False, str(parsed))

    empty = os.path.join(root, "empty.json")
    with open(empty, "w", encoding="utf-8") as handle:
        json.dump([], handle)
    code, parsed, _ = _cli(["--fixture", empty, "--json"])
    check("empty-ok-true", (parsed or {}).get("ok") is True, str(parsed))
    check("empty-count-0", (parsed or {}).get("count") == 0, str(parsed))

    mixed = os.path.join(root, "mixed.json")
    with open(mixed, "w", encoding="utf-8") as handle:
        json.dump([{"id": "keep", "name": "Keep"}, "junk", {"name": "no id"}], handle)
    code, parsed, _ = _cli(["--fixture", mixed, "--json"])
    check("mixed-keeps-good", (parsed or {}).get("count") == 1, str(parsed))
    check("mixed-warns", bool((parsed or {}).get("warnings")), str(parsed))

    code, parsed, _ = _cli(["--fixture", os.path.join(root, "nope.json"), "--json"])
    check("missing-exit-0", code == 0, "exit=%s" % code)
    check("missing-kind", (parsed or {}).get("kind") == "missing", str(parsed))

    # --- no secrets, no absolute home paths --------------------------------
    blob = json.dumps(payload)
    check("no-home-path", common.HOME not in blob, "absolute home path in payload")
    lowered = blob.lower()
    check(
        "no-secret-words",
        not any(word in lowered for word in ("password", "api_key", "auth_token", "bearer ")),
        "secret-ish word in payload",
    )

    print("\nself-check %s: %d passed, %d failed" % ("ok" if not bad else "FAILED", len(ok), len(bad)))
    if bad:
        print("failed: %s" % ", ".join(bad))
    return 0 if not bad else 1


# --------------------------------------------------------------------------- cli


def parse(argv):
    parser = argparse.ArgumentParser(description="Launcher apps feed for the v5 HUD.")
    common.add_common_args(parser)
    parser.add_argument("--apps", default=DEFAULT_APPS, help="live apps state file (default %s)" % DEFAULT_APPS)
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
