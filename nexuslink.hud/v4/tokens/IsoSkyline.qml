pragma ComponentBehavior: Bound

import QtQuick
import ".."

// IsoSkyline.qml — 30-day isometric token skyline (gen_M1_dp2 SKYLINE):
// one prism stack per day, providers stacked in `providers` order, dashed
// footprint when a day has no record, back-wall grid + linear value axis,
// date ruler, longest zero-run bracket, peak leader and "today partial"
// marker. Everything is one Canvas; it repaints when `rows`/`providers`
// or geometry change — never on a clock.
Item {
    id: root

    // rows: [{iso:"YYYY-MM-DD", label:"MM-DD", total:tokens, partial:bool,
    //         parts:{key:tokens}}]  — oldest -> today, length ~30
    property var rows: []
    // providers: [{key:"ocg", color, dash:[..]|"double"|null}]
    property var providers: []
    // nice-div override; <=0 -> auto from max day total (M units)
    property real vmaxM: 0
    property string unit: "M"          // values are in M tokens

    implicitWidth: 560
    implicitHeight: 320

    function fmtM(m) {
        if (m >= 1000) return (m / 1000).toFixed(2) + "B";
        if (m >= 100) return Math.round(m) + "M";
        if (m >= 10) return m.toFixed(1) + "M";
        if (m >= 1) return m.toFixed(2) + "M";
        if (m > 0) return Math.round(m * 1000) + "k";
        return "0";
    }

    // pick a linear axis: vmax = n*step covering the max day total,
    // ~7..10 divisions like the mock's 0..2.2B/250M grid
    function axisFit(maxv) {
        var steps = [50, 100, 250, 500, 1000, 2000, 4000];
        for (var i = 0; i < steps.length; i++) {
            var n = Math.ceil(Math.max(maxv, 1) / steps[i]);
            if (n <= 10)
                return { vmax: n * steps[i], step: steps[i], n: n };
        }
        return { vmax: Math.ceil(maxv / 4000) * 4000, step: 4000, n: Math.ceil(maxv / 4000) };
    }

    Canvas {
        id: cv
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            var R = root.rows || [];
            var PR = root.providers || [];
            var n = R.length;
            if (n === 0 || width < 120 || height < 90)
                return;
            ctx.globalAlpha = 1;
            ctx.lineWidth = 1;
            var ICE = FuiTokens.css(FuiTokens.ice);
            var WHITE = FuiTokens.css(FuiTokens.white);
            var ACID = FuiTokens.css(FuiTokens.acid);

            // ---- projection (m_lib: O origin, AV day, BV depth, v up) ------
            var axL = 56;                    // room for value-axis labels
            var rightPad = 96;               // peak label lane
            var O = { x: axL + 18, y: height - 44 };
            var bvx = 14, bvy = -10;
            var avail = width - O.x - bvx - rightPad;
            var avx = Math.min(24, Math.max(7, avail / n));
            var avy = avx * 0.156;
            bvx = Math.min(bvx, avx * 0.9);
            var fw = 0.70;

            var maxTot = 0;
            for (var i = 0; i < n; i++)
                if ((R[i].total || 0) > maxTot)
                    maxTot = R[i].total;
            var fit = root.vmaxM > 0
                    ? { vmax: root.vmaxM, step: root.vmaxM / 8, n: 8 }
                    : axisFit(maxTot);
            var vpx = O.y - 66;              // chart headroom for peak label
            function P(i, f, d, v) {
                return { x: O.x + (i + f) * avx + d * bvx,
                         y: O.y + (i + f) * avy + d * bvy - v / fit.vmax * vpx };
            }
            function line(a, b, col, op, dash) {
                ctx.globalAlpha = op;
                ctx.strokeStyle = col;
                ctx.setLineDash(dash || []);
                ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); ctx.stroke();
                ctx.setLineDash([]);
            }
            function txt(x, y, s, col, align, px) {
                ctx.globalAlpha = 1;
                ctx.fillStyle = col;
                ctx.font = (px || FuiTokens.px.micro) + "px \"" + FuiTokens.mono + "\"";
                ctx.textAlign = align || "left";
                ctx.textBaseline = "alphabetic";
                ctx.fillText(s, x, y);
            }
            function poly(pts, fill, stroke, op, dash) {
                ctx.beginPath();
                ctx.moveTo(pts[0].x, pts[0].y);
                for (var k = 1; k < pts.length; k++)
                    ctx.lineTo(pts[k].x, pts[k].y);
                ctx.closePath();
                if (fill) { ctx.globalAlpha = op.fill; ctx.fillStyle = fill; ctx.fill(); }
                ctx.globalAlpha = op.stroke;
                ctx.strokeStyle = stroke;
                ctx.setLineDash(dash || []);
                ctx.stroke();
                ctx.setLineDash([]);
            }

            // ---- back wall + floor ---------------------------------------
            for (var v = 0; v <= fit.vmax; v += fit.step / 2) {
                var mj = (Math.round(v / (fit.step / 2)) % 2 === 0);
                line(P(0, 0, 1, v), P(n, 0, 1, v), ICE, mj ? 0.16 : 0.07);
            }
            for (i = 0; i <= n; i++)
                line(P(i, 0, 0), P(i, 0, 1), ICE, 0.10);
            line(P(0, 0, 0), P(n, 0, 0), ICE, 0.45);
            line(P(0, 0, 1), P(n, 0, 1), ICE, 0.2);
            line(P(0, 0, 1, 0), P(0, 0, 1, fit.vmax), ICE, 0.2);

            // ---- value axis (back-left vertical) --------------------------
            var axX = P(0, 0, 1).x - 4, axY = P(0, 0, 1).y;
            line({ x: axX, y: axY }, { x: axX, y: axY - vpx }, ICE, 0.55);
            var sub = fit.step / 5;
            for (v = 0; v <= fit.vmax; v += sub) {
                var y = axY - v / fit.vmax * vpx;
                var isMaj = Math.abs(v / fit.step - Math.round(v / fit.step)) < 1e-6;
                var isMid = !isMaj && Math.abs(v / (fit.step / 2) - Math.round(v / (fit.step / 2))) < 1e-6;
                var tl = isMaj ? 8 : (isMid ? 5 : 3);
                line({ x: axX - tl, y: y }, { x: axX, y: y }, ICE, isMaj ? 0.55 : 0.3);
                if (isMaj)
                    txt(axX - tl - 3, y + 3, fmtM(v), FuiTokens.css(FuiTokens.dim), "right");
            }
            txt(axX - 12, axY - vpx - 10, "LIN", ICE, "right");

            // ---- prisms / zero-day footprints ------------------------------
            function prism(i, v0, v1, key) {
                var col = null, dash = null;
                for (var p = 0; p < PR.length; p++)
                    if (PR[p].key === key) {
                        col = (PR[p].color !== undefined) ? PR[p].color : PR[p].col;
                        dash = PR[p].dash;
                    }
                if (col === null)
                    col = FuiTokens.ice;
                var c = FuiTokens.css(col);
                var A = P(i, 0, 0, v0), B = P(i, fw, 0, v0), C = P(i, fw, 1, v0), D = P(i, 0, 1, v0);
                var A2 = P(i, 0, 0, v1), B2 = P(i, fw, 0, v1), C2 = P(i, fw, 1, v1), D2 = P(i, 0, 1, v1);
                var dd = dash && dash !== "double" ? dash : null;
                poly([A, B, B2, A2], "#0a1117", c, { fill: 0.96, stroke: 0.85 }, dd);
                poly([B, C, C2, B2], "#070c10", c, { fill: 0.96, stroke: 0.6 }, dd);
                poly([A2, B2, C2, D2], c, c, { fill: 0.10, stroke: 0.95 }, dd);
                if (dash === "double")      // cdx two-lane cue on the top face
                    line(P(i, 0.10, 0.5, v1), P(i, fw - 0.10, 0.5, v1), c, 0.8);
            }
            for (i = 0; i < n; i++) {
                var row = R[i] || {};
                if (!(row.total > 0)) {
                    poly([P(i, 0, 0), P(i, fw, 0), P(i, fw, 1), P(i, 0, 1)],
                         null, ICE, { fill: 0, stroke: 0.28 }, [1.5, 1.5]);
                    continue;
                }
                var acc = 0;
                for (var p = 0; p < PR.length; p++) {
                    var vv = (row.parts && row.parts[PR[p].key]) || 0;
                    if (vv <= 0)
                        continue;
                    prism(i, acc, acc + vv, PR[p].key);
                    acc += vv;
                }
            }

            // ---- date ruler along the front base ---------------------------
            for (i = 0; i <= n; i++) {
                var a = P(i, 0, 0), mj7 = i % 7 === 0;
                line({ x: a.x, y: a.y + 4 }, { x: a.x, y: a.y + (mj7 ? 12 : 7) }, ICE, mj7 ? 0.55 : 0.3);
            }
            var labEvery = n >= 29 ? 7 : Math.max(2, Math.floor(n / 5));
            for (i = 0; i < n; i += labEvery) {
                a = P(i + fw / 2, 0, 0);
                txt(a.x, a.y + 26, String(R[i].label || ""), FuiTokens.css(FuiTokens.dim), "center");
            }
            var last = R[n - 1] || {};
            if (last.partial) {
                a = P(n - 1 + fw / 2, 0, 0);
                line({ x: a.x + 3, y: a.y + 5 }, { x: a.x + 3, y: a.y + 31 }, ACID, 0.6);
                txt(a.x - 2, a.y + 42, String(last.label) + " partial", ACID, "start");
            }

            // ---- longest zero-run bracket ----------------------------------
            var best = null, run = [];
            for (i = 0; i < n; i++) {
                if (!(R[i].total > 0)) run.push(i);
                else { if (run.length > (best ? best.length : 0)) best = run; run = []; }
            }
            if (run.length > (best ? best.length : 0)) best = run;
            if (best && best.length >= 3) {
                var b0 = P(best[0], 0, 0), b1 = P(best[best.length - 1] + fw, 0, 0);
                ctx.globalAlpha = 0.6;
                ctx.strokeStyle = ICE;
                ctx.beginPath();
                ctx.moveTo(b0.x, b0.y - 14); ctx.lineTo(b0.x, b0.y - 20);
                ctx.lineTo(b1.x, b1.y - 20); ctx.lineTo(b1.x, b1.y - 14);
                ctx.stroke();
                var mid = P((best[0] + best[best.length - 1]) / 2, 0.3, 0);
                txt(mid.x, mid.y - 28, best.length + " zero days "
                    + String(R[best[0]].label) + ".." + String(R[best[best.length - 1]].label),
                    FuiTokens.css(FuiTokens.dim), "center");
            }

            // ---- peak leader -----------------------------------------------
            var ip = -1;
            for (i = 0; i < n; i++)
                if (ip < 0 || (R[i].total || 0) > (R[ip].total || 0))
                    ip = i;
            if (ip >= 0 && (R[ip].total || 0) > 0) {
                var top = P(ip, fw / 2, 0.5, R[ip].total);
                var lx = Math.min(top.x + 30, width - rightPad + 6), ly = Math.max(18, top.y - 46);
                ctx.globalAlpha = 0.7;
                ctx.strokeStyle = ICE;
                ctx.beginPath();
                ctx.moveTo(top.x, top.y); ctx.lineTo(top.x + 16, ly + 6); ctx.lineTo(lx + 60, ly + 6);
                ctx.stroke();
                ctx.fillStyle = ICE;
                ctx.beginPath(); ctx.arc(top.x, top.y, 2, 0, Math.PI * 2); ctx.fill();
                // top-2 contributors that day
                var parts = R[ip].parts || {}, contrib = [];
                for (var p2 = 0; p2 < PR.length; p2++) {
                    var pv = parts[PR[p2].key] || 0;
                    if (pv > 0) contrib.push({ k: PR[p2].key, v: pv });
                }
                contrib.sort(function (a, b) { return b.v - a.v; });
                txt(lx + 64, ly + 10, "PEAK " + String(R[ip].label) + " · Σ " + fmtM(R[ip].total),
                    WHITE, "left");
                if (contrib.length)
                    txt(lx + 64, ly + 22, contrib.slice(0, 2).map(function (e) {
                        return e.k.toUpperCase() + " " + fmtM(e.v)
                             + " (" + (e.v / R[ip].total * 100).toFixed(1) + "%)";
                    }).join(" + "), FuiTokens.css(FuiTokens.mute), "left", 11);
            }
            ctx.globalAlpha = 1;
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections {
            target: root
            function onRowsChanged() { cv.requestPaint(); }
            function onProvidersChanged() { cv.requestPaint(); }
            function onVmaxMChanged() { cv.requestPaint(); }
        }
    }
}
