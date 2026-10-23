import QtQuick
import "../kit"

// Static still of the shipped Swarm component at the s2 knot framing.
// speed is pinned low so the breath stays at its start value and the still is
// deterministic: the harness does not advance animations.
Item {
    id: root
    width: 720
    height: 720
    Rectangle { anchors.fill: parent; color: "#06080a"; z: -1 }

    Swarm {
        anchors.centerIn: parent
        size: 720
        speed: 0.00001
        accent: "#00c8f0"
    }
}
