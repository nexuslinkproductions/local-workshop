pragma ComponentBehavior: Bound

import QtQml.Models
import QtQuick
import Quickshell
import Quickshell.Io

// OpsView.qml — DP-2 second view "OPS" (lane B4): a live system feed.
// Hosted by BoardView.qml's tab bar (BOARD | OPS); receives the same parsed
// `stats` map the collector emits. Everything is driven by Topology.statsRev
// (the collector batch tick) — the journal tail is re-read every Nth tick and
// the event feed diffs frame n against frame n-1. One watchdog Timer exists
// solely to detect a DEAD collector (statsRev stops bumping); it runs only
// while this tab is shown.
//
// Honesty rules (BRIEF-V4-BUILD §3/§4), same as the board:
//   * a vital the collector does not emit renders "—", never fabricated
//   * service health is derived from stats keys only: a service is "up" when
//     it appears in the proc*_name top-CPU list, "unknown" when it does not
//     (absence from a top-6 is not proof of death — never "down" on a guess).
//     hud-collect is the exception: it feeds `stats` itself, so a stalled
//     statsRev is real evidence and reports "down".
//   * journal lines come from `journalctl --user` via Process/StdioCollector
//     (Navigator's pattern); if it fails, the feed still carries frame events.

Item {
    id: root

    // ---- injected by BoardView.qml ---------------------------------------
    property var stats: ({})            // last applyFrame map, key -> string
    property string screenName: "DP-2"
    property bool running: true         // screen is shown (HudV4 deck gate)
    property bool active: true          // this tab is selected — gates forks

    // ---- palette/font shortcuts (Style singleton, lane S) -----------------
    readonly property color cInk: Style.c.ink
    readonly property color cInk2: Style.c.ink2
    readonly property color cRecess: Style.c.recess
    readonly property color cRecessTop: Style.c.recessTop
    readonly property color cEdge: Style.c.edge
    readonly property color cTxt: Style.c.txt
    readonly property color cDim: Style.c.dim
    readonly property color cMute: Style.c.mute
    readonly property color cFaint: Style.c.faint
    readonly property color cAcc: Style.c.accent
    readonly property color cIce: Style.c.accent2
    readonly property color cWarn: Style.c.warn
    readonly property color cAlert: Style.c.alert
    readonly property color cMag: Style.c.magenta
    readonly property color cUnk: Style.c.unknown
    readonly property string fDisp: Style.f.display
    readonly property string fMono: Style.f.mono
    readonly property string dash: "—"

    // ---------- generic value helpers (absent key -> "—") -----------------
    function has(k) {
        return stats[k] !== undefined && stats[k] !== "";
    }
    function num(v) {
        var n = Number(v);
        return isFinite(n) ? n : NaN;
    }
    function sn(k) {
        return has(k) ? num(stats[k]) : NaN;
    }
    function ss(k) {
        return has(k) ? String(stats[k]) : dash;
    }
    function fmtUp(s) {
        if (!isFinite(s))
            return dash;
        var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
        return h + "h" + (m < 10 ? "0" : "") + m + "m";
    }
    function fmtAge(s) {
        if (!isFinite(s))
            return dash;
        if (s >= 86400)
            return Math.floor(s / 86400) + "d" + Math.floor((s % 86400) / 3600) + "h";
        if (s >= 3600)
            return Math.floor(s / 3600) + "h" + Math.floor((s % 3600) / 60) + "m";
        if (s >= 60)
            return Math.floor(s / 60) + "m";
        return Math.floor(s) + "s";
    }
    function pctS(v) {
        return isFinite(v) ? Math.round(v) + "%" : dash;
    }
    function toneCol(t) {
        switch (t) {
        case "acc":
            return root.cAcc;
        case "ice":
            return root.cIce;
        case "warn":
            return root.cWarn;
        case "alert":
            return root.cAlert;
        case "mag":
            return root.cMag;
        case "dim":
            return root.cDim;
        default:
            return root.cMute;
        }
    }

    // ============================ STATE ===================================
    // Frame diff state — rebuilt per statsRev; only extracted copies kept.
    property int _tick: 0
    property var _procSet: ({})         // name -> cpu of last frame's top procs
    property var _winSet: ({})          // win addr -> {cls,title} last frame
    property var _wsWins: ({})          // ws name -> wins last frame
    property var _ghevSeen: ({})        // "repo|type" -> age_s last seen
    property var _svcPrev: ({})         // svc id -> state last frame
    property string _themePrev: ""
    property string _batPrev: ""
    property int _ghPrev: -1
    property string _ghOkPrev: ""
    property int _pkgPrev: -1
    property int _agPrev: -1
    property int _sessPrev: -1
    property bool _seeded: false

    // proc snapshot rows for the rail repeater
    property var procRows: []

    // service strip rows for the rail repeater
    property var svcRows: []

    // collector liveness — the only service that can be proven down
    property real lastFrameMs: 0
    property real frameGapMs: 0
    property bool feedStale: false

    // journal tail state
    property string _jrnlNewest: ""
    property string _jrnlLastBody: ""
    property int jrnlExit: -1
    property int jrnlRuns: 0

    // ============================ FEED ====================================
    ListModel {
        id: feedModel
    }
    readonly property int feedCap: 80

    // Uptime-derived stamp on feed rows (M7): functional event time, not a readout.
    function feedTs() {
        var u = sn("uptime_s");
        return isFinite(u) ? "u" + fmtUp(u) : dash;
    }
    function pushEvt(tag, text, tone) {
        feedModel.insert(0, {
                "ets": feedTs(),
                "etag": tag,
                "etext": text,
                "etone": tone,
                "en": 1
            });
        while (feedModel.count > feedCap)
            feedModel.remove(feedCap, feedModel.count - feedCap);
    }

    // ---- journal tail (journalctl --user) — Navigator Process pattern ----
    // Re-read every 3rd stats tick (~4.5s at stream cadence) and only while
    // the OPS tab is on screen; dedupe collapses repeat spam lines into ×N.
    Process {
        id: jrnlProc
        running: false
        command: ["journalctl", "--user", "-n", "48", "--no-pager", "-o", "short-iso", "-q"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.ingestJournal(String(text))
        }
        onExited: function (exitCode) {
            root.jrnlExit = exitCode;
        }
    }

    function ingestJournal(text) {
        var lines = String(text).split("\n");
        var clean = [];
        for (var i = 0; i < lines.length; i++) {
            var ln = lines[i];
            if (ln !== "" && ln.indexOf("-- ") !== 0)
                clean.push(ln);
        }
        if (clean.length === 0)
            return;
        var start = 0;
        if (root._jrnlNewest !== "") {
            var at = clean.lastIndexOf(root._jrnlNewest);
            start = at < 0 ? 0 : at + 1;      // rotated past tail -> all new
        } else {
            start = Math.max(0, clean.length - 24); // first fill: cap flood
        }
        for (var j = start; j < clean.length; j++)
            root.pushJrnl(clean[j]);
        root._jrnlNewest = clean[clean.length - 1];
    }

    function pushJrnl(line) {
        // "2026-09-30T01:49:47+02:00 host unit[pid]: message"
        var ts = line.length > 19 ? line.substr(11, 8) : "";
        var rest = line.indexOf(" ", 26);
        var unit = "JRN", body = line;
        if (rest > 0) {
            var head = line.substr(rest + 1);
            var colon = head.indexOf(":");
            if (colon > 0 && colon < 40) {
                unit = head.substr(0, colon).replace(/\[[0-9]+\]$/, "");
                body = head.substr(colon + 1).replace(/^\s+/, "");
            }
        }
        var tone = "dim";
        if (/WARN|warn|Warning/.test(body))
            tone = "warn";
        if (/ERR|error|Failed|failed|FAIL/.test(body))
            tone = "alert";
        else if (/Started|Stopped|Reached/.test(body))
            tone = "ice";
        // collapse consecutive repeats of the same body into ×N on top row
        if (body === root._jrnlLastBody && feedModel.count > 0 && feedModel.get(0).etag === unit) {
            feedModel.setProperty(0, "en", feedModel.get(0).en + 1);
            feedModel.setProperty(0, "ets", ts !== "" ? ts : feedModel.get(0).ets);
            return;
        }
        feedModel.insert(0, {
                "ets": ts !== "" ? ts : feedTs(),
                "etag": unit,
                "etext": body,
                "etone": tone,
                "en": 1
            });
        while (feedModel.count > feedCap)
            feedModel.remove(feedCap, feedModel.count - feedCap);
        root._jrnlLastBody = body;
    }

    // ======================== FRAME DIFF (tick) ===========================
    Connections {
        target: Topology
        function onStatsRevChanged() {
            root.onFrame();
        }
    }

    // Sole timer: watchdog that proves the collector dead by statsRev silence.
    // Never samples; runs only while the OPS tab is on screen.
    Timer {
        id: staleWd
        interval: 2500
        repeat: true
        running: root.active
        onTriggered: root.checkStale()
    }
    onActiveChanged: {
        if (active) {
            checkStale();
            if (!jrnlProc.running)
                jrnlProc.running = true;
        }
    }
    onRunningChanged: checkStale()

    function checkStale() {
        var stale = root.lastFrameMs > 0 && (Date.now() - root.lastFrameMs) > 5500;
        if (stale !== root.feedStale) {
            root.feedStale = stale;
            pushEvt("SYS", stale ? "telemetry feed stale — no frames >5s" : "telemetry feed resumed", stale ? "alert" : "acc");
        }
        applySvc();
    }

    function onFrame() {
        var now = Date.now();
        if (root.lastFrameMs > 0)
            root.frameGapMs = now - root.lastFrameMs;
        root.lastFrameMs = now;
        if (root.feedStale) {
            root.feedStale = false;
            pushEvt("SYS", "telemetry feed resumed", "acc");
        }
        _tick++;

        // ---------- top procs (procN_name / procN_cpu, bounded scan) -------
        var procs = [];
        for (var i = 0; i < 8; i++) {
            var pn = stats["proc" + i + "_name"];
            if (pn === undefined || pn === "")
                break;
            procs.push({
                    "name": String(pn),
                    "cpu": num(stats["proc" + i + "_cpu"])
                });
        }
        procRows = procs;
        var newSet = {};
        for (var pi = 0; pi < procs.length; pi++)
            newSet[procs[pi].name] = procs[pi].cpu;
        if (_seeded && procs.length > 0) {
            for (var kn in newSet) {
                if (_procSet[kn] === undefined)
                    pushEvt("PROC", kn + " entered top procs · " + Math.round(newSet[kn]) + "%", "ice");
            }
            for (var ko in _procSet) {
                if (newSet[ko] === undefined)
                    pushEvt("PROC", ko + " left top procs", "dim");
            }
        }
        if (procs.length > 0)
            _procSet = newSet;         // absent keys keep last set — no false exits

        // ---------- windows (winN_addr/class/title) -----------------------
        var haveWins = has("win_count");
        var wins = {};
        var wc = haveWins ? Math.min(24, num(stats["win_count"])) : 0;
        for (var wi = 0; wi < wc; wi++) {
            var addr = stats["win" + wi + "_addr"];
            if (addr === undefined || addr === "")
                continue;
            wins[String(addr)] = {
                "cls": ss("win" + wi + "_class"),
                "title": ss("win" + wi + "_title"),
                "ws": ss("win" + wi + "_ws")
            };
        }
        if (_seeded && haveWins) {
            for (var wa in wins) {
                if (_winSet[wa] === undefined)
                    pushEvt("WIN", "+ " + wins[wa].cls + " — " + wins[wa].title, "acc");
                else if (_winSet[wa].title !== wins[wa].title)
                    pushEvt("WIN", "~ " + wins[wa].cls + " — " + wins[wa].title, "ice");
            }
            for (var wo in _winSet) {
                if (wins[wo] === undefined)
                    pushEvt("WIN", "− " + _winSet[wo].cls + " — " + _winSet[wo].title, "dim");
            }
        }
        if (haveWins)
            _winSet = wins;

        // ---------- workspaces (wsN_name/mon/wins) ------------------------
        var haveWs = has("ws_count");
        var wsc = haveWs ? Math.min(24, num(stats["ws_count"])) : 0;
        var wsNow = {};
        for (var wsi = 0; wsi < wsc; wsi++) {
            var wname = ss("ws" + wsi + "_name");
            wsNow[wname] = {
                "wins": num(stats["ws" + wsi + "_wins"]),
                "mon": ss("ws" + wsi + "_mon")
            };
        }
        if (_seeded && haveWs) {
            for (var wk in wsNow) {
                var old = _wsWins[wk];
                if (old !== undefined && old.wins !== wsNow[wk].wins)
                    pushEvt("WS", "ws " + wk + " @" + wsNow[wk].mon + " wins " + old.wins + "→" + wsNow[wk].wins, "dim");
            }
        }
        if (haveWs)
            _wsWins = wsNow;

        // ---------- github (gh_ok / gh_unread / ghevN_*) -------------------
        var ok = ss("gh_ok");
        if (_seeded && _ghOkPrev !== "" && ok !== _ghOkPrev)
            pushEvt("GH", ok === "1" ? "api reachable" : "api error", ok === "1" ? "acc" : "warn");
        _ghOkPrev = ok;
        var unr = sn("gh_unread");
        if (_seeded && _ghPrev >= 0 && isFinite(unr) && unr !== _ghPrev)
            pushEvt("GH", "unread " + _ghPrev + " → " + Math.round(unr), "ice");
        if (isFinite(unr))
            _ghPrev = unr;
        var gc = has("ghev_count") ? Math.min(12, num(stats["ghev_count"])) : 0;
        for (var gi = 0; gi < gc; gi++) {
            var repo = ss("ghev" + gi + "_repo");
            var typ = ss("ghev" + gi + "_type");
            var age = sn("ghev" + gi + "_age_s");
            var sig = repo + "|" + typ;
            var seen = _ghevSeen[sig];
            // a newer event for the same (repo,type) has a smaller age_s
            if (seen === undefined || (isFinite(age) && age < seen)) {
                var slash = repo.lastIndexOf("/");
                var short = slash >= 0 ? repo.substr(slash + 1) : repo;
                if (_seeded || seen === undefined)
                    pushEvt("GH", typ + " " + short + " · " + fmtAge(age) + " ago", "mag");
                _ghevSeen[sig] = age;
            } else if (isFinite(age)) {
                _ghevSeen[sig] = age;
            }
        }

        // ---------- system scalars ----------------------------------------
        var th = ss("theme_name");
        if (_seeded && _themePrev !== "" && th !== _themePrev)
            pushEvt("SYS", "theme → " + th, "ice");
        _themePrev = th;
        var bs = ss("bat0_state");
        if (_seeded && _batPrev !== "" && bs !== _batPrev && bs !== dash)
            pushEvt("PWR", "bat0 → " + bs, "warn");
        _batPrev = bs;
        var pk = sn("pkg_updates");
        if (_seeded && _pkgPrev >= 0 && isFinite(pk) && pk !== _pkgPrev)
            pushEvt("SYS", "pkg updates " + _pkgPrev + " → " + Math.round(pk), pk > _pkgPrev ? "warn" : "dim");
        if (isFinite(pk))
            _pkgPrev = pk;
        var ag = sn("agents_procs");
        if (_seeded && _agPrev >= 0 && isFinite(ag) && ag !== _agPrev)
            pushEvt("AGT", "agent procs " + _agPrev + " → " + Math.round(ag), "ice");
        if (isFinite(ag))
            _agPrev = ag;
        var sl = 0;
        var dc = has("devsess_count") ? Math.min(24, num(stats["devsess_count"])) : 0;
        for (var di = 0; di < dc; di++) {
            if (num(stats["devsess" + di + "_live"]) > 0)
                sl++;
        }
        if (dc > 0) {
            if (_seeded && _sessPrev >= 0 && sl !== _sessPrev)
                pushEvt("AGT", "devin sessions live " + _sessPrev + " → " + sl, "ice");
            _sessPrev = sl;
        }

        if (!_seeded) {
            _seeded = true;
            pushEvt("SYS", "ops feed armed · " + procs.length + " procs · " + wc + " wins · " + wsc + " ws", "acc");
        }

        applySvc();

        // journal tail at stats cadence — every 3rd tick, only while shown
        if (root.active && _tick % 3 === 1 && !jrnlProc.running) {
            jrnlRuns++;
            jrnlProc.running = true;
        }
    }

    // ======================== SERVICE STRIP ===============================
    // up/down/unknown derived strictly from stats keys — see file header.
    function svcDef() {
        return [
            { "id": "qs", "label": "QUICKSHELL", "match": ["quickshell"], "what": "this shell" },
            { "id": "hc", "label": "HUD-COLLECT", "match": null, "what": "frame feed" },
            { "id": "pw", "label": "PIPEWIRE", "match": ["pipewire", "wireplumber", "pipewire-pulse"], "what": "audio", "act": ["omarchy-restart-audio"] },
            { "id": "nm", "label": "NETMGR", "match": ["NetworkManager"], "what": "net", "act": ["omarchy-restart-wifi"] },
            { "id": "bt", "label": "BLUETOOTHD", "match": ["bluetoothd"], "what": "hci", "act": ["omarchy-restart-bluetooth"] }
        ];
    }
    function applySvc() {
        var procs = root.procRows;
        var rows = [];
        var defs = svcDef();
        for (var i = 0; i < defs.length; i++) {
            var d = defs[i];
            var state = "unknown", ev = "";
            if (d.id === "qs") {
                var qp = procHit(procs, d.match);
                state = "up";                  // self-evident: this UI renders
                ev = qp !== null ? "proc#" + qp.idx + " " + root.pctS(qp.cpu) : "self-rendered";
            } else if (d.id === "hc") {
                state = root.feedStale ? "down" : "up";
                ev = root.feedStale ? "no frames" : "gap " + (root.frameGapMs / 1000).toFixed(1) + "s";
            } else {
                var hit = procHit(procs, d.match);
                if (hit !== null) {
                    state = "up";
                    ev = "proc#" + hit.idx + " " + root.pctS(hit.cpu);
                } else {
                    state = "unknown";
                    ev = procs.length ? "not in top-" + procs.length : "no proc feed";
                }
            }
            var prev = _svcPrev[d.id];
            if (_seeded && prev !== undefined && prev !== state)
                pushEvt("SVC", d.label.toLowerCase() + " " + prev + " → " + state, state === "down" ? "alert" : (state === "up" ? "acc" : "warn"));
            _svcPrev[d.id] = state;
            rows.push({
                    "id": d.id,
                    "label": d.label,
                    "state": state,
                    "ev": ev,
                    "what": d.what,
                    "act": d.act !== undefined ? d.act : []
                });
        }
        svcRows = rows;
    }
    function procHit(procs, names) {
        if (names === null || procs === undefined)
            return null;
        for (var i = 0; i < procs.length; i++) {
            for (var j = 0; j < names.length; j++) {
                if (procs[i].name === names[j])
                    return {
                        "idx": i,
                        "cpu": procs[i].cpu
                    };
            }
        }
        return null;
    }

    // ============================ LAYOUT ==================================
    Row {
        anchors.fill: parent
        spacing: 12

        // ------------------------- LIVE FEED ------------------------------
        Rectangle {
            id: feedPane
            width: root.width - rail.width - 12
            height: root.height
            radius: Style.r.pane
            color: root.cInk
            border.color: root.cEdge
            border.width: 1

            Row {
                id: feedHead
                anchors.left: feedPane.left
                anchors.right: feedPane.right
                anchors.top: feedPane.top
                anchors.margins: 14
                anchors.bottomMargin: 0
                height: 20
                Text {
                    id: feedTitle
                    anchors.verticalCenter: feedHead.verticalCenter
                    font.family: root.fDisp
                    font.pixelSize: 10
                    font.letterSpacing: 3.0
                    color: root.cTxt
                    text: "LIVE<font color=\"" + root.cAcc + "\">FEED</font>"
                    textFormat: Text.RichText
                }
                Item {
                    width: Math.max(1, feedHead.width - feedTitle.implicitWidth - feedCapTxt.implicitWidth - 8)
                    height: 1
                }
                Text {
                    id: feedCapTxt
                    anchors.verticalCenter: feedHead.verticalCenter
                    font.family: root.fMono
                    font.pixelSize: 8
                    font.letterSpacing: 1.2
                    color: root.cFaint
                    text: {
                        var j = root.jrnlExit === 0 ? "jrnl ok" : (root.jrnlRuns > 0 ? "jrnl exit " + root.jrnlExit : "jrnl …");
                        return j + " · " + feedModel.count + "/" + root.feedCap + " · stats cadence";
                    }
                }
            }

            ListView {
                id: feed
                anchors.left: feedPane.left
                anchors.right: feedPane.right
                anchors.top: feedHead.bottom
                anchors.bottom: feedPane.bottom
                anchors.margins: 10
                anchors.topMargin: 8
                clip: true
                model: feedModel
                spacing: 0
                boundsBehavior: Flickable.StopAtBounds
                onCountChanged: {
                    if (atYBeginning)
                        positionViewAtBeginning();
                }
                delegate: Item {
                    id: frow
                    required property var ets
                    required property var etag
                    required property var etext
                    required property var etone
                    required property int en
                    required property int index
                    width: feed.width
                    height: 21
                    Row {
                        anchors.left: frow.left
                        anchors.right: frow.right
                        anchors.verticalCenter: frow.verticalCenter
                        spacing: 8
                        Text {
                            width: 64
                            font.family: root.fMono
                            font.pixelSize: 8
                            color: root.cFaint
                            text: frow.ets
                            elide: Text.ElideRight
                        }
                        Rectangle {
                            width: 62
                            height: 14
                            radius: Style.r.chip
                            anchors.verticalCenter: parent.verticalCenter
                            color: "transparent"
                            border.width: 1
                            border.color: Style.tone(root.toneCol(frow.etone), 0.5)
                            Text {
                                anchors.centerIn: parent
                                font.family: root.fMono
                                font.pixelSize: 7
                                font.letterSpacing: 0.8
                                color: root.toneCol(frow.etone)
                                text: String(frow.etag).toUpperCase()
                                elide: Text.ElideRight
                                width: parent.width - 4
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }
                        Text {
                            width: frow.width - 64 - 62 - 24
                            font.family: root.fMono
                            font.pixelSize: 9
                            color: root.toneCol(frow.etone)
                            elide: Text.ElideRight
                            text: String(frow.etext) + (frow.en > 1 ? "  ×" + frow.en : "")
                        }
                    }
                    Rectangle {
                        anchors.left: frow.left
                        anchors.right: frow.right
                        anchors.bottom: frow.bottom
                        height: 1
                        color: Qt.rgba(1, 1, 1, frow.index % 2 ? 0.015 : 0.03)
                    }
                }
                Text {
                    anchors.centerIn: parent
                    visible: feedModel.count === 0
                    font.family: root.fMono
                    font.pixelSize: 10
                    color: root.cFaint
                    text: "waiting for first collector frame…"
                }
            }
        }

        // --------------------------- RAIL ---------------------------------
        Column {
            id: rail
            width: Math.min(500, Math.round(root.width * 0.30))
            height: root.height
            spacing: 12

            // ------------- services: stats-derived up/down/unknown --------
            Rectangle {
                id: svcPane
                width: rail.width
                // sole survivor of the rail after D2 — takes the whole rail
                height: rail.height
                radius: Style.r.pane
                color: root.cInk
                border.color: root.cEdge
                border.width: 1
                Column {
                    anchors.fill: svcPane
                    anchors.margins: 12
                    spacing: 8
                    Text {
                        font.family: root.fMono
                        font.pixelSize: 8
                        font.letterSpacing: 1.7
                        color: root.cMute
                        text: "SERVICES · stats-derived"
                    }
                    Row {
                        width: svcPane.width - 24
                        height: 52
                        spacing: 6
                        Repeater {
                            model: root.svcRows
                            delegate: Rectangle {
                                id: svc
                                required property var modelData
                                readonly property var md: modelData
                                readonly property color stCol: md.state === "up" ? root.cAcc : md.state === "down" ? root.cAlert : root.cUnk
                                width: (svcPane.width - 24 - 4 * 6) / 5
                                height: 52
                                radius: Style.r.emboss
                                border.width: 1
                                border.color: Qt.rgba(0, 0, 0, 0.5)
                                gradient: Gradient {
                                    GradientStop {
                                        position: 0.0
                                        color: root.cRecessTop
                                    }
                                    GradientStop {
                                        position: 1.0
                                        color: root.cRecess
                                    }
                                }
                                // hover lights the rim; click restarts the service
                                // through its omarchy-restart-* helper (none for hud-collect)
                                Rectangle {
                                    anchors.fill: svc
                                    radius: Style.r.emboss
                                    color: svcMa.containsMouse && svc.md.act.length > 0 ? Style.c.azureWash : "transparent"
                                    border.width: 1
                                    border.color: svcMa.containsMouse && svc.md.act.length > 0 ? Style.tone(Style.c.accent2, 0.50) : "transparent"
                                }
                                MouseArea {
                                    id: svcMa
                                    anchors.fill: svc
                                    hoverEnabled: true
                                    enabled: svc.md.act.length > 0
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "ops"].concat(svc.md.act))
                                }
                                Column {
                                    anchors.fill: svc
                                    anchors.leftMargin: 7
                                    anchors.rightMargin: 5
                                    anchors.topMargin: 6
                                    spacing: 3
                                    Text {
                                        width: parent.width
                                        font.family: root.fMono
                                        font.pixelSize: 7
                                        font.letterSpacing: 0.6
                                        color: root.cMute
                                        elide: Text.ElideRight
                                        text: svc.md.label
                                    }
                                    Text {
                                        font.family: root.fDisp
                                        font.pixelSize: 10
                                        font.letterSpacing: 1.2
                                        color: svc.stCol
                                        text: svc.md.state.toUpperCase()
                                    }
                                    Text {
                                        width: parent.width
                                        font.family: root.fMono
                                        font.pixelSize: 7
                                        color: root.cFaint
                                        elide: Text.ElideRight
                                        text: svc.md.ev
                                    }
                                }
                            }
                        }
                    }

                    Text {
                        topPadding: 10
                        font.family: root.fMono
                        font.pixelSize: 8
                        font.letterSpacing: 1.7
                        color: root.cMute
                        text: "QUICK ACTIONS"
                    }
                    Column {
                        width: svcPane.width - 24
                        spacing: 4
                        ActionRow {
                            width: parent.width
                            glyph: Style.ico.broom
                            label: "CLEAR FEED"
                            hint: "LOCAL"
                            onTriggered: feedModel.clear()
                        }
                        ActionRow {
                            width: parent.width
                            glyph: Style.ico.term
                            label: "JOURNAL FOLLOW"
                            hint: "TUI"
                            onTriggered: Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "ops", "omarchy-launch-tui", "journalctl", "--user", "-f"])
                        }
                        ActionRow {
                            width: parent.width
                            glyph: Style.ico.chip
                            label: "SYSTEM MONITOR"
                            hint: "BTOP"
                            onTriggered: Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "ops", "omarchy-launch-tui", "btop"])
                        }
                        ActionRow {
                            width: parent.width
                            glyph: Style.ico.layers
                            label: "WORKBENCH"
                            hint: "HDMI"
                            onTriggered: Quickshell.execDetached(["hyprctl", "dispatch", "focusmonitor", "HDMI-A-3"])
                        }
                    }
                }
            }

        }
    }
}
