import QtQuick

// Knot: 4384-point triquetra swarm, drawn by one ShaderEffect.
// The mesh is a GridMesh of 2N columns by 1 row, so every point owns two
// columns; the vertex stage turns each pair into a quad and the fragment
// stage kills the bridge cells between neighbouring points.
// The deck drives `t` at 30 Hz. No Timer, no Canvas, no per frame JS.
Item {
    id: root

    // seconds, written by the deck
    property real t: 0
    // when false the shader is hidden and costs nothing
    property bool running: true
    // width of the knot in pixels (the mark is 540 px across at knotPx 540)
    property real knotPx: 540

    readonly property int pointCount: 4384
    readonly property int gridColumns: pointCount * 2
    // point texture layout, keep in sync with TEXEL_STRIDE / TEX_ROWS /
    // TEX_WIDTH at the top of shaders/knot.vert. v2 (knot-points2.png) keeps
    // the same stride and rows, so only the source and USE_UV2 change.
    readonly property int texelStride: 4
    readonly property int texRows: 9
    readonly property int texWidth: 2048
    readonly property int rows: 9

    width: 700
    height: 700

    // point data: xyz 16 bit, normal, strand, density threshold, class.
    // nearest sampling, no mipmap: the vertex stage reads exact texels.
    Image {
        id: points
        width: root.texWidth
        height: root.texRows
        smooth: false
        mipmap: false
        cache: true
        sourceSize.width: root.texWidth
        sourceSize.height: root.texRows
        source: Qt.resolvedUrl("shaders/knot-points.png")
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

    ShaderEffect {
        id: effect
        anchors.fill: parent
        visible: root.running
        blending: true

        vertexShader: Qt.resolvedUrl("shaders/knot.vert.qsb")
        fragmentShader: Qt.resolvedUrl("shaders/knot.frag.qsb")

        mesh: GridMesh {
            resolution: Qt.size(root.gridColumns, 1)
        }

        property Item src: pointTexture
        property real uN: root.pointCount
        property real uWidth: root.texWidth
        property real uRows: root.texRows
        property real t: root.t
        property real knotPx: root.knotPx
        property real uW: root.width
        property real uH: root.height
    }
}
