import QtQuick
import "../live"

// Verification scene for Environment.qml (E1). The root Item is resized by the harness
// (tools/linux/v5-shot.sh <this file> <out.png> W H). Defaults: 2560x1440 at origin 0,0,
// plain base, grid off. tools/linux/env/env-proof.py writes variants of this scene to scratch
// for the stitch proof and the hall rehearsal.
Item {
    id: root
    width: 2560
    height: 1440

    Environment {
        anchors.fill: parent
        objectName: "scene"
        origin: Qt.point(0, 0)
        world: Qt.rect(0, 0, 2560, 1440)
        debugGrid: false
    }
}
