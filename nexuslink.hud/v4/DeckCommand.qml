pragma ComponentBehavior: Bound

import QtQuick

// DeckCommand.qml — M1 DP-1 deck (crew / launch). Scaffold placeholder:
// proves the deck contract (stats, tokData, crew, screenName, shown,
// navigator, sayText/sayFlash) and shows a live SwimLane fed by crew.json.
// The builder replaces this layout; inputs and helpers are CONTRACT-fixed.
Item {
    id: root

    // ---- deck inputs (docs/m1/CONTRACT.md — do not rename) ---------------
    property var stats: ({})        // last hud-collect frame map
    property var tokData: ({})      // parsed tokens.json
    property var crew: ({})         // parsed crew.json
    property string screenName: "DP-1"
    property bool shown: true
    property var navigator: null
    property string sayText: ""
    property bool sayFlash: false

    function bots() { return crew && crew.bots ? crew.bots : []; }

    Rectangle { anchors.fill: parent; color: FuiTokens.bg }

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

    FuiFrame {
        anchors { fill: parent; margins: 24 }
        code: "M1-DP1"
        title: "Command · Crew / Launch"
        meta: root.screenName + " · placeholder"

        Column {
            anchors.fill: parent
            spacing: 10

            Text {
                text: "HERMES WORKSTATION · " + String(root.stats.host || root.screenName)
                color: FuiTokens.white
                font.family: FuiTokens.display
                font.pixelSize: FuiTokens.px.mid
                font.letterSpacing: FuiTokens.ls.title
            }
            Text {
                text: "scaffold — crew feed + stats wired; layout lands with the deck builder"
                color: FuiTokens.mute
                font.family: FuiTokens.mono
                font.pixelSize: FuiTokens.px.body
            }

            SwimLane {
                width: parent.width
                visible: root.bots().length > 0
                now: Date.now() / 1000
                windowEnd: now
                windowStart: now - 6 * 3600          // M1 CRW-TL window: 6 h
                labelWidth: 150
                metaWidth: 90
                rowHeight: 20
                model: {
                    var out = [];
                    var bs = root.bots();
                    for (var i = 0; i < bs.length; i++) {
                        var b = bs[i] || {};
                        out.push({
                            "label": String(b.name || "").toUpperCase(),
                            "sub": String(b.model || ""),
                            "color": FuiTokens.stateColor(b.state),
                            "events": b.events || [],
                            "meta": String(b.sessions_24h || 0) + " S24 · " + String(b.state || "")
                        });
                    }
                    return out;
                }
            }

            Text {
                visible: root.bots().length === 0
                text: "crew.json empty — python3 tokens/crew.py runs on the 60 s ledger cadence"
                color: FuiTokens.faint
                font.family: FuiTokens.mono
                font.pixelSize: FuiTokens.px.body
            }
        }
    }
}
