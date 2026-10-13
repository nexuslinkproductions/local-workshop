pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import "background" as Bg
import "command" as Cmd

// DeckCommand.qml — M1 DP-1 command deck. Panel layout follows
// src-M/gen_M1_dp1.py (2560x1440 reference) proportionally:
//   masthead (clock + ws-map + layout table)
//   CRW-TL swim-lane | CRW-OR orbit | QA rail
//   APP-DL dial | APP-RK ladder | APP-IX index
// Inputs are CONTRACT-fixed (stats, tokData, crew, screenName, shown,
// navigator, sayText/sayFlash). The only per-second element is the
// masthead clock; the monitors probe rides the ~1 Hz stats frame at 60 s.
Item {
    id: root

    // ---- deck inputs (docs/m1/CONTRACT.md — do not rename) ---------------
    property var stats: ({})
    property var tokData: ({})
    property var crew: ({})
    property string screenName: "DP-1"
    property bool shown: true
    property var navigator: null
    property string sayText: ""
    property bool sayFlash: false

    // ---- layout scale (design sheet 2560x1440) ---------------------------
    readonly property real mx: width * (40 / 2560)
    readonly property real gx: width * (24 / 2560)
    readonly property real my: height * (32 / 1440)
    readonly property real gy: height * (24 / 1440)
    readonly property real mastH: height * (184 / 1440)
    readonly property real row1H: height * (560 / 1440)
    readonly property real row1Y: my + mastH + gy
    readonly property real appY: row1Y + row1H + gy
    readonly property real appH: height * (584 / 1440)
    readonly property real qaX: width * (2304 / 2560)
    readonly property real qaW: width - qaX - mx
    readonly property real tlW: width * (1420 / 2560)
    readonly property real orW: qaX - gx - (mx + tlW + gx)
    readonly property real dlW: width * (1160 / 2560)
    readonly property real rkW: width * (516 / 2560)
    readonly property real ixX: mx + dlW + gx + rkW + gx
    readonly property real ixW: qaX - gx - ixX

    // ---- workspace rows from the stats frame (ws{i}_id/name/mon/wins) ----
    function has(k) { return stats[k] !== undefined && stats[k] !== ""; }
    function num(k) { return Number(stats[k]); }
    readonly property var wsRows: {
        var n = has("ws_count") ? Math.min(24, num("ws_count")) : 0;
        var out = [];
        for (var i = 0; i < n; i++)
            out.push({
                "id": has("ws" + i + "_id") ? num("ws" + i + "_id") : i + 1,
                "name": has("ws" + i + "_name") ? String(stats["ws" + i + "_name"])
                                                : String(num("ws" + i + "_id")),
                "mon": has("ws" + i + "_mon") ? String(stats["ws" + i + "_mon"]) : "",
                "wins": has("ws" + i + "_wins") ? Math.max(0, num("ws" + i + "_wins")) : -1
            });
        return out;
    }
    readonly property int winCount: has("win_count") ? Math.max(0, num("win_count")) : -1

    // ---- monitors probe: hyprctl -j monitors at 60 s, stats-frame driven --
    property var mons: []
    property double _monLast: -1
    onStatsChanged: {
        if (!shown) return;
        var t = Date.now();
        if (_monLast < 0 || t - _monLast >= 60000) {
            _monLast = t;
            if (!monProc.running)
                monProc.running = true;
        }
    }
    Process {
        id: monProc
        running: false
        command: ["hyprctl", "-j", "monitors"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    var raw = JSON.parse(text);
                    var out = [];
                    for (var i = 0; i < raw.length; i++)
                        out.push({ "name": String(raw[i].name),
                                   "x": Number(raw[i].x), "y": Number(raw[i].y),
                                   "width": Number(raw[i].width),
                                   "height": Number(raw[i].height) });
                    root.mons = out;
                } catch (e) { /* keep last good frame */ }
            }
        }
    }

    // ---- app catalogue ----------------------------------------------------
    Cmd.AppModel { id: appModel }

    Rectangle { anchors.fill: parent; color: FuiTokens.bg }

    Bg.PixelLogo {                  // knot watermark behind grid + frames
        width: Math.min(root.width * 0.45, root.height * 0.72)
        height: width
        x: root.width * 0.5 - width / 2
        y: root.height * 0.48 - height / 2
        shown: root.shown
    }

    Canvas {                        // 16/128 px schematic grid (paint once per size)
        id: grid
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            ctx.globalAlpha = 1;
            ctx.lineWidth = 1;
            for (var x = 0; x <= width; x += FuiTokens.gridMajor) {
                ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(FuiTokens.ice, 0.045));
                ctx.beginPath(); ctx.moveTo(x + 0.5, 0); ctx.lineTo(x + 0.5, height); ctx.stroke();
            }
            for (var y = 0; y <= height; y += FuiTokens.gridMajor) {
                ctx.beginPath(); ctx.moveTo(0, y + 0.5); ctx.lineTo(width, y + 0.5); ctx.stroke();
            }
            ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(FuiTokens.ice, 0.018));
            for (x = 0; x <= width; x += FuiTokens.gridMinor) {
                ctx.beginPath(); ctx.moveTo(x + 0.5, 0); ctx.lineTo(x + 0.5, height); ctx.stroke();
            }
            for (y = 0; y <= height; y += FuiTokens.gridMinor) {
                ctx.beginPath(); ctx.moveTo(0, y + 0.5); ctx.lineTo(width, y + 0.5); ctx.stroke();
            }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }

    // ================================================== masthead (40,32) ==
    FuiFrame {
        x: root.mx; y: root.my
        width: root.width - 2 * root.mx
        height: root.mastH
        Cmd.MastHead {
            anchors { fill: parent; margins: 4 }
            stats: root.stats
            mons: root.mons
            wsRows: root.wsRows
            winCount: root.winCount
            screenName: root.screenName
            shown: root.shown
        }
    }

    // ================================================== CRW-TL (40,240) ===
    FuiFrame {
        x: root.mx; y: root.row1Y
        width: root.tlW; height: root.row1H
        code: "CRW-TL"
        title: "Crew activity"
        meta: "src: crew.json · " + (root.crew.generated
                                     ? FuiTokens.fmtHm(root.crew.generated)
                                     : FuiTokens.unknownGlyph)
        Cmd.CrewSwimLane {
            anchors { fill: parent; margins: 2 }
            crew: root.crew
            shown: root.shown
        }
    }

    // ================================================== CRW-OR (1484,240) =
    FuiFrame {
        x: root.mx + root.tlW + root.gx; y: root.row1Y
        width: root.orW; height: root.row1H
        code: "CRW-OR"
        title: "Models"
        meta: "src: crew.json + tokens.json · " + (root.crew.generated
                                                   ? FuiTokens.fmtHm(root.crew.generated)
                                                   : FuiTokens.unknownGlyph)
        Cmd.CrewOrbit {
            anchors { fill: parent; margins: 2 }
            crew: root.crew
            tokData: root.tokData
        }
    }

    // ================================================== APP-DL (40,824) ===
    FuiFrame {
        x: root.mx; y: root.appY
        width: root.dlW; height: root.appH
        code: "APP-DL"
        title: "Launcher"
        meta: "src: /usr/share/applications · appuse.json"
        live: true                        // the deck's one live frame: launcher
        Cmd.AppDial {
            anchors { fill: parent; margins: 2 }
            apps: appModel.apps
            uses: appModel.counts
            totalUse: appModel.totalLaunches
            pinnedApps: appModel.pinned
            onLaunch: function (a) { appModel.launchEntry(a); }
        }
    }

    // ================================================== APP-RK (1224,824) =
    FuiFrame {
        x: root.mx + root.dlW + root.gx; y: root.appY
        width: root.rkW; height: root.appH
        code: "APP-RK"
        title: "Most used"
        meta: "src: appuse.json"
        Cmd.AppLadder {
            anchors { fill: parent; margins: 2 }
            apps: appModel.apps
            uses: appModel.counts
            totalUse: appModel.totalLaunches
            pinned: appModel.pinned
            onLaunch: function (a) { appModel.launchEntry(a); }
        }
    }

    // ================================================== APP-IX (1764,824) =
    FuiFrame {
        x: root.ixX; y: root.appY
        width: root.ixW; height: root.appH
        code: "APP-IX"
        title: "Apps"
        meta: "src: .desktop Categories"
        Cmd.AppIndex {
            anchors { fill: parent; margins: 2 }
            apps: appModel.apps
            uses: appModel.counts
            pinnedCount: 16
            onLaunch: function (a) { appModel.launchEntry(a); }
        }
    }

    // ================================================== QA (2304,240) =====
    FuiFrame {
        x: root.qaX; y: root.row1Y
        width: root.qaW
        height: root.row1H + root.gy + root.appH
        code: "QA"
        title: "Actions"
        meta: "x" + qa.keys.length
        Cmd.ActionRail {
            id: qa
            anchors { fill: parent; margins: 2 }
        }
    }

}
