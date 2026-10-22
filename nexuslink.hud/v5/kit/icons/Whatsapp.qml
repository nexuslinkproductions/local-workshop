import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: whatsapp. Brand mark, redrawn monochrome: speech bubble with the
// lower-left tail and the handset. 24 px grid, live area 3.4..20.4, stroke 1.5
// regular / 2.0 bold, round caps and joins.
// Bubble: circle centre (12, 11.8) r 7.7, arc from 145 deg the long way round to
// 105 deg, tail point at (3.4, 20.8).
Shape {
    id: root
    property color color: Tokens.ink
    property real weight: 1.5
    property real size: 24

    implicitWidth: 24
    implicitHeight: 24
    width: 24
    height: 24
    scale: size / 24
    transformOrigin: Item.Center
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 3.4
        startY: 20.8
        PathLine { x: 5.69; y: 16.22 }
        PathAngleArc {
            centerX: 12
            centerY: 11.8
            radiusX: 7.7
            radiusY: 7.7
            startAngle: 145
            sweepAngle: 320
            moveToStart: false
        }
        PathLine { x: 3.4; y: 20.8 }
    }
    // handset, sized to sit inside the bubble with air on every side
    ShapePath {
        strokeColor: "transparent"
        fillColor: root.color
        startX: 8.1
        startY: 8.4
        PathQuad { x: 9.7; y: 9.2; controlX: 9.2; controlY: 8.0 }
        PathLine { x: 10.2; y: 10.2 }
        PathQuad { x: 10.0; y: 11.3; controlX: 10.5; controlY: 10.8 }
        PathQuad { x: 12.6; y: 13.8; controlX: 10.9; controlY: 13.0 }
        PathQuad { x: 13.8; y: 13.6; controlX: 13.1; controlY: 13.3 }
        PathLine { x: 14.7; y: 14.1 }
        PathQuad { x: 15.4; y: 15.7; controlX: 15.7; controlY: 14.6 }
        PathQuad { x: 13.7; y: 16.5; controlX: 14.9; controlY: 16.6 }
        PathQuad { x: 9.0; y: 13.7; controlX: 10.7; controlY: 16.3 }
        PathQuad { x: 7.8; y: 9.1; controlX: 7.3; controlY: 11.3 }
        PathQuad { x: 8.1; y: 8.4; controlX: 7.9; controlY: 8.6 }
    }
}
