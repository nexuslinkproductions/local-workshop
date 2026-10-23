import QtQuick
import "../kit"

// WidgetBase.qml - shared shell for every v5 deck widget.
//
// Gives a widget four things so each widget file only draws its own dots:
//   1. idle drift: a 1 to 2 px sine wander computed from the deck tick, never still
//   2. pointer growth: proximity from ProximityField (distance based, hover free)
//      plus hover, whichever is larger, driven by a spring at display rate
//   3. neighbour push: pushX / pushY from ProximityField, spring damped
//   4. a single full-bounds MouseArea that emits clicked()
//
// The grow spring is a value source animation, not a deck-tick animation: it
// runs on the render thread's animation driver at display refresh, so a pointer
// move shows up on the next frame. Nothing here starts a Timer.
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
    // Seconds, advanced by the deck's single 24 Hz tick. Never start a Timer
    // inside a widget: read this instead.
    property real tick: 0
    property bool shown: true
    // Radians. Each widget passes its own number so drift phases differ.
    property real phase: 0
    property bool interactive: true
    // Content scale at full grow (1.12 means 12 percent bigger).
    property real hoverScale: 1.12
    property bool expandable: false

    // ---- inputs from ProximityField --------------------------------------
    // 0 far away, 1 at the pointer. Written by the field, never bound by hand.
    property real proximity: 0
    // Neighbour push in px, the offset the widget wants. Spring damped below.
    property real pushX: 0
    property real pushY: 0

    // ---- state ----------------------------------------------------------
    readonly property bool hovered: area.containsMouse
    readonly property bool pressed: area.pressed
    // Grow target: hover wins, proximity fills the gap in between.
    readonly property real growTarget: Math.max(root.hovered ? 1 : 0,
                                                Math.max(0, Math.min(1, root.proximity)))
    // 0 at rest, 1 fully grown. The Behavior spring below intercepts every
    // write, including the pointer driven ones, so this runs at display rate.
    property real grow: 0
    property real lastTarget: 0
    onGrowTargetChanged: {
        root.rising = root.growTarget > root.lastTarget
        root.lastTarget = root.growTarget
        root.grow = root.growTarget
    }

    // Rise and return use different spring constants, latched on target changes
    // only (never on grow crossing the target), so a rise keeps its overshoot
    // instead of being damped away halfway through.
    property bool rising: true

    // ---- outputs --------------------------------------------------------
    signal clicked()
    signal expandRequested()

    // ---- content --------------------------------------------------------
    default property alias content: holder.data

    // Drift: amplitude and periods come from Motion. Grow holds the drift at
    // Motion.driftHeldScale so a grown widget does not slide under the pointer.
    readonly property real driftAmp: Motion.driftAmpMax *
        (1 - (1 - Motion.driftHeldScale) * Math.min(1, Math.max(0, root.grow)))
    readonly property real driftX: root.driftAmp * Math.sin(root.tick * 2 * Math.PI / Motion.driftPeriodMax + root.phase)
    readonly property real driftY: root.driftAmp * 0.7 * Math.sin(root.tick * 2 * Math.PI / Motion.driftPeriodMin + root.phase * 1.7 + 0.9)

    // ---- springs (display rate, no tick) ---------------------------------
    // The Behavior form is used on purpose: a bare value source SpringAnimation
    // is inert on this Qt build, a Behavior one animates every write.
    Behavior on grow {
        SpringAnimation {
            spring: root.rising ? Motion.growSpring : Motion.growReturnSpring
            damping: root.rising ? Motion.growDamping : Motion.growReturnDamping
            epsilon: Motion.growEpsilon
        }
    }

    // Push offsets: damped, so an offset arrives without wobble and follows a
    // moving pointer instead of snapping.
    property real pushAnimX: 0
    property real pushAnimY: 0
    onPushXChanged: root.pushAnimX = root.pushX
    onPushYChanged: root.pushAnimY = root.pushY
    Behavior on pushAnimX {
        SpringAnimation {
            spring: Motion.pushSpring
            damping: Motion.pushDamping
            epsilon: 0.01
        }
    }
    Behavior on pushAnimY {
        SpringAnimation {
            spring: Motion.pushSpring
            damping: Motion.pushDamping
            epsilon: 0.01
        }
    }

    Item {
        id: holder
        anchors.fill: parent
        transformOrigin: Item.Center
        scale: 1 + (root.hoverScale - 1) * root.grow
        transform: Translate {
            x: root.driftX + root.pushAnimX
            y: root.driftY + root.pushAnimY
        }
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
