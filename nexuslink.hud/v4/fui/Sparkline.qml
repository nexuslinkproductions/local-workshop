pragma ComponentBehavior: Bound

import QtQuick
import ".."

// Sparkline.qml — hairline series + 8% area fill (m_lib spark()).
// Repaints only when `values` or geometry changes.
Item {
    id: root

    property var values: []         // numbers; null entries break the line
    property color color: FuiTokens.ice
    property bool fill: true
    property real maximum: -1       // <=0 -> autoscale to series max
    property real minimum: 0
    property bool lastDot: true     // dot on the last non-null value
    property bool floor: true        // hairline floor

    implicitWidth: 160
    implicitHeight: 40

    Canvas {
        id: c
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            ctx.globalAlpha = 1;
            var vs = root.values || [];
            var n = vs.length;
            if (n < 2)
                return;
            var mx = root.maximum > 0 ? root.maximum : 0;
            for (var i = 0; i < n; i++) {
                var v = Number(vs[i]);
                if (isFinite(v) && v > mx)
                    mx = v;
            }
            if (mx <= 0)
                mx = 1;
            var mn = Math.min(root.minimum, 0);
            var span = mx - mn;
            var w = width, h = height;
            function px(i) { return w * i / (n - 1); }
            function py(v) { return h - 1 - (h - 2) * (v - mn) / span; }
            var col = FuiTokens.css(root.color);
            if (root.floor) {
                ctx.strokeStyle = FuiTokens.css(FuiTokens.hair3);
                ctx.lineWidth = 1;
                ctx.beginPath(); ctx.moveTo(0, h - 0.5); ctx.lineTo(w, h - 0.5); ctx.stroke();
            }
            if (root.fill) {
                ctx.fillStyle = col;
                ctx.globalAlpha = 0.08;
                ctx.beginPath();
                ctx.moveTo(0, h);
                var started = false;
                for (i = 0; i < n; i++) {
                    v = Number(vs[i]);
                    if (!isFinite(v))
                        continue;
                    if (!started) { ctx.lineTo(px(i), h); started = true; }
                    ctx.lineTo(px(i), py(v));
                }
                ctx.lineTo(px(n - 1), h);
                ctx.closePath();
                ctx.fill();
                ctx.globalAlpha = 1;
            }
            ctx.strokeStyle = col;
            ctx.lineWidth = 1;
            ctx.beginPath();
            var pen = false;
            for (i = 0; i < n; i++) {
                v = Number(vs[i]);
                if (!isFinite(v)) { pen = false; continue; }
                if (!pen) { ctx.moveTo(px(i), py(v)); pen = true; }
                else ctx.lineTo(px(i), py(v));
            }
            ctx.stroke();
            if (root.lastDot) {
                for (i = n - 1; i >= 0; i--) {
                    v = Number(vs[i]);
                    if (isFinite(v)) {
                        ctx.fillStyle = col;
                        ctx.beginPath();
                        ctx.arc(px(i), py(v), 1.8, 0, Math.PI * 2);
                        ctx.fill();
                        break;
                    }
                }
            }
        }
        Connections {
            target: root
            function onValuesChanged() { c.requestPaint(); }
            function onColorChanged() { c.requestPaint(); }
            function onMaximumChanged() { c.requestPaint(); }
            function onMinimumChanged() { c.requestPaint(); }
            function onFillChanged() { c.requestPaint(); }
            function onFloorChanged() { c.requestPaint(); }
            function onLastDotChanged() { c.requestPaint(); }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }
}
