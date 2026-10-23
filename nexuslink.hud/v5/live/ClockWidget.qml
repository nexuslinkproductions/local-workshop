import QtQuick
import "../kit"

// ClockWidget - HH:MM in fixed width digit cells, weekday left and date right.
// No Timer: the deck updates `now` once a minute, the colon pulses from `tick`.
WidgetBase {
    id: root

    property date now: new Date()

    interactive: false

    readonly property int clockPx: 96
    readonly property int datePx: 20
    readonly property string hhText: isNaN(root.now.getTime()) ? "--" : ("0" + root.now.getHours()).slice(-2)
    readonly property string mmText: isNaN(root.now.getTime()) ? "--" : ("0" + root.now.getMinutes()).slice(-2)
    readonly property string digits: hhText + mmText
    readonly property var dayNames: ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
    readonly property var monthNames: ["JAN", "FEB", "MAR", "APR", "MAY", "JUN",
                                       "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
    readonly property string weekday: isNaN(root.now.getTime()) ? "" : dayNames[root.now.getDay()]
    readonly property string dayMonth: isNaN(root.now.getTime()) ? "" :
        (root.now.getDate() + " " + monthNames[root.now.getMonth()])

    // Widest digit advance at clock size, measured, so every cell is equal.
    readonly property real cellW: {
        var w = Math.max(tm0.advanceWidth, tm1.advanceWidth, tm2.advanceWidth, tm3.advanceWidth,
                         tm4.advanceWidth, tm5.advanceWidth, tm6.advanceWidth, tm7.advanceWidth,
                         tm8.advanceWidth, tm9.advanceWidth)
        return w > 0 ? Math.ceil(w) : Math.round(root.clockPx * 0.62)
    }
    readonly property real cellH: tmNum.height > 0 ? Math.ceil(tmNum.height) : Math.ceil(root.clockPx * 1.3)
    readonly property real colonW: 34
    // Baseline sits just under half the line box for Satoshi at this size.
    readonly property real baselineY: Math.round(cellH * 0.5 + clockPx * 0.385)

    // Font probes. Ten TextMetrics (TextMetrics is not an Item, so no Repeater).
    TextMetrics { id: tm0; font.family: Tokens.fontFamily; font.pixelSize: root.clockPx; font.weight: 400; text: "0" }
    TextMetrics { id: tm1; font.family: Tokens.fontFamily; font.pixelSize: root.clockPx; font.weight: 400; text: "1" }
    TextMetrics { id: tm2; font.family: Tokens.fontFamily; font.pixelSize: root.clockPx; font.weight: 400; text: "2" }
    TextMetrics { id: tm3; font.family: Tokens.fontFamily; font.pixelSize: root.clockPx; font.weight: 400; text: "3" }
    TextMetrics { id: tm4; font.family: Tokens.fontFamily; font.pixelSize: root.clockPx; font.weight: 400; text: "4" }
    TextMetrics { id: tm5; font.family: Tokens.fontFamily; font.pixelSize: root.clockPx; font.weight: 400; text: "5" }
    TextMetrics { id: tm6; font.family: Tokens.fontFamily; font.pixelSize: root.clockPx; font.weight: 400; text: "6" }
    TextMetrics { id: tm7; font.family: Tokens.fontFamily; font.pixelSize: root.clockPx; font.weight: 400; text: "7" }
    TextMetrics { id: tm8; font.family: Tokens.fontFamily; font.pixelSize: root.clockPx; font.weight: 400; text: "8" }
    TextMetrics { id: tm9; font.family: Tokens.fontFamily; font.pixelSize: root.clockPx; font.weight: 400; text: "9" }
    TextMetrics {
        id: tmNum
        font.family: Tokens.fontFamily
        font.pixelSize: root.clockPx
        font.weight: 400
        text: "23"
    }

    Row {
        id: numeralRow
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        Repeater {
            model: 2
            Item {
                width: root.cellW
                height: root.cellH
                Text {
                    width: parent.width
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignHCenter
                    text: root.digits.charAt(index)
                    font.family: Tokens.fontFamily
                    font.pixelSize: root.clockPx
                    font.weight: 400
                    color: Tokens.ink
                }
            }
        }

        // Colon: two dots, not a glyph. Opacity pulses 0.55 to 1.0 on 4 s.
        Item {
            width: root.colonW
            height: root.cellH
            readonly property real pulse: 0.775 + 0.225 * Math.sin(root.tick * 2 * Math.PI / 4)

            Rectangle {
                width: 10; height: 10; radius: 5
                x: (parent.width - width) / 2
                y: Math.round(root.baselineY - 0.42 * root.clockPx)
                color: Tokens.ink
                opacity: parent.pulse
            }
            Rectangle {
                width: 10; height: 10; radius: 5
                x: (parent.width - width) / 2
                y: Math.round(root.baselineY - 0.18 * root.clockPx)
                color: Tokens.ink
                opacity: parent.pulse
            }
        }

        Repeater {
            model: 2
            Item {
                width: root.cellW
                height: root.cellH
                Text {
                    width: parent.width
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignHCenter
                    text: root.digits.charAt(index + 2)
                    font.family: Tokens.fontFamily
                    font.pixelSize: root.clockPx
                    font.weight: 400
                    color: Tokens.ink
                }
            }
        }
    }

    Text {
        id: weekdayText
        text: root.weekday
        x: Math.round(numeralRow.x - width - 36)
        y: Math.round(numeralRow.y + root.baselineY - root.clockPx * 0.25 - height / 2)
        font.family: Tokens.fontFamily
        font.pixelSize: root.datePx
        font.weight: 500
        font.letterSpacing: root.datePx * Tokens.trackLabel
        color: Tokens.textDate
    }

    Text {
        id: dateText
        text: root.dayMonth
        x: Math.round(numeralRow.x + numeralRow.width + 36)
        y: Math.round(numeralRow.y + root.baselineY - root.clockPx * 0.25 - height / 2)
        font.family: Tokens.fontFamily
        font.pixelSize: root.datePx
        font.weight: 500
        font.letterSpacing: root.datePx * Tokens.trackLabel
        color: Tokens.textDate
    }
}
