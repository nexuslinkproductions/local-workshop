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
        }
    }
}
