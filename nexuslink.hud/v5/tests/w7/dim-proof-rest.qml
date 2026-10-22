import QtQuick
import "../../kit"

// Rest counterpart of dim-proof-active: same flat red content, focus inactive.
// Corner and centre must both be the untouched #ff0000.
Item {
    width: 300
    height: 200

    Focus {
        anchors.fill: parent
        active: false
        previewProgress: 0
        targetRect: Qt.rect(100, 70, 100, 60)
        content: Item {
            width: 300
            height: 200
            Rectangle { anchors.fill: parent; color: "#ff0000" }
        }
    }
}
