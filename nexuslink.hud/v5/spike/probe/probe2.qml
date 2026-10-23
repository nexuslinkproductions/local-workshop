import QtQuick

// Probe 2 still: byte roundtrip through an image texture on this platform.
// Expected corners R channel: TL 133, TR 200, BL 7, BR 200 (probe8.png is a
// flat 8x8 image of RGB 133/200/7, so every quadrant must read the same values).
Item {
    id: root
    width: 200
    height: 200

    Image { id: data; source: "probe8.png"; visible: false; smooth: false }
    Image { id: cal; source: "cal.png"; visible: false; smooth: false }

    ShaderEffect {
        anchors.fill: parent
        fragmentShader: "probe2.frag.qsb"
        property var u_tex: data
        property var u_cal: cal
        property vector2d u_texSize: Qt.vector2d(8, 8)
        property vector2d u_calSize: Qt.vector2d(1, 1)
    }
}
