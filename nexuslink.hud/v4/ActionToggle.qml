import QtQuick

// Pill toggle. State is caller-owned: `on` is bound in, `toggled` fires on
// click, the caller flips the real state. No internal animation timers; the
// thumb moves with a single short Behavior only on user input.
Item {
    id: tg

    property string label: ""
    property bool on: false
    property string tone: "azure"           // acid | ice | azure
    property alias hovered: ma.containsMouse
    readonly property color toneColor: tone === "acid" ? Style.c.accent
                                       : (tone === "ice" ? Style.c.accent2 : Style.c.azure)

    signal toggled

    implicitHeight: 20
    implicitWidth: Math.ceil(lab.implicitWidth) + track.width + 10
    opacity: tg.enabled ? 1 : 0.45

    Text {
        id: lab
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        visible: tg.label !== ""
        text: tg.label
        color: tg.hovered || tg.on ? Style.c.txt : Style.c.dim
        font.family: Theme.monoFamily
        font.pixelSize: Style.f.pxTag
        font.letterSpacing: Style.f.lsTag
    }

    Rectangle {
        id: track
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: 32
        height: 16
        radius: Style.r.disc
        border.width: 1
        border.color: tg.on ? Style.tone(tg.toneColor, 0.55)
                      : (tg.hovered ? Style.tone(Style.c.accent2, 0.50) : Qt.rgba(0, 0, 0, 0.5))
        gradient: Gradient {
            GradientStop { position: 0.0; color: tg.on ? Style.tone(tg.toneColor, 0.20) : Style.c.recessTop }
            GradientStop { position: 1.0; color: tg.on ? Style.tone(tg.toneColor, 0.10) : Style.c.recess }
        }

        Rectangle {
            width: 10
            height: 10
            radius: 5
            anchors.verticalCenter: parent.verticalCenter
            x: tg.on ? parent.width - width - 3 : 3
            color: tg.on ? tg.toneColor : (tg.hovered ? Style.c.dim : Style.c.faint)
            Behavior on x {
                NumberAnimation {
                    duration: Style.dur.snap
                    easing.type: Style.easing.standard
                }
            }
        }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: tg.toggled()
    }
}
