import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: power. System glyph: the ring with a 90 degree gap at the top and
// the stem running through the centre, standard shape so it reads before it is
// looked at. 24 px grid, live area 4.2..19.6, stroke 1.5 regular / 2.0 bold.
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
        PathAngleArc {
            centerX: 12
            centerY: 13.0
            radiusX: 6.6
            radiusY: 6.6
            startAngle: 225
            sweepAngle: 270
        }
    }
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 12
        startY: 4.2
        PathLine { x: 12; y: 12.4 }
    }
}
