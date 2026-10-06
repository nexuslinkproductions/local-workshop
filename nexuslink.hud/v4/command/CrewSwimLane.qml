pragma ComponentBehavior: Bound

import QtQuick
import ".."

// CrewSwimLane.qml — M1 CRW-TL crew activity table: LED/serial/handle cells,
// 6h event track with two-row packing and in-lane titles, +15min hatched
// future zone, S/24H odometer, LANE (model tag), LAST, STATE chips, NOW
// cursor and footer legend. Rows come straight from crew.json (named bots
// only; "default" is the shared store, filtered per contract). The now tick
// runs at 60 s and only while shown.
Item {
    id: root

    property var crew: ({})
    property bool shown: true

    property double now: Date.now() / 1000
    readonly property double windowStart: now - 6 * 3600
    readonly property double windowEnd: now + 15 * 60   // NOW sits at -15min zone edge

    Timer {
        interval: 60000
        repeat: true
        running: root.shown && root.visible
        triggeredOnStart: true
        onTriggered: root.now = Date.now() / 1000
    }

    readonly property var bots: {
        var src = (crew && crew.bots) ? crew.bots : [];
        var out = [];
        for (var i = 0; i < src.length; i++)
            if (src[i].name !== "default")
                out.push(src[i]);
        return out;
    }

    // ---- geometry (fractions of the 1420px design panel) -------------------
    readonly property real headH: 66                    // ruler/header zone
    readonly property real footH: 30
    readonly property real trackX0: width * (196 / 1420)
    readonly property real trackW: width * (864 / 1420)
    readonly property real futW: width * (36 / 1420)
    readonly property real rxX: width * (1104 / 1420)
    readonly property real rowsY: headH + 18
    readonly property real rowsH: Math.max(20, height - rowsY - footH)
    readonly property real rowH: bots.length > 0
                                 ? Math.max(17, Math.min(22, rowsH / bots.length)) : 22
    readonly property double tNow: windowEnd - 15 * 60
    // scale for the S/24H micro bar: busiest lane fills the column
    readonly property int maxSes: {
        var m = 0;
        for (var i = 0; i < bots.length; i++)
            m = Math.max(m, Number(bots[i].sessions_24h) || 0);
        return m;
    }

    function tx(ts) {
        // spans the 6h track AND the +15m future zone so an event may bleed
        // into it; the NOW line sits at trackX0+trackW.
        return trackX0 + (ts - windowStart) / 60 * (trackW / 360);
    }

    function modelTag(m) {
        var s = String(m || "");
        if (s === "") return FuiTokens.unknownGlyph;
        s = s.replace("claude-", "").replace("deepseek-", "ds-")
             .replace("cursor/", "").replace("-flash", "f");
        return s.length > 14 ? s.slice(0, 13) + "~" : s;
    }
    function laneTag(p) {
        var s = String(p || "");
        return s === "" ? FuiTokens.unknownGlyph : s.replace("-", " ").toUpperCase();
    }

    // greedy two-row packing of a bot's window events; returns
    // [{x0,x1,row,live,idle,ping,title,room}]
    function packEvents(events) {
        var out = [];
        if (!events || events.length === undefined)
            return out;
        var sess = [];
        for (var i = 0; i < events.length; i++) {
            var e = events[i];
            var s0 = Number(e[0]), s1 = (e[1] === null || e[1] === undefined) ? root.tNow : Number(e[1]);
            if (s1 < root.windowStart || s0 > root.windowEnd)
                continue;
            sess.push({ "s0": Math.max(s0, root.windowStart), "s1": Math.min(s1, root.tNow),
                        "open": e[1] === null || e[1] === undefined, "title": String(e[2] || "") });
        }
        sess.sort(function (a, b) { return a.s0 - b.s0; });
        var end = [-1e18, -1e18];
        for (i = 0; i < sess.length; i++) {
            var r = sess[i];
            var x0 = tx(r.s0);
            var x1 = Math.max(tx(r.s1), x0 + 3);
            var row = x0 >= end[0] + 1 ? 0 : (x0 >= end[1] + 1 ? 1 : 0);
            if (x0 < end[row] + 1 && row === 0 && x0 < end[1] + 1)
                continue;                        // both rows busy — clip
            end[row] = Math.max(end[row], x1);
            out.push({ "x0": x0, "x1": x1, "row": row, "live": r.open,
                       "ping": !r.open && (r.s1 - r.s0) < 90, "title": r.title });
        }
        return out;
    }

    // ------------------------------------------------------------ header
    // ruler baseline + 10min/hour ticks + full-height hour gridlines
    Canvas {
        id: grid
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            var base = root.headH;
            ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(FuiTokens.ice, 0.45));
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.moveTo(root.trackX0, base + 0.5);
            ctx.lineTo(root.trackX0 + root.trackW + root.futW, base + 0.5);
            ctx.stroke();
            var step = 600;
            var first = Math.ceil(root.windowStart / step) * step;
            var rowsBottom = root.rowsY + root.bots.length * root.rowH;
            for (var t = first; t <= root.windowEnd; t += step) {
                var x = root.tx(t);
                var hour = t % 3600 === 0;
                ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(FuiTokens.ice, hour ? 0.75 : 0.4));
                ctx.beginPath();
                ctx.moveTo(x + 0.5, base);
                ctx.lineTo(x + 0.5, base + (hour ? 9 : 4));
                ctx.stroke();
                if (hour) {
                    ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(FuiTokens.ice, 0.09));
                    ctx.beginPath();
                    ctx.moveTo(x + 0.5, base + 12);
                    ctx.lineTo(x + 0.5, rowsBottom);
                    ctx.stroke();
                }
            }
            // hatched +15m future zone
            var fx = root.trackX0 + root.trackW;
            ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(FuiTokens.ice, 0.12));
            ctx.beginPath();
            for (var hx = -rowsBottom; hx < root.futW + rowsBottom; hx += 6) {
                ctx.moveTo(fx + hx, rowsBottom);
                ctx.lineTo(fx + hx + rowsBottom, root.rowsY - 4);
            }
            ctx.save();
            ctx.beginPath();
            ctx.rect(fx, root.rowsY - 4, root.futW, rowsBottom - root.rowsY + 4);
            ctx.clip();
            ctx.stroke();
            ctx.restore();
        }
        Connections {
            target: root
            function onWindowStartChanged() { grid.requestPaint(); }
            function onTrackX0Changed() { grid.requestPaint(); }
            function onRowHChanged() { grid.requestPaint(); }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }

    // hour labels + window start label + +15M tag
    Repeater {
        model: {
            var out = [];
            var first = Math.ceil(root.windowStart / 3600) * 3600;
            for (var t = first; t <= root.windowEnd; t += 3600)
                out.push(t);
            return out;
        }
        delegate: Text {
            required property var modelData
            x: root.tx(modelData) - implicitWidth / 2
            y: root.headH - 10
            text: FuiTokens.fmtHm(modelData)
            color: FuiTokens.dim
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.micro
        }
    }
    Text {
        x: root.trackX0; y: root.headH - 10
        text: FuiTokens.fmtHm(root.windowStart)
        color: FuiTokens.mute
        font.family: FuiTokens.mono
        font.pixelSize: FuiTokens.px.micro
    }
    Text {
        x: root.trackX0 + root.trackW + root.futW / 2 - implicitWidth / 2
        y: root.headH - 24
        text: "+15M"
        color: FuiTokens.mute
        font.family: FuiTokens.mono
        font.pixelSize: FuiTokens.px.micro
    }

    // column heads
    Text {
        x: 12; y: root.headH - 10
        text: "CRW / HANDLE"
        color: FuiTokens.dim
        font.family: FuiTokens.mono
        font.pixelSize: FuiTokens.px.micro
        font.letterSpacing: FuiTokens.ls.cap
    }
    Row {
        x: root.rxX; y: root.headH - 10
        spacing: 0
        Repeater {
            model: [["S/24H", 92], ["LANE", 108], ["LAST", 46], ["STATE", 60]]
            delegate: Text {
                required property var modelData
                width: modelData[1]
                text: modelData[0]
                color: FuiTokens.dim
                font.family: FuiTokens.mono
                font.pixelSize: FuiTokens.px.micro
                font.letterSpacing: FuiTokens.ls.cap
            }
        }
    }
    Rectangle {
        x: root.rxX; y: root.headH - 1
        width: 306; height: 1
        color: FuiTokens.tone(FuiTokens.ice, 0.3)
    }

    // -------------------------------------------------------------- rows
    Column {
        y: root.rowsY
        Repeater {
            model: root.bots
            delegate: Item {
                id: lane
                required property int index
                required property var modelData
                readonly property var bot: modelData
                readonly property string st: String(bot.state || "dormant")
                readonly property color stc: FuiTokens.stateColor(st)
                readonly property var blocks: root.packEvents(bot.events)
                width: root.width
                height: root.rowH

                Rectangle {                        // zebra
                    visible: lane.index % 2 === 0
                    x: 8; width: root.width - 16
                    height: parent.height
                    color: FuiTokens.tone(FuiTokens.ice, 0.022)
                }
                Rectangle {                        // LED
                    x: 14; width: 6; height: 6
                    anchors.verticalCenter: parent.verticalCenter
                    color: lane.st === "active" ? FuiTokens.acid
                         : lane.st === "warm" ? FuiTokens.warn
                         : FuiTokens.faint
                }
                Text {                             // serial
                    x: 28; anchors.verticalCenter: parent.verticalCenter
                    text: "CRW-" + root.p2(lane.index + 1)
                    color: FuiTokens.tone(FuiTokens.azure, 0.75)
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.micro
                }
                Text {                             // handle
                    x: 78; anchors.verticalCenter: parent.verticalCenter
                    width: root.trackX0 - 84
                    elide: Text.ElideRight
                    text: String(lane.bot.name || "").toUpperCase()
                    color: lane.st === "dormant" ? FuiTokens.dim : FuiTokens.white
                    font.family: FuiTokens.display
                    font.pixelSize: FuiTokens.px.micro
                    font.letterSpacing: FuiTokens.ls.cap
                }
                Rectangle {                        // lane separator
                    x: root.trackX0; width: root.trackW
                    anchors.bottom: parent.bottom
                    height: 1
                    color: FuiTokens.tone(FuiTokens.ice, 0.06)
                }

                Repeater {
                    model: lane.blocks
                    delegate: Item {
                        id: blk
                        required property var modelData
                        readonly property var e: modelData
                        x: e.x0
                        width: e.ping ? 10 : Math.max(3, e.x1 - e.x0)
                        y: e.row === 0 ? 3 : parent.height / 2 + 1
                        height: e.row === 0 ? parent.height / 2 - 3 : parent.height / 2 - 4

                        Rectangle {
                            visible: !blk.e.ping
                            anchors.fill: parent
                            color: blk.e.live ? FuiTokens.tone(FuiTokens.acid, 0.14)
                                              : FuiTokens.tone(FuiTokens.ice, 0.05)
                            border.width: 1
                            border.color: blk.e.live ? FuiTokens.tone(FuiTokens.acid, 0.95)
                                                     : FuiTokens.tone(FuiTokens.ice, 0.55)
                        }
                        Rectangle {                // roll-call ping diamond
                            visible: blk.e.ping
                            anchors.centerIn: parent
                            width: 5; height: 5
                            rotation: 45
                            color: "transparent"
                            border.width: 1
                            border.color: FuiTokens.tone(FuiTokens.ice, 0.7)
                        }
                        Text {                     // in-lane title when roomy
                            visible: !blk.e.ping && blk.width > 44
                            anchors { left: parent.left; leftMargin: 4; verticalCenter: parent.verticalCenter }
                            width: parent.width - 8
                            elide: Text.ElideRight
                            text: blk.e.title
                            color: blk.e.live ? FuiTokens.dim : FuiTokens.mute
                            font.family: FuiTokens.mono
                            font.pixelSize: FuiTokens.px.micro
                        }
                    }
                }

                // ---- readout columns ------------------------------------
                Text {                             // S/24H count
                    x: root.rxX + 2
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    width: 26
                    text: lane.bot.sessions_24h !== undefined
                          ? root.p2(Number(lane.bot.sessions_24h)) : FuiTokens.unknownGlyph
                    color: FuiTokens.white
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.cap
                }
                Item {                             // S/24H micro bar (scaled to busiest lane)
                    x: root.rxX + 34
                    anchors.verticalCenter: parent.verticalCenter
                    width: 52; height: 9
                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        border.width: 1
                        border.color: FuiTokens.tone(FuiTokens.ice, 0.3)
                    }
                    Rectangle {
                        visible: lane.bot.sessions_24h !== undefined
                        x: 1; y: 1
                        width: root.maxSes > 0
                               ? Math.max(1, (parent.width - 2) * Math.min(1, (Number(lane.bot.sessions_24h) || 0) / root.maxSes))
                               : 0
                        height: parent.height - 2
                        color: FuiTokens.tone(lane.st === "dormant" ? FuiTokens.dim : FuiTokens.ice, 0.8)
                    }
                }
                Rectangle {                        // LANE chip (model tag)
                    x: root.rxX + 92
                    anchors.verticalCenter: parent.verticalCenter
                    height: 15
                    width: laneText.implicitWidth + 8
                    color: "transparent"
                    border.width: 1
                    border.color: FuiTokens.tone(FuiTokens.ice, 0.3)
                    Text {
                        id: laneText
                        anchors.centerIn: parent
                        text: root.modelTag(lane.bot.model)
                        color: FuiTokens.dim
                        font.family: FuiTokens.mono
                        font.pixelSize: FuiTokens.px.micro
                    }
                }
                Text {                             // LAST
                    x: root.rxX + 200
                    anchors.verticalCenter: parent.verticalCenter
                    text: FuiTokens.fmtHm(lane.bot.last_active)
                    color: FuiTokens.dim
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.cap
                }
                Rectangle {                        // STATE chip
                    x: root.rxX + 246
                    anchors.verticalCenter: parent.verticalCenter
                    width: 56; height: 15
                    color: "transparent"
                    border.width: 1
                    border.color: FuiTokens.tone(lane.stc, 0.6)
                    Text {
                        anchors.centerIn: parent
                        text: lane.st.toUpperCase()
                        color: lane.stc
                        font.family: FuiTokens.mono
                        font.pixelSize: FuiTokens.px.micro
                    }
                }
            }
        }
    }

    // NOW cursor + tag (sits at end of the 6h track, before the +15m zone)
    Rectangle {
        visible: root.bots.length > 0
        x: Math.round(root.trackX0 + root.trackW)
        y: root.headH - 26
        width: 1
        height: root.rowsY + root.bots.length * root.rowH - (root.headH - 26)
        color: FuiTokens.tone(FuiTokens.acid, 0.9)
    }
    Rectangle {
        visible: root.bots.length > 0
        x: Math.round(root.trackX0 + root.trackW) - 40
        y: root.headH - 38
        width: 80; height: 16
        color: FuiTokens.bg
        border.width: 1
        border.color: FuiTokens.tone(FuiTokens.acid, 0.8)
        Text {
            anchors.centerIn: parent
            text: "NOW " + FuiTokens.fmtHm(root.tNow)
            color: FuiTokens.acid
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.micro
        }
    }

    // ------------------------------------------------------------ footer
    Item {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: root.footH
        Rectangle {
            anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 12; rightMargin: 12 }
            height: 1
            color: FuiTokens.tone(FuiTokens.ice, 0.12)
        }
        Row {
            x: 14; y: 9
            spacing: 24
            Repeater {
                model: ["session (closed)", "open, live", "roll-call ping"]
                delegate: Row {
                    id: leg
                    required property int index
                    required property string modelData
                    spacing: 6
                    Rectangle {
                        visible: leg.index < 2
                        y: 4; width: 22; height: 9
                        color: leg.index === 1 ? FuiTokens.tone(FuiTokens.acid, 0.14)
                                           : FuiTokens.tone(FuiTokens.ice, 0.05)
                        border.width: 1
                        border.color: leg.index === 1 ? FuiTokens.tone(FuiTokens.acid, 0.95)
                                                  : FuiTokens.tone(FuiTokens.ice, 0.55)
                    }
                    Rectangle {
                        visible: leg.index === 2
                        y: 6; width: 5; height: 5
                        rotation: 45
                        color: "transparent"
                        border.width: 1
                        border.color: FuiTokens.tone(FuiTokens.ice, 0.7)
                    }
                    Text {
                        text: leg.modelData
                        color: FuiTokens.mute
                        font.family: FuiTokens.mono
                        font.pixelSize: FuiTokens.px.micro
                    }
                }
            }
        }
        Text {
            anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
            text: "window " + FuiTokens.fmtHm(root.windowStart) + "-" + FuiTokens.fmtHm(root.tNow)
                  + " · " + root.bots.length + " crew"
                  + " · 1 min = " + (root.trackW / 360).toFixed(1) + " px"
            color: FuiTokens.dim
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.micro
        }
    }

    // empty state
    Text {
        visible: root.bots.length === 0
        anchors.centerIn: parent
        text: "awaiting crew feed"
        color: FuiTokens.mute
        font.family: FuiTokens.mono
        font.pixelSize: FuiTokens.px.cap
        font.letterSpacing: FuiTokens.ls.cap
    }

    function p2(x) { return (x < 10 ? "0" : "") + x; }
}
