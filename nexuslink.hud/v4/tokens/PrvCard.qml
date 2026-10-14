pragma ComponentBehavior: Bound

import QtQuick
import ".."

// PrvCard.qml — provider detail block around the DP-2 hero rings
// (gen_M1_dp2 pblock): swatch + name + code, big token count + share %,
// share HairBar, cost/extra captions, 30-day sparkline with max marker.
Item {
    id: root

    property string name: ""
    property string code: ""
    property color color: FuiTokens.ice
    property var dash: null            // null = solid | [1.5,2.5] dotted | "double"
    property string valueText: ""      // "1.46B" | "—"
    property var share: null           // 0..1 | null
    property string costLine: ""
    property string extraLine: ""
    property var spark: []             // 30-day series
    property string sparkMax: ""       // "max 626M 10-04"
    property bool warned: false        // warn-toned extra line (history lags)
    property bool showDiagnostics: false   // instrument code + verbose captions

    implicitWidth: 276
    implicitHeight: col.height

    Column {
        id: col
        anchors { left: parent.left; right: parent.right }
        spacing: 4

        Item {
            width: parent.width
            height: 14
            // provider swatch — line sample (double edge for CDX lanes)
            Canvas {
                id: swatch
                anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                width: 26; height: 12
                onPaint: {
                    var ctx = getContext("2d");
                    ctx.clearRect(0, 0, width, height);
                    ctx.strokeStyle = FuiTokens.css(root.color);
                    ctx.lineWidth = 1.6;
                    ctx.globalAlpha = 0.95;
                    if (root.dash === "double") {
                        ctx.beginPath(); ctx.moveTo(0, 3.5); ctx.lineTo(width, 3.5); ctx.stroke();
                        ctx.beginPath(); ctx.moveTo(0, 8.5); ctx.lineTo(width, 8.5); ctx.stroke();
                    } else {
                        ctx.setLineDash(root.dash ? root.dash : []);
                        ctx.beginPath(); ctx.moveTo(0, 6); ctx.lineTo(width, 6); ctx.stroke();
                        ctx.setLineDash([]);
                    }
                }
                Connections {
                    target: root
                    function onColorChanged() { swatch.requestPaint(); }
                    function onDashChanged() { swatch.requestPaint(); }
                }
            }
            Tx {
                role: "lbl"; text: root.name; tone: FuiTokens.white
                font.pixelSize: FuiTokens.px.body
                width: Math.min(implicitWidth,
                                parent.width - swatch.width - 8
                                - (codeTxt.visible ? codeTxt.implicitWidth + 8 : 0))
                anchors { left: swatch.right; leftMargin: 8; verticalCenter: parent.verticalCenter }
            }
            Tx {
                id: codeTxt
                visible: root.showDiagnostics && root.code !== ""
                role: "code"; text: root.code
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            }
        }

        Item {
            width: parent.width
            height: 28
            Tx {
                role: "num"
                text: root.valueText
                font.pixelSize: FuiTokens.px.big + 6
                width: Math.min(implicitWidth, parent.width * 0.62)
                anchors { left: parent.left; verticalCenter: parent.verticalCenter }
            }
            Tx {
                role: "num"
                text: {
                    if (root.share === null || root.share === undefined
                            || !isFinite(Number(root.share)))
                        return FuiTokens.unknownGlyph;
                    return (Number(root.share) * 100).toFixed(2) + "%";
                }
                tone: FuiTokens.ice
                font.pixelSize: FuiTokens.px.mid
                width: Math.min(implicitWidth, parent.width * 0.34)
                anchors { right: parent.right; bottom: parent.bottom; bottomMargin: 4 }
            }
        }

        HairBar {
            width: parent.width
            value: root.share !== null && isFinite(Number(root.share))
                   ? Number(root.share) * 100 : null
            maximum: 100
            color: root.color
            trackH: 8
        }

        Tx {
            role: "cap"; text: root.costLine; tone: FuiTokens.dim
            width: parent.width
            visible: text !== ""
                     && (root.showDiagnostics || text.indexOf("n/a") < 0)
        }
        Tx {
            role: "cap"; text: root.extraLine
            width: parent.width
            visible: text !== "" && (root.warned || root.showDiagnostics)
            tone: root.warned ? FuiTokens.warn : FuiTokens.mute
        }

        Item {
            width: parent.width
            height: 10
            visible: root.spark.length > 1
            Tx { role: "micro"; text: "30D"; anchors.left: parent.left }
            Tx { role: "micro"; text: root.sparkMax; anchors.right: parent.right }
        }
        Sparkline {
            width: parent.width
            height: 24
            visible: root.spark.length > 1
            values: root.spark
            color: root.color
        }
    }
}
