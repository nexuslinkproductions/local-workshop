pragma ComponentBehavior: Bound

import QtQuick

// ConcentricRings.qml — N concentric rings around a centre hole (F2-style
// provider limit rings, M1 DP-2 hero). Per-ring model entries:
//   { label:"OpenCode Go", color:FuiTokens.ice,
//     value:0.66,          // 0..1 thin arc (share)   — null hides the arc
//     limit:1.0,           // 0..1 thick arc (limit used) — null = no feed,
//                          // nothing drawn
//     state:"alert",       // ok|warn|alert — colours the thick arc
//     dash:[2,3],          // optional dash pattern for the thin arc
//     valueText:"1.46B", reset:"≤5h" }   // shown in the label
// labelMode "inside"  — labels float in the mid-gap between rings at the
//     lower-left (angle table), each tied to its ring by a radial nub.
// labelMode "outside" — a `labelReserve`-wide column on the left holds one
//     two-line label per ring, clear of the bezel; a hairline leader runs
//     from the ring edge to each label's anchor.
// The outer bezel carries a 0-100 graduated scale with the unit printed on
// it ("0-100 %" at the zero index). Canvas repaints only when `model` or
// geometry changes. Centre content via the default property.
Item {
    id: root

    property var model: []
    property bool bezel: true         // outer graduated scale
    property bool bezelLabels: true
    property string labelMode: "inside"   // "inside" | "outside" | "none"
    property real labelReserve: 0     // left column width (outside mode)
    property real innerHole: 0.34     // fraction of radius kept for centre
    property real ringPitch: 0        // 0 = auto from available space
    property real margin: 6
    property bool glow: true

    default property alias centerData: centre.data
    implicitWidth: 460
    implicitHeight: 460

    // the dial's centre — with outside labels the circle sits right of the
    // label column, so cx is not simply width/2
    readonly property real cx: labelMode === "outside"
            ? labelReserve + Math.max(0, width - labelReserve) / 2
            : width / 2
    readonly property real cy: height / 2
    readonly property real rOuter: Math.min(
            width - (labelMode === "outside" ? labelReserve : 0), height) / 2
            - margin - (bezel ? 26 : 0)
    readonly property real rInner: rOuter * innerHole
    readonly property int ringCount: model.length
    readonly property real pitch: ringCount > 0
            ? (ringPitch > 0 ? ringPitch
                             : Math.max(13, (rOuter - rInner) / Math.max(1, ringCount)))
            : 0
    function ringR(i) { return rOuter - i * pitch; }

    // ---- outside-label geometry (shared by canvas leaders + repeater) ----
    readonly property real labelH: 32
    function labelCY(i) {       // vertical centre of label row i
        return cy - ringCount * labelH / 2 + i * labelH + labelH / 2;
    }
    function labelAnchorX() { return labelReserve - 8; }
    function leaderDeg(i) {     // angle pointing at the label's anchor
        var dx = labelAnchorX() - cx, dy = labelCY(i) - cy;
        return Math.atan2(dy, dx) * 180 / Math.PI + 90;
    }

    Canvas {
        id: rings
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            ctx.globalAlpha = 1;
            if (width <= 0 || height <= 0 || !(root.rOuter > 0))
                return;
            var cx = root.cx, cy = root.cy;
            // ---- outer graduated bezel (major 10, minor 2, micro 0.5) ----
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
                    // 0 and 100 share the top index — print the scale's unit
                    // there once instead of two colliding numerals
                    for (var m = 1; m <= 9; m++) {
                        var pt = FuiTokens.pol(cx, cy, rb + 9, m * 36);
                        ctx.fillText(String(m * 10), pt.x, pt.y);
                    }
                    ctx.fillText("0-100 %", cx, cy - rb - 9);
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
                if (!(r > 0))
                    continue;
                var col = e.color !== undefined ? e.color : FuiTokens.ice;
                // track
                ctx.globalAlpha = 1;
                ctx.setLineDash([]);
                ctx.strokeStyle = FuiTokens.css(FuiTokens.hair3);
                ctx.lineWidth = FuiTokens.lwHair;
                ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.stroke();
                // thin share arc 0 -> value, drawn ON the track
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
                // thick limit arc 0 -> limit (colour by state); only when a
                // limits feed exists — a null limit draws nothing
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
            if (root.labelMode === "inside") {
                // label nubs: short radial ticks from each ring into its
                // label's mid-gap lane (same angle table as the repeater)
                ctx.lineWidth = 1;
                ctx.strokeStyle = FuiTokens.css(FuiTokens.tone(FuiTokens.ice, 0.35));
                for (var li = 0; li < root.ringCount; li++) {
                    var la = 195 + li * 17;
                    var n0 = FuiTokens.pol(cx, cy, root.ringR(li) - 3, la);
                    var n1 = FuiTokens.pol(cx, cy,
                                 root.ringR(li) - Math.max(16, root.pitch / 2) + 3, la);
                    ctx.beginPath(); ctx.moveTo(n0.x, n0.y); ctx.lineTo(n1.x, n1.y); ctx.stroke();
                }
            } else if (root.labelMode === "outside") {
                // leader lines: ring edge -> past the bezel -> label anchor
                ctx.lineWidth = 1;
                for (var gi = 0; gi < root.ringCount; gi++) {
                    var md = root.model[gi] || {};
                    var lc2 = md.state === "alert" ? FuiTokens.alert
                            : md.state === "warn" ? FuiTokens.warn
                            : (md.color !== undefined ? md.color : FuiTokens.ice);
                    var deg = root.leaderDeg(gi);
                    var s = FuiTokens.pol(cx, cy, root.ringR(gi) - 2, deg);
                    var mpt = FuiTokens.pol(cx, cy, root.rOuter + 22, deg);
                    ctx.globalAlpha = 0.55;
                    ctx.strokeStyle = FuiTokens.css(lc2);
                    ctx.beginPath(); ctx.moveTo(s.x, s.y); ctx.lineTo(mpt.x, mpt.y);
                    ctx.lineTo(root.labelAnchorX(), root.labelCY(gi)); ctx.stroke();
                    // small dot at the anchor
                    ctx.fillStyle = FuiTokens.css(lc2);
                    ctx.beginPath();
                    ctx.arc(root.labelAnchorX(), root.labelCY(gi), 1.6, 0, Math.PI * 2);
                    ctx.fill();
                }
            }
            ctx.globalAlpha = 1;
        }
        Connections {
            target: root
            function onModelChanged() { rings.requestPaint(); }
            function onBezelChanged() { rings.requestPaint(); }
            function onBezelLabelsChanged() { rings.requestPaint(); }
            function onLabelModeChanged() { rings.requestPaint(); }
            function onLabelReserveChanged() { rings.requestPaint(); }
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
            readonly property real r: root.ringR(index) - Math.max(16, root.pitch / 2)
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

    // outside ring labels — two-line blocks in the reserved left column,
    // each aimed at by its leader line; clear of bezel ticks and numerals
    Repeater {
        model: root.labelMode === "outside" ? root.model : []
        delegate: Item {
            id: olbl
            required property int index
            required property var modelData
            x: 0
            y: root.labelCY(index) - root.labelH / 2
            width: Math.max(40, root.labelAnchorX() - 8)
            height: root.labelH
            Column {
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                spacing: 1
                Row {
                    anchors.right: parent.right
                    spacing: 6
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 5; height: 5
                        color: olbl.modelData.state === "alert" ? FuiTokens.alert
                             : olbl.modelData.state === "warn" ? FuiTokens.warn
                             : (olbl.modelData.color !== undefined ? olbl.modelData.color : FuiTokens.ice)
                    }
                    Text {
                        text: String(olbl.modelData.label || "")
                        color: FuiTokens.white
                        font.family: FuiTokens.mono
                        font.pixelSize: FuiTokens.px.tag
                        font.letterSpacing: FuiTokens.ls.tag
                    }
                }
                Text {
                    anchors.right: parent.right
                    visible: text !== ""
                    text: String(olbl.modelData.valueText || "")
                          + (olbl.modelData.reset ? " · " + String(olbl.modelData.reset) : "")
                    color: FuiTokens.dim
                    font.family: FuiTokens.mono
                    font.pixelSize: FuiTokens.px.micro
                }
            }
        }
    }

    Item {
        id: centre
        x: root.cx - root.rInner
        y: root.cy - root.rInner
        width: root.rInner * 2
        height: root.rInner * 2
    }
}
