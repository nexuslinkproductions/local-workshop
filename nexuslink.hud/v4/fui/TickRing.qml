pragma ComponentBehavior: Bound

import QtQuick

// TickRing.qml — ring gauge with a graduated tick bezel, value arc and
// optional min/max whiskers + redline (M1 instrument gauge).
// Angles follow m_lib convention: 0 deg = 12 o'clock, clockwise.
// startAngle/sweep describe the scale arc; e.g. -180/180 = half ring,
// -135/270 = classic gauge, 0/360 = full bezel.
// One Canvas paints all linework on property change only — never per frame.
Item {
    id: root

    property var value: null        // null -> arc hidden, centre reads "—"
    property real minimum: 0
    property real maximum: 100
    property real startAngle: -135  // degrees, 0 = top
    property real sweep: 270
    property int ticks: 48          // minor divisions
    property int majorEvery: 6
    property color color: FuiTokens.ice
    property bool live: false       // value arc paints acid
    property bool glow: true        // wide low-alpha under-stroke (static, painted)
    property var minMark: null      // whisker positions in value units
    property var maxMark: null
    property var warnAt: null       // redline tick position
    property bool tickLabels: true
    property int labelDecimals: 0
    property string unit: ""
    property string label: ""
    property int valuePx: 30
    property real margin: 4         // outer clearance for tick labels

    implicitWidth: 160
    implicitHeight: 160

    readonly property real frac: {
        var n = Number(root.value);
        if (root.value === null || !isFinite(n) || root.maximum <= root.minimum)
            return -1;
        return Math.min(1, Math.max(0, (n - root.minimum) / (root.maximum - root.minimum)));
    }

    function ang(v) {   // value -> degrees on the scale
        var f = Math.min(1, Math.max(0, (v - root.minimum) / (root.maximum - root.minimum)));
        return root.startAngle + root.sweep * f;
    }

    Canvas {
        id: ring
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            ctx.globalAlpha = 1;
            var w = width, h = height;
            var cx = w / 2, cy = h / 2;
            var lbl = root.tickLabels ? 13 : 0;
            var rOut = Math.min(w, h) / 2 - root.margin - lbl;
            var l1 = 4, l2 = 9;
            var rArc = rOut - l2 - 4;
            var tickCol = FuiTokens.css(FuiTokens.ice);
            // ---- bezel ticks ---------------------------------------------
            ctx.lineWidth = FuiTokens.lwHair;
            for (var i = 0; i <= root.ticks; i++) {
                var major = root.ticks > 0 && i % root.majorEvery === 0;
                var a = root.startAngle + root.sweep * i / Math.max(1, root.ticks);
                var p0 = FuiTokens.pol(cx, cy, rOut - (major ? l2 : l1), a);
                var p1 = FuiTokens.pol(cx, cy, rOut, a);
                ctx.globalAlpha = major ? 0.8 : 0.5;
                ctx.strokeStyle = tickCol;
                ctx.beginPath(); ctx.moveTo(p0.x, p0.y); ctx.lineTo(p1.x, p1.y); ctx.stroke();
                if (major && root.tickLabels) {
                    var v = root.minimum + (root.maximum - root.minimum) * i / root.ticks;
                    var pt = FuiTokens.pol(cx, cy, rOut + lbl - 2, a);
                    ctx.globalAlpha = 0.9;
                    ctx.fillStyle = FuiTokens.css(FuiTokens.mute);
                    ctx.font = FuiTokens.px.micro + "px \"" + FuiTokens.mono + "\"";
                    ctx.textAlign = "center"; ctx.textBaseline = "middle";
                    ctx.fillText(v.toFixed(root.labelDecimals), pt.x, pt.y);
                }
            }
            ctx.globalAlpha = 1;
            // ---- scale track ---------------------------------------------
            ctx.strokeStyle = FuiTokens.css(FuiTokens.hair3);
            ctx.lineWidth = FuiTokens.lwHair;
            ctx.beginPath();
            ctx.arc(cx, cy, rArc,
                    (root.startAngle - 90) * Math.PI / 180,
                    (root.startAngle + root.sweep - 90) * Math.PI / 180);
            ctx.stroke();
            // ---- min / max whiskers --------------------------------------
            function whisk(v, col) {
                var a2 = root.ang(v);
                var q0 = FuiTokens.pol(cx, cy, rArc - 5, a2);
                var q1 = FuiTokens.pol(cx, cy, rArc + 5, a2);
                ctx.strokeStyle = FuiTokens.css(col);
                ctx.lineWidth = FuiTokens.lwHair;
                ctx.beginPath(); ctx.moveTo(q0.x, q0.y); ctx.lineTo(q1.x, q1.y); ctx.stroke();
            }
            if (root.minMark !== null && isFinite(Number(root.minMark))) whisk(Number(root.minMark), FuiTokens.dim);
            if (root.maxMark !== null && isFinite(Number(root.maxMark))) whisk(Number(root.maxMark), FuiTokens.dim);
            if (root.warnAt !== null && isFinite(Number(root.warnAt))) whisk(Number(root.warnAt), FuiTokens.alert);
            // ---- value arc ------------------------------------------------
            if (root.frac >= 0) {
                var a0 = root.startAngle, a1 = root.startAngle + root.sweep * root.frac;
                var col = FuiTokens.css(root.live ? FuiTokens.acid : root.color);
                if (root.glow) {
                    ctx.strokeStyle = col;
                    ctx.globalAlpha = FuiTokens.glowAlpha;
                    ctx.lineWidth = FuiTokens.lwGlow;
                    ctx.beginPath();
                    ctx.arc(cx, cy, rArc, (a0 - 90) * Math.PI / 180, (a1 - 90) * Math.PI / 180);
                    ctx.stroke();
                    ctx.globalAlpha = 1;
                }
                ctx.strokeStyle = col;
                ctx.lineWidth = FuiTokens.lwArc;
                ctx.beginPath();
                ctx.arc(cx, cy, rArc, (a0 - 90) * Math.PI / 180, (a1 - 90) * Math.PI / 180);
                ctx.stroke();
                var tip = FuiTokens.pol(cx, cy, rArc, a1);
                ctx.fillStyle = col;
                ctx.beginPath(); ctx.arc(tip.x, tip.y, 1.8, 0, Math.PI * 2); ctx.fill();
            }
        }
        Connections {
            target: root
            function onValueChanged() { ring.requestPaint(); }
            function onFracChanged() { ring.requestPaint(); }
            function onMinimumChanged() { ring.requestPaint(); }
            function onMaximumChanged() { ring.requestPaint(); }
            function onStartAngleChanged() { ring.requestPaint(); }
            function onSweepChanged() { ring.requestPaint(); }
            function onTicksChanged() { ring.requestPaint(); }
            function onMajorEveryChanged() { ring.requestPaint(); }
            function onColorChanged() { ring.requestPaint(); }
            function onLiveChanged() { ring.requestPaint(); }
            function onGlowChanged() { ring.requestPaint(); }
            function onMinMarkChanged() { ring.requestPaint(); }
            function onMaxMarkChanged() { ring.requestPaint(); }
            function onWarnAtChanged() { ring.requestPaint(); }
            function onTickLabelsChanged() { ring.requestPaint(); }
            function onMarginChanged() { ring.requestPaint(); }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }

    Column {
        anchors.centerIn: parent
        spacing: 2
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.frac >= 0 ? String(Number(root.value).toFixed(root.labelDecimals)) : FuiTokens.unknownGlyph
            color: FuiTokens.white
            font.family: FuiTokens.mono
            font.pixelSize: root.valuePx
        }
        Text {
            visible: root.unit !== ""
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.unit
            color: FuiTokens.mute
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.tag
            font.letterSpacing: FuiTokens.ls.tag
        }
        Text {
            visible: root.label !== ""
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.label.toUpperCase()
            color: FuiTokens.dim
            font.family: FuiTokens.display
            font.pixelSize: FuiTokens.px.tag
            font.letterSpacing: FuiTokens.ls.label
        }
    }
}
