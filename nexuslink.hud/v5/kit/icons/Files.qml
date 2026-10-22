import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph: files. Custom mark: a folder with a deep cut tab, so the tab still
// reads at 24 px. 24 px grid, live area 3.4..20.6, stroke 1.5 regular / 2.0
// bold, round caps and joins.
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
        startY: 19.2
        PathLine { x: 3.4; y: 6.2 }
        PathLine { x: 9.0; y: 6.2 }
        PathLine { x: 11.4; y: 8.9 }
        PathLine { x: 20.6; y: 8.9 }
        PathLine { x: 20.6; y: 19.2 }
        PathLine { x: 3.4; y: 19.2 }
    }
}
