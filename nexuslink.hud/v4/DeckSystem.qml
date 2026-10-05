pragma ComponentBehavior: Bound

import QtQuick

// DeckSystem.qml — M1 HDMI-A-3 deck (devices / system). Scaffold
// placeholder: a TickRing fed by stats cpu + a HairBar fed by mem — proves
// the deck contract (stats, tokData, crew, screenName, shown). The builder
// replaces this layout.
Item {
    id: root

    // ---- deck inputs (docs/m1/CONTRACT.md — do not rename) ---------------
    property var stats: ({})
    property var tokData: ({})
    property var crew: ({})
    property string screenName: "HDMI-A-3"
    property bool shown: true
    property var navigator: null
    property string sayText: ""
    property bool sayFlash: false

    function num(v) { var n = Number(v); return isFinite(n) ? n : 0; }
    readonly property real memFrac: {
        var t = num(stats.mem_total_kb);
        return t > 0 ? (t - num(stats.mem_avail_kb)) / t : -1;
    }

    Rectangle { anchors.fill: parent; color: FuiTokens.bg }

    FuiFrame {
        anchors { fill: parent; margins: 24 }
        code: "M1-HDMI-03"
        title: "Devices · System"
        meta: root.screenName + " · placeholder"

        Column {
            anchors.fill: parent
            spacing: 14

            Text {
                text: "SYSTEM TELEMETRY"
                color: FuiTokens.dim
                font.family: FuiTokens.display
                font.pixelSize: FuiTokens.px.code
                font.letterSpacing: FuiTokens.ls.label
            }
            Text {
                text: "scaffold — gauges read the live stats frame; topology plates and routing matrix land with the deck builder"
                color: FuiTokens.mute
                font.family: FuiTokens.mono
                font.pixelSize: FuiTokens.px.body
            }

            Row {
                spacing: 24
                TickRing {
                    width: 190; height: 190
                    startAngle: -135; sweep: 270
                    ticks: 24; majorEvery: 6
                    minimum: 0; maximum: 120
                    value: root.stats.cpu_temp !== undefined ? root.num(root.stats.cpu_temp) : null
                    unit: "°C TCTL"
                    label: "CPU"
                    warnAt: 95
                    minMark: 20; maxMark: 95
                }
                TickRing {
                    width: 190; height: 190
                    startAngle: -135; sweep: 270
                    ticks: 24; majorEvery: 6
                    minimum: 0; maximum: 100
                    value: root.memFrac >= 0 ? Math.round(root.memFrac * 100) : null
                    unit: "% USED"
                    label: "MEM"
                }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    Text {
                        text: "UPTIME " + String(root.stats.uptime_s !== undefined
                              ? Math.round(root.num(root.stats.uptime_s) / 3600) + "h" : FuiTokens.unknownGlyph)
                             + " · LOAD " + String(root.stats.load1 !== undefined ? root.stats.load1 : FuiTokens.unknownGlyph)
                        color: FuiTokens.dim
                        font.family: FuiTokens.mono
                        font.pixelSize: FuiTokens.px.body
                    }
                    Text {
                        text: "mem used / total"
                        color: FuiTokens.faint
                        font.family: FuiTokens.mono
                        font.pixelSize: FuiTokens.px.micro
                    }
                    HairBar {
                        width: 260
                        value: root.memFrac >= 0 ? root.memFrac * 100 : null
                        maximum: 100
                        minMark: 0
                        maxMark: 100
                    }
                }
            }
        }
    }
}
