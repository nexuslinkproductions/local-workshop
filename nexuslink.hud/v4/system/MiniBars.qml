pragma ComponentBehavior: Bound

import QtQuick
import ".."

// MiniBars.qml — the M1 sheet bars() series: thin value columns on a hairline
// baseline (per-core MHz, per-channel temps, PSI pairs). `hi` marks values
// >= threshold with warn. Repaints on input/size change only.
Canvas {
    id: root

    property var values: []
    property real minimum: 0
    property real maximum: 100
    property color color: FuiTokens.ice
    property var hi: null             // values >= hi paint warn

    implicitWidth: 110
    implicitHeight: 34

    onPaint: {
        var ctx = getContext("2d");
        ctx.clearRect(0, 0, width, height);
        var vals = root.values;
        var n = vals.length;
        var span = root.maximum - root.minimum;
        if (n <= 0 || span <= 0) {
            ctx.strokeStyle = FuiTokens.css(FuiTokens.hair2);
            ctx.lineWidth = FuiTokens.lwHair;
            ctx.beginPath();
            ctx.moveTo(0, height - 0.5); ctx.lineTo(width, height - 0.5);
            ctx.stroke();
            return;
        }
        var bw = width / n;
        for (var i = 0; i < n; i++) {
            var v = Number(vals[i]);
            if (!isFinite(v))
                continue;
            var bh = height * (v - root.minimum) / span;
            if (bh < 0)
                bh = 0;
            var warn = root.hi !== null && isFinite(Number(root.hi)) && v >= Number(root.hi);
            ctx.fillStyle = FuiTokens.css(FuiTokens.tone(warn ? FuiTokens.warn : root.color, 0.75));
            ctx.fillRect(i * bw + 1, height - bh, Math.max(1, bw - 2), bh);
        }
        ctx.fillStyle = FuiTokens.css(FuiTokens.hair);
        ctx.fillRect(0, height - 0.5, width, 1);
    }

    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onValuesChanged: requestPaint()
    onMinimumChanged: requestPaint()
    onMaximumChanged: requestPaint()
    onColorChanged: requestPaint()
    onHiChanged: requestPaint()
}
