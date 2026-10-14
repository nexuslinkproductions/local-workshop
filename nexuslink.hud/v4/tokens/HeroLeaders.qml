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
            ctx.font = "11px \"" + FuiTokens.mono + "\"";
            // feedless entries dock in a stack at the ring's left edge instead
            // of piling on deg=0; each gets a stub from its own ring's 270° point
            var ghosts = [];
            for (var i = 0; i < M.length; i++) {
                var e = M[i] || {};
                var hasLim = e.limit !== null && e.limit !== undefined
                             && isFinite(Number(e.limit));
                var label;
                if (hasLim)
                    label = e.resetText !== undefined ? String(e.resetText)
                          : (e.resetMs ? root.fmtEta(e.resetMs - root.nowMs) : "");
                else
                    label = e.noFeedText !== undefined ? String(e.noFeedText) : "";
                if (label === "")
                    continue;
                var col = e.state === "alert" ? FuiTokens.css(FuiTokens.alert)
                        : e.state === "warn" ? FuiTokens.css(FuiTokens.warn)
                        : FuiTokens.css(e.color !== undefined ? e.color : FuiTokens.ice);
                if (!hasLim) {
                    ghosts.push({ "i": i, "label": label, "col": col });
                    continue;
                }
                var r = H.ringR(i) + 5;
                var deg = Math.min(1, Math.max(0, Number(e.limit))) * 360;
                // outward stub + chip hugging the ring
                var stub0 = FuiTokens.pol(cx, cy, r + 2, deg);
                var stub1 = FuiTokens.pol(cx, cy, r + 10, deg);
                ctx.globalAlpha = 0.8;
                ctx.strokeStyle = col;
                ctx.beginPath(); ctx.moveTo(stub0.x, stub0.y); ctx.lineTo(stub1.x, stub1.y); ctx.stroke();
                var w = ctx.measureText(label).width + 10;
                // place chip centred on the stub radial; nudge inside near bezel
                var bx = stub1.x, by = stub1.y;
                var halfW = w / 2;
                bx = Math.min(Math.max(bx, halfW + 2), width - halfW - 2);
                by = Math.min(Math.max(by, 10), height - 10);
                ctx.globalAlpha = 0.9;
                ctx.strokeStyle = col;
                ctx.strokeRect(bx - halfW + 0.5, by - 8.5, w - 1, 15);
                ctx.fillStyle = col;
                ctx.textAlign = "center";
                ctx.fillText(label, bx, by + 4);
            }
            // ghost stack, centred vertically off the ring's left flank
            for (var g = 0; g < ghosts.length; g++) {
                var gh = ghosts[g];
                var gw = ctx.measureText(gh.label).width + 10;
                var gx = 4, gy = cy - (ghosts.length * 19) / 2 + g * 19;
                // stub from this ring's leftmost arc point to the chip
                var r0 = H.ringR(gh.i) + 5;
                var sx = cx - r0 - 2;
                ctx.globalAlpha = 0.45;
                ctx.strokeStyle = gh.col;
                ctx.beginPath(); ctx.moveTo(sx, cy); ctx.lineTo(gx + gw + 4, gy + 8); ctx.stroke();
                ctx.globalAlpha = 0.6;
                ctx.strokeRect(gx + 0.5, gy + 0.5, gw - 1, 15);
                ctx.fillStyle = FuiTokens.css(FuiTokens.mute);
                ctx.textAlign = "left";
                ctx.fillText(gh.label, gx + 5, gy + 12);
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
