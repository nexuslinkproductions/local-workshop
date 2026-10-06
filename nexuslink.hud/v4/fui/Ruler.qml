pragma ComponentBehavior: Bound

import QtQuick

// Ruler.qml — graduated straight ruler strip (m_lib ruler()).
// Ticks run `from` -> `to` across the item's width (or height when
// `vertical`); major ticks get labels. `flip` hangs the scale on the other
// side (ticks grow up/left instead of down/right).
Item {
    id: root

    property real from: 0
    property real to: 100
    property int minor: 20          // number of divisions
    property int majorEvery: 5
    property var labels: []         // strings per major tick; [] = value text
    property bool vertical: false
    property bool flip: false       // ticks grow up/left, labels on the far side
    property bool showLabels: true
    property int labelDecimals: 0
    property color color: FuiTokens.ice
    property int tickMinor: 4
    property int tickMajor: 8

    implicitWidth: vertical ? 24 : 160
    implicitHeight: vertical ? 160 : 20

    readonly property int maj: Math.max(1, majorEvery)
    function frac(i) { return root.minor > 0 ? i / root.minor : 0; }
    function labelFor(mi) {
        var k = mi / root.maj;
        if (k < root.labels.length)
            return String(root.labels[k]);
        return (root.from + (root.to - root.from) * root.frac(mi)).toFixed(root.labelDecimals);
    }

    Canvas {
        id: c
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            ctx.globalAlpha = 0.55;
            ctx.strokeStyle = FuiTokens.css(root.color);
            ctx.lineWidth = 1;
            var w = width, h = height;
            // baseline
            ctx.beginPath();
            if (root.vertical) {
                var bx = root.flip ? w - 0.5 : 0.5;
                ctx.moveTo(bx, 0); ctx.lineTo(bx, h);
            } else {
                var by = root.flip ? h - 0.5 : 0.5;
                ctx.moveTo(0, by); ctx.lineTo(w, by);
            }
            ctx.stroke();
            for (var i = 0; i <= root.minor; i++) {
                var major = i % root.maj === 0;
                var L = major ? root.tickMajor : root.tickMinor;
                ctx.globalAlpha = major ? 0.9 : 0.5;
                ctx.beginPath();
                if (root.vertical) {
                    var y = h * root.frac(i);
                    var x1 = root.flip ? w - 1 : 0;
                    ctx.moveTo(x1 + 0.5, y + 0.5);
                    ctx.lineTo(x1 + (root.flip ? -L : L) + 0.5, y + 0.5);
                } else {
                    var x = w * root.frac(i);
                    var y1 = root.flip ? h - 1 : 0;
                    ctx.moveTo(x + 0.5, y1 + 0.5);
                    ctx.lineTo(x + 0.5, y1 + (root.flip ? -L : L) + 0.5);
                }
                ctx.stroke();
            }
            ctx.globalAlpha = 1;
        }
        Connections {
            target: root
            function onMinorChanged() { c.requestPaint(); }
            function onMajorEveryChanged() { c.requestPaint(); }
            function onFlipChanged() { c.requestPaint(); }
            function onVerticalChanged() { c.requestPaint(); }
            function onColorChanged() { c.requestPaint(); }
            function onFromChanged() { c.requestPaint(); }
            function onToChanged() { c.requestPaint(); }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }

    Repeater {
        model: root.showLabels ? Math.floor(root.minor / root.maj) + 1 : 0
        delegate: Text {
            required property int index
            readonly property int mi: index * root.maj
            text: root.labelFor(mi)
            color: FuiTokens.mute
            font.family: FuiTokens.mono
            font.pixelSize: FuiTokens.px.micro
            x: root.vertical ? (root.flip ? 0 : root.tickMajor + 3)
                             : root.frac(mi) * root.width - implicitWidth / 2
            y: root.vertical ? root.frac(mi) * root.height - implicitHeight / 2
                             : (root.flip ? 0 : root.tickMajor + 3)
            width: root.vertical ? Math.max(8, root.width - root.tickMajor - 3) : implicitWidth
            horizontalAlignment: root.vertical ? (root.flip ? Text.AlignRight : Text.AlignLeft)
                                               : Text.AlignHCenter
        }
    }
}
