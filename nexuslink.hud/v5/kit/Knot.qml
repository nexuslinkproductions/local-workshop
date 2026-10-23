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
// rebuilds kit/assets/swarm-knot-sdf-s2.png from the s2-rest.png crop, measures
// the strand half width there (13.04 px) and prints the two constants below.
// C2's default asset is never re-baked; Knot passes its own file. See
// docs/knot-iou.md for the crop, the meters and the achieved IoU.
//
// Contract: Knot { size, accent, focusLevel, activity, assembling,
//                  assembleProgress } plus animate/speed for stills.
// The dim amount is `focusLevel`, never `focus`: Item.focus is FINAL in Qt 6.12.
Item {
    id: root

    property real size: Tokens.knotDiameter
    // s2's knot is azure through ice, so the default is the ice end of that
    // ramp: the shader's depth mix darkens the far dots toward azure (0.72 x)
    // and lifts the cores toward white, which is the s2 range. Acid is a state
    // colour, not the default: a caller can pass Tokens.acid for a focus or
    // assemble cue.
    property color accent: Tokens.ice
    property real focusLevel: 0.0
    property real activity: 0.0

    // Startup sequence: with `assembling` true the points start scattered (the
    // cloud baked into the asset's B channel, hashed offsets up to 28 px) and
    // settle into the traced positions as `assembleProgress` goes 0 -> 1. With
    // `assembling` false the shader is told exactly 1.0, which is its untouched
    // rest path, so the rest frame is identical to a Knot that never assembled.
    property bool assembling: false
    property real assembleProgress: 1.0

    // Ambient motion passthrough. animate: false freezes the tick at phase 0
    // (yaw 0, tilt 0.0401 rad), which is the pose the stills are taken at.
    // breathSkew 0.4 is the card's 40/60 breath: 2.2 s out, 3.3 s back.
    property bool animate: true
    property real speed: 1.0

    // ---- s2 framing -------------------------------------------------------
    // Swarm's own scale rule is u_pxPerUnit = 0.30 * size and its tube radius is
    // a fixed 0.05640288 unit, so the strand half width in px is 0.05640288 *
    // 0.30 * size. The s2 trace's strand half width is 13.04 px, which puts the
    // renderer at 231.16 px per unit, i.e. a 770.5 px Swarm inside this 540 px
    // box. The overhang is empty: the shader writes vec4(0) outside the tube, so
    // nothing is painted outside the knot and nothing needs clipping.
    // KEEP IN SYNC: this number is what `tools/knot-iou.py trace` prints for the
    // shipped asset. A 1.5 percent mismatch costs ~0.09 band_iou (measured).
    readonly property real pxPerUnit: 231.16
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
        breathSkew: 0.4
        // 1.45, not C2's 1.28: the ice accent carries less luminance than the
        // acid one, and this holds the band coverage at the acid build's 0.0623
        // (measured: 0.0619 at 1.28, 0.0624 at 1.45). See docs/knot-iou.md.
        gain: 1.45
        sdfSource: "assets/swarm-knot-sdf-s2.png"
        assemble: root.assembling ? root.assembleProgress : 1.0
    }
}
