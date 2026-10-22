import QtQuick

// C0 toolchain test: proves qsb -> ShaderEffect -> offscreen PNG works.
// A diagonal gradient plus one round dot, no animation, so a grab is stable.
// Render with: tools/qml-shot.sh tools/tests/shadertest.qml /tmp/shadertest.png
// The harness resizes the root item to the requested W x H.
Item {
    id: root
    width: 640
    height: 360

    ShaderEffect {
        anchors.fill: parent
        fragmentShader: "shadertest.frag.qsb"
        property real phase: 0.5
        property real u_width: width
        property real u_height: height
    }
}
