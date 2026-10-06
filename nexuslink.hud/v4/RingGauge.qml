import QtQuick

// Ring gauge (reference "85% FOCUS" idiom): navy track, gradient arc, round
// caps, centre big text + micro label. Canvas repaints ONLY when value, colour
// or size changes (no Behavior: an eased value would repaint every frame).
Item {
    id: ring

    property real value: -1                 // 0..1, <0 = unknown (track only)
    property color trackColor: Style.c.azureDim
    property color progColor1: Style.c.azure
    property color progColor2: Style.c.accent2
    property real strokeWidth: Math.max(3, Math.round(size / 11))
    property real size: 56
    property string bigText: ""
    property string label: ""

    implicitWidth: size
    implicitHeight: size

    Canvas {
        id: cv
        anchors.fill: parent
        renderStrategy: Canvas.Cooperative
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            var w = ring.strokeWidth;
            var r = (Math.min(width, height) - w) / 2 - 1;
            if (r <= 2)
                return;
            var cx = width / 2, cy = height / 2;
            var a0 = -Math.PI / 2;
            ctx.lineCap = "round";
            ctx.lineWidth = w;
            ctx.strokeStyle = ring.trackColor;
            ctx.beginPath();
            ctx.arc(cx, cy, r, 0, 2 * Math.PI);
            ctx.stroke();
            var v = Math.max(0, Math.min(1, ring.value));
            if (ring.value < 0 || v <= 0.001)
                return;
            var g = ctx.createLinearGradient(0, height, width, 0);
            g.addColorStop(0, ring.progColor1);
            g.addColorStop(1, ring.progColor2);
            ctx.strokeStyle = g;
            ctx.beginPath();
            ctx.arc(cx, cy, r, a0, a0 + v * 2 * Math.PI);
            ctx.stroke();
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Component.onCompleted: requestPaint()
    }
    onValueChanged: cv.requestPaint()
    onTrackColorChanged: cv.requestPaint()
    onProgColor1Changed: cv.requestPaint()
    onProgColor2Changed: cv.requestPaint()
    onStrokeWidthChanged: cv.requestPaint()

    Column {
        anchors.centerIn: parent
        visible: ring.bigText !== "" || ring.label !== ""
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: ring.bigText !== ""
            text: ring.bigText
            color: Style.c.txt
            font.family: Theme.displayFamily
            font.pixelSize: Math.max(8, Math.round(ring.size * 0.24))
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: ring.label !== ""
            text: ring.label
            color: Style.c.mute
            font.family: Theme.monoFamily
            font.pixelSize: Style.f.pxMicro
            font.letterSpacing: Style.f.lsTag
        }
    }
}
