pragma ComponentBehavior: Bound

import QtQuick

// EngravedButton.qml — chamfered engraved control (M1 QA keys).
// Octagon-cut plate, recessed fill, double hairline (outer edge + inner
// engraving offset). Hover brightens the rim; `active` goes acid; a press
// dips the plate. No stock rounded-rect styling — this is the only button
// shape deck builders should use.
Item {
    id: root

    property string label: ""
    property string glyph: ""       // optional FA glyph (FuiTokens.ico.*)
    property string keybind: ""     // e.g. "SUPER+PRINT"
    property string code: ""        // serial, e.g. "QA-02"
    property bool active: false     // acid rim (stateful toggle ON / armed)
    property bool interactive: true
    property int chamfer: 6
    property bool pressedState: false   // `down` would warn on handler wiring

    signal activated()

    implicitWidth: 120
    implicitHeight: 34

    Canvas {
        id: plate
        anchors.fill: parent
        property bool hov: ma.containsMouse
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            ctx.globalAlpha = 1;
            var w = width, h = height, c = Math.min(root.chamfer, w / 2, h / 2);
            function path(off) {
                ctx.beginPath();
                ctx.moveTo(off + c, off);
                ctx.lineTo(w - off - c, off);
                ctx.lineTo(w - off, off + c);
                ctx.lineTo(w - off, h - off - c);
                ctx.lineTo(w - off - c, h - off);
                ctx.lineTo(off + c, h - off);
                ctx.lineTo(off, h - off - c);
                ctx.lineTo(off, off + c);
                ctx.closePath();
            }
            path(0.5);
            ctx.fillStyle = FuiTokens.css(
                !root.interactive ? FuiTokens.recess
                : root.pressedState ? FuiTokens.tone(FuiTokens.ice, 0.16)
                : hov ? FuiTokens.tone(root.active ? FuiTokens.acid : FuiTokens.ice, 0.14)
                : FuiTokens.recess);
            ctx.fill();
            ctx.strokeStyle = FuiTokens.css(
                !root.interactive ? FuiTokens.faint
                : root.active ? FuiTokens.acid
                : hov ? FuiTokens.ice : FuiTokens.hair2);
            ctx.lineWidth = hov || root.active ? 1.5 : FuiTokens.lwHair;
            ctx.stroke();
            path(2.5);              // inner engraving
            ctx.strokeStyle = FuiTokens.css(hov ? FuiTokens.tone(FuiTokens.ice, 0.35)
                                                : FuiTokens.hair3);
            ctx.stroke();
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections {
            target: root
            function onActiveChanged() { plate.requestPaint(); }
            function onEnabledChanged() { plate.requestPaint(); }
            function onChamferChanged() { plate.requestPaint(); }
            function onPressedStateChanged() { plate.requestPaint(); }
        }
        onHovChanged: requestPaint()
    }

    Text {                  // serial in the top-left chamfer
        visible: root.code !== ""
        x: root.chamfer + 4
        y: 3
        text: root.code
        color: FuiTokens.faint
        font.family: FuiTokens.mono
        font.pixelSize: FuiTokens.px.micro
    }
    Text {                  // keybind hint top-right
        visible: root.keybind !== ""
        anchors { right: parent.right; rightMargin: root.chamfer + 4; top: parent.top; topMargin: 3 }
        text: root.keybind
        color: FuiTokens.mute
        font.family: FuiTokens.mono
        font.pixelSize: FuiTokens.px.micro
    }

    Row {
        anchors.centerIn: parent
        spacing: 7
        Text {
            visible: root.glyph !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: root.glyph
            color: root.interactive ? (root.active ? FuiTokens.acid : plate.hov ? FuiTokens.ice : FuiTokens.dim)
                                : FuiTokens.faint
            font.family: FuiTokens.icons
            font.pixelSize: 12
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.label.toUpperCase()
            color: root.interactive ? (root.active ? FuiTokens.acid : plate.hov ? FuiTokens.white : FuiTokens.dim)
                                : FuiTokens.faint
            font.family: FuiTokens.display
            font.pixelSize: FuiTokens.px.micro + 1
            font.letterSpacing: FuiTokens.ls.label
        }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        enabled: root.interactive
        onPressed: root.pressedState = true
        onReleased: root.pressedState = false
        onCanceled: root.pressedState = false
        onClicked: root.activated()
    }
}
