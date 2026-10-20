pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import ".."

// CrewSwimLane.qml — M1 CRW-TL crew activity table: LED + handle cells,
// 6h event track with two-row packing and in-lane titles, +15min hatched
// future zone, S/24H odometer, LANE (model tag), LAST, STATE chips, NOW
// cursor and footer legend. Rows come straight from crew.json — the shared
// "default" store gets a lane too, displayed as HERMES (source name stays
// "default" for identity). The now tick runs at 60 s and only while shown.
Item {
    id: root

    property var crew: ({})
    property bool shown: true

    // ---- board feed (HUD 01) ----------------------------------------------
    // The remote Mac board, relayed by tokens/pull_remote.py over the SAME
    // ssh call as the token feed. It lands in its own file so the token
    // lane stays byte-identical with and without the board.
    //   $XDG_STATE_HOME/nexuslink/remote/<host>-kanban.json
    // Shape (written by pull_remote.write_kanban):
    //   {"updated": <iso>, "host": "mac", "stale": true?,
    //    "cards": [{"id", "title", "status", "assignee", "model_override",
    //               "started_at", "completed_at", "last_failure_error"}]}
    // `body`/`result` are dropped upstream and never reach this file.
    // The path mirrors pull_remote.py exactly: XDG_STATE_HOME when set,
    // otherwise ~/.local/state. A hard-coded ".local/state" would miss
    // the file whenever XDG_STATE_HOME points elsewhere.
    readonly property string boardPath:
        (Quickshell.env("XDG_STATE_HOME") !== ""
         ? Quickshell.env("XDG_STATE_HOME")
         : Quickshell.env("HOME") + "/.local/state")
        + "/nexuslink/remote/mac-kanban.json"
    property var board: ({})
    property bool boardLoaded: false
    // true while there is no usable payload (file absent, empty or
    // unparseable). Set explicitly in loadBoard — a failed load must not
    // look like "a board with zero cards".
    property bool boardMissing: true
    // A stale board still shows the last known cards; the strip says so.
    readonly property bool boardStale: board && board.stale === true
    // How often the board file is re-read. The relay writes it every
    // 5 min; the HUD reads it on the same 60 s cadence as the crew feed.
    readonly property int boardPollMs: 60000

    FileView {
        id: boardFile
        path: root.boardPath
        watchChanges: true
        atomicWrites: true
        printErrors: false
        onFileChanged: boardFile.reload()
        onLoaded: root.loadBoard(text())
        onLoadFailed: root.loadBoard("")
    }
    Timer {
        interval: root.boardPollMs
        repeat: true
        running: root.shown && root.visible
        triggeredOnStart: true
        onTriggered: boardFile.reload()
    }
    function loadBoard(raw) {
        var data = null
        try { data = JSON.parse(String(raw || "")) } catch (e) { data = null }
        if (data === null || typeof data !== "object" || Array.isArray(data))
            data = null
        if (data === null) {
            // no usable payload: say the feed is missing, never invent rows
            board = ({})
            boardMissing = true
            boardLoaded = true
            return
        }
        board = data
        boardMissing = false
        boardLoaded = true
    }

    // ---- board rows ------------------------------------------------------
    // Running and blocked sort first; done last. Within a tier the
    // oldest start comes first (longest-running on top).
    readonly property var boardRows: {
        var src = (board && board.cards) ? board.cards : []
        var out = []
        // running and blocked rank first (the two states that need a
        // human now), then the rest. done always sits at the bottom.
        function rank(s) {
            if (s === "running") return 0
            if (s === "blocked") return 1
            if (s === "failed") return 2
            if (s === "review") return 3
            if (s === "ready") return 4
            if (s === "scheduled") return 5
            if (s === "todo" || s === "triage") return 6
            if (s === "done") return 7
            return 4
        }
        for (var i = 0; i < src.length; i++) {
            var c = src[i]
            if (!c || typeof c !== "object")
                continue
            out.push({
                "id": String(c.id || ""),
                "title": String(c.title || ""),
                "status": String(c.status || ""),
                "assignee": String(c.assignee || ""),
                "model": String(c.model_override || ""),
                "started": Number(c.started_at) || 0,
                "completed": Number(c.completed_at) || 0,
                "error": String(c.last_failure_error || "")
            })
        }
        out.sort(function (a, b) {
            return rank(a.status) - rank(b.status)
                   || a.started - b.started
                   || a.id.localeCompare(b.id)
        })
        return out
    }

    // at most 8 rows, then a "+N" row
    readonly property int maxRows: 8
    readonly property var shownRows: boardRows.length > maxRows
                                    ? boardRows.slice(0, maxRows) : boardRows
    readonly property int hiddenRows: boardRows.length - shownRows.length

    // ---- TASKS strip geometry --------------------------------------------
    // Compact by design: the crew table keeps the rest of the panel. The
    // strip is 13 px per row (micro type) plus a one-line header.
    readonly property real stripHeadH: 15
    readonly property real stripRowH: 13
    readonly property int stripLineCount: shownRows.length
                                        + (hiddenRows > 0 ? 1 : 0)
    readonly property real stripH: stripHeadH + stripLineCount * stripRowH + 6

    // elapsed time since started_at, compact ("4m", "2h10", "3d")
    function elapsed(started) {
        if (!started)
            return ""
        var s = Math.max(0, Math.floor(root.now - started))
        if (s < 60)
            return s + "s"
        var m = Math.floor(s / 60)
        if (m < 60)
            return m + "m"
        var h = Math.floor(m / 60)
        if (h < 24)
            return h + "h" + (m % 60)
        return Math.floor(h / 24) + "d"
    }
    // dot colour: running = accent, blocked/failed = red, ready = muted,
    // done = dim
    function statusColor(status) {
        switch (String(status)) {
        case "running": return FuiTokens.acid
        case "blocked": return FuiTokens.alert
        case "failed": return FuiTokens.alert
        case "review": return FuiTokens.warn
        case "ready": return FuiTokens.mute
        case "done": return FuiTokens.faint
        default: return FuiTokens.mute
        }
    }
    // A done row carries a dim check instead of the status dot. The mono
    // faces (KodeMono / Michroma) have no U+2713, so the check is drawn
    // from two hairline strokes — no new font, no missing-glyph box.
    function isDone(status) {
        return String(status) === "done"
    }
    // `updated` is an ISO-8601 string (pull_remote writes
    // datetime.now(timezone.utc).isoformat). Date.parse reads it; the
    // result is epoch ms, which fmtHm wants in seconds.
    function updatedHm() {
        if (!board || !board.updated)
            return FuiTokens.unknownGlyph
        var ms = Date.parse(String(board.updated))
        if (!isFinite(ms))
            return FuiTokens.unknownGlyph
        return FuiTokens.fmtHm(ms / 1000)
    }

    property double now: Date.now() / 1000
    // auto-fit the axis to the earliest event in the last 24h (min 2h) —
    // a fixed 6h window reads as empty bars when the crew went quiet early.
    readonly property double windowStart: {
        var t0 = now - 2 * 3600;
        var cutoff = now - 24 * 3600;
        for (var i = 0; i < bots.length; i++) {
            var ev = bots[i].events;
            if (!ev || ev.length === undefined)
                continue;
            for (var j = 0; j < ev.length; j++) {
                var s0 = Number(ev[j][0]);
                if (isFinite(s0) && s0 > cutoff && s0 < t0)
                    t0 = s0;
            }
        }
        return t0;
    }
    readonly property double windowEnd: now + 15 * 60   // NOW sits at -15min zone edge
    readonly property double spanMin: (tNow - windowStart) / 60

    Timer {
        interval: 60000
        repeat: true
        running: root.shown && root.visible
        triggeredOnStart: true
        onTriggered: root.now = Date.now() / 1000
    }

    readonly property var bots: {
        // state-ranked: active first, warm/idle next, dormant last (stable
        // within a tier). _ord keeps the crew.json serial order so a state
        // flip never renumbers a lane.
        var src = (crew && crew.bots) ? crew.bots : [];
        var out = [];
        function rank(s) { return s === "active" ? 0 : (s === "dormant" ? 2 : 1); }
        for (var i = 0; i < src.length; i++) {
            var b = src[i];
            var rb = {};
            for (var k in b)
                rb[k] = b[k];
            rb._ord = i;
            rb._rank = rank(String(b.state || "dormant"));
            out.push(rb);
        }
        out.sort(function (a, b) {
            return a._rank - b._rank
                   || (Number(b.last_active) || 0) - (Number(a.last_active) || 0)
                   || a._ord - b._ord;
        });
        return out;
    }

    // ---- geometry (fractions of the 1420px design panel) -------------------
    // headH carries the TASKS strip: the strip owns the top of the panel,
    // the crew table starts under it.
    readonly property real headH: 66 + root.stripH        // ruler/header zone
    readonly property real footH: 30
    readonly property real trackX0: width * (196 / 1420)
    readonly property real trackW: width * (864 / 1420)
    readonly property real futW: width * (36 / 1420)
    readonly property real rxX: width * (1104 / 1420)
    readonly property real rowsY: headH + 18
    readonly property real rowsH: Math.max(20, height - rowsY - footH)
    // rows never exceed rowsH: if the roster can't fit at min row height the
    // tail collapses into a "+N dormant" summary row.
    readonly property int minRowH: 17
    readonly property int maxFit: Math.max(1, Math.floor(rowsH / minRowH))
    readonly property bool overflowed: bots.length > maxFit
    readonly property var shownBots: overflowed ? bots.slice(0, maxFit - 1) : bots
    readonly property int hiddenCount: bots.length - shownBots.length
    readonly property int nRows: shownBots.length + (overflowed ? 1 : 0)
    readonly property real rowH: nRows > 0 ? Math.min(22, rowsH / nRows) : 22
    readonly property double tNow: windowEnd - 15 * 60
    // ruler labels: px per hour from view geometry — label only major ticks
    // with >=60px of room so dense windows don't avalanche into each other
    readonly property real hourPx: trackW / Math.max(1, spanMin) * 60
    readonly property int labelStepH: Math.max(1, Math.ceil(60 / Math.max(1, hourPx)))
    // scale for the S/24H micro bar: busiest lane fills the column
    readonly property int maxSes: {
        var m = 0;
        for (var i = 0; i < bots.length; i++)
            m = Math.max(m, Number(bots[i].sessions_24h) || 0);
        return m;
    }

    function tx(ts) {
        // spans the fitted track AND the +15m future zone so an event may
        // bleed into it; the NOW line sits at trackX0+trackW.
        return trackX0 + (ts - windowStart) / 60 * (trackW / Math.max(1, spanMin));
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
    // display name only — the shared store keeps name==="default" for identity
    function displayName(n) {
        var s = String(n || "");
        return s === "default" ? "Hermes" : s;
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

    // ===================================================== TASKS strip ====
    // The Mac board as a compact status list. Sits above the crew table:
    // the board answers "what is the crew doing RIGHT NOW", the table
    // answers "how did it get here". Never invents rows — a missing or
    // stale file says so in words.
    Item {
        id: strip
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: root.stripH
        visible: root.shown

        // strip header: TASKS · n cards · source stamp
        Text {
            id: stripHead
            x: 12; y: 2
            text: "TASKS"
            color: FuiTokens.ice
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.micro
            font.letterSpacing: FuiTokens.ls.cap
        }
        Text {
            x: stripHead.x + stripHead.implicitWidth + 8; y: 2
            text: root.boardRows.length + (root.boardRows.length === 1 ? " card" : " cards")
            color: FuiTokens.dim
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.micro
        }
        Text {
            anchors { right: parent.right; rightMargin: 12; top: parent.top; topMargin: 2 }
            text: (root.boardMissing || root.boardStale) ? "board feed stale"
                 : root.updatedHm()
            color: (root.boardMissing || root.boardStale) ? FuiTokens.alert : FuiTokens.mute
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.micro
            font.letterSpacing: FuiTokens.ls.cap
        }
        Rectangle {
            anchors { left: parent.left; leftMargin: 12; right: parent.right; rightMargin: 12; top: parent.top; topMargin: root.stripHeadH }
            height: 1
            color: FuiTokens.hair3
        }

        // missing / stale board: say so, invent nothing
        Text {
            visible: root.boardMissing
            x: 12; y: root.stripHeadH + 3
            text: "board feed stale"
            color: FuiTokens.mute
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.micro
            font.letterSpacing: FuiTokens.ls.cap
        }

        Column {
            y: root.stripHeadH + 2
            Repeater {
                model: root.shownRows
                delegate: Item {
                    id: taskRow
                    required property int index
                    required property var modelData
                    readonly property var card: modelData
                    readonly property bool running: card.status === "running"
                    width: strip.width
                    height: root.stripRowH

                    // status dot — the ONLY moving element on the strip
                    Item {
                        id: dot
                        x: 14
                        width: 8; height: 8
                        anchors.verticalCenter: parent.verticalCenter

                        Rectangle {
                            id: dotDot
                            visible: !root.isDone(taskRow.card.status)
                            anchors.centerIn: parent
                            width: 6; height: 6; radius: 3
                            color: root.statusColor(taskRow.card.status)
                            // running = accent + slow pulse. Everything else
                            // is static, so an idle board costs nothing.
                            SequentialAnimation on opacity {
                                running: taskRow.running && taskRow.visible
                                         && root.shown && strip.visible
                                loops: Animation.Infinite
                                NumberAnimation { to: 0.3; duration: 1400; easing.type: Easing.InOutSine }
                                NumberAnimation { to: 1.0; duration: 1400; easing.type: Easing.InOutSine }
                            }
                        }

                        // done = a dim check, drawn from two hairlines
                        // (the mono faces have no U+2713)
                        Canvas {
                            visible: root.isDone(taskRow.card.status)
                            anchors.centerIn: parent
                            width: 8; height: 8
                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.clearRect(0, 0, width, height)
                                ctx.strokeStyle = FuiTokens.css(FuiTokens.faint)
                                ctx.lineWidth = 1
                                ctx.beginPath()
                                ctx.moveTo(1.5, 4.2)
                                ctx.lineTo(3.4, 6.2)
                                ctx.lineTo(6.8, 1.8)
                                ctx.stroke()
                            }
                        }
                    }

                    Text {
                        anchors { left: dot.right; leftMargin: 7; verticalCenter: parent.verticalCenter }
                        width: strip.width * (520 / 1420) - 30
                        elide: Text.ElideRight
                        text: taskRow.card.title
                        color: taskRow.card.status === "done" ? FuiTokens.faint
                             : taskRow.card.status === "blocked" || taskRow.card.status === "failed"
                               ? FuiTokens.white : FuiTokens.dim
                        font.family: FuiTokens.mono
                        font.pixelSize: FuiTokens.px.micro
                    }

                    // assignee
                    Text {
                        anchors { left: parent.left; leftMargin: strip.width * (520 / 1420); verticalCenter: parent.verticalCenter }
                        width: strip.width * (96 / 1420)
                        elide: Text.ElideRight
                        text: taskRow.card.assignee.toUpperCase()
                        color: FuiTokens.faint
                        font.family: FuiTokens.mono
                        font.pixelSize: FuiTokens.px.micro
                        font.letterSpacing: FuiTokens.ls.tag
                    }

                    // failure reason (only when the card carries one) — the
                    // red dot says something broke, this says what
                    Text {
                        visible: taskRow.card.error !== ""
                        anchors { left: parent.left; leftMargin: strip.width * (620 / 1420); verticalCenter: parent.verticalCenter }
                        width: strip.width * (300 / 1420)
                        elide: Text.ElideRight
                        text: taskRow.card.error
                        color: FuiTokens.alert
                        font.family: FuiTokens.mono
                        font.pixelSize: FuiTokens.px.micro
                    }

                    // elapsed since started_at
                    Text {
                        anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                        text: root.elapsed(taskRow.card.started)
                        color: FuiTokens.faint
                        font.family: FuiTokens.mono
                        font.pixelSize: FuiTokens.px.micro
                    }
                }
            }
        }

        // "+N" overflow row
        Text {
            visible: root.hiddenRows > 0
            x: 27; y: root.stripHeadH + 2 + root.shownRows.length * root.stripRowH
            text: "+ " + root.hiddenRows + " more"
            color: FuiTokens.mute
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.micro
            font.letterSpacing: FuiTokens.ls.cap
        }
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
            // tick step follows the fitted span: 10min under 4h, 30min
            // under 12h, hourly beyond (a 24h window would bury 10min ticks)
            var step = root.spanMin <= 240 ? 600 : (root.spanMin <= 720 ? 1800 : 3600);
            var first = Math.ceil(root.windowStart / step) * step;
            var rowsBottom = root.rowsY + root.nRows * root.rowH;
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

    // hour labels (only ticks with >=60px spacing) + window start + +15M tag
    Repeater {
        model: {
            var out = [];
            var step = root.labelStepH * 3600;
            var first = Math.ceil(root.windowStart / 3600) * 3600;
            for (var t = first; t <= root.windowEnd; t += step)
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
        // hide when the first labelled tick would sit within 60px of it
        visible: root.tx(Math.ceil(root.windowStart / 3600) * 3600) - root.trackX0 >= 60
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
            model: root.shownBots
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

                Rectangle {                        // zebra (root.rowH — parent
                    visible: lane.index % 2 === 0  // may be null mid-reload)
                    x: 8; width: root.width - 16
                    height: root.rowH
                    color: FuiTokens.tone(FuiTokens.ice, 0.022)
                }
                Rectangle {                        // LED
                    x: 14; width: 6; height: 6
                    anchors.verticalCenter: parent.verticalCenter
                    color: lane.st === "active" ? FuiTokens.acid
                         : lane.st === "warm" ? FuiTokens.warn
                         : FuiTokens.faint
                }
                Text {                             // handle
                    x: 28; anchors.verticalCenter: parent.verticalCenter
                    width: root.trackX0 - 34
                    elide: Text.ElideRight
                    text: root.displayName(lane.bot.name).toUpperCase()
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
                        // root.rowH == lane.height, but stable when the
                        // delegate's parent is null during model reload
                        y: e.row === 0 ? 3 : root.rowH / 2 + 1
                        height: e.row === 0 ? root.rowH / 2 - 3 : root.rowH / 2 - 4

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

    // "+N dormant" summary row — only when the roster overflows rowsH
    Item {
        visible: root.overflowed
        y: root.rowsY + root.shownBots.length * root.rowH
        width: root.width
        height: root.rowH
        Rectangle {
            x: 14; width: 6; height: 6
            anchors.verticalCenter: parent.verticalCenter
            color: FuiTokens.faint
        }
        Text {
            x: 28; anchors.verticalCenter: parent.verticalCenter
            text: "+ " + root.hiddenCount + " dormant"
            color: FuiTokens.mute
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.micro
            font.letterSpacing: FuiTokens.ls.cap
        }
        Rectangle {                        // continuation ticks on the track
            x: root.trackX0; width: root.trackW
            anchors.bottom: parent.bottom
            height: 1
            color: FuiTokens.tone(FuiTokens.ice, 0.06)
        }
    }

    // NOW cursor + tag (sits at end of the 6h track, before the +15m zone)
    Rectangle {
        visible: root.bots.length > 0
        x: Math.round(root.trackX0 + root.trackW)
        y: root.headH - 26
        width: 1
        height: root.rowsY + root.nRows * root.rowH - (root.headH - 26)
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
