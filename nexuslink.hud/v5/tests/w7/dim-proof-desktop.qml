import QtQuick
import "../../kit"

// Desktop-safety proof: the panel's own background (#101010 here, standing in
// for the desktop visible through a transparent panel) is behind HUD content
// that covers only the top-left quadrant. Focus is active with its target rect
// in the bottom-right, far from the content. Corner (0,0) is HUD content and
// must be dimmed to #2b0000; centre (150,100) is bare panel and must stay
// #101010 - the effect never dims what the HUD does not paint.
Item {
    width: 300
    height: 200

    Rectangle { anchors.fill: parent; color: "#101010" }

    Focus {
        anchors.fill: parent
        previewProgress: 1
        targetRect: Qt.rect(210, 150, 80, 40)
        content: Item {
            width: 300
            height: 200
            Rectangle { x: 0; y: 0; width: 120; height: 80; color: "#ff0000" }
        }
    }
}
