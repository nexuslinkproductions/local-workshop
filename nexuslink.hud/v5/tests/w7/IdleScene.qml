pragma ComponentBehavior: Bound

import QtQuick
import "../../kit"

// Still scene for W7 IdleDrift: six ambient dot clusters, each on its own
// phase offset. `amplitude` is raised to 18 px here so the displacement is
// visible in a still; the deck uses the 1 to 2 px Motion defaults. A dim primary
// dot marks each cluster's undeformed centre. Test scaffolding only.
Item {
    id: scene
    width: 2560
    height: 1440

    property real previewTime: 0
    property real amplitude: 18

    Rectangle { anchors.fill: parent; color: Tokens.field }

    Repeater {
        model: 6
        delegate: Item {
            id: cluster
            required property int index
            property real baseX: 420 + (index % 3) * 760
            property real baseY: 470 + Math.floor(index / 3) * 500

            x: baseX
            y: baseY
            width: 220
            height: 220

            Rectangle {
                // Undeformed centre marker.
                x: 108
                y: 108
                width: 4
                height: 4
                radius: 2
                color: Tokens.textDim
                opacity: 0.5
            }

            Repeater {
                model: 26
                delegate: Rectangle {
                    id: ambientDot
                    required property int index
                    property real a: index * 2.399963229728653
                    property real r: 14 + 92 * Math.sqrt((index + 0.5) / 26)
                    x: 110 + r * Math.cos(a) - width / 2
                    y: 110 + r * Math.sin(a) - height / 2
                    width: 5
                    height: 5
                    radius: 2.5
                    color: Tokens.ice
                    opacity: 0.3 + 0.5 * Math.abs(Math.sin(a * 1.3 + index))
                }
            }

            IdleDrift {
                target: cluster
                amplitude: scene.amplitude
                period: 7
                phaseOffset: cluster.index / 6
                previewTime: scene.previewTime
            }
        }
    }

    // Numeric readout, so the still carries its own evidence.
    Column {
        x: Tokens.safeMargin
        y: 1290
        spacing: 6
        Text {
            text: "IDLE DRIFT  t=" + scene.previewTime.toFixed(2) + " s  amplitude=" + scene.amplitude + " px"
            color: Tokens.textLabel
            font.family: Tokens.fontFamily
            font.weight: Tokens.weightMedium
            font.pixelSize: Tokens.sizeCaption
        }
        Text {
            text: "two sine terms, period ratio phi = " + Tokens.phi.toFixed(6) + " (irrational, no visible repeat)"
            color: Tokens.textDim
            font.family: Tokens.fontFamily
            font.weight: Tokens.weightRegular
            font.pixelSize: Tokens.sizeCaption
        }
    }
}
