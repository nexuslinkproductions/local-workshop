pragma ComponentBehavior: Bound

import QtQuick
import ".."

// HeroLeaders.qml — overlay on ConcentricRings that hangs a countdown chip
// off each ring's limit-arc tip (angle = limit*360 on r+5, same maths as the
// primitive paints its tip dot). Rings without a limit feed get a faint
// status chip at the ring top ("auth pending" / "no feed"). Pure Canvas;
// repaints when host geometry or `model`/`nowMs` change.
Item {
    id: root

    required property var host          // the ConcentricRings instance
    property var model: []              // same entries + resetMs/status fields
    property real nowMs: 0

    function fmtEta(ms) {
        var s = Math.max(0, Math.round(ms / 1000));
        var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600),
            m = Math.floor(s % 3600 / 60);
        if (d > 0) return d + "d" + h + "h";
        if (h > 0) return h + "h" + (m > 0 ? m + "m" : "");
        return m + "m";
    }

    Canvas {
        id: cv
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            var M = root.model || [], H = root.host;
            if (!H || !M.length)
                return;
            var cx = width / 2, cy = height / 2;
            ctx.font = "8px \"" + FuiTokens.mono + "\"";
            for (var i = 0; i < M.length; i++) {
                var e = M[i] || {};
                var r = H.ringR(i) + 5;
                var hasLim = e.limit !== null && e.limit !== undefined
                             && isFinite(Number(e.limit));
                var deg = hasLim ? Math.min(1, Math.max(0, Number(e.limit))) * 360 : 0;
                var tip = FuiTokens.pol(cx, cy, r, deg);
                var col = e.state === "alert" ? FuiTokens.css(FuiTokens.alert)
                        : e.state === "warn" ? FuiTokens.css(FuiTokens.warn)
                        : FuiTokens.css(e.color !== undefined ? e.color : FuiTokens.ice);
                var label;
                if (hasLim)
                    label = e.resetText !== undefined ? String(e.resetText)
                          : (e.resetMs ? root.fmtEta(e.resetMs - root.nowMs) : "");
                else
                    label = e.noFeedText !== undefined ? String(e.noFeedText) : "";
                if (label === "")
                    continue;
                // outward stub + chip hugging the ring
                var stub0 = FuiTokens.pol(cx, cy, r + 2, deg);
                var stub1 = FuiTokens.pol(cx, cy, r + 10, deg);
                ctx.globalAlpha = hasLim ? 0.8 : 0.45;
                ctx.strokeStyle = col;
                ctx.beginPath(); ctx.moveTo(stub0.x, stub0.y); ctx.lineTo(stub1.x, stub1.y); ctx.stroke();
                var w = ctx.measureText(label).width + 8;
                // place chip centred on the stub radial; nudge inside near bezel
                var bx = stub1.x, by = stub1.y;
                var halfW = w / 2;
                bx = Math.min(Math.max(bx, halfW + 2), width - halfW - 2);
                by = Math.min(Math.max(by, 9), height - 9);
                ctx.globalAlpha = hasLim ? 0.9 : 0.6;
                ctx.strokeStyle = col;
                ctx.strokeRect(bx - halfW + 0.5, by - 7.5, w - 1, 12);
                ctx.fillStyle = hasLim ? col : FuiTokens.css(FuiTokens.mute);
                ctx.textAlign = "center";
                ctx.fillText(label, bx, by + 1);
            }
            ctx.globalAlpha = 1;
        }
        Connections {
            target: root
            function onModelChanged() { cv.requestPaint(); }
            function onNowMsChanged() { cv.requestPaint(); }
            function onHostChanged() { cv.requestPaint(); }
        }
        Connections {
            target: root.host
            ignoreUnknownSignals: true
            function onROuterChanged() { cv.requestPaint(); }
            function onPitchChanged() { cv.requestPaint(); }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }
}
