import QtQuick

// F-key chip: recessed graphite slot with an engraved mono label.
//   text    "F1".."F10" or any short cap
//   tone    label colour (dim default, accent when active/hot)
//   active  light the chip (acid border + acid text)
Item {
    id: tag

    property string text: ""
    property bool active: false
    property color tone: active ? Style.c.accent : Style.c.faint
    property real radius: Style.r.chip

    implicitWidth: Math.ceil(label.implicitWidth + 14)
    implicitHeight: Math.ceil(label.implicitHeight + 5)

    Rectangle {
        id: well
        anchors.fill: parent
        radius: tag.radius
        border.width: 1
        border.color: tag.active ? Style.tone(Style.c.accent, 0.55) : Qt.rgba(0, 0, 0, 0.5)
        gradient: Gradient {
            GradientStop {
                position: 0.0
                color: Style.c.recessTop
            }
            GradientStop {
                position: 1.0
                color: Style.c.recess
            }
        }

        // recessed top shade (fakes the inset 0 2px 6px of the mock)
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: well.radius
            anchors.rightMargin: well.radius
            height: 1
            color: Qt.rgba(0, 0, 0, 0.7)
        }
        // bottom inner light
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: well.radius
            anchors.rightMargin: well.radius
            height: 1
            color: Qt.rgba(0.92, 0.96, 0.99, 0.08)
        }

        Text {
            id: label
            anchors.centerIn: parent
            text: tag.text
            color: tag.tone
            font.family: Theme.monoFamily
            font.pixelSize: Style.f.pxTag
            font.letterSpacing: Style.f.lsTag
        }
    }
}
