pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import ".."

// MastHead.qml — M1 masthead strip. Four blocks:
//   A wordmark + serial + tags + OWNS/DEFERS
//   B hero clock (HH:MM across-the-room) + 0-60 s ruler + date/ISO-week/DOY
//   C WS-MAP monitor schematic (WsMap)
//   D layout table
// The deck's only 1 Hz element lives here: the clock timer, gated by shown.
Item {
    id: root

    property var stats: ({})
    property var mons: []            // [{name,x,y,width,height}]
    property var wsRows: []          // [{id,name,mon,wins}]
    property int winCount: -1
    property string screenName: "DP-1"
    property bool shown: true

    property date now: new Date()

    Timer {
        interval: 1000
        repeat: true
        running: root.shown && root.visible
        triggeredOnStart: true
        onTriggered: root.now = new Date()
    }

    function has(k) { return stats[k] !== undefined && stats[k] !== ""; }
    function p2(x) { return (x < 10 ? "0" : "") + x; }
    function p3(x) { return (x < 100 ? (x < 10 ? "00" : "0") : "") + x; }
    readonly property string hostName: {
        if (has("host"))
            return String(stats.host).toUpperCase();
        var h = String(Quickshell.env("HOSTNAME") || "");
        return h !== "" ? h.toUpperCase() : "";
    }

    // ---- date derivations -------------------------------------------------
    readonly property int doy: {
        var d = now;
        return Math.floor((Date.UTC(d.getFullYear(), d.getMonth(), d.getDate())
                          - Date.UTC(d.getFullYear(), 0, 1)) / 86400000) + 1;
    }
    readonly property int yearDays: {
        var y = now.getFullYear();
        return Math.floor((Date.UTC(y + 1, 0, 1) - Date.UTC(y, 0, 1)) / 86400000);
    }
    readonly property int isoWeek: {
        var d = new Date(now.getTime());
        d.setHours(0, 0, 0, 0);
        d.setDate(d.getDate() + 3 - ((d.getDay() + 6) % 7)); // Thursday of week
        var w1 = new Date(d.getFullYear(), 0, 4);
        return 1 + Math.round(((d.getTime() - w1.getTime()) / 86400000
                               - 3 + ((w1.getDay() + 6) % 7)) / 7);
    }
    readonly property var weekDates: {          // Mon..Sun of this ISO week
        var d = new Date(now.getTime());
        var dow = (d.getDay() + 6) % 7;         // Mon=0
        var mon = new Date(d.getFullYear(), d.getMonth(), d.getDate() - dow);
        var out = [];
        for (var i = 0; i < 7; i++) {
            var dd = new Date(mon.getFullYear(), mon.getMonth(), mon.getDate() + i);
            out.push(dd);
        }
        return out;
    }
    readonly property int todayIdx: (now.getDay() + 6) % 7   // Mon=0
    readonly property string utcOff: {
        var o = -now.getTimezoneOffset();       // minutes east of UTC
        var s = o < 0 ? "-" : "+";
        var a = Math.abs(o);
        return "UTC" + s + p2(Math.floor(a / 60)) + ":" + p2(a % 60);
    }

    // ================================================================ layout
    // Fractions of masthead width from gen_M1_dp1.py (2480 px reference):
    //   A 0..0.236 | B 0.245..0.513 | C 0.524..0.766 | D 0.776..1
    Item {
        id: blockA
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: parent.width * 0.236

        Text {
            x: 20; y: 22
            text: "NEXUS <font color='" + FuiTokens.ice + "'>//</font> HERMES WORKSTATION"
            textFormat: Text.RichText
            color: FuiTokens.white
            font.family: FuiTokens.display
            font.pixelSize: 17
            font.letterSpacing: 3
        }
        Text {
            x: 20; y: 62
            text: "SN NX-" + (root.hostName !== "" ? root.hostName : "HOST")
                  + "-" + root.screenName + "-0A3  /  REV M1.04  /  LAYER BACKGROUND  /  QUICKSHELL TARGET"
            color: FuiTokens.mute
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.cap
            font.letterSpacing: FuiTokens.ls.cap
        }
        Row {
            x: 20; y: 88
            spacing: 8
            Repeater {
                model: [
                    "HOST " + (root.hostName !== "" ? root.hostName : FuiTokens.unknownGlyph),
                    "OMARCHY / HYPRLAND",
                    "DECK " + root.screenName + " CENTRE",
                    "PRIMARY"
                ]
                delegate: Rectangle {
                    id: tagCell
                    required property string modelData
                    height: 16
                    width: tagText.implicitWidth + 10
                    color: "transparent"
                    border.width: 1
                    border.color: FuiTokens.hair2
                    Text {
                        id: tagText
                        anchors.centerIn: parent
                        text: tagCell.modelData
                        color: FuiTokens.dim
                        font.family: FuiTokens.mono
                        font.pixelSize: FuiTokens.px.micro
                        font.letterSpacing: FuiTokens.ls.cap
                    }
                }
            }
        }
        Row {
            x: 20; y: 122
            spacing: 22
            Text {
                text: "OWNS"
                color: FuiTokens.mute
                font.family: FuiTokens.display
                font.pixelSize: FuiTokens.px.micro
                font.letterSpacing: 1.6
            }
            Text {
                text: "clock · crew · launcher · actions · ws-map"
                color: FuiTokens.mute
                font.family: FuiTokens.mono
                font.pixelSize: FuiTokens.px.cap
                font.letterSpacing: FuiTokens.ls.cap
            }
        }
        Row {
            x: 20; y: 146
            spacing: 22
            Text {
                text: "DEFERS"
                color: FuiTokens.mute
                font.family: FuiTokens.display
                font.pixelSize: FuiTokens.px.micro
                font.letterSpacing: 1.6
            }
            Text {
                text: "tokens/limits → DP-2   system/ctrl → HDMI-A-3"
                color: FuiTokens.mute
                font.family: FuiTokens.mono
                font.pixelSize: FuiTokens.px.cap
                font.letterSpacing: FuiTokens.ls.cap
            }
        }
    }

    // block dividers (design x = 584, 1272, 1900 of 2480)
    Repeater {
        model: [0.2355, 0.513, 0.766]
        delegate: Rectangle {
            required property real modelData
            x: Math.round(root.width * modelData) - 1
            y: 14
            width: 1
            height: root.height - 28
            color: FuiTokens.tone(FuiTokens.ice, 0.25)
        }
    }

    // ---- B: clock ---------------------------------------------------------
    Item {
        id: blockB
        x: Math.round(root.width * 0.245)
        width: root.width * 0.513 - x
        anchors { top: parent.top; bottom: parent.bottom }

        Row {
            x: 0; y: 10
            spacing: 8
            Text {
                text: "LOCAL TIME"
                color: FuiTokens.mute
                font.family: FuiTokens.display
                font.pixelSize: FuiTokens.px.micro
                font.letterSpacing: 1.6
            }
            Text {
                text: Qt.formatDateTime(root.now, "t") + " " + root.utcOff + " / 24H"
                color: FuiTokens.mute
                font.family: FuiTokens.mono
                font.pixelSize: FuiTokens.px.cap
                font.letterSpacing: FuiTokens.ls.cap
            }
        }
        Text {
            x: -2; y: 30
            text: Qt.formatDateTime(root.now, "HH:mm")
            color: FuiTokens.white
            font.family: FuiTokens.display
            font.pixelSize: Math.min(86, blockB.height * 0.5)
            font.letterSpacing: 6
        }
        // seconds ruler 0-60 + acid pointer (the deck's only per-second mover)
        Item {
            id: secRule
            x: 8
            y: blockB.height - 52
            width: blockB.width * 0.62
            height: 22
            property int sec: root.now.getSeconds() + root.now.getMilliseconds() / 1000
            Ruler {
                anchors { left: parent.left; right: parent.right; top: parent.top }
                height: 12
                from: 0; to: 60; minor: 60; majorEvery: 10
                labels: ["00", "10", "20", "30", "40", "50", "60"]
                flip: true
                showLabels: false
                tickMinor: 4
                tickMajor: 9
            }
            // minute tick labels under the ruler (Ruler label row is off for flip)
            Row {
                anchors { top: parent.top; topMargin: 2; left: parent.left; right: parent.right }
                height: 10
                Repeater {
                    model: ["00", "10", "20", "30", "40", "50", "60"]
                    delegate: Text {
                        required property int index
                        required property string modelData
                        x: secRule.width * index / 6 - (index === 6 ? implicitWidth : implicitWidth / 2)
                           + (index === 0 ? implicitWidth / 2 : 0)
                        text: modelData
                        color: FuiTokens.mute
                        font.family: FuiTokens.mono
                        font.pixelSize: FuiTokens.px.micro
                    }
                }
            }
            Canvas {
                id: secPointer
                anchors.fill: parent
                onPaint: {
                    var ctx = getContext("2d");
                    ctx.clearRect(0, 0, width, height);
                    var x = Math.round(width * Math.min(60, secRule.sec) / 60) + 0.5;
                    ctx.fillStyle = FuiTokens.css(FuiTokens.acid);
                    ctx.beginPath();
                    ctx.moveTo(x - 5, 0);
                    ctx.lineTo(x + 5, 0);
                    ctx.lineTo(x, 7);
                    ctx.closePath();
                    ctx.fill();
                }
                Connections {
                    target: secRule
                    function onSecChanged() { secPointer.requestPaint(); }
                }
                onWidthChanged: requestPaint()
            }
            Text {
                anchors { left: parent.right; leftMargin: 10; verticalCenter: parent.verticalCenter }
                text: "SEC " + root.p2(root.now.getSeconds())
                color: FuiTokens.mute
                font.family: FuiTokens.mono
                font.pixelSize: FuiTokens.px.micro
            }
        }
    }

    // ---- B2: date block (design x=1036/2480 → inside B's right side) -------
    Item {
        id: dateBlock
        x: Math.round(root.width * 0.418)
        width: root.width * 0.513 - x
        anchors { top: parent.top; bottom: parent.bottom }

        Text {
            x: 0; y: 26
            text: Qt.formatDateTime(root.now, "dddd").toUpperCase()
            color: FuiTokens.ice
            font.family: FuiTokens.display
            font.pixelSize: FuiTokens.px.micro
            font.letterSpacing: 1.6
        }
        Text {
            x: 0; y: 46
            text: Qt.formatDateTime(root.now, "dd MMM yyyy").toUpperCase()
            color: FuiTokens.white
            font.family: FuiTokens.display
            font.pixelSize: FuiTokens.px.big
            font.letterSpacing: 1
        }
        Text {
            x: 0; y: 84
            text: "ISO WEEK " + root.isoWeek + "  ·  DOY " + root.doy + "/" + root.yearDays
            color: FuiTokens.mute
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.cap
            font.letterSpacing: FuiTokens.ls.cap
        }
        // Mon..Sun cells, today acid; date numbers under
        Row {
            x: 0; y: 112
            spacing: 6
            Repeater {
                model: ["M", "T", "W", "T", "F", "S", "S"]
                delegate: Rectangle {
                    id: dayCell
                    required property int index
                    required property string modelData
                    width: 24; height: 22
                    color: "transparent"
                    border.width: 1
                    border.color: dayCell.index === root.todayIdx ? FuiTokens.acid : FuiTokens.hair
                    Text {
                        anchors.centerIn: parent
                        text: dayCell.modelData
                        color: dayCell.index === root.todayIdx ? FuiTokens.acid : FuiTokens.mute
                        font.family: FuiTokens.mono
                        font.pixelSize: FuiTokens.px.cap
                    }
                }
            }
        }
        Row {
            x: 0; y: 140
            spacing: 6
            Repeater {
                model: 7
                delegate: Text {
                    required property int index
                    width: 24
                    horizontalAlignment: Text.AlignHCenter
                    text: root.weekDates.length === 7
                          ? root.p2(root.weekDates[index].getDate()) : ""
                    color: index === root.todayIdx ? FuiTokens.acid : FuiTokens.mute
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.micro
                }
            }
        }
    }

    // ---- C: workspace map --------------------------------------------------
    WsMap {
        id: wsMap
        x: Math.round(root.width * 0.524)
        width: root.width * 0.766 - x
        anchors { top: parent.top; bottom: parent.bottom; topMargin: 8; bottomMargin: 6 }
        mons: root.mons
        wsRows: root.wsRows
        winCount: root.winCount
        screenName: root.screenName
    }

    // ---- D: layout table ----------------------------------------------------
    Item {
        id: blockD
        x: Math.round(root.width * 0.776)
        anchors { top: parent.top; bottom: parent.bottom; right: parent.right }

        Text {
            x: 0; y: 12
            text: "LAYOUT TABLE"
            color: FuiTokens.dim
            font.family: FuiTokens.display
            font.pixelSize: FuiTokens.px.micro
            font.letterSpacing: 1.6
        }
        // header + rows: MON / RES / ORIGIN / WS / DECK
        Column {
            x: 0; y: 40
            width: parent.width
            spacing: 0
            Row {
                width: parent.width
                Repeater {
                    model: [["MON", 0.20], ["RES", 0.24], ["ORIGIN", 0.20], ["WS", 0.22], ["DECK", 0.14]]
                    delegate: Text {
                        required property var modelData
                        width: blockD.width * modelData[1]
                        text: modelData[0]
                        color: FuiTokens.mute
                        font.family: FuiTokens.display
                        font.pixelSize: FuiTokens.px.micro
                        font.letterSpacing: 1.2
                    }
                }
            }
            Rectangle { width: parent.width; height: 1; color: FuiTokens.hair2 }
            Repeater {
                model: root.mons
                delegate: Item {
                    id: monRowWrap
                    required property var modelData
                    required property int index
                    readonly property bool you: String(modelData.name) === root.screenName
                    width: blockD.width
                    height: monRow.height + 8
                    Row {
                        id: monRow
                        width: parent.width
                        y: 4
                        Repeater {
                            model: [
                                [String(monRowWrap.modelData.name), 0.20],
                                [String(monRowWrap.modelData.width) + "x" + String(monRowWrap.modelData.height), 0.24],
                                [String(monRowWrap.modelData.x) + "," + String(monRowWrap.modelData.y), 0.20],
                                [wsMap.wsText(monRowWrap.modelData.name).replace(/  +/g, " · "), 0.22],
                                [String(monRowWrap.modelData.name) === "DP-1" ? "centre"
                                   : String(monRowWrap.modelData.name) === "DP-2" ? "right" : "left", 0.14]
                            ]
                            delegate: Text {
                                required property var modelData
                                width: blockD.width * modelData[1]
                                text: modelData[0]
                                elide: Text.ElideRight
                                color: monRowWrap.you ? FuiTokens.acid : FuiTokens.dim
                                font.family: FuiTokens.mono
                                font.pixelSize: FuiTokens.px.cap
                            }
                        }
                    }
                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width; height: 1
                        color: FuiTokens.hair3
                    }
                }
            }
        }
        Text {
            x: 0
            anchors { bottom: parent.bottom; bottomMargin: 8 }
            text: (root.wsRows.length) + " ws · "
                  + (root.winCount >= 0 ? root.winCount : FuiTokens.unknownGlyph)
                  + " windows · src: hyprctl -j · " + Qt.formatDateTime(root.now, "HH:mm")
            color: FuiTokens.mute
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.cap
            font.letterSpacing: FuiTokens.ls.cap
        }
    }
}
