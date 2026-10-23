import QtQuick

// Swarm: the triquetra point-swarm renderer (spike winner, option A).
//
// One GPU pass, one fragment shader, no Canvas and no per-frame JavaScript: the
// shader ray-marches a tube SDF of the traced knot and draws procedural round
// dot cells on the surface, so the dots stay attached to the geometry while the
// whole cloud wanders in 3D and breathes.
//
// Properties Wave 1 drives (none of them touch a shader):
//   size        item side in px; the ring lands at 0.30 * size (s2 framing)
//   accent      dot colour; brightness and the white core derive from it
//   focusLevel  0..1 dim for focus mode (1 = dimmed to the design floor)
//   activity    0..1 brightness lift, e.g. a crew session becoming active
//   speed       breath rate multiplier; 1.0 is the approved 5.5 s cycle
//
// The animation is a QML SequentialAnimation, so Qt advances it on the render
// thread without running any JS per frame.
Item {
    id: root

    property real size: 540
    property color accent: "#00c8f0"
    property real focusLevel: 0.0
    property real activity: 0.0
    property real speed: 1.0

    implicitWidth: size
    implicitHeight: size
    width: size
    height: size
    clip: false

    // 0..1 breath, 40 percent in and 60 percent out of a 5.5 s cycle
    property real breath: 0.0
    readonly property real cycleMs: 5500 / Math.max(0.05, speed)

    SequentialAnimation on breath {
        running: root.visible
        loops: Animation.Infinite
        NumberAnimation {
            from: 0.0; to: 1.0
            duration: root.cycleMs * 0.4
            easing.type: Easing.InOutSine
        }
        NumberAnimation {
            from: 1.0; to: 0.0
            duration: root.cycleMs * 0.6
            easing.type: Easing.InOutSine
        }
    }

    Image {
        id: sdf
        source: "assets/swarm-knot-sdf.png"
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
        property real u_dotR: 0.0115
        property real u_pitch: 0.01617480
        property real u_rTube: 0.05640288
        property real u_rRing: 0.01277046
        // slow rotational wander: 0.10 rad yaw, 0.045 rad tilt, never still
        property real u_yaw: 0.10 * (root.breath - 0.5) * 2.0
        property real u_tilt: 0.045 * (root.breath * 2.0 - 1.0)
        property real u_camDist: 6.0
        property vector2d u_sdfLo: Qt.vector2d(-1.45, -1.45)
        property real u_sdfSpan: 2.9
        property real u_sdfRange: 0.42
        property real u_shape: 0.0
        property real u_gain: 1.0
        property real u_focus: root.focusLevel
        property real u_activity: root.activity
        property real u_stipple: 0.86
    }
}
