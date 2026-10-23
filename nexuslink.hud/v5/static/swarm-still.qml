import QtQuick
import "../kit"

// Static still of the shipped Swarm component at the s2 knot framing.
//
// `animate: false` holds the tick, and phase 0 is the pose the s2 knot frame is
// scored at (yaw 0, tilt 0.0401, the same pose spike/options/a_knot.qml uses at
// benchPhase 0), so a render of this file is directly comparable with the
// numbers in docs/SWARM-DECISION.md.
//
// The harness resizes the root, so the same file renders 540, 720 or 1080.
Item {
    id: root
    width: 720
    height: 720
    Rectangle { anchors.fill: parent; color: "#06080a"; z: -1 }

    Swarm {
        anchors.centerIn: parent
        size: Math.min(root.width, root.height)
        phase: 0.0
        animate: false
        accent: "#00c8f0"
    }
}
