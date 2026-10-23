import QtQuick
import "../kit"
import "../live"

// Verification still for KnotSwarm. 1000 x 1000, field background.
// t is a plain property: edit tNow (or pass it as the first Qt argument)
// and re-run the GPU harness to get a still at that second.
// Suggested: 0 (front), 8, 17 (turned), 30.
Item {
    id: root
    width: 1000
    height: 1000

    property real tNow: 8

    Component.onCompleted: {
        var a = Qt.application.arguments
        if (a.length > 2) {
            let v = Number(a[2])
            if (!isNaN(v))
                root.tNow = v
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Tokens.field
    }

    KnotSwarm {
        anchors.centerIn: parent
        width: 700
        height: 700
        knotPx: 540
        t: root.tNow
        running: true
    }
}
