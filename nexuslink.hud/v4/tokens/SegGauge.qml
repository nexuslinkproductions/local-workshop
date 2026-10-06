pragma ComponentBehavior: Bound

import QtQuick
import ".."

// SegGauge.qml — segmented half-ring gauge (m_lib seg_half): N outlined
// annular sectors spanning -90..+90 deg; `frac` lights them left-to-right.
// `frac: null` renders every segment dashed ("n/a"), the mock's auth/no-feed
// state. `win` paints an inner dashed arc + elapsed fill + tip dot
// (window-elapsed ring). Repaints on property change only.
Item {
    id: root

    property var frac: null          // 0..1 | null = no feed
    property int segments: 24
    property real thickness: 10      // ring band width
    property color color: FuiTokens.ice
    property string sev: "ok"        // ok | warn | alert | na (was `state` — shadows Item.state)
    property var win: null           // 0..1 window elapsed | null
    property real margin: 22         // room for 0/50/100 labels

    implicitWidth: 150
    implicitHeight: 96

    readonly property color arcCol: sev === "alert" ? FuiTokens.alert
                                  : sev === "warn" ? FuiTokens.warn
                                  : color

    Canvas {
        id: c
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            var gcx = width / 2, gcy = height - root.margin * 0.4 - 4;
            var gr = Math.min(width / 2 - 6, gcy - 8);
            if (gr < 12)
                return;
            var w = Math.min(root.thickness, gr * 0.5);
            var n = Math.max(4, root.segments);
            var gap = 1.6;
            var na = root.frac === null || root.frac === undefined
                     || !isFinite(Number(root.frac)) || root.sev === "na";
            var fillfrac = na ? 0 : Math.min(1, Math.max(0, Number(root.frac)));
            var col = FuiTokens.css(root.arcCol);
            function pol(r, deg) {
                var a = (deg - 90) * Math.PI / 180;
                return { x: gcx + r * Math.cos(a), y: gcy + r * Math.sin(a) };
            }
            // ---- segmented band ------------------------------------------
            ctx.lineWidth = 1;
            for (var i = 0; i < n; i++) {
                var s = -90 + 180 * i / n + gap / 2;
                var e = -90 + 180 * (i + 1) / n - gap / 2;
                var ro = gr, ri = gr - w;
                ctx.beginPath();
                var p = pol(ro, s);
                ctx.moveTo(p.x, p.y);
                ctx.arc(gcx, gcy, ro, (s - 90) * Math.PI / 180, (e - 90) * Math.PI / 180);
                p = pol(ri, e);
                ctx.lineTo(p.x, p.y);
                ctx.arc(gcx, gcy, ri, (e - 90) * Math.PI / 180, (s - 90) * Math.PI / 180, true);
                ctx.closePath();
                var on = (i + 0.5) / n <= fillfrac;
                if (na) {
                    ctx.setLineDash([2, 2]);
                    ctx.strokeStyle = col;
                    ctx.globalAlpha = 0.28;
                    ctx.stroke();
                    ctx.setLineDash([]);
                } else if (on) {
                    ctx.fillStyle = col;
                    ctx.globalAlpha = 0.22;
                    ctx.fill();
                    ctx.globalAlpha = 0.95;
                    ctx.strokeStyle = col;
                    ctx.stroke();
                } else {
                    ctx.globalAlpha = 0.22;
                    ctx.strokeStyle = col;
                    ctx.stroke();
                }
            }
            ctx.globalAlpha = 1;
            // ---- outer hair arc + ticks ----------------------------------
            var rT = gr + 6;
            ctx.strokeStyle = FuiTokens.css(FuiTokens.ice);
            ctx.globalAlpha = 0.4;
            ctx.beginPath();
            ctx.arc(gcx, gcy, rT, Math.PI, 0);
            ctx.stroke();
            for (i = 0; i <= 20; i++) {
                var a2 = -90 + 180 * i / 20;
                var L = i % 5 === 0 ? 7 : 3;
                var q0 = pol(rT, a2), q1 = pol(rT + L, a2);
                ctx.globalAlpha = i % 5 === 0 ? 0.55 : 0.3;
                ctx.beginPath(); ctx.moveTo(q0.x, q0.y); ctx.lineTo(q1.x, q1.y); ctx.stroke();
            }
            // ---- inner window-elapsed arc ---------------------------------
            var rW = gr - w - 10;
            if (rW > 8) {
                ctx.setLineDash([2, 3]);
                ctx.strokeStyle = FuiTokens.css(FuiTokens.ice);
                ctx.globalAlpha = 0.18;
                ctx.lineWidth = 1;
                ctx.beginPath();
                ctx.arc(gcx, gcy, rW, Math.PI, 0);
                ctx.stroke();
                ctx.setLineDash([]);
                if (root.win !== null && root.win !== undefined && isFinite(Number(root.win))) {
                    var wf = Math.min(1, Math.max(0, Number(root.win)));
                    var wc = root.sev === "alert" ? FuiTokens.azure : root.arcCol;
                    ctx.strokeStyle = FuiTokens.css(wc);
                    ctx.globalAlpha = 0.9;
                    ctx.lineWidth = 1.6;
                    ctx.beginPath();
                    ctx.arc(gcx, gcy, rW, Math.PI, Math.PI + wf * Math.PI);
                    ctx.stroke();
                    var tp = pol(rW, -90 + 180 * wf);
                    ctx.fillStyle = FuiTokens.css(FuiTokens.white);
                    ctx.beginPath(); ctx.arc(tp.x, tp.y, 2, 0, Math.PI * 2); ctx.fill();
                }
            }
            // ---- base rule + scale labels ---------------------------------
            ctx.globalAlpha = 0.3;
            ctx.lineWidth = 1;
            ctx.strokeStyle = FuiTokens.css(FuiTokens.ice);
            ctx.beginPath(); ctx.moveTo(gcx - gr - 10, gcy + 0.5); ctx.lineTo(gcx + gr + 10, gcy + 0.5); ctx.stroke();
            ctx.globalAlpha = 0.9;
            ctx.fillStyle = FuiTokens.css(FuiTokens.mute);
            ctx.font = FuiTokens.px.micro + "px \"" + FuiTokens.mono + "\"";
            ctx.textAlign = "center"; ctx.textBaseline = "top";
            ctx.fillText("0", gcx - gr - 6, gcy + 4);
            ctx.fillText("50", gcx, gcy - rT - 16);
            ctx.fillText("100", gcx + gr + 6, gcy + 4);
            ctx.globalAlpha = 1;
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections {
            target: root
            function onFracChanged() { c.requestPaint(); }
            function onSevChanged() { c.requestPaint(); }
            function onColorChanged() { c.requestPaint(); }
            function onWinChanged() { c.requestPaint(); }
            function onSegmentsChanged() { c.requestPaint(); }
            function onThicknessChanged() { c.requestPaint(); }
        }
    }

    // centre readout — big % / "n/a" + "USED %" sub
    Column {
        anchors { horizontalCenter: parent.horizontalCenter
                  bottom: parent.bottom; bottomMargin: 12 }
        spacing: 0
        Tx {
            anchors.horizontalCenter: parent.horizontalCenter
            role: "num"
            font.pixelSize: root.frac === null || !isFinite(Number(root.frac)) ? 15 : 21
            text: {
                if (root.frac === null || root.frac === undefined || !isFinite(Number(root.frac)))
                    return "n/a";
                return String(Math.round(Number(root.frac) * 100)) + " %";
            }
            tone: root.frac === null || !isFinite(Number(root.frac))
                  ? FuiTokens.faint : root.arcCol
        }
        Tx {
            anchors.horizontalCenter: parent.horizontalCenter
            role: "micro"
            text: root.frac === null || !isFinite(Number(root.frac)) ? "USED % N/A" : "USED %"
        }
    }
}
