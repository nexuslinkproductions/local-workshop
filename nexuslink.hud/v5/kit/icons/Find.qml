import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: find. System glyph: a lens with a full-length handle, drawn at icon
// weight so the deck never shows a big magnifying glass. 24 px grid, live area
// 4.4..20.4, stroke 2.0, round caps and joins.
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

    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        PathAngleArc {
            centerX: 10.2
            centerY: 10.2
            radiusX: 5.8
            radiusY: 5.8
            startAngle: 0
            sweepAngle: 360
        }
    }
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 14.3
        startY: 14.3
        PathLine { x: 20.4; y: 20.4 }
    }
}
