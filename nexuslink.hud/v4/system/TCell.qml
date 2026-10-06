pragma ComponentBehavior: Bound

import QtQuick
import ".."

// TCell.qml — one SYS-TLM cell: corner-bracket hairline tile with a code tag,
// a GaugeDial on the left, a label:value stat column on the right, a MiniBars
// block + Sparkline strip beneath it, and two label:value foot lines at the
// bottom-left. All content is bound by the deck; the cell only lays it out.
Item {
    id: root

    property string code: ""

    // gauge (aliased through to the embedded dial)
    property alias gaugeV: gauge.value
    property alias gaugeMin: gauge.minimum
    property alias gaugeMax: gauge.maximum
    property alias gaugeMajors: gauge.majors
    property alias gaugeRedFrom: gauge.redFrom
    property alias gaugeRedTo: gauge.redTo
    property alias gaugeMarkers: gauge.markers
    property alias gaugeColor: gauge.color
    property alias gaugeUnit: gauge.unit
    property alias gaugeTitle: gauge.title
    property alias gaugeSub: gauge.sub
    property alias gaugeValueText: gauge.valueText

    // right column
    property var statRows: []        // [{l, v, vc?}]
    property string barsCap: ""
    property var bars: []
    property real barsMin: 0
    property real barsMax: 100
    property var barsHi: null
    property color barsColor: FuiTokens.ice
    property string sparkCap: ""
    property var spark: []
    property color sparkColor: FuiTokens.ice

    property var footLines: []       // [{l, v, vc?}] max 2 rendered

    implicitWidth: 336
    implicitHeight: 288

    Canvas {
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            ctx.strokeStyle = FuiTokens.css(FuiTokens.hair2);
            ctx.lineWidth = FuiTokens.lwHair;
            ctx.strokeRect(0.5, 0.5, width - 1, height - 1);
            ctx.strokeStyle = FuiTokens.css(FuiTokens.ice);
            ctx.globalAlpha = 0.7;
            var L = 10;
            ctx.beginPath();
            ctx.moveTo(0.5, L); ctx.lineTo(0.5, 0.5); ctx.lineTo(L, 0.5);
            ctx.moveTo(width - L, 0.5); ctx.lineTo(width - 0.5, 0.5); ctx.lineTo(width - 0.5, L);
            ctx.moveTo(0.5, height - L); ctx.lineTo(0.5, height - 0.5); ctx.lineTo(L, height - 0.5);
            ctx.moveTo(width - L, height - 0.5); ctx.lineTo(width - 0.5, height - 0.5); ctx.lineTo(width - 0.5, height - L);
            ctx.stroke();
            ctx.globalAlpha = 1;
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }

    Text {
        id: codeTxt
        x: 8; y: 5
        text: root.code
        color: FuiTokens.mute
        font.family: FuiTokens.mono
        font.pixelSize: FuiTokens.px.cap
        font.letterSpacing: FuiTokens.ls.tag
    }

    GaugeDial {
        id: gauge
        anchors { left: parent.left; leftMargin: 4; top: parent.top; topMargin: 20 }
        width: Math.min(parent.width * 0.56, parent.height - 78, 212)
        height: width
        valuePx: width > 180 ? 26 : 20
    }

    // right column: stat rows, then bars, then sparkline — stacked top-down
    Column {
        id: statCol
        anchors { left: gauge.right; leftMargin: 6; right: parent.right; rightMargin: 8; top: parent.top; topMargin: 24 }
        spacing: 4
        Repeater {
            model: root.statRows
            delegate: Item {
                id: statRow
                required property var modelData
                width: statCol.width
                height: 13
                Text {
                    anchors.left: parent.left
                    text: statRow.modelData.l
                    color: FuiTokens.mute
                    font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body
                }
                Text {
                    anchors.right: parent.right
                    text: statRow.modelData.v
                    color: statRow.modelData.vc !== undefined ? statRow.modelData.vc : FuiTokens.dim
                    font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, parent.width - 40)
                }
            }
        }
    }

    Column {
        id: barCol
        visible: root.barsCap !== ""
        anchors { left: statCol.left; right: statCol.right; top: parent.top
                  topMargin: 24 + Math.min(root.statRows.length, 6) * 17 + 14 }
        spacing: 3
        Text {
            text: root.barsCap
            color: FuiTokens.mute
            font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.tag
            font.letterSpacing: FuiTokens.ls.tag
        }
        MiniBars {
            width: Math.min(barCol.width, 130)
            height: 30
            values: root.bars
            minimum: root.barsMin
            maximum: root.barsMax
            hi: root.barsHi
            color: root.barsColor
        }
    }

    Column {
        id: sparkCol
        visible: root.sparkCap !== ""
        anchors { left: statCol.left; right: statCol.right; bottom: parent.bottom; bottomMargin: 10 }
        spacing: 2
        Text {
            text: root.sparkCap
            color: FuiTokens.mute
            font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.tag
            font.letterSpacing: FuiTokens.ls.tag
        }
        Sparkline {
            width: sparkCol.width
            height: 26
            values: root.spark
            color: root.sparkColor
        }
    }

    Column {
        anchors { left: parent.left; leftMargin: 10; right: statCol.left
                  bottom: parent.bottom; bottomMargin: 10 }
        spacing: 3
        Repeater {
            model: root.footLines.slice(0, 2)
            delegate: Row {
                id: ftRow
                required property var modelData
                spacing: 6
                Text {
                    text: ftRow.modelData.l
                    color: FuiTokens.mute
                    font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body
                }
                Text {
                    text: ftRow.modelData.v
                    color: ftRow.modelData.vc !== undefined ? ftRow.modelData.vc : FuiTokens.dim
                    font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, statCol.x - 68)
                }
            }
        }
    }
}
