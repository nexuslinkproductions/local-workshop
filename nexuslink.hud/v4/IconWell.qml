import QtQuick

// Icon in a tinted rounded well (reference "icon-in-tinted-well").
// Either a font glyph (Style.ico.*) or a themed bitmap `source`; apps keep
// their honest bitmaps, chrome gets glyphs. Hover brightens (WS-05 semantics).
Item {
    id: well

    property string glyph: ""
    property bool brand: false              // Font Awesome Brands face (bluetooth)
    property string source: ""                 // .desktop / theme bitmap
    property color tint: Style.c.azure
    property bool active: false             // lit rim + brighter fill
    property bool hovered: false            // fed by the owning MouseArea
    property real size: 24
    property real radius: Style.r.well

    implicitWidth: size
    implicitHeight: size

    Rectangle {
        anchors.fill: parent
        radius: Math.min(well.radius, width / 2)
        color: Style.tone(well.tint, well.active ? 0.22 : (well.hovered ? 0.18 : 0.10))
        border.width: 1
        border.color: well.active ? Style.tone(well.tint, 0.55)
                      : (well.hovered ? Style.tone(well.tint, 0.40) : Style.tone(well.tint, 0.16))
    }

    Text {
        anchors.centerIn: parent
        visible: well.glyph !== "" && well.source === ""
        text: well.glyph
        color: well.hovered || well.active ? Qt.lighter(well.tint, 1.25) : well.tint
        font.family: well.brand ? Style.brandFont : Style.iconFont
        font.pixelSize: Math.round(well.size * 0.46)
        renderType: Text.NativeRendering
    }

    Image {
        anchors.centerIn: parent
        visible: well.source !== ""
        width: Math.round(well.size * 0.66)
        height: width
        source: well.source
        sourceSize: Qt.size(width, width)
        asynchronous: true
        smooth: true
    }
}
