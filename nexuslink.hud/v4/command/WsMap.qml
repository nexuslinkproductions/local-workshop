pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import ".."
import "../ScreenRoles.js" as Roles

// WsMap.qml — monitor schematic (M1 masthead "Displays"). Real monitor
// geometry (name/x/y/w/h from hyprctl -j monitors via the deck's poll).
// Monitors are drawn to scale in the virtual layout; each plate carries one
// readable role label bounded inside the rect, and the deck's own output is
// marked by the acid rim only. wsRows/winCount stay in the input contract
// (MastHead binds them) but no longer render captions.
Item {
    id: root

    // [{name,x,y,width,height}] in hyprctl px; [] -> awaiting poll
    property var mons: []
    // [{id,name,mon,wins}] from stats ws{i}_* keys — contract input, not drawn
    property var wsRows: []
    property int winCount: -1
    property string screenName: "DP-1"

    // connector name -> readable role label. Identity follows QsScreen EDID
    // (ScreenRoles), not the connector, so labels survive output renumbering;
    // unknown outputs keep their connector name.
    function labelForName(name) {
        var n = String(name || "");
        var screens = Quickshell.screens;
        for (var i = 0; i < screens.length; i++) {
            if (String(screens[i].name) === n) {
                switch (Roles.roleForScreen(screens[i])) {
                case "command":  return "Main";
                case "hardware": return "Right";
                case "ops":      return "Left";
                case "glasses":  return "XREAL";
                }
            }
        }
        return n;
    }

    readonly property var bounds: {
        if (mons.length === 0)
            return { "x0": 0, "y0": 0, "x1": 1, "y1": 1 };
        var x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
        for (var i = 0; i < mons.length; i++) {
            var m = mons[i];
            x0 = Math.min(x0, Number(m.x));
            y0 = Math.min(y0, Number(m.y));
            x1 = Math.max(x1, Number(m.x) + Number(m.width));
            y1 = Math.max(y1, Number(m.y) + Number(m.height));
        }
        return { "x0": x0, "y0": y0, "x1": x1, "y1": y1 };
    }
    readonly property real vw: Math.max(1, bounds.x1 - bounds.x0)
    readonly property real vh: Math.max(1, bounds.y1 - bounds.y0)

    // layout: simple header, map below. Plates scale to the virtual layout.
    readonly property real mapTop: 34
    readonly property real mapH: Math.max(10, height - mapTop)

    function scaleFor() {
        if (mons.length === 0)
            return 0;
        var sx = width / vw;
        var sy = mapH / vh;
        return Math.min(sx, sy);
    }
    readonly property real sc: scaleFor()
    readonly property real mapW: vw * sc
    readonly property real mapX0: Math.max(0, (width - mapW) / 2)

    function mx(px) { return mapX0 + (px - bounds.x0) * sc; }
    function my(py) { return mapTop + (py - bounds.y0) * sc; }

    // -------------------------------------------------------------- header
    Text {
        x: 0; y: 0
        text: "Displays"
        color: FuiTokens.dim
        font.family: FuiTokens.display
        font.pixelSize: FuiTokens.px.tag
        font.letterSpacing: 1.6
    }
    Rectangle {
        anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 22 }
        height: 1
        color: FuiTokens.hair2
    }

    // monitor plates
    Repeater {
        model: root.mons
        delegate: Item {
            id: mon
            required property var modelData
            required property int index
            readonly property bool you: String(modelData.name) === root.screenName
            x: root.mx(Number(modelData.x)) + 2
            y: root.my(Number(modelData.y))
            width: Math.max(26, Number(modelData.width) * root.sc - 4)
            height: Math.max(22, Number(modelData.height) * root.sc)

            Rectangle {
                anchors.fill: parent
                color: "transparent"
                border.width: 1
                border.color: mon.you ? FuiTokens.tone(FuiTokens.acid, 0.75)
                                      : FuiTokens.hair
            }
            Rectangle {
                anchors { fill: parent; margins: 4 }
                color: "transparent"
                border.width: 1
                border.color: FuiTokens.hair3
            }
            // one role label, elided inside the rect; the acid rim alone
            // marks the current output (a caption spilled into neighbours)
            Text {
                x: 8; y: 7
                width: Math.max(0, mon.width - 16)
                elide: Text.ElideRight
                text: root.labelForName(mon.modelData.name)
                color: FuiTokens.white
                font.family: FuiTokens.mono
                font.pixelSize: FuiTokens.px.micro
                font.letterSpacing: 0
            }
        }
    }
}
