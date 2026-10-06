pragma ComponentBehavior: Bound

import QtQuick
import ".."

// DayHeatmap.qml — 26-week daily token heatmap (gen_M1_dp2 HEATMAP):
// 26 columns × 7 rows (Mon..Sun), ice intensity over each day's tokens,
// "wk N" index on the left edge, month-rule labels above the columns,
// missing/omitted days draw as empty hair cells, today glows acid.
Item {
    id: root

    // cells: [{iso:"YYYY-MM-DD", label:"MM-DD", total, partial}] — the 26*7
    //        grid already laid out column-major (col = week, row = dow);
    //        entries may be null for pre-epoch padding
    property var cells: []
    property int weeks: 26
    property int todayCol: -1          // column index containing today
    property string unit: "M"

    implicitWidth: 560
    implicitHeight: 150

    function fmtM(m) {
        if (m >= 1000) return (m / 1000).toFixed(2) + "B";
        if (m >= 100) return Math.round(m) + "M";
        if (m >= 10) return m.toFixed(1) + "M";
        if (m > 0) return m.toFixed(1) + "M";
        return "0";
    }

    Canvas {
        id: cv
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            var C = root.cells || [];
            var W = root.weeks;
            if (!C.length || width < 80 || height < 60)
                return;
            var ICE = FuiTokens.css(FuiTokens.ice);
            var ACID = FuiTokens.css(FuiTokens.acid);

            var gx = 36, gy = 22;                  // grid origin (fits MON@11px)
            var gw = width - gx - 8, gh = height - gy - 18;
            var cw = gw / W, chh = gh / 7, pad = 1;

            // log-step intensity (m_lib STEPS): 0 / <10M / 10M / 50M / 200M / 1B+
            var ALP = [0, 0.12, 0.24, 0.40, 0.62, 0.90];
            function lvl(v) {
                if (!(v > 0)) return 0;
                if (v < 10) return 1;
                if (v < 50) return 2;
                if (v < 200) return 3;
                if (v < 1000) return 4;
                return 5;
            }

            // month rules: label the column where the month changes
            var lastMon = "";
            for (var c = 0; c < W; c++) {
                var head = C[c * 7];
                if (!head) continue;
                var mon = String(head.iso).substr(5, 2);
                if (mon !== lastMon && c > 0) {
                    var mx = gx + c * cw;
                    ctx.globalAlpha = 0.18;
                    ctx.strokeStyle = ICE;
                    ctx.beginPath(); ctx.moveTo(mx - 0.5, gy - 4); ctx.lineTo(mx - 0.5, gy + gh + 4); ctx.stroke();
                    ctx.globalAlpha = 0.85;
                    ctx.fillStyle = FuiTokens.css(FuiTokens.dim);
                    ctx.font = "11px \"" + FuiTokens.mono + "\"";
                    ctx.textAlign = "left";
                    ctx.fillText(monName(mon), mx + 2, gy - 7);
                    lastMon = mon;
                } else if (mon !== lastMon) {
                    lastMon = mon;
                }
            }
            function monName(mm) {
                var names = ["01","02","03","04","05","06","07","08","09","10","11","12"];
                var idx = Math.max(0, Math.min(11, parseInt(mm, 10) - 1));
                return "M" + mm;   // keep numeric month tag — matches mock's 09/10 rules
            }

            // day-of-week labels on the left edge
            var dows = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"];
            for (var r2 = 0; r2 < 7; r2 += 2) {
                ctx.globalAlpha = 0.8;
                ctx.fillStyle = FuiTokens.css(FuiTokens.mute);
                ctx.font = "11px \"" + FuiTokens.mono + "\"";
                ctx.textAlign = "right";
                ctx.fillText(dows[r2], gx - 4, gy + r2 * chh + chh * 0.75);
            }

            // cells
            for (var i = 0; i < C.length; i++) {
                var col = Math.floor(i / 7), r = i % 7;
                var x = gx + col * cw, y = gy + r * chh;
                var cell = C[i];
                var isToday = cell && cell.partial;
                if (!cell) {
                    ctx.globalAlpha = 0.10;
                    ctx.strokeStyle = ICE;
                    ctx.strokeRect(x + pad + 0.5, y + pad + 0.5,
                                   cw - pad * 2 - 1, chh - pad * 2 - 1);
                    continue;
                }
                var v = cell.total || 0, l = lvl(v);
                if (l > 0) {
                    ctx.globalAlpha = ALP[l];
                    ctx.fillStyle = ICE;
                    ctx.fillRect(x + pad, y + pad, cw - pad * 2 - 1, chh - pad * 2 - 1);
                }
                ctx.globalAlpha = isToday ? 0.9 : (0.25 + 0.1 * l);
                ctx.strokeStyle = isToday ? ACID : ICE;
                if (isToday)
                    ctx.setLineDash([]);
                ctx.strokeRect(x + pad + 0.5, y + pad + 0.5,
                               cw - pad * 2 - 1, chh - pad * 2 - 1);
            }
            ctx.globalAlpha = 1;
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections {
            target: root
            function onCellsChanged() { cv.requestPaint(); }
            function onWeeksChanged() { cv.requestPaint(); }
        }
    }
}
