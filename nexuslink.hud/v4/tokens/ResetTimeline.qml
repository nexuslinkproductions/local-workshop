pragma ComponentBehavior: Bound

import QtQuick
import ".."

// ResetTimeline.qml — RESETS band of DP-2 (gen_M1_dp2 reset timeline):
// a horizontal time axis from NOW to horizon (auto = furthest known reset
// or +24h), ticked hourly/day, one diamond mark + countdown chip per
// provider limit feed, "no limit feed" entries right-docked as ghost
// chips. Input is a precomputed model — the deck owns the clock that
// refreshes it, this item only repaints when the model changes.
Item {
    id: root

    // marks: [{key, color, label, atMs (epoch ms) | null, status:"ok"|"warn"|
    //         "alert"|"na", etaText:"in 3d 21h"|"AUTH PENDING"|"NO FEED",
    //         note:"5h lim"|"wk lim"}]
    property var marks: []
    property real nowMs: 0              // deck-supplied clock
    property int horizonMs: 0           // <=0 -> auto

    implicitWidth: 560
    implicitHeight: 96

    function fmtDur(ms) {
        var s = Math.max(0, Math.round(ms / 1000));
        var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600),
            m = Math.floor(s % 3600 / 60);
        if (d > 0) return d + "d " + h + "h";
        if (h > 0) return h + "h " + m + "m";
        return m + "m";
    }

    Canvas {
        id: cv
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            var M = root.marks || [];
            var now = root.nowMs;
            if (!now || width < 100)
                return;
            var ICE = FuiTokens.css(FuiTokens.ice);
            var ACID = FuiTokens.css(FuiTokens.acid);

            // horizon: furthest known mark, padded, min now+24h
            var far = now + 24 * 3600e3;
            var timed = [];
            for (var i = 0; i < M.length; i++)
                if (M[i].atMs && M[i].atMs > far)
                    far = M[i].atMs;
            if (root.horizonMs > 0)
                far = Math.max(far, now + root.horizonMs);
            far += (far - now) * 0.06;

            var x0 = 10, x1 = width - 96, baseY = height - 30;
            function tx(ms) { return x0 + (ms - now) / (far - now) * (x1 - x0); }

            // axis + hour/day ticks
            ctx.globalAlpha = 0.4;
            ctx.strokeStyle = ICE;
            ctx.beginPath(); ctx.moveTo(x0, baseY); ctx.lineTo(x1, baseY); ctx.stroke();
            var spanH = (far - now) / 3600e3;
            var tickH = spanH > 72 ? 24 : (spanH > 30 ? 12 : 6);
            var t = Math.ceil(now / (tickH * 3600e3)) * tickH * 3600e3;
            ctx.font = "11px \"" + FuiTokens.mono + "\"";
            for (; t < far; t += tickH * 3600e3) {
                var xx = tx(t);
                var d = new Date(t);
                var major = d.getHours() === 0;
                ctx.globalAlpha = major ? 0.5 : 0.28;
                ctx.beginPath(); ctx.moveTo(xx, baseY - (major ? 8 : 4)); ctx.lineTo(xx, baseY); ctx.stroke();
                if (major) {
                    ctx.globalAlpha = 0.85;
                    ctx.fillStyle = FuiTokens.css(FuiTokens.dim);
                    ctx.textAlign = "center";
                    var mm = String(d.getMonth() + 1), dd = String(d.getDate());
                    ctx.fillText((mm.length < 2 ? "0" : "") + mm + "-" + (dd.length < 2 ? "0" : "") + dd, xx, baseY - 12);
                }
            }

            // NOW marker
            ctx.globalAlpha = 0.8;
            ctx.strokeStyle = ACID;
            ctx.beginPath(); ctx.moveTo(x0, baseY - 14); ctx.lineTo(x0, baseY + 14); ctx.stroke();
            ctx.fillStyle = ACID;
            ctx.textAlign = "left";
            ctx.fillText("NOW", x0 + 4, baseY + 20);

            // provider marks — timed ones on the axis, feedless ones as
            // ghost chips docked right
            var gi = 0;
            for (i = 0; i < M.length; i++) {
                var mk = M[i], col = FuiTokens.css(mk.color || FuiTokens.ice);
                var scol = mk.status === "alert" ? FuiTokens.css(FuiTokens.alert)
                         : mk.status === "warn" ? FuiTokens.css(FuiTokens.warn) : col;
                if (!mk.atMs) {
                    // ghost chips stack upward from just above the axis so
                    // a tall band never leaves an empty right lane
                    var gw2 = 96, gx2 = width - 8 - gw2, gy2 = baseY - 38 - gi * 17;
                    gi++;
                    ctx.globalAlpha = 0.75;
                    ctx.strokeStyle = FuiTokens.css(FuiTokens.hair2);
                    ctx.strokeRect(gx2, gy2, gw2, 15);
                    ctx.fillStyle = FuiTokens.css(FuiTokens.mute);
                    ctx.textAlign = "left";
                    ctx.fillText(String(mk.label) + " " + String(mk.etaText || "NO FEED"), gx2 + 4, gy2 + 12);
                    continue;
                }
                var mx = tx(mk.atMs);
                ctx.globalAlpha = 0.9;
                ctx.strokeStyle = scol;
                // diamond on the axis
                ctx.beginPath();
                ctx.moveTo(mx, baseY - 7); ctx.lineTo(mx + 5, baseY);
                ctx.lineTo(mx, baseY + 7); ctx.lineTo(mx - 5, baseY);
                ctx.closePath(); ctx.stroke();
                // stem up to chip row (alternate two lanes to avoid overlap);
                // lanes hang just above the axis so a tall band stays tight
                var lane = i % 2, cy = baseY - 34 - lane * 19;
                ctx.globalAlpha = 0.45;
                ctx.beginPath(); ctx.moveTo(mx, baseY - 7); ctx.lineTo(mx, cy + 15); ctx.stroke();
                // chip — note folds into the label so nothing floats over lanes
                var lab = String(mk.label) + " " + String(mk.etaText || "")
                          + (mk.note ? " · " + String(mk.note) : "");
                ctx.font = "11px \"" + FuiTokens.mono + "\"";
                var cw = ctx.measureText(lab).width + 10;
                // clamp inside the axis span, short of the ghost dock
                var gxLim = width - 8 - 96 - 6;
                var cx = Math.min(Math.max(mx - cw / 2, x0), gxLim - cw);
                ctx.globalAlpha = 0.85;
                ctx.strokeStyle = scol;
                ctx.strokeRect(cx + 0.5, cy + 0.5, cw, 15);
                ctx.fillStyle = scol;
                ctx.textAlign = "left";
                ctx.fillText(lab, cx + 5, cy + 12);
            }
            ctx.globalAlpha = 1;
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections {
            target: root
            function onMarksChanged() { cv.requestPaint(); }
            function onNowMsChanged() { cv.requestPaint(); }
            function onHorizonMsChanged() { cv.requestPaint(); }
        }
    }
}
