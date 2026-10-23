import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: wifi. System glyph: two arcs and one node, the link signal. Arc
// gaps widen on the outer arc so the three radii read as evenly spaced, and the
// whole mark sits high enough that its ink centre lands on the grid centre. 24
// px grid, live area 3.4..20.6, stroke 2.0, round caps.
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

    // node
    ShapePath {
        strokeColor: "transparent"
        fillColor: root.color
        PathAngleArc { centerX: 12; centerY: 16.2; radiusX: 1.4; radiusY: 1.4; startAngle: 0; sweepAngle: 360 }
    }
    // inner arc
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        PathAngleArc {
            centerX: 12
            centerY: 16.4
            radiusX: 5.0
            radiusY: 5.0
            startAngle: 216
            sweepAngle: 108
        }
    }
    // outer arc
    ShapePath {
        strokeColor: root.color
        strokeWidth: root.weight
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        PathAngleArc {
            centerX: 12
            centerY: 16.4
            radiusX: 8.6
            radiusY: 8.6
            startAngle: 219
            sweepAngle: 102
        }
    }
}
