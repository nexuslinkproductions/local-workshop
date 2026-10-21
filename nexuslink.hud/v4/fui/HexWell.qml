pragma ComponentBehavior: Bound

import QtQuick
import ".."
import Quickshell
import Quickshell.Widgets

// HexWell.qml — flat-top hex hairline well holding a real app icon
// (M1 APP-DL hex targets). `icon` is a themed icon name or absolute path
// resolved through Quickshell.iconPath (AppGrid's iconSrc contract); when
// nothing resolves, `glyph` falls back to an FA glyph. Default render is
// icon + name only; serial/launch-count/sub captions sit behind
// showDiagnostics:false (FuiFrame contract — count < 0 still reads
// "untracked" when diagnostics are on).
Item {
    id: root

    property string icon: ""        // .desktop icon name or /abs/path
    property string glyph: ""       // FA fallback glyph (FuiTokens.ico.*)
    property string label: ""
    property string sub: ""         // category / caption
    property string serial: ""      // APP-0xNN
    property int count: -1          // <0 -> "untracked" (diagnostics only)
    property bool live: false       // acid hairline (launch/tracked-live state)
    property bool hovered: false    // fed externally; MouseArea also sets it
    property int margin: 5
    property bool showDiagnostics: false   // serial + count + sub captions

    signal activated()

    implicitWidth: 152
    implicitHeight: 132

    function iconSrc(icn) {
        if (!icn || icn === "")
            return "";
        if (icn.charAt(0) === "/")
            return "file://" + icn;
        var p = String(Quickshell.iconPath(icn, true) || "");
        return p === "" ? "" : p;
    }
    readonly property string _src: iconSrc(icon)

    Canvas {
        id: hex
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            ctx.globalAlpha = 1;
            var cx = width / 2, cy = height / 2;
            var rx = width / 2 - root.margin - 0.5, ry = height / 2 - root.margin - 0.5;
            ctx.beginPath();
            for (var i = 0; i < 6; i++) {   // flat-top hex (m_lib hexpath flat)
                var a = (30 + 60 * i) * Math.PI / 180;
                var x = cx + rx * Math.cos(a), y = cy + ry * Math.sin(a);
                if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
            }
            ctx.closePath();
            ctx.fillStyle = FuiTokens.css(
                root.hovered ? FuiTokens.tone(root.live ? FuiTokens.acid
                                                        : FuiTokens.ice, 0.11)
                             : FuiTokens.recess);
            ctx.fill();
            ctx.strokeStyle = FuiTokens.css(
                root.live ? FuiTokens.tone(FuiTokens.acid, root.hovered ? 1.0 : 0.55)
                          : (root.hovered ? FuiTokens.ice
                                          : FuiTokens.hair2));
            ctx.lineWidth = FuiTokens.lwHair;
            ctx.stroke();
        }
        Connections {
            target: root
            function onLiveChanged() { hex.requestPaint(); }
            function onHoveredChanged() { hex.requestPaint(); }
            function onMarginChanged() { hex.requestPaint(); }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }

    Text {                  // serial, top-right outside the icon column
        visible: root.showDiagnostics && root.serial !== ""
        anchors { top: parent.top; topMargin: 9; right: parent.right; rightMargin: 14 }
        text: root.serial
        color: FuiTokens.mute
        font.family: FuiTokens.mono
        font.pixelSize: FuiTokens.px.micro
    }

    Column {
        anchors.centerIn: parent
        spacing: 4
        width: parent.width - 2 * root.margin - 16
        Item {                  // icon or fallback glyph
            anchors.horizontalCenter: parent.horizontalCenter
            width: 26; height: 26
            scale: root.hovered ? 1.14 : 1.0
            IconImage {
                anchors.centerIn: parent
                visible: root._src !== ""
                width: 24; height: 24
                implicitSize: 24
                source: root._src
                asynchronous: true
                mipmap: true
            }
            Text {
                anchors.centerIn: parent
                visible: root._src === "" && root.glyph !== ""
                text: root.glyph
                color: root.hovered ? FuiTokens.white : FuiTokens.dim
                font.family: FuiTokens.icons
                font.pixelSize: 15
            }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            // word-boundary wrap, second line elides — "OBS STUDIO" stays
            // whole instead of splitting "STUDI O"
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            lineHeight: 0.95
            text: root.label.toUpperCase()
            color: root.hovered ? FuiTokens.white : FuiTokens.dim
            font.family: FuiTokens.display
            font.pixelSize: FuiTokens.px.micro
            font.letterSpacing: 1.2
        }
        Text {
            visible: root.showDiagnostics
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.count >= 0 ? "LAUNCH " + (root.count < 10 ? "0" : "")
                                    + root.count + " : " + root.count + "x"
                                  : "untracked"
            color: root.count > 0 ? FuiTokens.mute : FuiTokens.faint
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.micro
        }
        Text {
            visible: root.showDiagnostics && root.sub !== ""
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: root.sub
            color: FuiTokens.mute
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.micro
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onEntered: root.hovered = true
        onExited: root.hovered = false
        onClicked: root.activated()
    }
}
