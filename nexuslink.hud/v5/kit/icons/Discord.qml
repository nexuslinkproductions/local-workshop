import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: discord. Brand mark, redrawn monochrome on the same grid: the wide
// face with two ear tufts, a low centre dip and two eye nodes. 24 px grid, live
// area 2.8..21.2, stroke 1.5 regular / 2.0 bold, round caps and joins.
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
        startX: 4.0
        startY: 7.6
        PathQuad { x: 7.2; y: 5.8; controlX: 4.6; controlY: 6.0 }
        PathQuad { x: 12.0; y: 7.0; controlX: 9.8; controlY: 5.4 }
        PathQuad { x: 16.8; y: 5.8; controlX: 14.2; controlY: 5.4 }
        PathQuad { x: 20.0; y: 7.6; controlX: 19.4; controlY: 6.0 }
        PathQuad { x: 20.6; y: 13.6; controlX: 21.2; controlY: 10.4 }
        PathQuad { x: 12.0; y: 19.2; controlX: 20.2; controlY: 18.4 }
        PathQuad { x: 3.4; y: 13.6; controlX: 3.8; controlY: 18.4 }
        PathQuad { x: 4.0; y: 7.6; controlX: 2.8; controlY: 10.4 }
    }
    // eye nodes
    ShapePath {
        strokeColor: "transparent"
        fillColor: root.color
        PathAngleArc { centerX: 8.6; centerY: 12.4; radiusX: 1.6; radiusY: 1.6; startAngle: 0; sweepAngle: 360 }
    }
    ShapePath {
        strokeColor: "transparent"
        fillColor: root.color
        PathAngleArc { centerX: 15.4; centerY: 12.4; radiusX: 1.6; radiusY: 1.6; startAngle: 0; sweepAngle: 360 }
    }
}
