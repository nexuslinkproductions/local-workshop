pragma ComponentBehavior: Bound
import QtQuick

// KnotSwarm: the knot as a continuous fine particle strand (round 5, spec
// KNOT-SPEC-R5 section 4). Portable component: it imports QtQuick only, reads
// its data through Qt.resolvedUrl (copy the whole folder anywhere), and has no
// Timer, no Canvas, no per frame JS, no kit or Tokens, no Quickshell.
//
// Interface (keep these names, DeckView and verify/knot.qml use them):
//   t            real, seconds, written by the deck at 24 to 30 Hz (the only clock)
//   running      bool, false hides the effect and costs nothing (default true)
//   knotPx       real, knot width in px at the 540 reference (default 540)
//   width        real, item size, the knot is centred in it (default 700)
//   height       real, item size (default 700)
//   pointsSource url, the point texture (default shaders/knot-points5.png:
//                2048 x 178 RGB, 11 texels per point, 33000 points, nearest,
//                no mipmap; the shader constants TEX_ROWS and N must match)
//   pointCount   int, read only, 33000
//
// Deck B mapping (PORTING-RULES section 3): kit/Knot.qml wraps kit/Swarm.qml.
// The port swaps its inner Swarm for KnotSwarm: Knot.size -> knotPx (the knot
// is knotPx px across), Knot.animate -> running, and the deck tick -> t.
// Knot.accent, focusLevel, activity, assembling, assembleProgress and speed
// have no counterpart in KnotSwarm and are not read here.
//
// Mesh: one GridMesh of 2 x sliceSize columns per slice. A single GridMesh of
// all 33000 points would need 132002 vertices, above the 65535 limit of the
// 16 bit index buffer, so the points are drawn in slices of at most 16000
// (a Repeater of ShaderEffect items, each with uOffset = first point).
Item {
    id: root

    // seconds, written by the deck
    property real t: 0
    // when false the shader is hidden and costs nothing
    property bool running: true
    // width of the knot in pixels (the mark is 540 px across at knotPx 540)
    property real knotPx: 540
    // point texture, see the header. A scene may swap the whole point set here.
    property url pointsSource: Qt.resolvedUrl("shaders/knot-points5.png")

    // CALM (P4): the acid sparks follow the strand dimming (shaders/knot.vert DIM 0.85)
    readonly property real sparkDim: 0.85

    readonly property int pointCount: 33000
    // texture layout, keep in sync with TEXEL_STRIDE / TEX_ROWS / TEX_WIDTH at
    // the top of shaders/knot.vert
    readonly property int texelStride: 11
    readonly property int texRows: 178
    readonly property int texWidth: 2048

    // slices of at most 16000 points each (vertex limit of one GridMesh)
    readonly property int sliceCount: Math.ceil(pointCount / 16000)
    readonly property int sliceSize: Math.ceil(pointCount / sliceCount)

    width: 700
    height: 700

    // point data, one point per 11 texels, see shaders/knot.vert for the fields
    Image {
        id: points
        width: root.texWidth
        height: root.texRows
        smooth: false
        mipmap: false
        cache: true
        sourceSize.width: root.texWidth
        sourceSize.height: root.texRows
        source: root.pointsSource
        asynchronous: false
    }

    // static data, so the source renders once (live: false) and never again
    ShaderEffectSource {
        id: pointTexture
        sourceItem: points
        hideSource: true
        visible: false
        live: false
        recursive: false
        smooth: false
        mipmap: false
        width: root.texWidth
        height: root.texRows
        textureSize: Qt.size(root.texWidth, root.texRows)
    }

    Repeater {
        model: root.sliceCount

        ShaderEffect {
            required property int index
            anchors.fill: parent
            visible: root.running
            blending: true

            vertexShader: Qt.resolvedUrl("shaders/knot.vert.qsb")
            fragmentShader: Qt.resolvedUrl("shaders/knot.frag.qsb")

            mesh: GridMesh {
                resolution: Qt.size(root.sliceSize * 2, 1)
            }

            property Item src: pointTexture
            // points in this slice, and the index of its first point
            property real uN: root.sliceSize
            property real uOffset: index * root.sliceSize
            property real uWidth: root.texWidth
            property real uRows: root.texRows
            property real t: root.t
            property real knotPx: root.knotPx
            property real uW: root.width
            property real uH: root.height
            // K3c: explicit zeros, the spark-disc mode must be off for the strands.
            // Unset uniforms read stale memory (the strands turned into spark discs).
            property vector4d uSparkCol: Qt.vector4d(0, 0, 0, 0)
            property vector4d uSparkGeom: Qt.vector4d(0, 0, 0, 0)
        }
    }

    // K3c: fourth draw, the acid sparks as solid discs. Declared after the
    // strand Repeater, so they are drawn last and no ice dot paints over them.
    // Each spark is a one point ShaderEffect (uN 1, uOffset = point id); the
    // disc centre is the rest point projected with the global pose, plus the
    // offset that puts it on the target spot (see work5/K3c/spark_pick.json).
    readonly property var sparkSpots: [
        { pid: 2435, dx: -0.09, dy: -0.46, rgb: [196, 239, 61], r: 7.5 },
        { pid: 14845, dx: 0.81, dy: -2.67, rgb: [195, 237, 62], r: 7.5 },
        { pid: 27313, dx: -19.65, dy: 0.44, rgb: [160, 197, 66], r: 7.5 }
    ]

    Repeater {
        model: root.sparkSpots

        ShaderEffect {
            required property var modelData
            anchors.fill: parent
            visible: root.running
            blending: true

            vertexShader: Qt.resolvedUrl("shaders/knot.vert.qsb")
            fragmentShader: Qt.resolvedUrl("shaders/knot.frag.qsb")

            mesh: GridMesh {
                resolution: Qt.size(2, 1)
            }

            property Item src: pointTexture
            property real uN: 1
            property real uOffset: modelData.pid
            property real uWidth: root.texWidth
            property real uRows: root.texRows
            property real t: root.t
            property real knotPx: root.knotPx
            property real uW: root.width
            property real uH: root.height
            property vector4d uSparkCol: Qt.vector4d(modelData.rgb[0] / 255 * root.sparkDim,
                                                     modelData.rgb[1] / 255 * root.sparkDim,
                                                     modelData.rgb[2] / 255 * root.sparkDim, 1.0)
            property vector4d uSparkGeom: Qt.vector4d(1.0, modelData.r, modelData.dx, modelData.dy)
        }
    }
}
