import QtQuick

// Swarm option C still, knot. One quad; the fragment shader does the neighbour
// lookup in the baked cell lists.
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
    property color accent: "#00c8f0"

    Image {
        id: pts
        source: "../assets/swarm-knot-cells.png"
        visible: false
        smooth: false
    }
    Image {
        id: counts
        source: "../assets/swarm-knot-cellcount.png"
        visible: false
        smooth: false
    }

    ShaderEffect {
        anchors.fill: parent
        fragmentShader: "../shaders/swarm_c.frag.qsb"
        property var u_pts: pts
        property var u_counts: counts
        property vector2d u_size: Qt.vector2d(root.width, root.height)
        property real u_pxPerUnit: root.width * root.knotScale
        property vector4d u_accent: Qt.vector4d(root.accent.r, root.accent.g, root.accent.b, 1.0)
        property vector3d u_posBase: Qt.vector3d(-1.218089, -1.218089, -0.048528)
        property real u_pitch: 0.01617480
        property real u_dotR: root.dotR
        property real u_rTube: 0.05640288
        property real u_yaw: root.yaw
        property real u_tilt: root.tilt
        property real u_camDist: 6.0
        property real u_gain: root.gain
        property real u_focus: root.focusLevel
        property real u_activity: root.activity
        property vector4d u_texInfo: Qt.vector4d(33, 33, 128, 1089)
        property vector4d u_cellInfo: Qt.vector4d(-1.093975, -1.126327, 0.06810913, 0)
        property vector2d u_cellN: Qt.vector2d(33, 33)
    }
}
