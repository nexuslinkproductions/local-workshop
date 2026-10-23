import QtQuick
import "../kit"

// Static still of the shipped SwarmSphere (crew orb).
//
// `animate: false` holds the tick and phase 0 fixes the pose, so the grab is
// deterministic. The harness resizes the root, so the same file renders the orb
// at 224 and at 320.
Item {
    id: root
    width: 224
    height: 224
    Rectangle { anchors.fill: parent; color: "#06080a"; z: -1 }

    SwarmSphere {
        anchors.centerIn: parent
        size: Math.min(root.width, root.height)
        phase: 0.0
        animate: false
        accent: "#00c8f0"
    }
}
