import QtQuick

// Launch/jump/run row: IconWell + engraved label + optional key chip.
// Hover only ever lights UP (wash + rim), never darkens a border.
Item {
    id: row

    property string glyph: ""
    property bool brand: false
    property string label: ""
    property string hint: ""                // right-side micro chip text
    property color tint: Style.c.azure
    property bool active: false
    property bool busy: false
    property real rowHeight: 30
    property alias hovered: ma.containsMouse

    signal triggered

    implicitHeight: rowHeight
    implicitWidth: 160

    Rectangle {
        anchors.fill: parent
        radius: Style.r.key
        color: row.hovered ? Style.c.azureWash : (row.active ? Style.tone(row.tint, 0.06) : "transparent")
        border.width: 1
        border.color: row.hovered ? Style.tone(Style.c.accent2, 0.50)
                      : (row.busy ? Style.tone(Style.c.accent, 0.55) : "transparent")
    }

    IconWell {
        id: well
        anchors.left: parent.left
        anchors.leftMargin: 3
        anchors.verticalCenter: parent.verticalCenter
        size: row.rowHeight - 8
        glyph: row.glyph
        brand: row.brand
        tint: row.tint
        active: row.active
        hovered: row.hovered
    }

    Text {
        anchors.left: well.right
        anchors.leftMargin: 9
        anchors.right: chip.visible ? chip.left : parent.right
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        text: row.label
        color: row.hovered || row.active ? Style.c.txt : Style.c.dim
        font.family: Theme.displayFamily
        font.pixelSize: Style.f.pxLabel
        font.letterSpacing: Style.f.lsTag
    }

    Tag {
        id: chip
        anchors.right: parent.right
        anchors.rightMargin: 4
        anchors.verticalCenter: parent.verticalCenter
        visible: row.hint !== ""
        text: row.hint
        active: row.active
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.triggered()
    }
}
