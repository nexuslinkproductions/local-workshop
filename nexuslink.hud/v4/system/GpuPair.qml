pragma ComponentBehavior: Bound

import QtQuick
import ".."
import "../GpuCards.js" as GpuCards

// GpuPair.qml — SYS-TLM graphics cell. Lists every GPU in collector
// inventory order (Intel first — GpuCards.cards sorts), each row a static
// isometric die glyph + real device name + Primary/Secondary + the
// readings the collector actually reports. A missing reading renders "—";
// a card with no sensor lane at all reads "sensors unavailable". Never
// borrows the legacy gpu_name/gpu_temp aggregate keys.
Item {
    id: root

    property var stats: ({})
    readonly property var cards: GpuCards.cards(root.stats)

    implicitWidth: 336
    implicitHeight: 288

    // same hairline + corner-bracket plate as TCell
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
        id: head
        x: 10; y: 7
        width: Math.min(implicitWidth, parent.width - 20)
        elide: Text.ElideRight
        text: "GRAPHICS"
        color: FuiTokens.white
        font.family: FuiTokens.display
        font.pixelSize: FuiTokens.px.code
        font.letterSpacing: FuiTokens.ls.title
    }

    Rectangle {
        anchors { left: parent.left; right: parent.right; top: head.bottom; topMargin: 6 }
        height: 1
        color: FuiTokens.hair3
    }

    Column {
        id: cardCol
        anchors { left: parent.left; right: parent.right; top: head.bottom
                  bottom: parent.bottom; topMargin: 12; leftMargin: 12
                  rightMargin: 12; bottomMargin: 10 }

        Repeater {
            model: root.cards
            delegate: Item {
                id: cardRow
                required property var modelData
                required property int index
                readonly property color accent: modelData.kind === "intel"
                                                ? FuiTokens.ice : FuiTokens.azure
                readonly property bool noSensors: modelData.temp === null
                                                  && modelData.utilization === null
                                                  && modelData.power === null
                                                  && modelData.clock === null
                width: cardCol.width
                height: root.cards.length > 0
                        ? cardCol.height / root.cards.length : 0

                // static isometric die — identity glyph only, no data geometry
                Canvas {
                    id: die
                    anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                    width: 34; height: 26
                    onPaint: {
                        var ctx = getContext("2d");
                        ctx.clearRect(0, 0, width, height);
                        ctx.lineWidth = 1;
                        ctx.strokeStyle = FuiTokens.css(cardRow.accent);
                        ctx.fillStyle = FuiTokens.css(FuiTokens.tone(cardRow.accent, 0.14));
                        // top face
                        ctx.beginPath();
                        ctx.moveTo(17, 1.5); ctx.lineTo(31.5, 8.5);
                        ctx.lineTo(17, 15.5); ctx.lineTo(2.5, 8.5);
                        ctx.closePath();
                        ctx.fill(); ctx.stroke();
                        // left face
                        ctx.beginPath();
                        ctx.moveTo(2.5, 8.5); ctx.lineTo(17, 15.5);
                        ctx.lineTo(17, 24.5); ctx.lineTo(2.5, 17.5);
                        ctx.closePath();
                        ctx.globalAlpha = 0.55; ctx.fill(); ctx.globalAlpha = 1;
                        ctx.stroke();
                        // right face
                        ctx.beginPath();
                        ctx.moveTo(17, 15.5); ctx.lineTo(31.5, 8.5);
                        ctx.lineTo(31.5, 17.5); ctx.lineTo(17, 24.5);
                        ctx.closePath();
                        ctx.globalAlpha = 0.3; ctx.fill(); ctx.globalAlpha = 1;
                        ctx.stroke();
                        // die mark on the top face
                        ctx.globalAlpha = 0.8;
                        ctx.beginPath();
                        ctx.moveTo(17, 5.5); ctx.lineTo(24.5, 8.5);
                        ctx.lineTo(17, 11.5); ctx.lineTo(9.5, 8.5);
                        ctx.closePath();
                        ctx.stroke();
                        ctx.globalAlpha = 1;
                    }
                    Connections {
                        target: cardRow
                        function onAccentChanged() { die.requestPaint(); }
                    }
                }

                Text {
                    id: nameTxt
                    anchors { left: die.right; leftMargin: 10; top: parent.top
                              topMargin: Math.max(2, (parent.height - 44) / 2) }
                    width: Math.min(implicitWidth,
                                    parent.width - die.width - 18 - roleTxt.width - 8)
                    elide: Text.ElideRight
                    text: cardRow.modelData.name
                    color: FuiTokens.dim
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.mid
                }
                Text {
                    id: roleTxt
                    anchors { right: parent.right; baseline: nameTxt.baseline }
                    text: String(cardRow.modelData.role).toUpperCase()
                    color: FuiTokens.tone(cardRow.accent, 0.8)
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.tag
                    font.letterSpacing: FuiTokens.ls.tag
                }
                Text {
                    anchors { left: nameTxt.left; right: parent.right; top: nameTxt.bottom
                              topMargin: 4 }
                    elide: Text.ElideRight
                    text: {
                        var c = cardRow.modelData;
                        if (cardRow.noSensors)
                            return "sensors unavailable";
                        var dash = FuiTokens.unknownGlyph;
                        var parts = [
                            c.temp !== null ? Math.round(c.temp) + "°C" : dash,
                            c.utilization !== null ? Math.round(c.utilization) + "%" : dash,
                            c.power !== null ? Math.round(c.power) + " W" : dash
                        ];
                        if (c.clock !== null)
                            parts.push(Math.round(c.clock) + " MHz");
                        return parts.join(" · ");
                    }
                    color: cardRow.noSensors ? FuiTokens.faint : FuiTokens.mute
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.body
                }
                Rectangle {
                    visible: cardRow.index < root.cards.length - 1
                    anchors { left: parent.left; right: parent.right
                              bottom: parent.bottom; bottomMargin: 1 }
                    height: 1
                    color: FuiTokens.hair3
                }
            }
        }

        Text {
            visible: root.cards.length === 0
            width: parent.width
            elide: Text.ElideRight
            text: FuiTokens.unknownGlyph + " no intel/nvidia in inventory"
            color: FuiTokens.mute
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.body
        }
    }
}
