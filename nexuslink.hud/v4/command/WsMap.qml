pragma ComponentBehavior: Bound

import QtQuick
import ".."

// WsMap.qml — HYPRCTL monitor schematic (M1 masthead "WS-MAP"). Real monitor
// geometry (name/x/y/w/h from hyprctl -j monitors via the deck's poll),
// workspaces + window counts from the collector's ws{i}_*/win_count keys.
// Monitors are drawn to scale in the virtual layout; the deck's own output
// carries the acid "YOU ARE HERE" rim.
Item {
    id: root

    // [{name,x,y,width,height}] in hyprctl px; [] -> awaiting poll
    property var mons: []
    // [{id,name,mon,wins}] from stats ws{i}_* keys
    property var wsRows: []
    property int winCount: -1
    property string screenName: "DP-1"

    function wsFor(mon) {
        var out = [];
        for (var i = 0; i < wsRows.length; i++)
            if (String(wsRows[i].mon) === String(mon))
                out.push(wsRows[i]);
        out.sort(function (a, b) { return a.id - b.id; });
        return out;
    }
    function wsText(mon) {
        var l = wsFor(mon);
        if (l.length === 0)
            return FuiTokens.unknownGlyph;
        var s = "";
        for (var i = 0; i < l.length; i++)
            s += (i ? "  " : "") + String(l[i].id);
        return s;
    }
    function winText(mon) {
        var l = wsFor(mon);
        var n = 0, known = false;
        for (var i = 0; i < l.length; i++)
            if (l[i].wins >= 0) {
                n += l[i].wins;
                known = true;
            }
        return known ? n + " win" : FuiTokens.unknownGlyph;
    }
    function roleOf(name) {
        if (name === "DP-1") return "CREW / APPS";
        if (name === "DP-2") return "TOKENS / LIMITS";
        if (name === "HDMI-A-3") return "SYSTEM / CTRL";
        return "";
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

    // layout: header 40 px, map below. Monitor block width also needs room
    // for its caption columns, so each monitor gets a fixed label slot of
    // 108 px around its scaled rect (design: inner text columns).
    readonly property real mapTop: 44
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
        text: "WS-MAP // HYPRCTL MONITORS"
        color: FuiTokens.dim
        font.family: FuiTokens.display
        font.pixelSize: FuiTokens.px.tag
        font.letterSpacing: 1.6
    }
    Text {
        anchors { right: parent.right }
        y: 0
        text: root.mons.length > 0
              ? "virtual " + Math.round(root.vw) + " x " + Math.round(root.vh)
                + " px · 1:" + Math.max(1, Math.round(1 / root.sc))
              : "awaiting hyprctl"
        color: FuiTokens.mute
        font.family: FuiTokens.mono
        font.pixelSize: FuiTokens.px.micro
    }
    Rectangle {
        anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 22 }
        height: 1
        color: FuiTokens.hair2
    }

    // origin / edge labels along the top of the map
    Repeater {
        model: root.mons
        delegate: Item {
            id: monMark
            required property var modelData
            readonly property real ex: root.mx(Number(modelData.x))
            Rectangle { x: monMark.ex; y: 26; width: 1; height: 10; color: FuiTokens.hair }
            Text {
                x: monMark.ex + 3; y: 18
                text: (Number(monMark.modelData.x) > 0 ? "+" : "") + String(monMark.modelData.x)
                color: FuiTokens.mute
                font.family: FuiTokens.mono
                font.pixelSize: FuiTokens.px.micro
            }
        }
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
            Column {
                anchors { left: parent.left; top: parent.top; leftMargin: 8; topMargin: 7 }
                spacing: 3
                Row {
                    spacing: 6
                    Text {
                        text: String(mon.modelData.name)
                        color: FuiTokens.white
                        font.family: FuiTokens.display
                        font.pixelSize: FuiTokens.px.micro
                        font.letterSpacing: 1.2
                    }
                    Text {
                        visible: mon.you
                        anchors.verticalCenter: parent.verticalCenter
                        text: "· YOU ARE HERE"
                        color: FuiTokens.acid
                        font.family: FuiTokens.mono
                        font.pixelSize: FuiTokens.px.micro
                    }
                }
                Text {
                    text: String(mon.modelData.width) + "x" + String(mon.modelData.height)
                    color: FuiTokens.dim
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.micro
                }
                Text {
                    text: "WS " + root.wsText(mon.modelData.name)
                    color: FuiTokens.ice
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.micro
                }
                Text {
                    text: root.winText(mon.modelData.name)
                    color: FuiTokens.mute
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.micro
                }
                Text {
                    visible: root.roleOf(mon.modelData.name) !== ""
                    text: root.roleOf(mon.modelData.name)
                    color: FuiTokens.mute
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.micro
                }
            }

            Text {
                visible: mon.you
                anchors { right: parent.right; bottom: parent.bottom; rightMargin: 7; bottomMargin: 6 }
                text: "PRIMARY"
                color: FuiTokens.mute
                font.family: FuiTokens.mono
                font.pixelSize: FuiTokens.px.micro
            }
        }
    }
}
