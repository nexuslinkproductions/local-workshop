import QtQuick
import NexusHud.V5 1.0

// W3 gauge proof sheet, kept for the integrator (card W3). Four columns, one
// per component, three states per column:
//
//   row 1 (y 60)   rest: no text, focus 0, the deck shape
//   row 2 (y 360)  values: showValue true, the label and the reading
//   row 3 (y 660)  focus 1 inside a parent at opacity 0.3: still legible
//
// Render (1:1 deck scale, 1220 x 960):
//   QML_IMPORT_PATH=<dir with NexusHud/V5> \
//   tools/qml-shot.sh nexuslink.hud/v5/stills/w3-gauge-harness.qml \
//       nexuslink.hud/v5/stills/w3-gauges.png 1220 960
// The import path is only needed until the integrator registers the four
// components in kit/qmldir (task I1); kit/qmldir is not this card's file.
//
// Fixture values (v5/fixtures/):
//   PulseRing 7.5 ms        link.json rtt.median (breath period 2.932 s)
//   DotArc    100 percent   link.json mac.batt
//   DotBar    76 percent    metrics.json host.load1_frac 0.7617
//   LocalOrb  0.33 GB       metrics.json local_ai.size_gb, activity 0 in the
//                           rest row and 0.55 in the values and focus rows
//                           (the fixture records 0.0 CPU s, so the busy
//                           reading is staged for the proof and labelled as
//                           such in the card summary)
//
// Column boxes at 1:1 (x, y, w, h); the four per-component stills are crops of
// this frame along these columns, noted in the card summary:
//   pulse ring  x 192, w 156
//   dot arc     x 422, w 216
//   dot bar     x 724, w 132
//   local orb   x 978, w 144
Item {
    id: frame

    width: 1220
    height: 960

    FontLoader { source: "../fonts/Satoshi-Regular.ttf" }
    FontLoader { source: "../fonts/Satoshi-Medium.ttf" }
    FontLoader { source: "../fonts/Satoshi-Bold.ttf" }
    FontLoader { source: "../fonts/Satoshi-Black.ttf" }

    Rectangle {
        anchors.fill: parent
        color: Tokens.field
    }

    Text {
        x: 40
        y: 18
        text: "W3 GAUGES  REST / VALUES / FOCUS 1 AT PARENT OPACITY 0.3  1:1"
        color: Tokens.textDim
        font.family: Tokens.fontFamily
        font.pixelSize: Tokens.sizeCaption
        font.weight: Tokens.weightBold
        font.letterSpacing: Tokens.sizeCaption * Tokens.trackLabel
    }

    Repeater {
        model: [
            { "y": 60, "caption": "REST" },
            { "y": 360, "caption": "VALUES" },
            { "y": 660, "caption": "FOCUS 1 AT 0.3" }
        ]

        Text {
            required property var modelData
            x: 40
            y: modelData.y - 22
            text: modelData.caption
            color: Tokens.textDim
            font.family: Tokens.fontFamily
            font.pixelSize: Tokens.sizeCaption
            font.weight: Tokens.weightMedium
            font.letterSpacing: Tokens.sizeCaption * Tokens.trackLabel
        }
    }

    // Row 1: rest, no text.
    PulseRing {
        x: 192
        y: 100
        size: 156
        value: 7.5
        accent: Tokens.ice
        showValue: false
    }

    DotArc {
        x: 422
        y: 80
        size: 216
        level: 1.0
        accent: Tokens.white
        showValue: false
    }

    DotBar {
        x: 724
        y: 200
        size: 132
        segments: 12
        level: 0.7617
        accent: Tokens.cyan
        showValue: false
    }

    LocalOrb {
        x: 978
        y: 118
        size: 144
        sizeGb: 0.33
        activity: 0
        accent: Tokens.acid
        showValue: false
    }

    // Row 2: values. Text grows the implicit height, the art keeps its size.
    PulseRing {
        x: 192
        y: 400
        size: 156
        value: 7.5
        accent: Tokens.ice
        showValue: true
        label: "MAC"
    }

    DotArc {
        x: 422
        y: 380
        size: 216
        level: 1.0
        accent: Tokens.white
        showValue: true
        label: "BATTERY"
    }

    DotBar {
        x: 724
        y: 500
        size: 132
        segments: 12
        level: 0.7617
        accent: Tokens.cyan
        showValue: true
        label: "LOAD"
    }

    LocalOrb {
        x: 978
        y: 418
        size: 144
        sizeGb: 0.33
        activity: 0.55
        accent: Tokens.acid
        showValue: true
        label: "LOCAL"
    }

    // Row 3: focus 1 inside the focus dim band from Tokens.focusDimMin to
    // focusDimMax. The gauge must still read at the 0.3 ceiling.
    Item {
        x: 160
        y: 660
        width: 220
        height: 290
        opacity: Tokens.focusDimMax

        PulseRing {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 20
            size: 156
            value: 7.5
            accent: Tokens.ice
            focusLevel: 1
            showValue: true
            label: "MAC"
        }
    }

    Item {
        x: 390
        y: 660
        width: 290
        height: 290
        opacity: Tokens.focusDimMax

        DotArc {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 0
            size: 216
            level: 1.0
            accent: Tokens.white
            focusLevel: 1
            showValue: true
            label: "BATTERY"
        }
    }

    Item {
        x: 690
        y: 660
        width: 200
        height: 290
        opacity: Tokens.focusDimMax

        DotBar {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 110
            size: 132
            segments: 12
            level: 0.7617
            accent: Tokens.cyan
            focusLevel: 1
            showValue: true
            label: "LOAD"
        }
    }

    Item {
        x: 950
        y: 660
        width: 200
        height: 290
        opacity: Tokens.focusDimMax

        LocalOrb {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 20
            size: 144
            sizeGb: 0.33
            activity: 0.55
            accent: Tokens.acid
            focusLevel: 1
            showValue: true
            label: "LOCAL"
        }
    }
}
