import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: crew. System glyph: three nodes in a triangle, the same dot the
// swarm uses for a session. 24 px grid, live area 3.9..20.1, round dots only.
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
        strokeColor: "transparent"
        fillColor: root.color
        PathAngleArc { centerX: 12; centerY: 5.9; radiusX: 2.0; radiusY: 2.0; startAngle: 0; sweepAngle: 360 }
    }
    ShapePath {
        strokeColor: "transparent"
        fillColor: root.color
        PathAngleArc { centerX: 5.9; centerY: 17.8; radiusX: 2.0; radiusY: 2.0; startAngle: 0; sweepAngle: 360 }
    }
    ShapePath {
        strokeColor: "transparent"
        fillColor: root.color
        PathAngleArc { centerX: 18.1; centerY: 17.8; radiusX: 2.0; radiusY: 2.0; startAngle: 0; sweepAngle: 360 }
    }
}
