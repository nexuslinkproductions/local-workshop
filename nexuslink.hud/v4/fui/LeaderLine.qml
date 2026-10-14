pragma ComponentBehavior: Bound

import QtQuick

// LeaderLine.qml — thin annotation leader with an endpoint label
// (m_lib leader()): dot at the target (x1,y1) -> elbow (x2,y2) -> optional
// horizontal run to x3. The item is an overlay; give it the region's bounds
// and pass LOCAL coordinates. `side` picks which way the label grows from
// the final point.
Item {
    id: root

    property real x1: 0
    property real y1: 0
    property real x2: 0
    property real y2: 0
    property real x3: -1            // <0 -> label at (x2,y2)
    property string label: ""
    property string sub: ""
    property color color: FuiTokens.ice
    property bool dot: true
    property string side: "right"   // label grows "right" | "left" of the end
    property real labelDx: 6
    property real labelDy: -7

    readonly property real endX: x3 >= 0 ? x3 : x2
    readonly property real endY: y2

    Canvas {
        id: c
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            ctx.globalAlpha = 0.55;
            ctx.strokeStyle = FuiTokens.css(root.color);
            ctx.lineWidth = FuiTokens.lwHair;
            ctx.beginPath();
            ctx.moveTo(root.x1, root.y1);
            ctx.lineTo(root.x2, root.y2);
            if (root.x3 >= 0)
                ctx.lineTo(root.x3, root.y2);
            ctx.stroke();
            ctx.globalAlpha = 1;
            if (root.dot) {
                ctx.fillStyle = FuiTokens.css(root.color);
                ctx.beginPath();
                ctx.arc(root.x1, root.y1, 2, 0, Math.PI * 2);
                ctx.fill();
            }
        }
        Connections {
            target: root
            function onX1Changed() { c.requestPaint(); }
            function onY1Changed() { c.requestPaint(); }
            function onX2Changed() { c.requestPaint(); }
            function onY2Changed() { c.requestPaint(); }
            function onX3Changed() { c.requestPaint(); }
            function onColorChanged() { c.requestPaint(); }
            function onDotChanged() { c.requestPaint(); }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }

    Column {
        visible: root.label !== "" || root.sub !== ""
        x: root.side === "right" ? root.endX + root.labelDx
                                 : root.endX - width - root.labelDx
        y: root.endY + root.labelDy
        Text {
            visible: root.label !== ""
            text: root.label
            color: FuiTokens.dim
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.tag
            font.letterSpacing: FuiTokens.ls.tag
        }
        Text {
            visible: root.sub !== ""
            text: root.sub
            color: FuiTokens.mute
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.micro
        }
    }
}
