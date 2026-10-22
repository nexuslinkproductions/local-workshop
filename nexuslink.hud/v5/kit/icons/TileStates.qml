pragma ComponentBehavior: Bound

import QtQuick
import NexusHud.V5 1.0
import ".." as Kit

// W4 IconTile state sheet. Dev artifact, not registered in kit/qmldir: one
// still that shows every state of the tile contract at a known position, so the
// numbers can be re-measured from a clean checkout.
//
//   tools/qml-shot.sh nexuslink.hud/v5/kit/icons/TileStates.qml <out.png>
//
// Tile top-left = (90 + col * 320, 190 + row * 330), the tile centred in a 300 px
// cell. Sizes are 96 px unless the entry says otherwise.
Item {
    id: page
    width: 2560
    height: 1440

    Rectangle { anchors.fill: parent; color: Tokens.field }

    FontLoader { source: Qt.resolvedUrl("../../fonts/Satoshi-Regular.ttf") }
    FontLoader { source: Qt.resolvedUrl("../../fonts/Satoshi-Medium.ttf") }
    FontLoader { source: Qt.resolvedUrl("../../fonts/Satoshi-Bold.ttf") }

    readonly property var entries: [
        { "c": 0, "r": 0, "g": "hermes",   "l": "Hermes",   "n": 0,  "run": false, "sel": false, "dim": false, "s": 96, "note": "idle, no launches" },
        { "c": 1, "r": 0, "g": "devin",    "l": "Devin",    "n": 3,  "run": false, "sel": false, "dim": false, "s": 96, "note": "launchCount 3" },
        { "c": 2, "r": 0, "g": "discord",  "l": "Discord",  "n": 8,  "run": false, "sel": false, "dim": false, "s": 96, "note": "launchCount 8" },
        { "c": 3, "r": 0, "g": "chrome",   "l": "Chrome",   "n": 20, "run": false, "sel": false, "dim": false, "s": 96, "note": "launchCount 20, capped at 12" },
        { "c": 4, "r": 0, "g": "files",    "l": "Files",    "n": 2,  "run": true,  "sel": false, "dim": false, "s": 96, "note": "running" },
        { "c": 5, "r": 0, "g": "terminal", "l": "Terminal", "n": 1,  "run": false, "sel": true,  "dim": false, "s": 96, "note": "selected" },
        { "c": 0, "r": 1, "g": "youtube",  "l": "YouTube",  "n": 5,  "run": false, "sel": false, "dim": true,  "s": 96, "note": "dimmed" },
        { "c": 1, "r": 1, "g": "whatsapp", "l": "WhatsApp", "n": 4,  "run": true,  "sel": true,  "dim": false, "s": 96, "note": "selected + running" },
        { "c": 2, "r": 1, "g": "x",        "l": "X",        "n": 7,  "run": false, "sel": false, "dim": false, "s": 56, "note": "56 px tile" },
        { "c": 3, "r": 1, "g": "arc-raiders", "l": "Arc Raiders", "n": 0, "run": true, "sel": false, "dim": false, "s": 56, "note": "56 px, running" },
        { "c": 4, "r": 1, "g": "settings", "l": "Settings", "n": 0,  "run": false, "sel": false, "dim": false, "s": 56, "note": "56 px tile" },
        { "c": 5, "r": 1, "g": "no-such-key", "l": "Unknown", "n": 0, "run": false, "sel": false, "dim": false, "s": 56, "note": "unknown key" },
        { "c": 0, "r": 2, "g": "hermes",   "l": "Hermes",   "n": 9,  "run": true,  "sel": false, "dim": false, "s": 240, "note": "anatomy, 240 px" }
    ]

    Text {
        x: 90
        y: 70
        text: "ICONTILE  ·  launch-count ring  ·  running node  ·  selected = scale 1.06  ·  dimmed = " + Tokens.focusDimMax
        color: Tokens.textLabel
        font.pixelSize: 20
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.letterSpacing: 1.4
    }

    Repeater {
        model: page.entries
        delegate: Item {
            id: cell
            required property int index
            readonly property var entry: page.entries[index]
            x: 90 + cell.entry.c * 320
            y: 190 + cell.entry.r * 330
            width: 300
            height: 300

            Kit.IconTile {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 0
                glyph: cell.entry.g
                label: cell.entry.l
                launchCount: cell.entry.n
                running: cell.entry.run
                selected: cell.entry.sel
                dimmed: cell.entry.dim
                size: cell.entry.s
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                y: cell.entry.s + 22
                text: cell.entry.note
                color: Tokens.textDate
                font.pixelSize: 16
                font.family: Tokens.fontFamily
                font.weight: Tokens.weightRegular
            }
        }
    }
}
