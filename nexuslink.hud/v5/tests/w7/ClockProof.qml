pragma ComponentBehavior: Bound

import QtQuick
import "../../kit"

// Numeric proof for Clock: the same box must hold 01:11 and 18:48 at exactly the
// same width, and Satoshi's tabular figures must show up in Text.contentWidth.
// Run: QML2_IMPORT_PATH=<imports> qml tests/w7/ClockProof.qml
Item {
    id: proof
    width: 1280
    height: 720

    FontLoader { id: face400; source: Qt.resolvedUrl("../../fonts/Satoshi-Regular.ttf") }

    property bool ready: face400.status === FontLoader.Ready

    Clock { id: clockA; time: "01:11"; pixelSize: 168 }
    Clock { id: clockB; time: "18:48"; pixelSize: 168 }
    Clock { id: clockC; time: ""; pixelSize: 168 }
    Clock { id: clockD; time: "21:47:09"; pixelSize: 168; showSeconds: true }

    // Hidden metrics pairs: the same four digits with and without tnum.
    Text {
        id: plain0
        opacity: 0
        text: "0000"
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightRegular
        font.pixelSize: 168
    }
    Text {
        id: plain1
        opacity: 0
        text: "1111"
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightRegular
        font.pixelSize: 168
    }
    Text {
        id: tab0
        opacity: 0
        text: "0000"
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightRegular
        font.pixelSize: 168
        font.features: ({ "tnum": 1 })
    }
    Text {
        id: tab1
        opacity: 0
        text: "1111"
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightRegular
        font.pixelSize: 168
        font.features: ({ "tnum": 1 })
    }

    function report() {
        console.log("CLOCK time=01:11 implicitWidth=" + clockA.implicitWidth.toFixed(3)
                    + " textWidth=" + clockA.textWidth.toFixed(3)
                    + " cells=" + clockA.cells.length)
        console.log("CLOCK time=18:48 implicitWidth=" + clockB.implicitWidth.toFixed(3)
                    + " textWidth=" + clockB.textWidth.toFixed(3)
                    + " cells=" + clockB.cells.length)
        console.log("CLOCK resting valid=" + clockC.valid
                    + " implicitWidth=" + clockC.implicitWidth.toFixed(3)
                    + " cells=" + clockC.cells.length)
        console.log("CLOCK seconds time=21:47:09 implicitWidth=" + clockD.implicitWidth.toFixed(3)
                    + " cells=" + clockD.cells.length)
        console.log("TNUM off 0000=" + plain0.contentWidth.toFixed(3)
                    + " 1111=" + plain1.contentWidth.toFixed(3)
                    + " delta=" + Math.abs(plain0.contentWidth - plain1.contentWidth).toFixed(3))
        console.log("TNUM on  0000=" + tab0.contentWidth.toFixed(3)
                    + " 1111=" + tab1.contentWidth.toFixed(3)
                    + " delta=" + Math.abs(tab0.contentWidth - tab1.contentWidth).toFixed(3))
        var same = Math.abs(clockA.implicitWidth - clockB.implicitWidth) < 0.001
        var resting = Math.abs(clockC.implicitWidth - clockA.implicitWidth) < 0.001
        console.log("CLOCK_CHECK " + ((same && resting) ? "PASS" : "FAIL")
                    + " same_width=" + same + " resting_same_width=" + resting)
        Qt.exit((same && resting) ? 0 : 1)
    }

    // One report, after the first layout pass (Text contentWidth is 0 until the
    // text has been laid out once).
    Timer {
        interval: 250
        running: true
        repeat: false
        onTriggered: {
            if (proof.ready)
                proof.report()
        }
    }
}
