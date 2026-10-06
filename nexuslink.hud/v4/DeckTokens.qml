pragma ComponentBehavior: Bound

import QtQuick

// DeckTokens.qml — M1 DP-2 deck (tokens / limits). Scaffold placeholder:
// a ConcentricRings hero fed by tokData.providers week figures, plus the
// ledger stamp — proves the deck contract (stats, tokData, crew,
// screenName, shown). The builder replaces this layout.
Item {
    id: root

    // ---- deck inputs (docs/m1/CONTRACT.md — do not rename) ---------------
    property var stats: ({})
    property var tokData: ({})
    property var crew: ({})
    property string screenName: "DP-2"
    property bool shown: true
    property var navigator: null
    property string sayText: ""
    property bool sayFlash: false

    // week in+out per provider -> ring model (scaffold ordering: share desc)
    function rings() {
        var p = tokData && tokData.providers ? tokData.providers : {};
        var list = [];
        var sum = 0;
        for (var k in p) {
            var w = (p[k] && p[k].week) || {};
            var tot = (w["in"] || 0) + (w["out"] || 0);
            if (tot > 0) { list.push({ "id": k, "tot": tot }); sum += tot; }
        }
        list.sort(function (a, b) { return b.tot - a.tot; });
        var cols = [FuiTokens.ice, FuiTokens.white, FuiTokens.azure, FuiTokens.dim];
        var out = [];
        for (var i = 0; i < list.length && i < 4; i++) {
            var e = list[i];
            out.push({
                "label": String(e.id).toUpperCase(),
                "valueText": FuiTokens.fmtTok(e.tot),
                "value": sum > 0 ? e.tot / sum : 0,
                "limit": null,
                "color": cols[i % cols.length]
            });
        }
        return { "model": out, "sum": sum };
    }

    Rectangle { anchors.fill: parent; color: FuiTokens.bg }

    FuiFrame {
        anchors { fill: parent; margins: 24 }
        code: "M1-DP2"
        title: "Tokens · Limits"
        meta: root.screenName + " · " + String(root.tokData && root.tokData.updated ? root.tokData.updated : "no ledger")

        Row {
            anchors.fill: parent
            spacing: 24

            ConcentricRings {
                width: Math.min(parent.height, 520)
                height: parent.height
                bezel: true
                model: root.rings().model
                Text {
                    anchors.centerIn: parent
                    text: FuiTokens.fmtTok(root.rings().sum)
                    color: FuiTokens.white
                    font.family: FuiTokens.display
                    font.pixelSize: FuiTokens.px.hero
                }
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 10
                width: parent.width - parent.spacing - Math.min(parent.height, 520)
                Text {
                    text: "TOKEN FLUX / WEEK"
                    color: FuiTokens.dim
                    font.family: FuiTokens.display
                    font.pixelSize: FuiTokens.px.code
                    font.letterSpacing: FuiTokens.ls.label
                }
                Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: "scaffold — rings show week in+out share from tokens.json; limit rings, skyline and ledger land with the deck builder"
                    color: FuiTokens.mute
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.body
                }
                Sparkline {
                    width: parent.width
                    height: 48
                    values: {
                        var h = root.tokData && root.tokData.history ? root.tokData.history : {};
                        var acc = {};
                        for (var k in h) {
                            var rows = h[k] || [];
                            for (var i = 0; i < rows.length; i++) {
                                var d = rows[i] || {};
                                acc[d.d] = (acc[d.d] || 0) + (d["in"] || 0) + (d["out"] || 0);
                            }
                        }
                        var days = [];
                        for (var key in acc) days.push(key);
                        days.sort();
                        var last = days.slice(-30);
                        var out = [];
                        for (i = 0; i < last.length; i++) out.push(acc[last[i]]);
                        return out;
                    }
                }
                Text {
                    text: "30d Σ tokens (history, all providers)"
                    color: FuiTokens.faint
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.micro
                }
            }
        }
    }
}
