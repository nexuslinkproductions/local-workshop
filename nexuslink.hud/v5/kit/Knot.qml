import QtQuick
import NexusHud.V5 1.0

// Knot: the 540 px triquetra point swarm (W1).
//
// Nothing is rendered here that C2's Swarm does not already do: one raymarched
// tube SDF, procedural round dots on its surface, a 30 Hz tick and a 5.5 s
// breath. Knot is the placement and state wrapper the deck composes, so the
// whole component is one Swarm plus the numbers that turn the s2 trace into a
// 540 px frame. No Canvas, no second shader, no per-frame JS, no glow.
//
// The trace is fitted to s2, not to the logo-r1 SVG: `tools/knot-iou.py trace`
// rebuilds kit/assets/swarm-knot-sdf.png from the s2-rest.png crop, measures the
// strand half width there (12.81 px) and prints the two constants below. See
// docs/knot-iou.md for the crop, the meters and the achieved IoU.
//
// Contract: Knot { size, accent, focusLevel, activity, assembling,
//                  assembleProgress } plus animate/speed for stills.
// The dim amount is `focusLevel`, never `focus`: Item.focus is FINAL in Qt 6.12.
Item {
    id: root

    property real size: Tokens.knotDiameter
    property color accent: Tokens.acid
    property real focusLevel: 0.0
    property real activity: 0.0

    // Startup sequence: with `assembling` true the points sit scattered and
    // settle into the triquetra as `assembleProgress` goes 0 -> 1. With
    // `assembling` false the shader is told exactly 1.0, which is its untouched
    // rest path, so the rest frame is identical to a Knot that never assembled.
    property bool assembling: false
    property real assembleProgress: 1.0

    // Ambient motion passthrough. animate: false freezes the tick at phase 0
    // (yaw 0, tilt 0.0401 rad), which is the pose the stills are taken at.
    property bool animate: true
    property real speed: 1.0

    // ---- s2 framing -------------------------------------------------------
    // Swarm's own scale rule is u_pxPerUnit = 0.30 * size and its tube radius is
    // a fixed 0.05640288 unit, so the strand half width in px is 0.05640288 *
    // 0.30 * size. The s2 trace's strand half width is 12.81 px, which puts the
    // renderer at 227.05 px per unit, i.e. a 757 px Swarm inside this 540 px
    // box. The overhang is empty: the shader writes vec4(0) outside the tube, so
    // nothing is painted outside the knot and nothing needs clipping.
    readonly property real pxPerUnit: 227.05
    readonly property real swarmSize: size * pxPerUnit / Tokens.knotDiameter / 0.30

    implicitWidth: size
    implicitHeight: size
    width: size
    height: size

    // Default placement is the deck's knot box (Tokens.centreX, goldenY1); a
    // parent that anchors this item overrides it.
    x: Tokens.knotCentreX - size / 2.0
    y: Tokens.knotCentreY - size / 2.0

    Swarm {
        anchors.centerIn: parent
        size: root.swarmSize
        accent: root.accent
        focusLevel: root.focusLevel
        activity: root.activity
        animate: root.animate
        speed: root.speed
        sdfSource: "assets/swarm-knot-sdf.png"
        assemble: root.assembling ? root.assembleProgress : 1.0
    }
}
