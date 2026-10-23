import QtQuick
import "../kit"
import "../live"

// w3-storage.qml - offscreen scene for W3 (StorageWidget, StorageExpanded).
// Six stills, one per state, saved into the W3 scratch dir:
//   0 rest sample, 1 rest hovered (grow forced to 1), 2 rest empty,
//   3 expanded sample, 4 expanded one disk, 5 expanded empty.
Window {
    id: win
    width: 1100
    height: 760
    visible: true
    color: Tokens.field

    Item {
        id: scene

        anchors.fill: parent

        property int view: 0
        property int idx: 0

        FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Regular.ttf") }
        FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Medium.ttf") }
        FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Bold.ttf") }
        FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Black.ttf") }

        readonly property var sample: [
            { "label": "ROOT", "fs": "btrfs", "mount": "/", "usedPct": 47, "sizeBytes": 1.2e12, "usedBytes": 5.64e11, "freeBytes": 6.85e11 },
            { "label": "T7", "fs": "exfat", "mount": "/run/media/nexuslink/T7", "usedPct": 81, "sizeBytes": 1.0e12, "usedBytes": 8.1e11, "freeBytes": 1.9e11 },
            { "label": "KINGSTON", "fs": "ntfs3", "mount": "/run/media/nexuslink/KINGSTON", "usedPct": 72, "sizeBytes": 1.0e12, "usedBytes": 7.2e11, "freeBytes": 2.8e11 },
            { "label": "DATA", "fs": "ntfs3", "mount": "/mnt/DATA", "usedPct": 0.4, "sizeBytes": 1.0e12, "usedBytes": 4.0e9, "freeBytes": 9.96e11 }
        ]

        Rectangle {
            anchors.fill: parent
            color: Tokens.field
        }

        StorageWidget {
            id: restMain
            x: (scene.width - width) / 2
            y: (scene.height - height) / 2
            width: 340
            height: 200
            tick: 12.3
            disks: scene.sample
            grow: scene.view === 1 ? 1 : 0
            visible: scene.view <= 1
        }

        StorageWidget {
            id: restEmpty
            x: (scene.width - width) / 2
            y: (scene.height - height) / 2
            width: 340
            height: 200
            tick: 12.3
            disks: []
            visible: scene.view === 2
        }

        StorageExpanded {
            id: expSample
            x: 0
            y: 0
            disks: scene.sample
            visible: scene.view === 3
        }

        StorageExpanded {
            id: expOne
            x: 0
            y: 0
            disks: [scene.sample[1]]
            visible: scene.view === 4
        }

        StorageExpanded {
            id: expEmpty
            x: 0
            y: 0
            disks: []
            visible: scene.view === 5
        }

        function shot() {
            var names = ["w3-rest", "w3-rest-hover", "w3-rest-empty",
                         "w3-expanded", "w3-expanded-one", "w3-expanded-empty"]
            var p = "/home/nexuslink/.hermes/cache/scratch/hud-live/work/W3/" + names[scene.idx] + ".png"
            scene.grabToImage(function (r) { r.saveToFile(p) })
        }

        Timer {
            id: step
            interval: 700
            running: true
            repeat: true
            onTriggered: {
                if (scene.idx > 5) {
                    Qt.quit()
                    return
                }
                scene.view = scene.idx
                grabTimer.start()
            }
        }

        Timer {
            id: grabTimer
            interval: 500
            onTriggered: {
                scene.shot()
                scene.idx++
            }
        }
    }
}
