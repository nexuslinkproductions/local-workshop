import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: spotify. Brand mark, redrawn monochrome on the same grid: the disc
// ring with three bars inside, longest at the top and each a low hump, so the
// mark reads as one sound wave and not three ticks. The bars stop short of the
// ring on every axis, so the disc stays the outline. 24 px grid, live area
// 2.8..21.2, stroke 2.0, round caps and joins.
Shape {
    id: root
    property color color: Tokens.ink
    property real weight: 2.0
    property real size: 24

    implicitWidth: 24
    implicitHeight: 24
    width: 24
    height: 24
    scale: size / 24
    transformOrigin: Item.Center
    preferredRendererType: Shape.CurveRenderer

    // disc
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        PathAngleArc { centerX: 12; centerY: 12; radiusX: 8.2; radiusY: 8.2; startAngle: 0; sweepAngle: 360 }
    }
    // three bars: top longest, bottom shortest, each humped 0.9 above its ends
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 6.9
        startY: 10.2
        PathQuad { x: 17.1; y: 10.2; controlX: 12.0; controlY: 8.4 }
    }
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 7.9
        startY: 13.2
        PathQuad { x: 16.1; y: 13.2; controlX: 12.0; controlY: 11.6 }
    }
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 9.0
        startY: 16.2
        PathQuad { x: 15.0; y: 16.2; controlX: 12.0; controlY: 14.7 }
    }
}
