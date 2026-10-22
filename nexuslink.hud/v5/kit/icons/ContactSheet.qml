pragma ComponentBehavior: Bound

import QtQuick
import NexusHud.V5 1.0
import ".." as Kit

// W4 contact sheet. Dev artifact, not registered in kit/qmldir: it exists so a
// still can be re-rendered from a clean checkout and the set judged as a whole.
//
//   tools/qml-shot.sh nexuslink.hud/v5/kit/icons/ContactSheet.qml <out.png>
//
// Rows are weight 2.0 (top three) then weight 1.5, each at 72 / 48 / 24 px. The
// strip at the bottom is IconTile.qml at two sizes, seven states.
Item {
    id: page
    width: 2560
    height: 1440

    readonly property var keys: [
        "hermes", "devin", "files", "terminal", "chrome", "discord",
        "x", "youtube", "whatsapp", "arc-raiders",
        "find", "crew", "power", "wifi", "battery", "volume", "settings"
    ]
    readonly property var rows: [
        { "w": 2.0, "s": 72 }, { "w": 2.0, "s": 48 }, { "w": 2.0, "s": 24 },
        { "w": 1.5, "s": 72 }, { "w": 1.5, "s": 48 }, { "w": 1.5, "s": 24 }
    ]
    readonly property int colX0: 190
    readonly property int colPitch: 138
    readonly property int rowY0: 170
    readonly property int rowPad: 40
    readonly property int tileY: 760

    readonly property var cells: {
        var out = []
        for (var r = 0; r < page.rows.length; r++) {
            var s = page.rows[r].s
            for (var c = 0; c < page.keys.length; c++) {
                out.push({
                    "key": page.keys[c],
                    "weight": page.rows[r].w,
                    "size": s,
                    "x": page.colX0 + c * page.colPitch + (page.colPitch - s) / 2,
                    "y": page.rowTop(r) + (page.rowPad / 2)
                })
            }
        }
        return out
    }

    readonly property var tiles: [
        { "g": "hermes",  "l": "Hermes",   "c": 0, "run": false, "sel": false, "dim": false, "s": 96 },
        { "g": "devin",   "l": "Devin",    "c": 3, "run": false, "sel": false, "dim": false, "s": 96 },
        { "g": "discord", "l": "Discord",  "c": 8, "run": true,  "sel": false, "dim": false, "s": 96 },
        { "g": "files",   "l": "Files",    "c": 2, "run": false, "sel": true,  "dim": false, "s": 96 },
        { "g": "terminal","l": "Terminal", "c": 1, "run": false, "sel": false, "dim": true,  "s": 96 },
        { "g": "youtube", "l": "YouTube",  "c": 5, "run": true,  "sel": false, "dim": false, "s": 56 },
        { "g": "whatsapp","l": "WhatsApp", "c": 2, "run": false, "sel": true,  "dim": false, "s": 56 }
    ]

    function rowTop(i) {
        var y = page.rowY0
        for (var r = 0; r < i; r++)
            y += page.rows[r].s + page.rowPad
        return y
    }

    Rectangle { anchors.fill: parent; color: Tokens.field }

    FontLoader { source: Qt.resolvedUrl("../../fonts/Satoshi-Regular.ttf") }
    FontLoader { source: Qt.resolvedUrl("../../fonts/Satoshi-Medium.ttf") }
    FontLoader { source: Qt.resolvedUrl("../../fonts/Satoshi-Bold.ttf") }

    Text {
        x: 60
        y: 96
        text: "W4 ICONS  ·  17 glyphs  ·  24 px grid  ·  stroke 1.5 / 2.0  ·  round caps"
        color: Tokens.textLabel
        font.pixelSize: 20
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.letterSpacing: 1.4
    }

    // one column header per glyph key, so the sheet is self-documenting
    Repeater {
        model: page.keys
        delegate: Text {
            required property int index
            x: page.colX0 + index * page.colPitch
               + (page.colPitch - width) / 2
            y: page.rowY0 - 34
            text: page.keys[index]
            color: Tokens.textDim
            font.pixelSize: 16
            font.family: Tokens.fontFamily
            font.weight: Tokens.weightRegular
        }
    }

    // row labels
    Repeater {
        model: page.rows
        delegate: Text {
            required property int index
            x: 60
            y: page.rowTop(index) + page.rows[index].s / 2 - 10
            text: "w " + page.rows[index].w.toFixed(1) + "   " + page.rows[index].s + " px"
            color: Tokens.textDim
            font.pixelSize: 16
            font.family: Tokens.fontFamily
            font.weight: Tokens.weightRegular
        }
    }

    // the 17 x 3 x 2 grid
    Repeater {
        model: page.cells
        delegate: Item {
            id: glyphCell
            required property int index
            readonly property var cell: page.cells[index]
            x: glyphCell.cell.x
            y: glyphCell.cell.y
            width: glyphCell.cell.size
            height: glyphCell.cell.size

            Glyph {
                anchors.fill: parent
                glyph: glyphCell.cell.key
                weight: glyphCell.cell.weight
                size: glyphCell.cell.size
                color: Tokens.ink
            }
        }
    }

    // IconTile states: idle, launch count, running, selected, dimmed
    Text {
        x: 60
        y: page.tileY - 34
        text: "ICONTILE  ·  launch-count ring, running node, selected = scale only, dimmed = " + Tokens.focusDimMax
        color: Tokens.textLabel
        font.pixelSize: 20
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.letterSpacing: 1.4
    }

    Row {
        x: 60
        y: page.tileY
        spacing: 46

        Repeater {
            model: page.tiles
            delegate: Column {
                id: tileCell
                required property int index
                readonly property var entry: page.tiles[index]
                spacing: 10
                Kit.IconTile {
                    anchors.horizontalCenter: parent.horizontalCenter
                    glyph: tileCell.entry.g
                    label: tileCell.entry.l
                    launchCount: tileCell.entry.c
                    running: tileCell.entry.run
                    selected: tileCell.entry.sel
                    dimmed: tileCell.entry.dim
                    size: tileCell.entry.s
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: tileCell.entry.s + " px"
                    color: Tokens.textDate
                    font.pixelSize: 16
                    font.family: Tokens.fontFamily
                    font.weight: Tokens.weightRegular
                }
            }
        }
    }
}
