import QtQuick

// Static scanline sheet (mock .scan): 1 px dark line every `pitch` px,
// painted once. No timers, no per-frame repaint — CPU cost is a single
// onPaint per geometry change.
Canvas {
    id: scan

    property real pitch: 4          // line spacing in px
    property real lineWidth: 1
    property real lineAlpha: 0.09   // mock uses rgba(0,0,0,.09)

    opacity: 0.5                    // mock overlays the sheet at .5
    renderStrategy: Canvas.Cooperative
    onPaint: {
        var ctx = getContext("2d");
        ctx.clearRect(0, 0, width, height);
        var p = Math.max(2, pitch);
        var w = Math.max(0.5, lineWidth);
        ctx.fillStyle = "rgba(0,0,0," + lineAlpha.toFixed(3) + ")";
        for (var y = 0; y < height; y += p)
            ctx.fillRect(0, y, width, w);
    }

    Component.onCompleted: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPitchChanged: requestPaint()
    onLineAlphaChanged: requestPaint()
    onLineWidthChanged: requestPaint()
}
