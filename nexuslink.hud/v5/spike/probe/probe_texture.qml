import QtQuick

// Probe 1 still. tools/qml-shot.sh probe_texture.qml /tmp/probe.png 200 200
// Data texture is 160 x 120 (see spike/geometry/make_swarm.py).
Item {
    id: root
    width: 200
    height: 200

    Image {
        id: data
        source: "../assets/swarm-knot-grid.png"
        visible: false
        smooth: false
    }

    ShaderEffect {
        anchors.fill: parent
        fragmentShader: "probe_texture.frag.qsb"
        property var u_tex: data
        property vector2d u_texSize: Qt.vector2d(160, 120)
        property real u_pickX: 156.5
        property real u_pickY: 116.5
    }
}
