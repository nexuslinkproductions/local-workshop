pragma ComponentBehavior: Bound
import QtQuick
import "../kit"

// StorageExpanded.qml - v5 expanded storage panel.
//
// 1100 x 760 modal block: back chevron (5 squared dots), breadcrumb of three
// dots (HOME, LOCAL, STORAGE; the current one is large), then one gauge per
// disk in a 2 x 2 grid. A gauge is a 10 x 10 grid of squared cells, one cell
// per percent, amber at 80 percent used or more. Amendment: no circles or arcs.
// Sizes are decimal (base 1000): GB = 1e9 bytes, TB = 1e12 bytes.
// Read only: there are no cleanup actions here, the maintenance engine comes later.
Item {
    id: root

    property var disks: []
    signal closeRequested()

    width: 1100
    height: 760
    focus: true

    Keys.onEscapePressed: root.closeRequested()

    readonly property var rows: root.rowsFrom(root.disks)

    function rowsFrom(d) {
        var out = []
        if (!d || typeof d.length !== "number")
            return out
        for (var i = 0; i < d.length && out.length < 4; i++) {
            var x = d[i]
            if (!x || typeof x !== "object")
                continue
            var p = Number(x.usedPct)
            if (!isFinite(p))
                p = 0
            p = Math.max(0, Math.min(100, p))
            out.push({
                "label": x.label ? String(x.label) : (x.mount ? String(x.mount) : "DISK"),
                "fs": x.fs ? String(x.fs) : "",
                "mount": x.mount ? String(x.mount) : "",
                "pct": p,
                "sizeBytes": Number(x.sizeBytes) || 0,
                "usedBytes": Number(x.usedBytes) || 0,
                "freeBytes": Number(x.freeBytes) || 0
            })
        }
        return out
    }

    // Decimal units, one number after the point for TB, whole GB otherwise.
    function human(n) {
        if (!(n > 0))
            return "--"
        if (n >= 1e12)
            return (n / 1e12).toFixed(1) + " TB"
        if (n >= 1e9)
            return Math.round(n / 1e9) + " GB"
        if (n >= 1e6)
            return Math.round(n / 1e6) + " MB"
        return Math.round(n / 1e3) + " KB"
    }

    function mountBase(m) {
        if (!m)
            return ""
        var s = String(m)
        if (s === "/")
            return "/"
        var parts = s.split("/")
        var last = parts[parts.length - 1]
        return last.length > 0 ? last : s
    }

    function pctText(p) {
        if (p >= 1)
            return Math.round(p) + "%"
        if (p > 0)
            return p.toFixed(1) + "%"
        return "0%"
    }

    // ---- back chevron: five squared dots, click closes -------------------
    Item {
        id: chevron
        x: 26
        y: 28
        width: 34
        height: 40

        readonly property var pts: [[22, 2], [14, 11], [6, 20], [14, 29], [22, 38]]

        Repeater {
            model: 5

            delegate: Rectangle {
                required property int index

                x: chevron.pts[index][0]
                y: chevron.pts[index][1]
                width: 7
                height: 7
                radius: 1
                color: hot.containsMouse ? Tokens.white : Tokens.textCaption
            }
        }

        MouseArea {
            id: hot
            anchors.fill: parent
            anchors.margins: -12
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.closeRequested()
        }
    }

    // ---- breadcrumb ------------------------------------------------------
    Row {
        id: crumbs
        x: 96
        y: 34
        spacing: 34

        Repeater {
            model: ["HOME", "LOCAL", "STORAGE"]

            delegate: Item {
                id: crumb

                required property int index
                required property string modelData

                readonly property bool current: index === 2
                readonly property real dotSize: current ? 16 : 10

                width: dotSize + 10 + label.implicitWidth
                height: 30

                Rectangle {
                    x: 0
                    y: (crumb.height - height) / 2
                    width: crumb.dotSize
                    height: width
                    radius: 1.5
                    color: crumb.current ? Tokens.white : Tokens.ice
                    opacity: crumb.current ? 1.0 : 0.55
                }

                Text {
                    id: label
                    x: crumb.dotSize + 10
                    y: (crumb.height - height) / 2
                    text: crumb.modelData
                    color: crumb.current ? Tokens.white : Tokens.textDim
                    font.family: Tokens.fontFamily
                    font.pixelSize: 16
                    font.weight: crumb.current ? Tokens.weightMedium : Tokens.weightRegular
                    font.letterSpacing: 16 * Tokens.trackLabel * 0.4
                }
            }
        }
    }

    // ---- gauges ----------------------------------------------------------
    Repeater {
        model: Math.min(4, root.rows.length)

        delegate: Item {
            id: gauge

            required property int index
            readonly property var d: root.rows[index]
            readonly property int col: index % 2
            readonly property int row: Math.floor(index / 2)
            readonly property int full: Math.floor(d.pct)
            readonly property bool partial: (d.pct - Math.floor(d.pct)) >= 0.02
            readonly property color lit: d.pct >= 80 ? Tokens.amber : Tokens.ice

            x: 50 + col * 524
            y: 160 + row * 280
            width: 476
            height: 256

            // 10 x 10 squared cells, 22 px each, 4 px gaps.
            Repeater {
                model: 100

                delegate: Rectangle {
                    required property int index

                    readonly property int cellRow: Math.floor(index / 10)
                    readonly property int cellCol: index % 10
                    readonly property bool isFull: index < gauge.full
                    readonly property bool isPartial: index === gauge.full && gauge.partial

                    x: cellCol * 26
                    y: cellRow * 26
                    width: 22
                    height: 22
                    radius: 2
                    color: gauge.lit
                    opacity: isFull ? 1.0 : (isPartial ? 0.5 : 0.18)
                }
            }

            // Text column to the right of the cell block.
            Column {
                x: 256 + 30
                y: 6
                width: 190
                spacing: 6

                Text {
                    width: parent.width
                    text: gauge.d.label
                    elide: Text.ElideRight
                    color: Tokens.white
                    font.family: Tokens.fontFamily
                    font.pixelSize: 26
                    font.weight: Tokens.weightMedium
                    font.letterSpacing: 26 * Tokens.trackName * 0.5
                }

                Text {
                    text: root.pctText(gauge.d.pct)
                    color: gauge.d.pct >= 80 ? Tokens.amber : Tokens.ice
                    font.family: Tokens.fontFamily
                    font.pixelSize: 44
                    font.weight: Tokens.weightMedium
                    font.letterSpacing: -0.6
                }

                Text {
                    width: parent.width
                    visible: gauge.d.fs.length > 0
                    text: gauge.d.fs
                    elide: Text.ElideRight
                    color: Tokens.textDim
                    font.family: Tokens.fontFamily
                    font.pixelSize: 16
                    font.weight: Tokens.weightRegular
                }

                Text {
                    width: parent.width
                    visible: root.mountBase(gauge.d.mount).length > 0
                    text: root.mountBase(gauge.d.mount)
                    elide: Text.ElideRight
                    color: Tokens.textDim
                    opacity: 0.8
                    font.family: Tokens.fontFamily
                    font.pixelSize: 16
                    font.weight: Tokens.weightRegular
                }

                Item { width: 1; height: 6 }

                Text {
                    text: root.human(gauge.d.usedBytes) + " of " + root.human(gauge.d.sizeBytes)
                    color: Tokens.textCaption
                    font.family: Tokens.fontFamily
                    font.pixelSize: 20
                    font.weight: Tokens.weightRegular
                }

                Text {
                    text: root.human(gauge.d.freeBytes) + " free"
                    color: Tokens.textLabel
                    font.family: Tokens.fontFamily
                    font.pixelSize: Tokens.sizeLabel
                    font.weight: Tokens.weightMedium
                }
            }
        }
    }

    // ---- empty state -----------------------------------------------------
    Text {
        x: 50
        y: 160
        visible: root.rows.length === 0
        text: "no disks"
        color: Tokens.textDim
        opacity: 0.7
        font.family: Tokens.fontFamily
        font.pixelSize: 16
        font.weight: Tokens.weightRegular
    }

    // ---- read-only note --------------------------------------------------
    Text {
        x: 50
        y: 722
        text: "read only"
        color: Tokens.textDim
        opacity: 0.65
        font.family: Tokens.fontFamily
        font.pixelSize: 16
        font.weight: Tokens.weightRegular
        font.letterSpacing: 16 * Tokens.trackLabel * 0.6
    }
}
