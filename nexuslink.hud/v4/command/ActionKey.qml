pragma ComponentBehavior: Bound

import QtQuick
import ".."

// ActionKey.qml — tall QA key (M1 action rail): octagon plate, glyph chip +
// keybind hint on the top row, big label, QA-NN serial + command caption.
// Local to command/ because EngravedButton is a single-row control and the
// rail spec is a three-row cell.
Item {
    id: root

    property string label: ""
    property string glyph: ""
    property string keybind: ""
    property string code: ""
    property string command: ""
    property bool danger: false
    property bool interactive: true
    property bool pressedState: false
    property bool hov: false

    signal activated()

    implicitWidth: 192
    implicitHeight: 84

    Canvas {
        id: plate
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            var w = width, h = height, c = 10;
            ctx.beginPath();
            ctx.moveTo(0.5 + c, 0.5);
            ctx.lineTo(w - 0.5 - c, 0.5);
            ctx.lineTo(w - 0.5, 0.5 + c);
            ctx.lineTo(w - 0.5, h - 0.5 - c);
            ctx.lineTo(w - 0.5 - c, h - 0.5);
            ctx.lineTo(0.5 + c, h - 0.5);
            ctx.lineTo(0.5, h - 0.5 - c);
            ctx.lineTo(0.5, 0.5 + c);
            ctx.closePath();
            ctx.fillStyle = FuiTokens.css(root.pressedState ? FuiTokens.tone(FuiTokens.ice, 0.10)
                                : root.hov ? FuiTokens.tone(FuiTokens.ice, 0.05)
                                : FuiTokens.tone(FuiTokens.ice, 0.025));
            ctx.fill();
            ctx.strokeStyle = FuiTokens.css(
                root.danger ? FuiTokens.tone(FuiTokens.warn, root.hov ? 0.9 : 0.7)
                            : FuiTokens.tone(FuiTokens.ice, root.hov ? 0.8 : 0.5));
            ctx.lineWidth = 1;
            ctx.stroke();
            // mid hairline under the glyph/keybind row
            ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(FuiTokens.ice, 0.1));
            ctx.beginPath();
            ctx.moveTo(10.5, 29.5);
            ctx.lineTo(w - 10.5, 29.5);
            ctx.stroke();
        }
        Connections {
            target: root
            function onHovChanged() { plate.requestPaint(); }
            function onPressedStateChanged() { plate.requestPaint(); }
            function onDangerChanged() { plate.requestPaint(); }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }

    Row {                          // glyph chip + keybind
        x: 12; y: 7
        width: parent.width - 24
        spacing: 8
        Rectangle {
            width: 20; height: 15
            color: "transparent"
            border.width: 1
            border.color: FuiTokens.hair
            Text {
                anchors.centerIn: parent
                text: root.glyph
                color: FuiTokens.ice
                font.family: FuiTokens.icons
                font.pixelSize: 11
            }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 28
            horizontalAlignment: Text.AlignRight
            text: root.keybind
            color: root.keybind === "unbound" ? FuiTokens.faint : FuiTokens.mute
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.micro
        }
    }
    Text {                         // label
        x: 12; y: 36
        width: parent.width - 24
        elide: Text.ElideRight
        text: root.label
        color: root.danger ? FuiTokens.warn : FuiTokens.white
        font.family: FuiTokens.display
        font.pixelSize: FuiTokens.px.cap
        font.letterSpacing: 1.0
    }
    Row {                          // serial + command caption
        x: 12; y: 58
        width: parent.width - 24
        spacing: 6
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.code
            color: FuiTokens.ice
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.micro
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 40
            elide: Text.ElideRight
            text: root.command
            color: FuiTokens.mute
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.micro
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        enabled: root.interactive
        onEntered: root.hov = true
        onExited: { root.hov = false; root.pressedState = false; }
        onPressed: root.pressedState = true
        onReleased: root.pressedState = false
        onCanceled: root.pressedState = false
        onClicked: root.activated()
    }
}
