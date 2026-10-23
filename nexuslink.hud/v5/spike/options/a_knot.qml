import QtQuick

// Swarm option A still, knot. Default framing matches the s2 knot frame: the
// ring lands at knotScale * width (0.30 -> 216 px in a 720 crop). knotScale
// 0.435 reproduces the s1 crop framing (237 px ring in a 540 crop).
Item {
    id: root
    width: 720
    height: 720

    property real knotScale: 0.30
    property real benchPhase: 0.0
    property real yaw: 0.10 * Math.sin(benchPhase * 6.2831853)
    property real tilt: 0.045 * Math.sin(benchPhase * 10.7 + 1.1)
    property real gain: 1.0
    property real activity: 0.0
    property real focusLevel: 0.0
    property real dotR: 0.0115
    property real stipple: 0.86
    property color accent: "#00c8f0"

    Image {
        id: sdf
        source: "../assets/swarm-knot-sdf.png"
        visible: false
        smooth: true
    }

    ShaderEffect {
        anchors.fill: parent
        fragmentShader: "../shaders/swarm_a.frag.qsb"
        property var u_sdf: sdf
        property vector2d u_size: Qt.vector2d(root.width, root.height)
        property real u_pxPerUnit: root.width * root.knotScale
        property vector4d u_accent: Qt.vector4d(root.accent.r, root.accent.g, root.accent.b, 1.0)
        property real u_dotR: root.dotR
        property real u_pitch: 0.01617480
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
        property real u_stipple: root.stipple
    }
}
