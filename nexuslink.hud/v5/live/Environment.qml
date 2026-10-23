import QtQuick

// Environment: the background slot of the HUD. One instance per output window.
// Portable: imports QtQuick only. Contract: ENV-SPEC section 1 (work5). Properties are exact.
//
//   QML property   type      default           shader name    meaning
//   origin         point     (0,0)             ORG            global desktop pixel of this output's top left
//   world          rect      (0,0,2560,1440)   WORLD          bounding box of all outputs, global pixels
//   (width/height) real      item size         R              this output's size in pixels
//   t              real      0                 T              seconds; the host writes it only if a shader moves
//   par            point     (0,0)             PAR            pointer parallax in px
//   link           real      0                 LINK           Mac round trip, ms
//   ai             real      0                 AI             local AI load 0..1
//   bayA           vector4d  0                 BAY[0..3]      crew slots 0..3 (0 free, 0.5 idle, 1 live)
//   bayB           vector4d  0                 BAY[4], [5]    crew slots 4, 5 in x and y (z, w spare)
//   disk           vector2d  0                 DISK[0..1]     used share of two disks
//   baseColor      color     #06080a                          opaque base of the plain shader
//   running        bool      true                             false hides the effect and its cost
//   debugGrid      bool      false                            100 px grid, 1000 px marks, global pixels (stitch proof)
//
// The output name for the evidence line is objectName (set by the host, e.g. screen.name).
// Evidence line at load, one console.log line:
//   nexuslink-hud environment: output=<name> origin=<x>,<y> size=<w>x<h> world=<x>,<y>,<w>x<h> shader=plain
//
// Behaviour: no Timer, no Canvas, no per-frame JS. The effect redraws only when a bound value changes.
// The host keeps an opaque base under this item, so a failed load never leaves a transparent hole.
Item {
    id: root

    property point origin: Qt.point(0, 0)
    property rect world: Qt.rect(0, 0, 2560, 1440)
    property real t: 0
    property point par: Qt.point(0, 0)
    property real link: 0
    property real ai: 0
    property vector4d bayA: Qt.vector4d(0, 0, 0, 0)
    property vector4d bayB: Qt.vector4d(0, 0, 0, 0)
    property vector2d disk: Qt.vector2d(0, 0)
    property color baseColor: "#06080a"
    property bool running: true
    property bool debugGrid: false

    Component.onCompleted: console.log("nexuslink-hud environment: output="
        + (root.objectName !== "" ? root.objectName : "unnamed")
        + " origin=" + root.origin.x + "," + root.origin.y
        + " size=" + root.width + "x" + root.height
        + " world=" + root.world.x + "," + root.world.y + "," + root.world.width + "x" + root.world.height
        + " shader=plain")

    ShaderEffect {
        id: effect
        anchors.fill: parent
        visible: root.running
        blending: false
        vertexShader: Qt.resolvedUrl("shaders/env.vert.qsb")
        fragmentShader: Qt.resolvedUrl("shaders/env.frag.qsb")

        // Names must equal the uniform block members in shaders/env.frag and env.vert.
        property vector2d origin: Qt.vector2d(root.origin.x, root.origin.y)
        property vector4d world: Qt.vector4d(root.world.x, root.world.y, root.world.width, root.world.height)
        property vector2d itemSize: Qt.vector2d(root.width, root.height)
        property real t: root.t
        property vector2d par: Qt.vector2d(root.par.x, root.par.y)
        property real link: root.link
        property real ai: root.ai
        property vector4d bayA: root.bayA
        property vector4d bayB: root.bayB
        property vector2d disk: Qt.vector2d(root.disk.x, root.disk.y)
        property vector4d baseColor: Qt.vector4d(root.baseColor.r, root.baseColor.g, root.baseColor.b, 1.0)
        property real debugGrid: root.debugGrid ? 1.0 : 0.0
    }
}
