pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import ".."

// Ledger.qml — LEDGER frame content: THEME, POWER PROFILE, UPDATES, TOGGLES,
// WORKSPACE JUMP. All values live (stats + SysPoll); every control runs the
// real omarchy/hyprctl command (argv, no interpolation). Workspace focus uses
// Hyprland 0.56 Lua dispatch syntax.
Item {
    id: root

    property var poll: null
    property var stats: ({})
    property string screenName: ""

    // collector emits indexed ws<i>_id/name/mon/wins — map ws number -> wins
    function wsWins(n) {
        var cnt = Number(stats.ws_count);
        if (!isFinite(cnt))
            return -1;
        for (var i = 0; i < cnt; i++) {
            if (Number(stats["ws" + i + "_id"]) === n)
                return Number(stats["ws" + i + "_wins"]);
        }
        return 0;
    }
    // this monitor's active workspace (hyprctl -j monitors via SysPoll)
    readonly property int wsFocused: {
        if (poll === null || screenName === "")
            return -1;
        var id = poll.monActive[screenName];
        return id !== undefined ? Number(id) : -1;
    }

    function execArgv(argv) {
        Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "ledger"].concat(argv));
    }
    // compound shell (two hyprctl dispatches) — literals only, no input
    function execShell(line) {
        Quickshell.execDetached(["bash", "-lc", line]);
    }

    // ---- inline widgets --------------------------------------------------
    component SegBar: Row {          // engraved segmented control
        id: seg
        property var items: []       // [{label, value}]
        property string value: ""
        signal picked(string v)
        spacing: 6
        Repeater {
            model: seg.items
            delegate: Item {
                id: segCell
                required property var modelData
                required property int index
                width: (seg.width - seg.spacing * Math.max(0, seg.items.length - 1))
                       / Math.max(1, seg.items.length)
                height: 28
                Rectangle {
                    anchors.fill: parent
                    color: segCell.modelData.value === seg.value ? FuiTokens.tone(FuiTokens.acid, 0.07) : FuiTokens.recess
                    border.width: FuiTokens.lwHair
                    border.color: segCell.modelData.value === seg.value ? FuiTokens.tone(FuiTokens.acid, 0.6) : FuiTokens.hair2
                }
                Rectangle {   // active keyline under the label
                    visible: segCell.modelData.value === seg.value
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 4 }
                    height: 1
                    color: FuiTokens.acid
                }
                Text {
                    anchors.centerIn: parent
                    text: segCell.modelData.label
                    color: segCell.modelData.value === seg.value ? FuiTokens.acid : (hov.hovered ? FuiTokens.white : FuiTokens.dim)
                    font.family: FuiTokens.display
                    font.pixelSize: FuiTokens.px.cap
                    font.letterSpacing: 1.2
                }
                HoverHandler { id: hov }
                TapHandler { onTapped: seg.picked(segCell.modelData.value) }
            }
        }
    }

    component Tgl: Item {            // hairline toggle switch + label + note
        id: tgl
        property string label: ""
        property string note: ""
        property bool on: false
        property bool known: true    // false -> dim "—" state, no interaction
        signal toggled()
        height: 30
        implicitWidth: 150
        Row {
            spacing: 10
            Item {
                width: 36; height: 16
                anchors.verticalCenter: parent.verticalCenter
                Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    border.width: FuiTokens.lwHair
                    border.color: tgl.known ? (tgl.on ? FuiTokens.acid : FuiTokens.ice) : FuiTokens.faint
                }
                Rectangle {
                    width: 10; height: 10
                    anchors.verticalCenter: parent.verticalCenter
                    x: tgl.on ? parent.width - 14 : 4
                    color: tgl.known ? (tgl.on ? FuiTokens.acid : FuiTokens.mute) : FuiTokens.faint
                }
                TapHandler { enabled: tgl.known; onTapped: tgl.toggled() }
            }
            Column {
                spacing: 1
                Text { text: tgl.label; color: FuiTokens.dim; font.family: FuiTokens.display; font.pixelSize: FuiTokens.px.cap; font.letterSpacing: 1.5 }
                Text { text: tgl.note; color: tgl.known ? FuiTokens.mute : FuiTokens.faint; font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body }
            }
        }
    }

    // ---- section frame: cap label + hairline under it --------------------
    component Sec: Item {
        id: sec
        property string cap: ""
        property alias contentX: capCol.x
        default property alias contents: capCol.children
        Item {
            id: capRow
            height: 14
            anchors { left: parent.left; right: parent.right; top: parent.top }
            Text {
                id: capTxt
                text: sec.cap
                color: FuiTokens.mute
                font.family: FuiTokens.display
                font.pixelSize: FuiTokens.px.cap
                font.letterSpacing: 1.5
            }
            Rectangle {
                anchors { left: capTxt.right; right: parent.right; leftMargin: 8; verticalCenter: capTxt.verticalCenter }
                height: 1; color: FuiTokens.hair2
            }
        }
        Column {
            id: capCol
            anchors { left: parent.left; right: parent.right; top: capRow.bottom; topMargin: 5
                      bottom: parent.bottom; bottomMargin: 3 }
            spacing: 5
            clip: true
        }
    }

    // ---- layout ----------------------------------------------------------
    Row {
        anchors.fill: parent
        spacing: 28

        Sec {
            cap: "THEME"
            width: Math.round(parent.width * 0.16)
            height: parent.height
            Text {
                text: root.stats.theme_name !== undefined
                      ? String(root.stats.theme_name).toUpperCase() : FuiTokens.unknownGlyph
                color: FuiTokens.white
                font.family: FuiTokens.display
                font.pixelSize: FuiTokens.px.mid
                font.letterSpacing: 2
                elide: Text.ElideRight
                width: parent.width
            }
            EngravedButton {
                label: "BG SWITCHER"
                width: 212; height: 26
                onActivated: root.execArgv(["omarchy-theme-bg-switcher"])
            }
            Text {
                color: FuiTokens.faint
                font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body
                text: "omarchy-theme-bg-switcher · SUPER+CTRL+SPACE"
            }
        }

        Sec {
            cap: "POWER PROFILE"
            width: Math.round(parent.width * 0.2)
            height: parent.height
            SegBar {
                width: parent.width
                items: [
                    { "label": "POWER-SAVER", "value": "power-saver" },
                    { "label": "BALANCED", "value": "balanced" },
                    { "label": "PERFORMANCE", "value": "performance" }
                ]
                value: root.poll !== null ? root.poll.powerProfile : ""
                onPicked: function(v) { root.execArgv(["omarchy-powerprofiles-set", "autodetect", v]); }
            }
            Text {
                color: FuiTokens.mute
                font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body
                text: "powerprofilesctl · ac/battery autodetect"
            }
        }

        Sec {
            cap: "UPDATES"
            width: Math.round(parent.width * 0.15)
            height: parent.height
            Row {
                spacing: 12
                Text {
                    text: root.stats.pkg_updates !== undefined ? String(root.stats.pkg_updates) : FuiTokens.unknownGlyph
                    color: FuiTokens.white
                    font.family: FuiTokens.display
                    font.pixelSize: 22
                }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1
                    Text { text: "pending"; color: FuiTokens.mute; font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body }
                    Text { text: "checkupdates"; color: FuiTokens.mute; font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body }
                }
            }
            EngravedButton {
                label: "UPDATE"
                active: root.stats.pkg_updates !== undefined && Number(root.stats.pkg_updates) > 0
                width: 140; height: 26
                onActivated: root.execArgv(["omarchy-launch-terminal", "omarchy-update"])
            }
        }

        Sec {
            cap: "TOGGLES"
            width: Math.round(parent.width * 0.17)
            height: parent.height
            Tgl {
                label: "NIGHT LIGHT"
                known: root.poll !== null && root.poll.night !== null
                on: root.poll !== null && root.poll.night !== null && root.poll.night.enabled === true
                note: {
                    if (root.poll === null || root.poll.night === null)
                        return "awaiting status";
                    var t = Number(root.poll.night.temperature);
                    return root.poll.night.enabled === true
                        ? "on" + (isFinite(t) && t > 0 ? " " + Math.round(t) + "K" : "") : "off";
                }
                onToggled: root.execArgv(["omarchy-shell", "-q", "nightlight", "toggle"])
            }
            Tgl {
                label: "DO NOT DISTURB"
                known: root.poll !== null && root.poll.dnd !== ""
                on: root.poll !== null && root.poll.dnd === "on"
                note: root.poll === null || root.poll.dnd === "" ? "awaiting status" : root.poll.dnd
                onToggled: root.execArgv(["omarchy-shell", "-q", "notifications", "toggleDnd"])
            }
        }

        Sec {
            cap: "WORKSPACE JUMP  SUPER+1..0"
            height: parent.height
            width: 420
            Row {
                spacing: 6
                Repeater {
                    model: 10
                    delegate: Item {
                        id: wsBox
                        required property int index
                        property int n: (index + 1) % 10   // boxes 1..9,0
                        property int wins: root.wsWins(n)
                        property bool occupied: wins > 0
                        property bool focused: root.wsFocused === n
                        width: 34; height: 30
                        Rectangle {
                            anchors.fill: parent
                            color: wsBox.focused ? FuiTokens.tone(FuiTokens.acid, 0.10) : FuiTokens.recess
                            border.width: FuiTokens.lwHair
                            border.color: wsBox.focused ? FuiTokens.acid : FuiTokens.hair2
                        }
                        Text {
                            anchors { centerIn: parent; verticalCenterOffset: -5 }
                            text: wsBox.n
                            color: wsBox.focused ? FuiTokens.acid : wsBox.occupied ? FuiTokens.white : FuiTokens.mute
                            font.family: FuiTokens.mono
                            font.pixelSize: 12
                        }
                        Text {   // window count under the digit
                            visible: wsBox.occupied
                            anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 1 }
                            text: "·" + wsBox.wins
                            color: FuiTokens.mute
                            font.family: FuiTokens.mono
                            font.pixelSize: 11
                        }
                        TapHandler {
                            // focus THIS output first, then the workspace —
                            // a key on HDMI-A-3 must switch HDMI's workspace
                            onTapped: {
                                var line = "hyprctl dispatch 'hl.dsp.focus({ workspace = \""
                                           + wsBox.n + "\" })'";
                                if (root.screenName !== "")
                                    line = "hyprctl dispatch 'hl.dsp.focus({ monitor = \""
                                           + root.screenName + "\" })' && " + line;
                                root.execShell(line);
                            }
                        }
                    }
                }
            }
            Row {
                spacing: 6
                Repeater {
                    model: ["", "", "", "", "", "", "", "", "", ""]
                    delegate: Text {
                        required property int index
                        width: 34
                        horizontalAlignment: Text.AlignHCenter
                        text: index === 0 ? "col 1" : ""
                        color: FuiTokens.faint
                        font.family: FuiTokens.mono; font.pixelSize: FuiTokens.px.body
                    }
                }
            }
        }
    }
}
