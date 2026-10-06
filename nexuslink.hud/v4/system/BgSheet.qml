pragma ComponentBehavior: Bound

import QtQuick
import ".."

// BgSheet.qml — the M1 sheet's static schematic layer: faint dashed circles,
// a crosshair through the hero centre, 256 px coordinate labels and corner
// crop marks. Design coords are relative to the 1920x1200 sheet and scale
// with the deck. Paints on size change only.
Canvas {
    id: root

    anchors.fill: parent

    onPaint: {
        var ctx = getContext("2d");
        ctx.clearRect(0, 0, width, height);
        var sx = width / 1920, sy = height / 1200;
        if (!(sx > 0) || !(sy > 0))
            return;
        var ice = FuiTokens.css(FuiTokens.ice);
        var m = 14, L = 22;

        ctx.lineWidth = FuiTokens.lwHair;
        ctx.strokeStyle = ice;
        ctx.setLineDash([2, 6]);
        function circ(cxD, cyD, rD, op) {
            ctx.globalAlpha = op;
            ctx.beginPath();
            ctx.arc(cxD * sx, cyD * sy, rD * Math.min(sx, sy), 0, Math.PI * 2);
            ctx.stroke();
        }
        circ(590, 430, 520, 0.045);
        circ(1540, 430, 300, 0.045);
        circ(1540, 430, 380, 0.045);
        ctx.setLineDash([]);

        ctx.globalAlpha = 0.04;
        ctx.beginPath();
        ctx.moveTo(0, 430 * sy); ctx.lineTo(width, 430 * sy);
        ctx.moveTo(590 * sx, 0); ctx.lineTo(590 * sx, height);
        ctx.stroke();

        // coordinate labels along the top edge / right edge every 256 design px
        ctx.globalAlpha = 0.35;
        ctx.fillStyle = ice;
        ctx.font = FuiTokens.px.body + "px \"" + FuiTokens.mono + "\"";
        ctx.textAlign = "left"; ctx.textBaseline = "alphabetic";
        for (var x = 128; x < 1920; x += 256)
            ctx.fillText("H" + ("000" + x).slice(-4), x * sx + 4, 12);
        for (var y = 128; y < 1200 - 60; y += 256)
            ctx.fillText("V" + ("000" + y).slice(-4), width - 52, y * sy - 4);

        // crop marks: corner brackets + edge-mid crosshairs
        ctx.globalAlpha = 0.45;
        var w = width, h = height;
        function corner(cx, cy, dx, dy) {
            ctx.beginPath();
            ctx.moveTo(cx, cy + dy * L); ctx.lineTo(cx, cy); ctx.lineTo(cx + dx * L, cy);
            ctx.stroke();
        }
        corner(m, m, 1, 1); corner(w - m, m, -1, 1);
        corner(m, h - m, 1, -1); corner(w - m, h - m, -1, -1);
        function cross(px, py, dx, dy) {
            ctx.beginPath();
            ctx.moveTo(px - 10, py); ctx.lineTo(px + 10, py);
            ctx.moveTo(px, py - 6); ctx.lineTo(px, py + 6);
            ctx.stroke();
        }
        cross(w / 2, m, 0, 1); cross(w / 2, h - m, 0, -1);
        cross(m, h / 2, 1, 0); cross(w - m, h / 2, -1, 0);
        ctx.globalAlpha = 1;
    }

    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
}
