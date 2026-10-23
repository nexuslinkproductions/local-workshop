import QtQuick
import "../kit"

// MacWidget - 24 column dot-matrix RTT field, battery bar and load dots.
// No circle, no frame: label and value sit above the field, left aligned.
WidgetBase {
    id: root

    property var link: null

    readonly property var rtt: (root.link && root.link.rtt_ms) ? root.link.rtt_ms : null
    readonly property var samples: (root.rtt && root.rtt.samples) ? root.rtt.samples : []
    readonly property var mac: (root.link && root.link.mac) ? root.link.mac : null
    readonly property bool live: root.link !== null && root.link !== undefined &&
        root.link.tunnel === "active" && root.samples.length > 0
    readonly property color battColor: !root.live ? Tokens.textDim
        : (root.charging ? Tokens.acid : Tokens.ice)
    readonly property color loadColor: root.live ? Tokens.ice : Tokens.textDim

    readonly property int cols: 24
    readonly property int rows: 6
    readonly property real dotPx: 10
    readonly property real gapPx: 4
    readonly property real fieldW: cols * dotPx + (cols - 1) * gapPx
    readonly property real fieldH: rows * dotPx + (rows - 1) * gapPx
    readonly property real fieldY: 104

    readonly property int battPct: (root.mac && typeof root.mac.batt === "number") ? root.mac.batt : 0
    readonly property int battFilled: root.live ? Math.max(0, Math.min(10, Math.round(root.battPct / 10))) : 0
    readonly property bool charging: root.mac && root.mac.state === "charging"
    readonly property var load: (root.mac && root.mac.load) ? root.mac.load : []

    readonly property string valueText: root.live ? String(Math.round(root.rtt.last)) : "--"

    // 0..5 ms one row, up to 100 ms six rows, log between.
    function levelFor(ms) {
        if (ms === undefined || ms === null || isNaN(ms))
            return 0
        if (ms <= 5)
            return 1
        return Math.max(1, Math.min(6, Math.round(1 + 5 * Math.log(ms / 5) / Math.log(20))))
    }

    TextMetrics {
        id: tmValue
        font.family: Tokens.fontFamily
        font.pixelSize: 68
        font.weight: 400
        text: "0"
    }
    TextMetrics {
        id: tmUnit
        font.family: Tokens.fontFamily
        font.pixelSize: 20
        font.weight: 500
        text: "ms"
    }

    Text {
        id: label
        text: "MAC"
        x: 0
        y: 0
        font.family: Tokens.fontFamily
        font.pixelSize: 16
        font.weight: 500
        font.letterSpacing: 16 * Tokens.trackLabel
        color: Tokens.textLabel
    }

    Text {
        id: value
        text: root.valueText
        x: 0
        y: 24
        font.family: Tokens.fontFamily
        font.pixelSize: 68
        font.weight: 400
        color: root.live ? Tokens.ink : Tokens.textDim
    }

    Text {
        id: unit
        text: "ms"
        x: value.x + value.width + 12
        y: Math.round(value.y + tmValue.height * 0.78 - tmUnit.height * 0.78)
        font.family: Tokens.fontFamily
        font.pixelSize: 20
        font.weight: 500
        color: Tokens.textLabel
        visible: root.live
    }

    // Dot-matrix field: one column per sample, oldest left.
    Item {
        id: field
        x: 0
        y: root.fieldY
        width: root.fieldW
        height: root.fieldH

        Repeater {
            model: root.cols
            Item {
                id: col
                width: root.dotPx
                height: root.fieldH
                x: index * (root.dotPx + root.gapPx)

                readonly property int si: root.samples.length - root.cols + index
                readonly property bool has: si >= 0 && si < root.samples.length
                readonly property real ms: has ? root.samples[si] : 0
                readonly property int lvl: has ? root.levelFor(ms) : 0
                readonly property bool hot: has && ms > 60
                readonly property real colOpacity: !root.live ? 0.25
                    : (has ? (index === root.cols - 1 ? 1.0 : 0.62) : 0.10)

                Repeater {
                    model: root.rows
                    Rectangle {
                        width: root.dotPx
                        height: width
                        radius: width / 2
                        x: 0
                        y: (root.rows - 1 - index) * (root.dotPx + root.gapPx)
                        color: col.has && (root.rows - 1 - index) < col.lvl
                            ? (col.hot ? Tokens.amber : Tokens.ice)
                            : Tokens.textDim
                        opacity: col.has && (root.rows - 1 - index) < col.lvl ? col.colOpacity : 0.12
                    }
                }
            }
        }

        // Empty state: one amber dot, bottom left.
        Rectangle {
            visible: !root.live
            width: root.dotPx; height: width; radius: width / 2
            x: 0
            y: root.fieldH - height
            color: Tokens.amber
            opacity: 0.9
        }
    }

    // Battery: 10 segments, acid only while charging.
    Row {
        id: battRow
        x: 0
        y: root.height - 18
        spacing: 5
        Repeater {
            model: 10
            Rectangle {
                width: 8; height: 8; radius: 4
                color: root.battColor
                opacity: index < root.battFilled ? 0.9 : (root.live ? 0.22 : 0.25)
            }
        }
    }

    // Load: three tiny dots for 1, 5, 15 minutes.
    Row {
        id: loadRow
        x: root.width - width - 4
        y: root.height - 17
        spacing: 5
        Repeater {
            model: 3
            Rectangle {
                readonly property real l: index < root.load.length ? root.load[index] : 0
                width: 6; height: 6; radius: 3
                color: root.loadColor
                opacity: root.live ? Math.max(0.18, Math.min(1.0, l / 8.0)) : 0.25
            }
        }
    }
}
