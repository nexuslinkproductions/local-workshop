import QtQuick

// Swarm: the triquetra point-swarm renderer (spike winner, option A).
//
// One GPU pass, one fragment shader, no Canvas: the shader ray-marches a tube
// SDF of the traced knot and draws procedural round dot cells on the surface,
// so the dots stay attached to the geometry while the whole cloud wanders in 3D.
//
// Ambient motion runs on an explicit tick, not on the display. A Timer steps
// `phase` (0..1, one 5.5 s cycle) every `tickMs` milliseconds and every animated
// uniform is a pure function of `phase`. MAIN-SCREEN-BUILD.md constraint 3 asks
// for a 24 to 30 Hz tick; 33 ms is 30.3 Hz. The geometry is static and the
// shader runs once per tick, so the tick costs one uniform update.
//
// Properties Wave 1 drives (none of them touch a shader):
//   size        item side in px; one unit is 0.30 * size, so a knot traced at
//               1.0 unit lobe radius lands at 0.30 * size from the centre
//   accent      dot colour; brightness and the white core derive from it
//   focusLevel  0..1 dim for focus mode (1 = dimmed to the design floor)
//   activity    0..1 brightness lift, e.g. a crew session becoming active
//   speed       cycle rate multiplier; 1.0 is the approved 5.5 s cycle
//   phase       0..1 cycle position, advanced by the tick. Set it to desync two
//               swarms, or pin it with animate: false for a deterministic still.
//   animate     false freezes the tick (stills, tests)
//
// Two additions from W1 KNOT (additive, defaults keep every existing caller and
// its rest frame bit-identical):
//   sdfSource   the centre-line distance texture to march. Default is the C2
//               spike trace; Knot passes the s2-fitted trace instead.
//   assemble    0..1: 1 is the rest shape, 0 is fully scattered (startup
//               sequence). The scatter is one hashed offset per dot cell, and at
//               1 the shader skips it entirely, so nothing moves at rest.
Item {
    id: root

    property real size: 540
    property color accent: "#00c8f0"
    property real focusLevel: 0.0
    property real activity: 0.0
    property real speed: 1.0
    property real phase: 0.0
    property bool animate: true
    property url sdfSource: "assets/swarm-knot-sdf.png"
    property real assemble: 1.0
    // Dot brightness multiplier. 1.28 is C2's shipped value; the s2-fitted trace
    // needs more because the trace puts the dot pitch at 4.4 px (s2's is 5.5) and
    // the shader's AA ramp eats the dot radius, so at 1.28 the strand edges fall
    // under the meter's threshold. See docs/knot-iou.md.
    property real gain: 1.28

    // 33 ms is 30.3 Hz: inside the 24 to 30 Hz band the build plan asks for.
    readonly property int tickMs: 33
    readonly property real cycleMs: 5500 / Math.max(0.05, speed)

    implicitWidth: size
    implicitHeight: size
    width: size
    height: size
    clip: false

    // The slow rotational wander: 0.10 rad yaw, 0.045 rad tilt, one cycle each,
    // tilt a quarter turn behind. At phase 0 the pose is yaw 0 / tilt 0.0401,
    // which is the pose the s2 knot frame is scored at (spike still a_knot).
    readonly property real yaw: 0.10 * Math.sin(6.2831853 * phase)
    readonly property real tilt: 0.045 * Math.sin(6.2831853 * phase + 1.1)

    // Wall clock at the previous tick. The tick advances the phase by the time
    // that actually passed, not by tickMs: a timer that is late (a coarse timer,
    // a busy main thread, an OS that throttles a background app) then still
    // keeps the 5.5 s cycle, it only moves in bigger steps. dt is capped so a
    // resume after a long stall does not jump the pose.
    property double lastTickMs: 0

    Timer {
        interval: root.tickMs
        repeat: true
        running: root.visible && root.animate
        triggeredOnStart: true
        onTriggered: {
            var now = Date.now();
            if (root.lastTickMs === 0) {
                root.lastTickMs = now;
                return;
            }
            var dt = Math.min(now - root.lastTickMs, 500);
            root.lastTickMs = now;
            if (dt <= 0)
                return;
            var p = root.phase + dt / root.cycleMs;
            root.phase = p >= 1.0 ? p - Math.floor(p) : p;
        }
    }

    Image {
        id: sdf
        source: root.sdfSource
        visible: false
        smooth: true
    }

    ShaderEffect {
        anchors.fill: parent
        fragmentShader: "shaders/swarm.frag.qsb"
        property var u_sdf: sdf
        property vector2d u_size: Qt.vector2d(root.width, root.height)
        property real u_pxPerUnit: root.width * 0.30
        property vector4d u_accent: Qt.vector4d(root.accent.r, root.accent.g,
                                                root.accent.b, 1.0)
        // 0.45 x the dot pitch: the disc stays inside its cell, so the field
        // reads as discrete points with dark gaps (cell fill 0.37 against s2's
        // 0.36) instead of the touching square tiles a 0.0115 radius produced
        // at the old 0.01617 pitch (disc 1.42 x pitch).
        property real u_dotR: 0.0086
        property real u_pitch: 0.01907400
        property real u_rTube: 0.05640288
        property real u_rRing: 0.01277046
        property real u_yaw: root.yaw
        property real u_tilt: root.tilt
        property real u_camDist: 6.0
        property vector2d u_sdfLo: Qt.vector2d(-1.45, -1.45)
        property real u_sdfSpan: 2.9
        property real u_sdfRange: 0.42
        property real u_shape: 0.0
        property real u_gain: root.gain
        property real u_focus: root.focusLevel
        property real u_activity: root.activity
        property real u_stipple: 0.94
        property real u_assemble: root.assemble
    }
}
