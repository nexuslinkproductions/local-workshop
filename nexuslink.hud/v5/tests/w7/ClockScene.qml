import QtQuick
import "../../kit"

// Still scene for W7 Clock: the deck field, the clock on its top baseline, and
// just enough ambient furniture to judge the numerals in place. Test
// scaffolding only - not part of the kit.
Item {
    id: scene
    width: 2560
    height: 1440

    property string timeText: "01:11"
    property bool seconds: false

    Rectangle { anchors.fill: parent; color: Tokens.field }

    Clock {
        id: clock
        time: scene.timeText
        showSeconds: scene.seconds
        anchors.horizontalCenter: parent.horizontalCenter
        y: 62
    }

    // s1: the date flanks the clock on one baseline, two short words.
    Text {
        x: clock.x - width - Tokens.sp4
        y: 62 + Tokens.sizeClock * 0.36
        text: "THU"
        color: Tokens.textDate
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.pixelSize: Tokens.sizeLabel
        font.letterSpacing: Tokens.sizeLabel * Tokens.trackLabel
    }
    Text {
        x: clock.x + clock.width + Tokens.sp4
        y: clock.y + Tokens.sizeClock * 0.36
        text: "23 OCT"
        color: Tokens.textDate
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.pixelSize: Tokens.sizeLabel
        font.letterSpacing: Tokens.sizeLabel * Tokens.trackLabel
    }

    // A silhouette stand-in for the knot, so the still reads as the deck.
    Repeater {
        model: 240
        delegate: Rectangle {
            id: dot
            required property int index
            property real a: index * 2.399963229728653
            property real r: 250 * (0.55 + 0.45 * Math.sin(3 * a)) * Math.sqrt((index + 0.5) / 240)
            x: 1280 + r * Math.cos(a) - width / 2
            y: 550 + r * Math.sin(a) - height / 2
            width: 5
            height: 5
            radius: 2.5
            color: Tokens.azure
            opacity: 0.25 + 0.55 * Math.abs(Math.sin(a * 1.7 + index * 0.11))
        }
    }
}
