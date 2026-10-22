import QtQuick
import "../kit"

// WidgetBase.qml - shared shell for every v5 deck widget.
//
// Gives a widget three things so each widget file only draws its own dots:
//   1. idle drift: a 1 to 2 px sine wander computed from the deck tick, never still
//   2. hover grow: the content scales up with a 5 percent overshoot spring on
//      enter (Motion.expandMillis) and eases back slower with no overshoot
//      (Motion.returnMillis) on leave
//   3. a single full-bounds MouseArea that emits clicked()
//
// Children declared inside a WidgetBase land in the transformed content holder.
// The widget size comes from the parent (width and height); lay content out
// relative to width and height, not with fixed pixels, so one file works at
// rest size and at test size.
//
// Pure QtQuick: imports QtQuick and the kit singletons only.
Item {
    id: root

    // ---- inputs from the deck -------------------------------------------
    // Seconds, advanced by the deck's single 30 Hz tick. Never start a Timer
    // inside a widget: read this instead.
    property real tick: 0
    property bool shown: true
    // Radians. Each widget passes its own number so drift phases differ.
    property real phase: 0
    property bool interactive: true
    // Content scale at full hover (1.06 means 6 percent bigger).
    property real hoverScale: 1.06
    property bool expandable: false

    // ---- state ----------------------------------------------------------
    readonly property bool hovered: area.containsMouse
    readonly property bool pressed: area.pressed
    // 0 at rest, 1 while hovered. Animated with the expand and return springs.
    property real grow: area.containsMouse ? 1 : 0

    // ---- outputs --------------------------------------------------------
    signal clicked()
    signal expandRequested()

    // ---- content --------------------------------------------------------
    default property alias content: holder.data

    // Drift: amplitude and periods come from Motion. Hover holds the drift at
    // Motion.driftHeldScale so a grown widget does not slide under the pointer.
    readonly property real driftAmp: Motion.driftAmpMax *
        (1 - (1 - Motion.driftHeldScale) * Math.min(1, Math.max(0, root.grow)))
    readonly property real driftX: root.driftAmp * Math.sin(root.tick * 2 * Math.PI / Motion.driftPeriodMax + root.phase)
    readonly property real driftY: root.driftAmp * 0.7 * Math.sin(root.tick * 2 * Math.PI / Motion.driftPeriodMin + root.phase * 1.7 + 0.9)

    Behavior on grow {
        NumberAnimation {
            duration: area.containsMouse ? Motion.expandMillis : Motion.returnMillis
            easing.type: area.containsMouse ? Easing.OutBack : Easing.InOutQuad
            // 1.22 gives a 4.8 percent peak overshoot on a 0 to 1 move.
            easing.overshoot: 1.22
        }
    }

    Item {
        id: holder
        anchors.fill: parent
        transformOrigin: Item.Center
        scale: 1 + (root.hoverScale - 1) * root.grow
        transform: Translate { x: root.driftX; y: root.driftY }
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        enabled: root.interactive && root.shown
        cursorShape: root.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: {
            root.clicked()
            if (root.expandable)
                root.expandRequested()
        }
    }
}
