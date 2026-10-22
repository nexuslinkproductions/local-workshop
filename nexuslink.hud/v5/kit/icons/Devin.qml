import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: devin. Custom mark: a node diamond with one centre dot, the agent
// reading of the dot language. 24 px grid, live area 3.4..20.6, stroke 1.5
// regular / 2.0 bold, round caps and joins.
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
        startX: 12
        startY: 3.4
        PathLine { x: 20.4; y: 12 }
        PathLine { x: 12; y: 20.6 }
        PathLine { x: 3.6; y: 12 }
        PathLine { x: 12; y: 3.4 }
    }
    // centre node
    ShapePath {
        strokeColor: "transparent"
        fillColor: root.color
        PathAngleArc {
            centerX: 12
            centerY: 12
            radiusX: 2.0
            radiusY: 2.0
            startAngle: 0
            sweepAngle: 360
        }
    }
}
