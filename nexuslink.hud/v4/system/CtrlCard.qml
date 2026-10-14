pragma ComponentBehavior: Bound

import QtQuick
import ".."

// CtrlCard.qml — xHCI controller card for the DEV-BAY map: azure frame with
// dashed inner keyline, code + pci bdf, Michroma name, label:value rows and
// an optional die-temp strip (ruler + value bar) when a prom21 sensor feed
// is present.
Item {
    id: root

    property string code: ""          // XHC-A
    property string pci: ""           // 11:00.0
    property string name: ""          // "AMD 800 SERIES / USB 3.X XHCI"
    property var lines: []            // [{l, v, vc?}]
    property var temp: null           // deg C -> thermometer strip (null hides it)
    property real tempMin: 20
    property real tempMax: 100

    implicitWidth: 228
    implicitHeight: 136

    Canvas {
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            ctx.strokeStyle = FuiTokens.css(FuiTokens.azure);
            ctx.globalAlpha = 0.55;
            ctx.lineWidth = FuiTokens.lwHair;
            ctx.strokeRect(0.5, 0.5, width - 1, height - 1);
            ctx.globalAlpha = 0.18;
            ctx.setLineDash([2, 3]);
            ctx.strokeRect(4.5, 4.5, width - 9, height - 9);
            ctx.setLineDash([]);
            ctx.globalAlpha = 1;
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }

    Rectangle { anchors.fill: parent; color: Qt.rgba(8/255, 12/255, 16/255, 0.55) }

    Item {
        anchors { fill: parent; margins: 14 }
        Row {
            id: hd
            spacing: 8
            Text {
                text: root.code
                color: FuiTokens.azure
                font.family: FuiTokens.mono
                font.pixelSize: FuiTokens.px.body
            }
            Text {
                text: "pci " + root.pci
                visible: root.pci !== ""
                color: FuiTokens.mute
                font.family: FuiTokens.mono
                font.pixelSize: FuiTokens.px.body
            }
        }
        Text {
            anchors { top: hd.bottom; topMargin: 8; left: parent.left; right: parent.right }
            text: root.name
            color: FuiTokens.white
            font.family: FuiTokens.display
            font.pixelSize: 12
            font.letterSpacing: 2
            wrapMode: Text.Wrap
            lineHeight: 18
            lineHeightMode: Text.FixedHeight
        }
        Column {
            anchors { left: parent.left; right: parent.right
                      top: parent.top; topMargin: 78 }
            spacing: 2
            Repeater {
                model: root.lines
                delegate: Row {
                id: lnRow
                    required property var modelData
                    spacing: 6
                    Text {
                        text: lnRow.modelData.l
                        color: FuiTokens.mute
                        font.family: FuiTokens.mono
                        font.pixelSize: FuiTokens.px.body
                    }
                    Text {
                        text: lnRow.modelData.v
                        color: lnRow.modelData.vc !== undefined ? lnRow.modelData.vc : FuiTokens.dim
                        font.family: FuiTokens.mono
                        font.pixelSize: FuiTokens.px.body
                        elide: Text.ElideRight
                    }
                }
            }
        }
    }

    // die-temp strip: 20-100 C ruler + value bar + readout (like the sheet's
    // prom21 thermometer block)
    Item {
        visible: root.temp !== null
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom
                  leftMargin: 14; rightMargin: 14; bottomMargin: 12 }
        height: 44
        Canvas {
            id: strip
            anchors.fill: parent
            onPaint: {
                var ctx = getContext("2d");
                ctx.clearRect(0, 0, width, height);
                var t = Number(root.temp);
                if (!isFinite(t))
                    return;
                var lo = root.tempMin, hi = root.tempMax;
                var len = width - 20;
                // ruler ticks 20..100 step 16 (5 majors)
                ctx.strokeStyle = FuiTokens.css(FuiTokens.ice);
                ctx.lineWidth = FuiTokens.lwHair;
                var n = 20;
                for (var i = 0; i <= n; i++) {
                    var px = 4 + len * i / n;
                    var L = i % 5 === 0 ? 8 : 4;
                    ctx.globalAlpha = 0.45;
                    ctx.beginPath();
                    ctx.moveTo(px, 30); ctx.lineTo(px, 30 - L);
                    ctx.stroke();
                }
                ctx.globalAlpha = 0.9;
                ctx.fillStyle = FuiTokens.css(FuiTokens.mute);
                ctx.font = FuiTokens.px.body + "px \"" + FuiTokens.mono + "\"";
                ctx.textAlign = "center";
                var labs = [20, 40, 60, 80, 100];
                for (var k = 0; k < labs.length; k++)
                    ctx.fillText(String(labs[k]), 4 + len * k / (labs.length - 1), 14);
                // value bar + readout
                var f = Math.min(1, Math.max(0, (t - lo) / (hi - lo)));
                ctx.fillStyle = FuiTokens.css(FuiTokens.ice);
                ctx.globalAlpha = 0.85;
                ctx.fillRect(4, 34, len * f, 4);
                ctx.globalAlpha = 1;
                ctx.fillStyle = FuiTokens.css(FuiTokens.white);
                ctx.font = "13px \"" + FuiTokens.mono + "\"";
                ctx.textAlign = "left";
                ctx.fillText(t.toFixed(1) + " C", 4 + len * f + 6, 32);
            }
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            Connections {
                target: root
                function onTempChanged() { strip.requestPaint(); }
            }
        }
    }
}
