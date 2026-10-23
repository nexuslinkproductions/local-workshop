pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0
import "icons" as Icons

// QuickActions.qml - the five icon-only quick actions on the bottom edge.
// Owner: worker Q. Pure QtQuick plus the kit's own Power glyph. No Quickshell.
//
// Contract (do not rename without telling the lead):
//   mediaPlaying, mediaAvailable: bool   drive the first glyph
//   signal actionRequested(string actionId)
//   ids: visualizer | apps | screen-scan | text-scan | power
//
// The component fills the deck (anchors.fill) and places its five icons on the
// row rowY, at the centres below. The left pair sits beside the media pill
// (pill x 250..567); the right trio sits on the right margin. Every target is a
// 56 px MouseArea over its full bounds. Icons only: no boxes, no outlines, no
// glow. Colour: ice at rest, white on hover (brighter, never darker), acid only
// while media plays. Hover also lifts the glyph by a small scale.
Item {
    id: root

    property bool mediaPlaying: false
    property bool mediaAvailable: false

    signal actionRequested(string actionId)

    // ---- named constants (Tokens has no quick-action entries) -------------
    // Icon centres on the 2560 x 1440 surface, measured on e-rest.png.
    readonly property real rowY: 1310
    readonly property real visualizerX: 118
    readonly property real appsX: 194
    readonly property real screenScanX: 2290
    readonly property real textScanX: 2366
    readonly property real powerX: 2440
    // Hit bounds per icon, px (the kit rule: a MouseArea over the full 56 px).
    readonly property int targetSize: 56
    // Visible glyph box: Tokens.sp5 (55 px). The 16-unit live area of the 24 px
    // grid then reads about 32 to 38 px on screen, as e-rest measures.
    readonly property real glyphSize: Tokens.sp5
    // Glyphs are drawn on the 24 px grid and scaled to glyphSize.
    readonly property real gridScale: glyphSize / 24
    readonly property real strokeWeight: 1.6   // grid units, about 2.3 px on screen
    readonly property real dotRadius: 1.6      // apps grid dot, grid units
    // Visualizer ring radius, grid units. 9.5 drew about 47 px outer on screen;
    // 7.05 gives about 36 px outer at glyphSize 55 (design e-rest: about 36 px).
    readonly property real ringRadius: 7.05
    readonly property real hoverScale: 1.08
    // Visualizer with no media player: dimmed, a little brighter on hover.
    readonly property real dimOpacity: 0.28
    readonly property real dimHoverOpacity: 0.55
    readonly property color restInk: Tokens.ice
    readonly property color hoverInk: Tokens.white
    readonly property color liveInk: Tokens.acid

    // One hit target: a 56 px MouseArea centred on (centreX, rowY). The glyph
    // children are placed in `holder`, which lifts on hover.
    component QuickTarget: Item {
        id: target

        property string actionId: ""
        property real centreX: 0
        property bool live: false
        property bool dimmed: false
        default property alias glyph: holder.data

        readonly property bool hovered: area.containsMouse
        readonly property color ink: target.live ? root.liveInk
            : (target.hovered ? root.hoverInk : root.restInk)
        readonly property real inkOpacity: target.dimmed
            ? (target.hovered ? root.dimHoverOpacity : root.dimOpacity) : 1

        x: target.centreX - root.targetSize / 2
        y: root.rowY - root.targetSize / 2
        width: root.targetSize
        height: root.targetSize

        MouseArea {
            id: area

            objectName: "quick-" + target.actionId
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.actionRequested(target.actionId)
        }

        Item {
            id: holder

            objectName: "glyph-" + target.actionId
            anchors.centerIn: parent
            width: root.glyphSize
            height: root.glyphSize
            opacity: target.inkOpacity
            scale: target.hovered ? root.hoverScale : 1
        }
    }

    // Four corner brackets on the 24 px grid, inset to 4..20, round caps.
    component Brackets: Shape {
        id: brackets

        property color ink: Tokens.ice

        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: brackets.ink
            strokeWidth: root.strokeWeight
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            startX: 4
            startY: 9.5
            PathLine { x: 4; y: 4 }
            PathLine { x: 9.5; y: 4 }
        }
        ShapePath {
            strokeColor: brackets.ink
            strokeWidth: root.strokeWeight
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            startX: 14.5
            startY: 4
            PathLine { x: 20; y: 4 }
            PathLine { x: 20; y: 9.5 }
        }
        ShapePath {
            strokeColor: brackets.ink
            strokeWidth: root.strokeWeight
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            startX: 4
            startY: 14.5
            PathLine { x: 4; y: 20 }
            PathLine { x: 9.5; y: 20 }
        }
        ShapePath {
            strokeColor: brackets.ink
            strokeWidth: root.strokeWeight
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            startX: 20
            startY: 14.5
            PathLine { x: 20; y: 20 }
            PathLine { x: 14.5; y: 20 }
        }
    }

    // ---- 1. visualizer: ring with level bars (playing) or a play mark (paused)
    QuickTarget {
        id: visualizer

        actionId: "visualizer"
        centreX: root.visualizerX
        live: root.mediaPlaying
        dimmed: !root.mediaAvailable

        Item {
            anchors.centerIn: parent
            width: 24
            height: 24
            scale: root.gridScale

            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer

                ShapePath {
                    strokeColor: visualizer.ink
                    strokeWidth: root.strokeWeight
                    fillColor: "transparent"
                    PathAngleArc {
                        centerX: 12
                        centerY: 12
                        radiusX: root.ringRadius
                        radiusY: root.ringRadius
                        startAngle: 0
                        sweepAngle: 360
                    }
                }
            }

            Rectangle {
                objectName: "vis-bars"
                visible: root.mediaPlaying
                x: 8.2 - 1.1
                y: 9
                width: 2.2
                height: 6
                radius: 1.1
                color: visualizer.ink
            }
            Rectangle {
                visible: root.mediaPlaying
                x: 12 - 1.1
                y: 7
                width: 2.2
                height: 10
                radius: 1.1
                color: visualizer.ink
            }
            Rectangle {
                visible: root.mediaPlaying
                x: 15.8 - 1.1
                y: 9.75
                width: 2.2
                height: 4.5
                radius: 1.1
                color: visualizer.ink
            }

            Shape {
                objectName: "vis-play"
                anchors.fill: parent
                visible: !root.mediaPlaying
                preferredRendererType: Shape.CurveRenderer

                ShapePath {
                    strokeColor: "transparent"
                    fillColor: visualizer.ink
                    startX: 10.2
                    startY: 8.4
                    PathLine { x: 16.2; y: 12 }
                    PathLine { x: 10.2; y: 15.6 }
                    PathLine { x: 10.2; y: 8.4 }
                }
            }
        }
    }

    // ---- 2. apps: 3 x 3 grid of dots, focuses the launcher ----------------
    QuickTarget {
        id: apps

        actionId: "apps"
        centreX: root.appsX

        Item {
            anchors.centerIn: parent
            width: 24
            height: 24
            scale: root.gridScale

            Repeater {
                model: 9

                Rectangle {
                    required property int index

                    readonly property real cellX: 6 + (index % 3) * 6
                    readonly property real cellY: 6 + Math.floor(index / 3) * 6

                    x: cellX - root.dotRadius
                    y: cellY - root.dotRadius
                    width: root.dotRadius * 2
                    height: root.dotRadius * 2
                    radius: root.dotRadius
                    color: apps.ink
                }
            }
        }
    }

    // ---- 3. screen scan: corner brackets around a dot ---------------------
    QuickTarget {
        id: screenScan

        actionId: "screen-scan"
        centreX: root.screenScanX

        Item {
            anchors.centerIn: parent
            width: 24
            height: 24
            scale: root.gridScale

            Brackets { ink: screenScan.ink }

            Rectangle {
                x: 10
                y: 10
                width: 4
                height: 4
                radius: 2
                color: screenScan.ink
            }
        }
    }

    // ---- 4. text scan: corner brackets around a line ----------------------
    QuickTarget {
        id: textScan

        actionId: "text-scan"
        centreX: root.textScanX

        Item {
            anchors.centerIn: parent
            width: 24
            height: 24
            scale: root.gridScale

            Brackets { ink: textScan.ink }

            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer

                ShapePath {
                    strokeColor: textScan.ink
                    strokeWidth: root.strokeWeight
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    startX: 7.5
                    startY: 12
                    PathLine { x: 16.5; y: 12 }
                }
            }
        }
    }

    // ---- 5. power: the kit's own power glyph (opens the system menu) ------
    QuickTarget {
        id: power

        actionId: "power"
        centreX: root.powerX

        Icons.Power {
            anchors.centerIn: parent
            color: power.ink
            weight: root.strokeWeight
            size: root.glyphSize
        }
    }
}
