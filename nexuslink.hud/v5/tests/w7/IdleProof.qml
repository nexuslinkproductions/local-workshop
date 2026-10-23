pragma ComponentBehavior: Bound

import QtQuick
import "../../kit"

// Numeric trace for IdleDrift, driving the real component on a real target:
//   phase 1  8 s of drift, sampled every frame (dx, dy, phase, phaseSecondary)
//   phase 2  enabled = false, 1.2 s: gain and offset must reach exactly zero and
//            the target's own transform list must be restored
//   phase 3  enabled = true again, 1 s: drift must resume
// Run: QT_QPA_PLATFORM=offscreen qml tests/w7/IdleProof.qml
Window {
    id: win
    width: 480
    height: 320
    visible: true

    property real t0: 0
    property string phase: "idle"
    property real lastSample: -1
    property int transformCountBefore: 0

    Item {
        id: drifted
        x: 120
        y: 100
        width: 200
        height: 120
        // One transform already on the target, to prove the helper appends and
        // then restores rather than clobbering.
        transform: Rotation { origin.x: 10; origin.y: 10; angle: 9 }
        Rectangle { anchors.fill: parent; color: Tokens.azure; radius: 60 }
    }

    IdleDrift {
        id: drift
        target: drifted
        amplitude: 2.0
        period: 2.0
    }

    FrameAnimation {
        running: true
        onTriggered: {
            if (win.t0 === 0) {
                win.t0 = Date.now()
                win.phase = "drift"
                win.transformCountBefore = drifted.transform.length
                console.log("IDLE config amplitude=" + drift.amplitude
                            + " period=" + drift.period
                            + " secondaryPeriod=" + drift.secondaryPeriod.toFixed(5)
                            + " ratio=" + (drift.secondaryPeriod / drift.period).toFixed(6)
                            + " transformsAtStart=" + win.transformCountBefore)
                return
            }
            var ms = Date.now() - win.t0
            var s = ms / 1000
            if (win.phase === "drift") {
                if (win.lastSample < 0 || s - win.lastSample >= 0.1) {
                    win.lastSample = s
                    console.log("IDLE drift t=" + s.toFixed(3)
                                + " dx=" + drift.dx.toFixed(5)
                                + " dy=" + drift.dy.toFixed(5)
                                + " phase=" + drift.phase.toFixed(5)
                                + " phaseSecondary=" + drift.phaseSecondary.toFixed(5)
                                + " transforms=" + drifted.transform.length)
                }
                if (ms >= 8000) {
                    win.phase = "stopping"
                    drift.enabled = false
                    console.log("IDLE stop_begin t=" + s.toFixed(3)
                                + " dx=" + drift.dx.toFixed(5)
                                + " dy=" + drift.dy.toFixed(5))
                }
            } else if (win.phase === "stopping") {
                if (win.lastSample < 0 || s - win.lastSample >= 0.1) {
                    win.lastSample = s
                    console.log("IDLE stopping t=" + s.toFixed(3)
                                + " dx=" + drift.dx.toFixed(5)
                                + " dy=" + drift.dy.toFixed(5)
                                + " transforms=" + drifted.transform.length)
                }
                if (ms >= 9600) {
                    console.log("IDLE stop_done dx=" + drift.dx.toFixed(5)
                                + " dy=" + drift.dy.toFixed(5)
                                + " transforms=" + drifted.transform.length)
                    win.phase = "restart"
                    drift.enabled = true
                    win.lastSample = -1
                    console.log("IDLE restart dx=" + drift.dx.toFixed(5)
                                + " dy=" + drift.dy.toFixed(5)
                                + " transforms=" + drifted.transform.length)
                }
            } else if (win.phase === "restart") {
                if (win.lastSample < 0 || s - win.lastSample >= 0.1) {
                    win.lastSample = s
                    console.log("IDLE resumed t=" + s.toFixed(3)
                                + " dx=" + drift.dx.toFixed(5)
                                + " dy=" + drift.dy.toFixed(5)
                                + " phase=" + drift.phase.toFixed(5)
                                + " transforms=" + drifted.transform.length)
                }
                if (ms >= 11000) {
                    win.phase = "done"
                    console.log("IDLE summary transformsEnd=" + drifted.transform.length
                                + " dxEnd=" + drift.dx.toFixed(5)
                                + " dyEnd=" + drift.dy.toFixed(5))
                    Qt.exit(0)
                }
            }
        }
    }
}
