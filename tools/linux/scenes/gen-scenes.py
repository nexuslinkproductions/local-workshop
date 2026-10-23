#!/usr/bin/env python3
"""Generate the deck B offscreen scenes (rest plus six focus states).

Usage: gen-scenes.py [OUTDIR] [--clock-text TEXT]

OUTDIR defaults to $TMPDIR/deckb-scenes. The worktree root is derived from this
file's location (tools/linux/scenes/gen-scenes.py), so no path is hard-coded.
Writes scene-<state>.qml for rest, crew, find, launcher, mac, storage and local,
plus a copy of nexuslink.hud/v5/stills/DeckFixtures.qml. The scenes import this
worktree's kit and v5 directories as file:// URIs.

--clock-text TEXT replaces the fixture clock with a literal string (used to
prove that the clock is tabular: 18:48 and 01:11 must measure the same width).
"""
import argparse
import json
import os
import pathlib
import shutil
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]  # tools/linux/scenes -> worktree root
V5 = ROOT / "nexuslink.hud" / "v5"
KIT = V5 / "kit"
FIXTURES = V5 / "stills" / "DeckFixtures.qml"
STATES = ["rest", "crew", "find", "launcher", "mac", "storage", "local"]

TEMPLATE = """import QtQuick
import "{kit}"
import "{v5}" as Deck

// Generated offscreen scene: deck B state "{state}". Do not edit; run gen-scenes.py.
Item {{
    id: root
    width: 2560
    height: 1440

    DeckFixtures {{ id: fx }}

    Rectangle {{ anchors.fill: parent; color: Tokens.field }}

    Deck.DeckSurface {{
        anchors.fill: parent
        animate: false
        benchPhase: 0
{focus}        clockText: {clock}
        dayText: fx.dayText
        dateText: fx.dateText
        sessions: fx.sessions
        apps: fx.apps
        allApps: fx.allApps
        hero: fx.hero
        findResults: fx.findResults
{find}        rttMs: fx.rttMs
        batteryLevel: fx.batteryLevel
        loadLevel: fx.loadLevel
        modelGb: fx.modelGb
        modelActivity: fx.modelActivity
        disks: fx.disks
    }}
}}
"""


def main(argv=None):
    ap = argparse.ArgumentParser(description="Generate deck B scenes for the Linux render path.")
    ap.add_argument("outdir", nargs="?",
                    default=os.path.join(os.environ.get("TMPDIR", "/tmp"), "deckb-scenes"))
    ap.add_argument("--clock-text", default=None,
                    help="literal clockText override, e.g. 18:48")
    args = ap.parse_args(argv)

    for p in (KIT, FIXTURES):
        if not p.exists():
            sys.exit("gen-scenes: missing " + str(p))

    out = pathlib.Path(args.outdir)
    out.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(FIXTURES, out / "DeckFixtures.qml")

    clock = "fx.clockText" if args.clock_text is None else json.dumps(args.clock_text)
    for state in STATES:
        focus = ""
        if state != "rest":
            focus = ("        stillFocusProgress: 1\n"
                     "        focusRequest: \"%s\"\n" % state)
        find = '        findQuery: "hud"\n' if state == "find" else ""
        text = TEMPLATE.format(kit=KIT.as_uri(), v5=V5.as_uri(), state=state,
                               focus=focus, clock=clock, find=find)
        (out / ("scene-%s.qml" % state)).write_text(text, encoding="ascii")

    print("gen-scenes: wrote %d scenes + DeckFixtures.qml to %s" % (len(STATES), out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
