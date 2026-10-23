import QtQuick

// SwarmSphere: the crew orb, the same dot language as Swarm on a sphere.
//
// This uses the option B path (vertex expansion over a GridMesh: one vertex per
// dot, read from a data texture) rather than Swarm's raymarched SDF, because the
// raymarch sphere branch loses most dots at orb size: the surface cell centre
// sits up to half a lattice cell off the sphere, so the dot disc test rejects
// almost every fragment (measured: 28 lit pixels on a 224 px orb). The vertex
// path is exact on a sphere and costs less than the raymarch at this size.
//
// Properties match Swarm: size, accent, focusLevel, activity, speed, plus phase
// so Wave 1 can run several orbs out of step.
Item {
    id: root

    property real size: 224
    property color accent: "#00c8f0"
    property real focusLevel: 0.0
    property real activity: 0.0
    property real speed: 1.0
    property real phase: 0.0

    implicitWidth: size
    implicitHeight: size
    width: size
    height: size

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
        id: pts
        source: "assets/swarm-orb-grid.png"
        visible: false
        smooth: false
    }

    ShaderEffect {
        anchors.fill: parent
        vertexShader: "shaders/swarm_vertex.vert.qsb"
        fragmentShader: "shaders/swarm_vertex.frag.qsb"
        property var u_pts: pts
        property vector2d u_size: Qt.vector2d(root.width, root.height)
        property real u_pxPerUnit: root.width * 0.5
        property vector4d u_accent: Qt.vector4d(root.accent.r, root.accent.g,
                                                root.accent.b, 1.0)
        // the orb cloud stores q = round(p / pitch) + 64, so the base is -64 pitch
        property vector3d u_posBase: Qt.vector3d(-1.7152, -1.7152, -1.7152)
        property real u_pitch: 0.0268
        property real u_dotR: 0.0135
        property real u_rTube: 0.5
        property real u_yaw: 0.16 * (root.breath - 0.5) * 2.0
        property real u_tilt: 0.09 * (root.breath * 2.0 - 1.0)
        property real u_camDist: 6.0
        property real u_gain: 1.0
        property real u_focus: root.focusLevel
        property real u_activity: root.activity
        property vector4d u_texInfo: Qt.vector4d(160, 120, 128, 0)
        property vector4d u_cellInfo: Qt.vector4d(0, 0, 0, 0)
        property vector2d u_cellN: Qt.vector2d(0, 0)
        mesh: GridMesh { resolution: Qt.size(160, 120) }
    }
}
