import QtQuick
import "../kit"

// LocalWidget - a tall slim level stack, one dot per GB share of the 4 GB budget.
// Text block left, stack right, so the form is a column, not a circle.
WidgetBase {
    id: root

    property var localAi: null

    readonly property var ai: root.localAi ? root.localAi : ({})
    readonly property bool present: root.ai.present === true
    readonly property bool active: root.ai.active === true
    readonly property real sizeGb: (typeof root.ai.sizeGb === "number") ? root.ai.sizeGb : 0
    readonly property real vramGb: (typeof root.ai.vramGb === "number") ? root.ai.vramGb : 0
    readonly property real shownGb: root.sizeGb > 0 ? root.sizeGb : root.vramGb
    readonly property real activity: (typeof root.ai.activity === "number")
        ? Math.max(0, Math.min(1, root.ai.activity)) : 0

    readonly property int segCount: 12
    readonly property real segDot: 14
    readonly property real segGap: 4
    readonly property real stackH: segCount * segDot + (segCount - 1) * segGap
    readonly property int filled: root.present
        ? Math.max(1, Math.min(root.segCount, Math.round(root.segCount * root.shownGb / 4.0)))
        : 0

    readonly property string valueText: root.present ? root.shownGb.toFixed(1) : "idle"

    TextMetrics {
        id: tmValue
        font.family: Tokens.fontFamily
        font.pixelSize: 68
        font.weight: 400
        text: "0.0"
    }
    TextMetrics {
        id: tmUnit
        font.family: Tokens.fontFamily
        font.pixelSize: 20
        font.weight: 500
        text: "GB"
    }

    Text {
        id: label
        text: "LOCAL"
        x: 0
        y: Math.round(root.height / 2 - 58)
        font.family: Tokens.fontFamily
        font.pixelSize: 16
        font.weight: 500
        font.letterSpacing: 16 * Tokens.trackLabel
        color: Tokens.textLabel
    }

    Text {
        id: value
        text: root.valueText
        x: 0
        y: label.y + 26
        font.family: Tokens.fontFamily
        font.pixelSize: root.present ? 68 : 44
        font.weight: 400
        color: root.present ? Tokens.ink : Tokens.textDim
    }

    Text {
        id: unit
        text: "GB"
        visible: root.present
        x: value.x + value.width + 14
        y: Math.round(value.y + tmValue.height * 0.78 - tmUnit.height * 0.78)
        font.family: Tokens.fontFamily
        font.pixelSize: 20
        font.weight: 500
        color: Tokens.textLabel
    }

    Item {
        id: stack
        width: root.segDot
        height: root.stackH
        x: root.width - width - 8
        y: Math.round((root.height - height) / 2)

        Repeater {
            model: root.segCount
            Rectangle {
                id: seg
                readonly property int fromTop: root.segCount - 1 - index

                width: root.segDot
                height: width
                radius: width / 2
                x: 0
                y: (root.segCount - 1 - index) * (root.segDot + root.segGap)
                color: root.present ? Tokens.ice : Tokens.textDim
                opacity: {
                    if (!root.present)
                        return 0.25
                    if (index >= root.filled)
                        return 0.18
                    var o = (index === root.filled - 1)
                        ? 0.8 + 0.2 * Math.sin(root.tick * 2 * Math.PI / 6)
                        : 0.9
                    if (root.active && index >= root.filled - 3 && index < root.filled - 1)
                        o = o * (1 - 0.25 * root.activity * (0.5 + 0.5 * Math.sin(root.tick * 5.2 + index * 1.7)))
                    return o
                }
            }
        }
    }
}
