import QtQuick

// Embossed neumorphic control (mock .emboss + optional .holo rim).
// Machined graphite surface: top-light edge + bottom shade + dark border.
// Optional tile header (led dot + Michroma name + F-key Tag) and insight
// line, matching the hub tiles on the DP-1 mock. Children land in the body
// zone below the header via the default `contentData` alias.
Item {
    id: tile

    default property alias contentData: content.data
    property real padding: 12
    property real radius: Style.r.emboss
    property string title: ""
    property string keyCap: ""            // F-key label -> Tag chip
    property string insight: ""
    property bool hot: false              // acid led + hover rim
    property color ledColor: hot ? Style.c.accent : Style.c.accent2
    property bool holo: false
    property bool dropShadow: true
    // hoverExternal lets an overlay MouseArea (which sits above hoverArea and
    // therefore steals hover) keep the rim lit
    property bool hoverExternal: false
    readonly property bool hovered: hoverArea.containsMouse || hoverExternal

    signal clicked

    implicitWidth: Math.ceil(inner.implicitWidth + 2 * padding + 2)
    implicitHeight: Math.ceil(inner.implicitHeight + 2 * padding + 2)

    // static bloom behind hot tiles: a soft stacked-rect halo, no blur filter
    Rectangle {
        anchors.fill: parent
        anchors.margins: -3
        radius: tile.radius + 3
        color: "transparent"
        border.width: 3
        border.color: Style.tone(Style.c.accent, 0.10)
        visible: tile.hot
    }

    // drop shadow plate (static, no filters)
    Rectangle {
        anchors.fill: parent
        anchors.topMargin: 2
        anchors.bottomMargin: -2
        radius: tile.radius + 1
        color: Style.shadow(Qt.rgba(0, 0, 0, 1), 8)
        visible: tile.dropShadow
    }

    // 1px dark keyline
    Rectangle {
        anchors.fill: parent
        radius: tile.radius
        color: "transparent"
        border.width: 1
        border.color: Qt.rgba(0, 0, 0, 0.55)
    }

    // embossed face
    Rectangle {
        id: face
        anchors.fill: parent
        anchors.margins: 1
        radius: Math.max(0, tile.radius - 1)
        clip: true
        color: "transparent"
        gradient: Gradient {
            GradientStop {
                position: 0.0
                color: Style.c.ink2
            }
            GradientStop {
                position: 1.0
                color: Style.c.ink
            }
        }

        // inset top light / bottom shade
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: face.radius
            anchors.rightMargin: face.radius
            height: 1
            color: Qt.rgba(0.92, 0.96, 0.99, 0.20)
        }
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: face.radius
            anchors.rightMargin: face.radius
            height: 1
            color: Qt.rgba(0, 0, 0, 0.65)
        }
    }

    // iridescent top rim: a plain horizontal-gradient Rectangle (no Canvas
    // texture per instance; ~40 panes/tiles carry one)
    Rectangle {
        id: holoStrip
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        height: 2
        opacity: 0.75
        visible: tile.holo
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 0.2; color: Style.c.accent2 }
            GradientStop { position: 0.4; color: Style.c.azure }
            GradientStop { position: 0.6; color: Style.c.magenta }
            GradientStop { position: 0.8; color: Style.c.accent }
            GradientStop { position: 1.0; color: "transparent" }
        }
    }

    // hover rim: acid for hot tiles, ice otherwise (mock .tile:hover)
    Rectangle {
        anchors.fill: parent
        radius: tile.radius
        color: "transparent"
        border.width: 1
        border.color: Style.tone(tile.hot ? Style.c.accent : Style.c.accent2, 0.50)
        opacity: tile.hovered ? 1 : 0
        Behavior on opacity {
            NumberAnimation {
                duration: Style.dur.snap
                easing.type: Style.easing.standard
            }
        }
    }

    Column {
        id: inner
        anchors.fill: parent
        anchors.margins: tile.padding + 1
        spacing: 7

        Row {
            id: head
            width: parent.width
            height: Math.max(led.height, name.implicitHeight, tile.keyCap !== "" ? cap.implicitHeight : 0)
            spacing: 9
            visible: tile.title !== "" || tile.keyCap !== ""

            Rectangle {
                id: led
                width: 7
                height: 7
                radius: 4
                anchors.verticalCenter: parent.verticalCenter
                color: tile.ledColor
            }

            Text {
                id: name
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, parent.width - led.width - (cap.visible ? cap.width + head.spacing : 0) - head.spacing)
                elide: Text.ElideRight
                text: tile.title
                color: Style.c.txt
                font.family: Theme.displayFamily
                font.pixelSize: Style.f.pxTile
                font.letterSpacing: Style.f.lsTitle
            }
            Tag {
                id: cap
                anchors.verticalCenter: parent.verticalCenter
                text: tile.keyCap
                visible: tile.keyCap !== ""
            }
        }

        Text {
            id: ins
            width: parent.width
            visible: tile.insight !== ""
            elide: Text.ElideRight
            text: tile.insight
            color: Style.c.dim
            font.family: Theme.monoFamily
            font.pixelSize: Style.f.pxInsight
        }

        Item {
            id: content
            width: parent.width
            height: Math.max(0, inner.height - (head.visible ? head.height + inner.spacing : 0) - (ins.visible ? ins.height + inner.spacing : 0))
        }
    }

    MouseArea {
        id: hoverArea
        anchors.fill: parent
        hoverEnabled: true
        onClicked: tile.clicked()
    }
}
