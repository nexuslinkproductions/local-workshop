import QtQuick
import "../kit"
import "../live"

// W1 verify scene: clock, mac link (live and empty), local ai (loaded, active, idle).
Window {
    id: root
    width: 1240
    height: 760
    visible: true
    color: Tokens.field

    FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Regular.ttf") }
    FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Medium.ttf") }
    FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Bold.ttf") }
    FontLoader { source: Qt.resolvedUrl("../fonts/Satoshi-Black.ttf") }

    property real tick: 12.3

    property var sampleLink: ({
        "route": "direct",
        "tunnel": "active",
        "rtt_ms": {
            "median": 7.5,
            "last": 5,
            "min": 5,
            "max": 92,
            "samples": [8, 7, 7, 11, 5, 92, 11, 6, 8, 7, 7, 7, 71, 8, 6, 5, 9, 9, 17, 62, 5, 8, 6, 5]
        },
        "mac": { "load": [3.94, 4.45, 4.81], "batt": 100, "state": "charged", "rem": "0:00", "up_min": 13 }
    })

    ClockWidget {
        x: 270
        y: 40
        width: 700
        height: 130
        tick: root.tick
        now: new Date(2026, 9, 23, 23, 47, 0)
    }

    MacWidget {
        x: 60
        y: 230
        width: 360
        height: 220
        tick: root.tick
        link: root.sampleLink
    }

    LocalWidget {
        x: 500
        y: 230
        width: 320
        height: 220
        tick: root.tick
        localAi: ({ present: true, active: false, model: "embeddinggemma",
                    sizeGb: 0.33, vramGb: 0, tokS: 0, activity: 0 })
    }

    LocalWidget {
        x: 880
        y: 230
        width: 320
        height: 220
        tick: root.tick
        localAi: ({ present: true, active: true, model: "embeddinggemma",
                    sizeGb: 2.4, vramGb: 0, tokS: 18, activity: 0.7 })
    }

    // Empty state row
    MacWidget {
        x: 60
        y: 500
        width: 360
        height: 220
        tick: root.tick
        link: null
    }

    LocalWidget {
        x: 500
        y: 500
        width: 320
        height: 220
        tick: root.tick
        localAi: ({ present: false, active: false, model: "", sizeGb: 0, vramGb: 0, tokS: 0, activity: 0 })
    }

    Timer {
        interval: 900
        running: true
        onTriggered: root.contentItem.grabToImage(function(r) {
            r.saveToFile("/home/nexuslink/.hermes/cache/scratch/hud-live/work/W1/w1-widgets.png")
            Qt.quit()
        })
    }
}
