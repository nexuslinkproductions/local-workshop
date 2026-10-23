import QtQuick
import "../../kit"

// Pixel proof for the dim/scrim numbers: flat red HUD content, a 100 x 60 focus
// rect in the middle. The harness prints the centre (inside the rect, sharp
// #ff0000) and the corner (outside: 0.26 opacity over black, then 35 percent
// toward black -> #2b0000). Run with tools/qml-shot.sh at 300x200.
Item {
    width: 300
    height: 200

    Focus {
        anchors.fill: parent
        previewProgress: 1
        targetRect: Qt.rect(100, 70, 100, 60)
        content: Item {
            width: 300
            height: 200
            Rectangle { anchors.fill: parent; color: "#ff0000" }
        }
    }
}
