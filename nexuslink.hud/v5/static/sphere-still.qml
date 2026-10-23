import QtQuick
import "../kit"

// Static still of the shipped SwarmSphere (crew orb) at 224 px.
// speed is pinned low so the pose is deterministic in a grab.
Item {
    id: root
    width: 320
    height: 320
    Rectangle { anchors.fill: parent; color: "#06080a"; z: -1 }

    SwarmSphere {
        anchors.centerIn: parent
        size: 224
        speed: 0.00001
        accent: "#00c8f0"
    }
}
