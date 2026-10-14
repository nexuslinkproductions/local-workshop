pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import ".."

// MastHead.qml — M1 masthead strip. Three blocks:
//   A wordmark (auto pixel-size fit) + host name — two bounded lines only
//   B hero clock (HH:MM across-the-room) + 0-60 s ruler + date
//   C WS-MAP monitor schematic (WsMap), spanning to the right edge
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
    readonly property string hostName: {
        if (has("host"))
            return String(stats.host).toUpperCase();
        var h = String(Quickshell.env("HOSTNAME") || "");
        return h !== "" ? h.toUpperCase() : "";
    }

    // ---- date derivations -------------------------------------------------
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
    //   A 0..0.236 | B 0.245..0.513 | C 0.524..1 (blockD layout table removed)
    Item {
        id: blockA
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: parent.width * 0.236

        // two bounded lines: wordmark shrinks to fit blockA width, then host
        Column {
            x: 20
            width: blockA.width - 32
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            Text {
                width: parent.width
                // plain text — RichText ignores fontSizeMode, which cut the
                // wordmark on compact decks
                text: "NEXUS // HERMES"
                textFormat: Text.PlainText
                color: FuiTokens.white
                font.family: FuiTokens.display
                font.pixelSize: 34
                font.letterSpacing: 3
                fontSizeMode: Text.HorizontalFit
                minimumPixelSize: FuiTokens.px.cap
                maximumLineCount: 1
                clip: true
            }
            Text {
                width: parent.width
                elide: Text.ElideRight
                maximumLineCount: 1
                text: root.hostName !== "" ? root.hostName : "HOST"
                color: FuiTokens.mute
                font.family: FuiTokens.mono
                font.pixelSize: FuiTokens.px.cap
                font.letterSpacing: FuiTokens.ls.cap
            }
        }
    }

    // block dividers (design x = 584, 1272 of 2480; the 0.766 split is gone
    // with blockD)
    Repeater {
        model: [0.2355, 0.513]
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
            x: -2; y: 24
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
            y: blockB.height - 42
            width: blockB.width * 0.62
            height: 34
            property int sec: root.now.getSeconds() + root.now.getMilliseconds() / 1000
            Ruler {
                anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 8 }
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
                anchors { top: parent.top; topMargin: 23; left: parent.left; right: parent.right }
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

    // ---- C: workspace map (spans to the right edge) -----------------------
    WsMap {
        id: wsMap
        x: Math.round(root.width * 0.524)
        width: root.width - x
        anchors { top: parent.top; bottom: parent.bottom; topMargin: 8; bottomMargin: 6 }
        mons: root.mons
        wsRows: root.wsRows
        winCount: root.winCount
        screenName: root.screenName
    }
}
