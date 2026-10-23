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
// same shader is black. The vertex path is exact on a sphere and measures 0.77 ms
// (p95 1.28) at 224 px and 1.07 ms (p95 1.61) at 320 px after the ring rebuild.
//
// The dot field: 3,664 dots on a unit sphere in a ring layout (one ring per
// mesh row, dots spread evenly round it and jittered by up to 45 percent of a
// ring step), so texel neighbours are neighbours on the sphere in both axes. At
// 224 px that is a 5.9 to 8.8 px ring pitch with a 2.0 px radius disc on the near
// side and 1.1 px at the limb: about 0.4 of the pitch, so neighbours keep a dark
// gap. The radius carries a depth mix on top of perspective (shader), and near
// dots are brighter than limb dots.
//
// The mesh cell has to stay wider than a dot's disc (2.36 px at 224, 3.37 px at
// 320 against a 2.0 px near disc at 224 and 2.9 px at 320): the four quads that
// meet at a dot are what draw it, so a finer mesh clips discs to squares. That is
// why the data grid is 96 x 60 and not the knot's 160 x 120.
//
// Layout history, so it is not undone: the dots used to be baked in a
// nearest-neighbour walk order, which put dots that are far apart on the sphere
// into adjacent texels. The quads then spanned the sphere and each disc was drawn
// only by the ribbons crossing it, which is why a 3.4 px disc rendered as a 1 to
// 2 px dash with one straight edge.
//
// Motion: same 24 to 30 Hz tick as Swarm. A Timer steps `phase` (0..1 per 5.5 s
// cycle) and the pose is a pure function of it, so two orbs with different
// starting phases stay out of step without any per-frame animation. The same
// tick advances `breathPhase` over Motion.breathPeriod (5.8 s), which drives a
// 2 percent dot scale and a 14 percent brightness lift: eased in over the first
// 40 percent of the cycle and out over the last 60. Still renders with
// `animate: false` sit at breath 0, so a still is a fixed frame.
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

    // Breath, from the Motion singleton: 5.8 s, 40 percent in, 60 percent out.
    // Its own accumulator so it does not ride on the 5.5 s rotation wander.
    readonly property real breathPeriodMs: Motion.breathPeriod * 1000
    property double breathPhase: 0.0
    readonly property real breath: {
        var p = breathPhase;
        var u = p < Motion.breathInhale
                ? p / Motion.breathInhale
                : 1.0 - (p - Motion.breathInhale) / Motion.breathExhale;
        u = Math.max(0.0, Math.min(1.0, u));
        return u * u * (3.0 - 2.0 * u);
    }
    readonly property real breathScale: 1.0 + Motion.breathScale * breath
    readonly property real breathBright: 1.0 + Motion.breathBright * breath

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
            var b = root.breathPhase + dt / root.breathPeriodMs;
            root.breathPhase = b >= 1.0 ? b - Math.floor(b) : b;
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
        // the orb grid stores p * 127 + 127, so one step is 1/127 unit and the
        // base is -127 steps
        property vector3d u_posBase: Qt.vector3d(-1.0, -1.0, -1.0)
        property real u_pitch: 0.0078740157
        // 2.0 px radius at 224 on the near side, 1.1 px at the limb: about 0.4 of
        // the ring pitch, so the lattice keeps a dark gap all round.
        property real u_dotR: 0.0148
        property real u_rTube: 0.5
        property real u_yaw: root.yaw
        property real u_tilt: root.tilt
        property real u_camDist: 6.0
        property real u_gain: 0.95
        property real u_focus: root.focusLevel
        property real u_activity: root.activity
        property vector4d u_texInfo: Qt.vector4d(96, 60, 128, 0)
        property vector4d u_cellInfo: Qt.vector4d(0, 0, 0, 0)
        property vector2d u_cellN: Qt.vector2d(0, 0)
        // All dots are kept: the ring layout already spaces them 5.9 to 8.8 px
        // apart at 224 and the row rounding gives the field its irregularity.
        property real u_stipple: 1.0
        property real u_breathScale: root.breathScale
        property real u_breathBright: root.breathBright
        mesh: GridMesh { resolution: Qt.size(96, 60) }
    }
}
