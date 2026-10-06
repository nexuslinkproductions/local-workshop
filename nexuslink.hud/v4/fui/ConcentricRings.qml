pragma ComponentBehavior: Bound

import QtQuick

// ConcentricRings.qml — N concentric rings around a centre hole (F2-style
// provider limit rings, M1 DP-2 hero). Per-ring model entries:
//   { label:"OCG", color:FuiTokens.ice,
//     value:0.66,          // 0..1 thin arc (share)   — null hides the arc
//     limit:1.0,           // 0..1 thick arc (limit used) — null = no feed
//     state:"alert",       // ok|warn|alert — colours the thick arc
//     dash:[2,3],          // optional dash pattern for the thin arc
//     valueText:"1.46B", reset:"≤5h" }   // shown in the inside label
// Labels hug the inside of each ring at the lower-left (angle table), the
// outer bezel carries a 0-100% graduated scale. Canvas repaints only when
// `model` or geometry changes. Centre content via the default property.
Item {
    id: root

    property var model: []
    property bool bezel: true         // outer 0-100% graduated scale
    property bool bezelLabels: true
    property string labelMode: "inside"   // "inside" | "none"
    property real innerHole: 0.34     // fraction of radius kept for centre
    property real ringPitch: 0        // 0 = auto from available space
    property real margin: 6
    property bool glow: true

    default property alias centerData: centre.data
    implicitWidth: 460
    implicitHeight: 460

    readonly property int ringCount: model.length
    readonly property real rOuter: Math.min(width, height) / 2 - margin - (bezel ? 26 : 0)
    readonly property real rInner: rOuter * innerHole
    readonly property real pitch: ringCount > 0
            ? (ringPitch > 0 ? ringPitch
                             : Math.max(13, (rOuter - rInner) / Math.max(1, ringCount)))
            : 0
    function ringR(i) { return rOuter - i * pitch; }

    Canvas {
        id: rings
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            ctx.globalAlpha = 1;
            var cx = width / 2, cy = height / 2;
            // ---- outer 0-100% bezel (major 10, minor 2, micro 0.5) --------
            if (root.bezel) {
                var rb = root.rOuter + 10;
                ctx.strokeStyle = FuiTokens.css(FuiTokens.ice);
                ctx.lineWidth = FuiTokens.lwHair;
                for (var i = 0; i <= 200; i++) {
                    var major = i % 20 === 0, minor = i % 4 === 0;
                    var L = major ? 9 : minor ? 6 : 3;
                    var a = i * 0.5 * 3.6;                    // 0.5% steps -> deg
                    var p0 = FuiTokens.pol(cx, cy, rb - L, a);
                    var p1 = FuiTokens.pol(cx, cy, rb, a);
                    ctx.globalAlpha = major ? 0.8 : minor ? 0.5 : 0.28;
                    ctx.beginPath(); ctx.moveTo(p0.x, p0.y); ctx.lineTo(p1.x, p1.y); ctx.stroke();
                }
                if (root.bezelLabels) {
                    ctx.globalAlpha = 0.9;
                    ctx.fillStyle = FuiTokens.css(FuiTokens.mute);
                    ctx.font = FuiTokens.px.micro + "px \"" + FuiTokens.mono + "\"";
                    ctx.textAlign = "center"; ctx.textBaseline = "middle";
                    for (var m = 0; m <= 10; m++) {
                        var pt = FuiTokens.pol(cx, cy, rb + 9, m * 36);
                        ctx.fillText(String(m * 10), pt.x, pt.y);
                    }
                }
                // acid zero index at the ring origin (m_lib: green index = 0%)
                var z0 = FuiTokens.pol(cx, cy, rb - 12, 0);
                var z1 = FuiTokens.pol(cx, cy, rb + 4, 0);
                ctx.globalAlpha = 1;
                ctx.strokeStyle = FuiTokens.css(FuiTokens.acid);
                ctx.beginPath(); ctx.moveTo(z0.x, z0.y); ctx.lineTo(z1.x, z1.y); ctx.stroke();
            }
            // ---- rings ----------------------------------------------------
            for (var k = 0; k < root.ringCount; k++) {
                var e = root.model[k] || {};
                var r = root.ringR(k);
                var col = e.color !== undefined ? e.color : FuiTokens.ice;
                // track
                ctx.globalAlpha = 1;
                ctx.setLineDash([]);
                ctx.strokeStyle = FuiTokens.css(FuiTokens.hair3);
                ctx.lineWidth = FuiTokens.lwHair;
                ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.stroke();
                // thin share arc 0 -> value
                if (e.value !== null && e.value !== undefined && isFinite(Number(e.value))) {
                    var vf = Math.min(1, Math.max(0, Number(e.value)));
                    ctx.strokeStyle = FuiTokens.css(col);
                    ctx.lineWidth = 1.4;
                    ctx.setLineDash(e.dash !== undefined ? e.dash : []);
                    ctx.beginPath();
                    ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + vf * Math.PI * 2);
                    ctx.stroke();
                    ctx.setLineDash([]);
                }
                // thick limit arc 0 -> limit (colour by state)
                if (e.limit !== null && e.limit !== undefined && isFinite(Number(e.limit))) {
                    var lf = Math.min(1, Math.max(0, Number(e.limit)));
                    var lc = e.state === "alert" ? FuiTokens.alert
                           : e.state === "warn" ? FuiTokens.warn
                           : col;
                    var rl = r + 5;         // thick arc rides just outside the share arc
                    if (root.glow) {
                        ctx.globalAlpha = FuiTokens.glowAlpha;
                        ctx.strokeStyle = FuiTokens.css(lc);
                        ctx.lineWidth = FuiTokens.lwGlow;
                        ctx.beginPath();
                        ctx.arc(cx, cy, rl, -Math.PI / 2, -Math.PI / 2 + lf * Math.PI * 2);
                        ctx.stroke();
                    }
                    ctx.globalAlpha = 1;
                    ctx.strokeStyle = FuiTokens.css(lc);
                    ctx.lineWidth = 3;
                    ctx.beginPath();
                    ctx.arc(cx, cy, rl, -Math.PI / 2, -Math.PI / 2 + lf * Math.PI * 2);
                    ctx.stroke();
                    var tip = FuiTokens.pol(cx, cy, rl, lf * 360);
                    ctx.fillStyle = FuiTokens.css(lc);
                    ctx.beginPath(); ctx.arc(tip.x, tip.y, 1.8, 0, Math.PI * 2); ctx.fill();
                }
            }
            ctx.setLineDash([]);
            ctx.globalAlpha = 1;
        }
        Connections {
            target: root
            function onModelChanged() { rings.requestPaint(); }
            function onBezelChanged() { rings.requestPaint(); }
            function onBezelLabelsChanged() { rings.requestPaint(); }
            function onInnerHoleChanged() { rings.requestPaint(); }
            function onRingPitchChanged() { rings.requestPaint(); }
            function onMarginChanged() { rings.requestPaint(); }
            function onGlowChanged() { rings.requestPaint(); }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }

    // inside ring labels (lower-left stack, one per ring)
    Repeater {
        model: root.labelMode === "inside" ? root.model : []
        delegate: Item {
            id: lbl
            required property int index
            required property var modelData
            readonly property real a: 195 + index * 17
            readonly property real r: root.ringR(index) - 14
            readonly property var p: FuiTokens.pol(root.width / 2, root.height / 2, Math.max(10, r), a)
            x: p.x - 150
            y: p.y - 8
            width: 150
            height: 16
            Row {
                spacing: 6
                anchors.right: parent.right
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 5; height: 5
                    color: lbl.modelData.state === "alert" ? FuiTokens.alert
                         : lbl.modelData.state === "warn" ? FuiTokens.warn
                         : (lbl.modelData.color !== undefined ? lbl.modelData.color : FuiTokens.ice)
                }
                Text {
                    text: String(lbl.modelData.label || "")
                    color: FuiTokens.white
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.tag
                    font.letterSpacing: FuiTokens.ls.tag
                }
                Text {
                    visible: text !== ""
                    text: String(lbl.modelData.valueText || "")
                    color: FuiTokens.dim
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.tag
                }
                Text {
                    visible: text !== ""
                    text: String(lbl.modelData.reset || "")
                    color: FuiTokens.mute
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.micro
                }
            }
        }
    }

    Item {
        id: centre
        anchors.centerIn: parent
        width: root.rInner * 2
        height: root.rInner * 2
    }
}
