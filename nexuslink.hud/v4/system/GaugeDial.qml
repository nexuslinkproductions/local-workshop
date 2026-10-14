pragma ComponentBehavior: Bound

import QtQuick
import ".."

// GaugeDial.qml — the M1 sheet gauge() as a Canvas: outer tick scale with
// major labels, an alert zone arc on the rim, a glow bed + value arc on the
// inner ring, labeled marker whiskers, and value/unit/title/sub centre text.
// Paints only when an input or the size changes; never animates.
Item {
    id: root

    property var value: null          // null -> arc hidden, centre reads "—"
    property real minimum: 0
    property real maximum: 100
    property real startAngle: -120    // 0 deg = top, clockwise
    property real sweep: 240
    property var majors: []           // major tick labels, evenly spaced
    property var redFrom: null        // alert zone on the rim (value units)
    property var redTo: null
    property var markers: []          // [{v, t}] whisker + small label
    property color color: FuiTokens.ice
    property string unit: ""
    property string title: ""
    property string sub: ""
    property string valueText: ""     // override for the centre readout
    property int valuePx: 26

    implicitWidth: 210
    implicitHeight: 210

    function ang(v) {
        var f = Math.min(1, Math.max(0, (v - minimum) / (maximum - minimum)));
        return startAngle + sweep * f;
    }
    function rad(d) { return (d - 90) * Math.PI / 180; }

    Canvas {
        id: cv
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            var w = width, h = height;
            var cx = w / 2, cy = h / 2 - h * 0.06;
            var lbl = root.majors.length > 0 ? 14 : 0;
            var r = Math.min(w, h) / 2 - lbl - 10;
            if (r < 12)
                r = 12;
            var ice = FuiTokens.css(FuiTokens.ice);
            ctx.lineWidth = FuiTokens.lwHair;

            function arc(rr, a0, a1, col, lw, alpha) {
                if (a1 - a0 >= 359.9)
                    a1 = a0 + 359.9;
                ctx.globalAlpha = alpha;
                ctx.strokeStyle = FuiTokens.css(col);
                ctx.lineWidth = lw;
                ctx.beginPath();
                ctx.arc(cx, cy, rr, root.rad(a0), root.rad(a1));
                ctx.stroke();
                ctx.globalAlpha = 1;
                ctx.lineWidth = FuiTokens.lwHair;
            }

            // scale track + tick scale
            arc(r, root.startAngle, root.startAngle + root.sweep, FuiTokens.ice, FuiTokens.lwHair, 0.3);
            var n = Math.max(1, (root.majors.length - 1) * 5);
            for (var i = 0; i <= n; i++) {
                var major = i % 5 === 0;
                var a = root.startAngle + root.sweep * i / n;
                var L = major ? 9 : 4;
                var p0 = FuiTokens.pol(cx, cy, r + 3, a);
                var p1 = FuiTokens.pol(cx, cy, r + 3 + L, a);
                ctx.globalAlpha = major ? 0.72 : 0.42;
                ctx.strokeStyle = ice;
                ctx.beginPath(); ctx.moveTo(p0.x, p0.y); ctx.lineTo(p1.x, p1.y); ctx.stroke();
                if (major && root.majors.length > 0) {
                    var k = i / 5;
                    if (k < root.majors.length) {
                        var pt = FuiTokens.pol(cx, cy, r + 3 + 9 + 11, a);
                        // keep label centres inside the item — the ±120° end
                        // labels otherwise clip the cell's inner border
                        pt.x = Math.min(Math.max(pt.x, 14), w - 14);
                        pt.y = Math.min(Math.max(pt.y, 8), h - 8);
                        ctx.globalAlpha = 0.9;
                        ctx.fillStyle = FuiTokens.css(FuiTokens.mute);
                        ctx.font = FuiTokens.px.body + "px \"" + FuiTokens.mono + "\"";
                        ctx.textAlign = "center"; ctx.textBaseline = "middle";
                        ctx.fillText(String(root.majors[k]), pt.x, pt.y);
                    }
                }
            }
            ctx.globalAlpha = 1;

            // alert zone on the rim
            if (root.redFrom !== null && root.redTo !== null
                    && isFinite(Number(root.redFrom)) && isFinite(Number(root.redTo)))
                arc(r + 6, root.ang(Number(root.redFrom)), root.ang(Number(root.redTo)),
                    FuiTokens.alert, 3, 0.85);

            // inner glow bed + value arc
            arc(r - 10, root.startAngle, root.startAngle + root.sweep, FuiTokens.ice, 8, 0.05);
            if (root.value !== null && isFinite(Number(root.value))) {
                var a1 = root.ang(Number(root.value));
                arc(r - 10, root.startAngle, a1, root.color, FuiTokens.lwGlow, FuiTokens.glowAlpha);
                arc(r - 10, root.startAngle, a1, root.color, FuiTokens.lwArc, 1);
            }

            // marker whiskers + labels
            for (var mi = 0; mi < root.markers.length; mi++) {
                var mk = root.markers[mi];
                if (mk === null || mk === undefined || !isFinite(Number(mk.v)))
                    continue;
                var ma = root.ang(Number(mk.v));
                var q0 = FuiTokens.pol(cx, cy, r - 15, ma);
                var q1 = FuiTokens.pol(cx, cy, r - 2, ma);
                ctx.strokeStyle = FuiTokens.css(FuiTokens.white);
                ctx.lineWidth = 1.5;
                ctx.beginPath(); ctx.moveTo(q0.x, q0.y); ctx.lineTo(q1.x, q1.y); ctx.stroke();
                ctx.lineWidth = FuiTokens.lwHair;
                if (mk.t !== undefined && mk.t !== "") {
                    var tp = FuiTokens.pol(cx, cy, r - 25, ma);
                    ctx.fillStyle = FuiTokens.css(FuiTokens.white);
                    ctx.font = FuiTokens.px.body + "px \"" + FuiTokens.mono + "\"";
                    ctx.textAlign = "center"; ctx.textBaseline = "middle";
                    ctx.fillText(String(mk.t), tp.x, tp.y);
                }
            }

            // centre readout
            ctx.textAlign = "center"; ctx.textBaseline = "alphabetic";
            ctx.fillStyle = FuiTokens.css(FuiTokens.white);
            ctx.font = root.valuePx + "px \"" + FuiTokens.mono + "\"";
            var vt = root.valueText !== "" ? root.valueText
                     : (root.value !== null && isFinite(Number(root.value))
                        ? String(Number(root.value)) : FuiTokens.unknownGlyph);
            ctx.fillText(vt, cx, cy + 6);
            if (root.unit !== "") {
                ctx.fillStyle = FuiTokens.css(FuiTokens.mute);
                ctx.font = FuiTokens.px.body + "px \"" + FuiTokens.mono + "\"";
                ctx.fillText(root.unit, cx, cy + 26);
            }
            if (root.title !== "") {
                ctx.fillStyle = FuiTokens.css(FuiTokens.white);
                ctx.font = FuiTokens.px.body + "px \"" + FuiTokens.display + "\"";
                try { ctx.letterSpacing = "3px"; } catch (e) {}
                ctx.fillText(root.title.toUpperCase(), cx, Math.min(cy + 58, h - 24));
            }
            if (root.sub !== "") {
                ctx.fillStyle = FuiTokens.css(FuiTokens.mute);
                ctx.font = FuiTokens.px.body + "px \"" + FuiTokens.mono + "\"";
                ctx.fillText(root.sub, cx, Math.min(cy + 76, h - 12));
            }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections {
            target: root
            function onValueChanged() { cv.requestPaint(); }
            function onMinimumChanged() { cv.requestPaint(); }
            function onMaximumChanged() { cv.requestPaint(); }
            function onStartAngleChanged() { cv.requestPaint(); }
            function onSweepChanged() { cv.requestPaint(); }
            function onMajorsChanged() { cv.requestPaint(); }
            function onRedFromChanged() { cv.requestPaint(); }
            function onRedToChanged() { cv.requestPaint(); }
            function onMarkersChanged() { cv.requestPaint(); }
            function onColorChanged() { cv.requestPaint(); }
            function onUnitChanged() { cv.requestPaint(); }
            function onTitleChanged() { cv.requestPaint(); }
            function onSubChanged() { cv.requestPaint(); }
            function onValueTextChanged() { cv.requestPaint(); }
            function onValuePxChanged() { cv.requestPaint(); }
        }
    }
}
