import QtQuick

// Dock action token: tinted icon well over a micro label. Never shows a
// value (dedupe law: dock cells are actions). `hot` lights the state ring,
// `busy` lights the acid rim while a poller/command is in flight.
Item {
    id: cell

    property string glyph: ""
    property bool brand: false
    property string label: ""
    property bool hot: false
    property bool busy: false
    property string kind: "button"          // button | toggle | link
    property color tint: hot ? Style.c.accent : Style.c.azure
    property alias hovered: ma.containsMouse

    signal activated
    signal secondary

    EmbossedTile {
        anchors.fill: parent
        radius: 12
        padding: 4
        hot: cell.hot
        dropShadow: false
    }

    Rectangle {
        anchors.fill: parent
        radius: 12
        color: cell.hovered ? Style.c.azureWash : "transparent"
        border.width: 1
        border.color: cell.busy ? Style.tone(Style.c.accent, 0.60)
                      : (cell.hovered ? Style.tone(Style.c.accent2, 0.50) : "transparent")
    }

    Column {
        anchors.centerIn: parent
        spacing: 5
        IconWell {
            anchors.horizontalCenter: parent.horizontalCenter
            size: Math.max(20, Math.min(30, cell.height - 28))
            glyph: cell.glyph
            brand: cell.brand
            tint: cell.tint
            active: cell.hot
            hovered: cell.hovered
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(implicitWidth, cell.width - 8)
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            visible: cell.label !== ""
            text: cell.label
            color: cell.hovered || cell.hot ? Style.c.txt : Style.c.dim
            font.family: Theme.monoFamily
            font.pixelSize: Style.f.pxMicro
            font.letterSpacing: Style.f.lsTag
        }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: mouse => mouse.button === Qt.RightButton ? cell.secondary() : cell.activated()
    }
}
