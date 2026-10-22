import QtQuick
import "../../kit"

// Still scene for W7 Focus: a HUD-shaped stage (clock, knot silhouette, four
// hero widgets) plus one large expanded card near the centre, wrapped in Focus.
// The focus target is deliberately a large card (900 x 620), not a small widget.
// Test scaffolding only - not part of the kit.
Item {
    id: scene
    width: 2560
    height: 1440

    property bool isActive: false
    property bool expanded: false
    property real preview: -1
    property rect focusRect: Qt.rect(830, 400, 900, 620)

    Rectangle { anchors.fill: parent; color: Tokens.field }

    Focus {
        id: focus
        anchors.fill: parent
        active: scene.isActive
        previewProgress: scene.preview
        targetRect: scene.focusRect

        content: Item {
            id: hud
            width: scene.width
            height: scene.height

            Clock {
                time: "21:47"
                anchors.horizontalCenter: parent.horizontalCenter
                y: 62
            }

            // Knot silhouette.
            Repeater {
                model: 240
                delegate: Rectangle {
                    id: knotDot
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

            // Four hero widgets on the thirds power points.
            Repeater {
                model: [
                    { "x": 853, "y": 480, "label": "CREW" },
                    { "x": 1707, "y": 480, "label": "FIND" },
                    { "x": 853, "y": 960, "label": "MAC" },
                    { "x": 1707, "y": 960, "label": "LOCAL" }
                ]
                delegate: Item {
                    id: hero
                    required property var modelData
                    x: modelData.x - 60
                    y: modelData.y - 60
                    width: 120
                    height: 120
                    Repeater {
                        model: 22
                        delegate: Rectangle {
                            id: ringDot
                            required property int index
                            property real a: index / 22 * 2 * Math.PI
                            x: 60 + 46 * Math.cos(a) - width / 2
                            y: 60 + 46 * Math.sin(a) - height / 2
                            width: 5
                            height: 5
                            radius: 2.5
                            color: Tokens.ice
                            opacity: 0.55
                        }
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 100
                        text: hero.modelData.label
                        color: Tokens.textLabel
                        font.family: Tokens.fontFamily
                        font.weight: Tokens.weightMedium
                        font.pixelSize: Tokens.sizeCaption
                        font.letterSpacing: Tokens.sizeCaption * Tokens.trackLabel
                    }
                }
            }

            // The expanded card near the centre: the focus target.
            Item {
                id: card
                visible: scene.expanded
                x: scene.focusRect.x
                y: scene.focusRect.y
                width: scene.focusRect.width
                height: scene.focusRect.height

                Text {
                    x: 0
                    y: 0
                    text: "CREW"
                    color: Tokens.textLabel
                    font.family: Tokens.fontFamily
                    font.weight: Tokens.weightMedium
                    font.pixelSize: Tokens.sizeLabel
                    font.letterSpacing: Tokens.sizeLabel * Tokens.trackLabel
                }

                Text {
                    x: 0
                    y: 54
                    text: "182k"
                    color: Tokens.ink
                    font.family: Tokens.fontFamily
                    font.weight: Tokens.weightBlack
                    font.pixelSize: Tokens.sizeReadout
                    font.features: ({ "tnum": 1 })
                }

                Text {
                    x: 0
                    y: 186
                    text: "TOKENS TODAY"
                    color: Tokens.textCaption
                    font.family: Tokens.fontFamily
                    font.weight: Tokens.weightRegular
                    font.pixelSize: Tokens.sizeCaption
                    font.letterSpacing: Tokens.sizeCaption * Tokens.trackLabel
                }

                Repeater {
                    model: [
                        "bezier · 74k · 12m",
                        "amber · 61k · 26m",
                        "quill · 47k · 41m"
                    ]
                    delegate: Text {
                        required property int index
                        required property string modelData
                        x: 0
                        y: 250 + index * 52
                        text: modelData
                        color: Tokens.ink
                        opacity: 0.9
                        font.family: Tokens.fontFamily
                        font.weight: Tokens.weightRegular
                        font.pixelSize: Tokens.sizeBody
                    }
                }

                // Token strip: horizontal position is session start.
                Repeater {
                    model: 40
                    delegate: Rectangle {
                        id: stripDot
                        required property int index
                        x: 24 + index * 21
                        y: 470 + (index % 3) * 4
                        width: 5
                        height: 5
                        radius: 2.5
                        color: index < 26 ? Tokens.acid : Tokens.ice
                        opacity: index < 26 ? 0.85 : 0.45
                    }
                }
            }
        }
    }
}
