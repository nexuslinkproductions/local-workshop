pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as QQC
import ".."

// ActionKey.qml — tall QA key (M1 action rail): octagon plate with the glyph
// chip + one/two-line action name centred in the cell. Serials and raw
// command strings are never rendered; the keybind lives in a hover tooltip
// (hidden when "unbound"). Local to command/ because EngravedButton is a
// single-row control.
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
            ctx.fillStyle = FuiTokens.css(root.pressedState ? FuiTokens.tone(FuiTokens.ice, 0.16)
                                : root.hov ? FuiTokens.tone(FuiTokens.ice, 0.12)
                                : FuiTokens.tone(FuiTokens.ice, 0.025));
            ctx.fill();
            ctx.strokeStyle = FuiTokens.css(
                root.danger ? FuiTokens.tone(FuiTokens.warn, root.hov ? 1.0 : 0.7)
                            : (root.hov ? FuiTokens.ice
                                        : FuiTokens.tone(FuiTokens.ice, 0.5)));
            ctx.lineWidth = root.hov ? 1.5 : 1;
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

    Row {                          // glyph chip + action name, centred in the cell
        anchors.centerIn: parent    // 8px horizontal insets — narrow QA column
        width: parent.width - 16
        spacing: 6
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 14; height: 14
            color: "transparent"
            border.width: 1
            border.color: FuiTokens.hair
            Text {
                anchors.centerIn: parent
                text: root.glyph
                color: FuiTokens.ice
                font.family: FuiTokens.icons
                font.pixelSize: 9
            }
        }
        Text {                     // plain text; shrinks 11->10 to fit, 2 lines max
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 20
            height: root.height - 16
            textFormat: Text.PlainText
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            // Text.Wrap — word wrap with character fallback so long single
            // words ("Keybindings") still fill two lines instead of eliding
            wrapMode: Text.Wrap
            maximumLineCount: 2
            lineHeight: 0.95
            fontSizeMode: Text.Fit
            minimumPixelSize: 10
            text: root.label
            color: root.danger ? FuiTokens.warn : (root.hov ? FuiTokens.white : FuiTokens.txt)
            font.family: FuiTokens.display
            font.pixelSize: FuiTokens.px.cap
            font.letterSpacing: 1.0
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

    QQC.ToolTip {                  // keybind on hover only; "unbound" stays hidden
        visible: root.hov && root.keybind !== "" && root.keybind !== "unbound"
        delay: 250
        text: root.keybind
        font.family: FuiTokens.mono
    }
}
