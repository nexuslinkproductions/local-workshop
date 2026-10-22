pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import NexusHud.V5 1.0

// W4 glyph dispatcher: one key in, one 24 px glyph out. Keys are the ids the
// launcher and the integrator use: the launcher set from the binding design
// amendments (hermes, devin, files, terminal, chrome, discord, x, youtube,
// whatsapp, arc-raiders) plus the seven system glyphs (find, crew, power, wifi,
// battery, volume, settings). An unknown key draws a calm single node instead
// of an error, so a feed that renames an app never breaks the deck.
//
// Each key is a Component that binds the three glyph inputs (color, weight,
// size) to this item. Nothing is instantiated until a key is set, so a deck of
// nine tiles pays for nine glyphs, not seventeen.
Item {
    id: root

    property string glyph: ""
    property color color: Tokens.ink
    property real weight: 1.5
    property real size: 24

    readonly property var components: ({
        "hermes": hermesGlyph,
        "devin": devinGlyph,
        "files": filesGlyph,
        "terminal": terminalGlyph,
        "chrome": chromeGlyph,
        "discord": discordGlyph,
        "x": xGlyph,
        "youtube": youtubeGlyph,
        "whatsapp": whatsappGlyph,
        "arc-raiders": arcRaidersGlyph,
        "find": findGlyph,
        "crew": crewGlyph,
        "power": powerGlyph,
        "wifi": wifiGlyph,
        "battery": batteryGlyph,
        "volume": volumeGlyph,
        "settings": settingsGlyph
    })
    readonly property bool known: root.components[root.glyph] !== undefined

    implicitWidth: size
    implicitHeight: size
    width: size
    height: size

    Loader {
        anchors.centerIn: parent
        width: 24
        height: 24
        sourceComponent: root.known ? root.components[root.glyph] : unknownGlyph
    }

    Component { id: hermesGlyph; Hermes { color: root.color; weight: root.weight; size: root.size } }
    Component { id: devinGlyph; Devin { color: root.color; weight: root.weight; size: root.size } }
    Component { id: filesGlyph; Files { color: root.color; weight: root.weight; size: root.size } }
    Component { id: terminalGlyph; Terminal { color: root.color; weight: root.weight; size: root.size } }
    Component { id: chromeGlyph; Chrome { color: root.color; weight: root.weight; size: root.size } }
    Component { id: discordGlyph; Discord { color: root.color; weight: root.weight; size: root.size } }
    Component { id: xGlyph; XMark { color: root.color; weight: root.weight; size: root.size } }
    Component { id: youtubeGlyph; Youtube { color: root.color; weight: root.weight; size: root.size } }
    Component { id: whatsappGlyph; Whatsapp { color: root.color; weight: root.weight; size: root.size } }
    Component { id: arcRaidersGlyph; ArcRaiders { color: root.color; weight: root.weight; size: root.size } }
    Component { id: findGlyph; Find { color: root.color; weight: root.weight; size: root.size } }
    Component { id: crewGlyph; Crew { color: root.color; weight: root.weight; size: root.size } }
    Component { id: powerGlyph; Power { color: root.color; weight: root.weight; size: root.size } }
    Component { id: wifiGlyph; Wifi { color: root.color; weight: root.weight; size: root.size } }
    Component { id: batteryGlyph; Battery { color: root.color; weight: root.weight; size: root.size } }
    Component { id: volumeGlyph; Volume { color: root.color; weight: root.weight; size: root.size } }
    Component { id: settingsGlyph; Settings { color: root.color; weight: root.weight; size: root.size } }

    // Unknown key: one node, the dot the set already uses for accents.
    Component {
        id: unknownGlyph
        Shape {
            width: 24
            height: 24
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeColor: "transparent"
                fillColor: root.color
                PathAngleArc {
                    centerX: 12
                    centerY: 12
                    radiusX: 2.6
                    radiusY: 2.6
                    startAngle: 0
                    sweepAngle: 360
                }
            }
        }
    }
}
