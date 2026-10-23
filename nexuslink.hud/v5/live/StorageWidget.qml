pragma ComponentBehavior: Bound
import QtQuick
import "../kit"

// StorageWidget.qml - v5 rest form for disk usage.
//
// One slim horizontal bar of 20 squared cells per disk, up to 5 disks.
// Amendment (Marcel, 2026-10-23): no circles or arcs for storage. The rest
// form is stacked squared-cell bars; the expanded view uses squared cells too.
// At rest only the word STORAGE and the fullest disk percent are visible.
// Disk names fade in with the WidgetBase hover grow (200 ms) and are gone
// again at rest.
WidgetBase {
    id: root

    // Array of { label, fs, mount, usedPct (0..100), sizeBytes, usedBytes, freeBytes }.
    // Tolerates undefined, null and {}.
    property var disks: []

    expandable: true
    hoverScale: 1.05

    readonly property var rows: root.rowsFrom(root.disks)
    readonly property real fullest: root.fullestOf(root.rows)

    function rowsFrom(d) {
        var out = []
        if (!d || typeof d.length !== "number")
            return out
        for (var i = 0; i < d.length && out.length < 5; i++) {
            var x = d[i]
            if (!x || typeof x !== "object")
                continue
            var p = Number(x.usedPct)
            if (!isFinite(p))
                p = 0
            p = Math.max(0, Math.min(100, p))
            out.push({
                "label": x.label ? String(x.label) : (x.mount ? String(x.mount) : "DISK"),
                "pct": p
            })
        }
        return out
    }

    function fullestOf(list) {
        var m = -1
        for (var i = 0; i < list.length; i++)
            if (list[i].pct > m)
                m = list[i].pct
        return m
    }

    function pctText(p) {
        if (p < 0)
            return "--"
        if (p >= 1)
            return Math.round(p) + "%"
        if (p > 0)
            return p.toFixed(1) + "%"
        return "0%"
    }

    // One cell is 5 percent here: 20 cells per disk.
    function fillCount(p) {
        if (!(p > 0))
            return 0
        return Math.max(1, Math.min(20, Math.ceil(p * 20 / 100)))
    }

    Text {
        id: title
        x: 0
        y: 0
        text: "STORAGE"
        color: Tokens.textLabel
        font.family: Tokens.fontFamily
        font.pixelSize: 16
        font.weight: Tokens.weightMedium
        font.letterSpacing: 16 * Tokens.trackLabel
    }

    Text {
        id: big
        x: root.width - width
        y: -2
        text: root.rows.length === 0 ? "--" : root.pctText(root.fullest)
        color: root.fullest >= 80 ? Tokens.amber : Tokens.ice
        font.family: Tokens.fontFamily
        font.pixelSize: 44
        font.weight: Tokens.weightMedium
        font.letterSpacing: -0.6
    }

    // ---- disk bars -------------------------------------------------------
    Column {
        id: bars
        x: 0
        y: 72
        spacing: 15
        visible: root.rows.length > 0

        Repeater {
            model: root.rows.length

            delegate: Item {
                id: rowItem

                required property int index
                readonly property var disk: root.rows[index]
                readonly property int filled: root.fillCount(disk.pct)

                width: root.width
                height: 9

                Repeater {
                    model: 20

                    delegate: Rectangle {
                        required property int index

                        x: index * 14
                        y: 0
                        width: 9
                        height: 9
                        radius: 1.5
                        color: rowItem.disk.pct >= 80 ? Tokens.amber : Tokens.ice
                        opacity: index < rowItem.filled ? 1.0 : 0.22
                    }
                }

                // Name: hover only, fades with the grow.
                Text {
                    id: name
                    x: root.width - width
                    y: -4
                    width: 64
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideRight
                    text: rowItem.disk.label
                    color: Tokens.textCaption
                    font.family: Tokens.fontFamily
                    font.pixelSize: 16
                    font.weight: Tokens.weightRegular
                    opacity: Math.max(0, Math.min(1, root.grow * 1.4))
                    Behavior on opacity {
                        NumberAnimation {
                            duration: 200
                            easing.type: Easing.OutCubic
                        }
                    }
                }
            }
        }
    }

    // ---- empty state -----------------------------------------------------
    Column {
        x: 0
        y: 72
        spacing: 15
        visible: root.rows.length === 0

        Repeater {
            model: 3

            delegate: Rectangle {
                width: 275
                height: 9
                radius: 1.5
                color: Tokens.textDim
                opacity: 0.22
            }
        }
    }
}
