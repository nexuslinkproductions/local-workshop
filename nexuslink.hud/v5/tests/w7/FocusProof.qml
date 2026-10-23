pragma ComponentBehavior: Bound

import QtQuick
import "../../kit"

// Numeric motion trace for Focus. Drives the real component: `active` goes true,
// `springProgress` is sampled every frame; after 900 ms `active` goes false and
// the return is sampled. Output lines:
//   FOCUS in <ms> <springProgress>
//   FOCUS out <ms> <springProgress>
//   FOCUS summary in_peak=.. out_final=..
// Run: QT_QPA_PLATFORM=offscreen qml tests/w7/FocusProof.qml
Window {
    id: win
    width: 640
    height: 360
    visible: true

    property real t0: 0
    property string phase: "idle"
    property real inPeak: 0
    property int lastMs: 0

    Focus {
        id: focus
        anchors.fill: parent
        targetRect: Qt.rect(120, 90, 320, 200)
        content: Item {
            width: 640
            height: 360
            Rectangle { anchors.fill: parent; color: Tokens.field }
            Rectangle { x: 40; y: 40; width: 180; height: 90; color: "#8fd8e8"; radius: 45 }
            Rectangle { x: 300; y: 60; width: 220; height: 120; color: "#60a5fa"; radius: 60 }
            Rectangle { x: 120; y: 220; width: 300; height: 100; color: "#c8f31d"; radius: 50 }
        }
    }

    FrameAnimation {
        running: true
        onTriggered: {
            if (win.t0 === 0) {
                win.t0 = Date.now()
                win.phase = "in"
                focus.active = true
                return
            }
            var ms = Date.now() - win.t0
            if (win.phase === "in") {
                if (focus.springProgress > win.inPeak)
                    win.inPeak = focus.springProgress
                console.log("FOCUS in " + ms + " " + focus.springProgress.toFixed(5))
                if (ms >= 900) {
                    win.phase = "out"
                    focus.active = false
                }
            } else if (win.phase === "out") {
                console.log("FOCUS out " + ms + " " + focus.springProgress.toFixed(5))
                if (ms >= 1600) {
                    win.phase = "done"
                    console.log("FOCUS summary in_peak=" + win.inPeak.toFixed(5)
                                + " out_final=" + focus.springProgress.toFixed(5)
                                + " progress_final=" + focus.progress.toFixed(5)
                                + " effectsVisible=" + focus.effectsVisible)
                    Qt.exit(0)
                }
            }
        }
    }
}
