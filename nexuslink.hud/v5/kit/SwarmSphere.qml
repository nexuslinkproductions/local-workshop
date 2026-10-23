import QtQuick

// SwarmSphere: the crew orb, the same dot language as Swarm on a sphere.
//
// This uses the option B path (vertex expansion over a GridMesh: one vertex per
// dot, read from a data texture) rather than Swarm's raymarched SDF. The
// raymarch sphere branch does not render at orb size: the fragment shader builds
// its ray nearly orthographically while `project()` places the dot centres with
// a perspective scale, and at a 3 px dot pitch the mismatch exceeds the dot
// radius, so almost every fragment rejects every dot. Measured on this Mac, the
// raymarched unit sphere at dotR 0.0100 / pitch 0.0268 gives max luminance
// 23-30 of 255 at 540 and 1080 (black frame, 0.0000 lit at 0.35); at 224 the
// same shader is black. The vertex path is exact on a sphere and was measured at
// 0.994 ms (p95 1.587) at 224 px and 1.335 ms (p95 1.778) at 320 px.
//
// The shell is a dense cube-lattice sample, so the dots land about one pitch
// apart and read as a mesh at orb size. `u_stipple` keeps a share of the lattice
// points (hashed per dot) to turn it back into discrete round points with gaps;
// at 320 px the measured merge ratio goes from 0.16 (fused clusters) to 0.36,
// and the 4x crops show separate round points.
//
// Motion: same 24 to 30 Hz tick as Swarm. A Timer steps `phase` (0..1 per 5.5 s
// cycle) and the pose is a pure function of it, so two orbs with different
// starting phases stay out of step without any per-frame animation.
//
// Properties match Swarm: size, accent, focusLevel, activity, speed, plus phase
// so Wave 1 can run several orbs out of step, and animate for stills.
Item {
    id: root

    property real size: 224
    property color accent: "#00c8f0"
    property real focusLevel: 0.0
    property real activity: 0.0
    property real speed: 1.0
    property real phase: 0.0
    property bool animate: true

    readonly property int tickMs: 33
    readonly property real cycleMs: 5500 / Math.max(0.05, speed)

    implicitWidth: size
    implicitHeight: size
    width: size
    height: size

    // 0.16 rad yaw, 0.09 rad tilt, one cycle each, tilt behind by 1.1 rad.
    readonly property real yaw: 0.16 * Math.sin(6.2831853 * phase)
    readonly property real tilt: 0.09 * Math.sin(6.2831853 * phase + 1.1)

    // Same wall-clock tick as Swarm: the phase moves by the time that actually
    // passed, capped so a stall cannot jump the pose.
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
        property real u_dotR: 0.0085
        property real u_rTube: 0.5
        property real u_yaw: root.yaw
        property real u_tilt: root.tilt
        property real u_camDist: 6.0
        property real u_gain: 1.28
        property real u_focus: root.focusLevel
        property real u_activity: root.activity
        property vector4d u_texInfo: Qt.vector4d(160, 120, 128, 0)
        property vector4d u_cellInfo: Qt.vector4d(0, 0, 0, 0)
        property vector2d u_cellN: Qt.vector2d(0, 0)
        property real u_stipple: 0.30
        mesh: GridMesh { resolution: Qt.size(160, 120) }
    }
}
