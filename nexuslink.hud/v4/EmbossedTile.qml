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
    property alias hovered: hoverArea.containsMouse

    signal clicked

    implicitWidth: Math.ceil(inner.implicitWidth + 2 * padding + 2)
    implicitHeight: Math.ceil(inner.implicitHeight + 2 * padding + 2)

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

    // iridescent top rim (painted once)
    Canvas {
        id: holoStrip
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        height: 2
        opacity: 0.75
        visible: tile.holo
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            if (width <= 0)
                return;
            var g = ctx.createLinearGradient(0, 0, width, 0);
            var stops = ["transparent", Style.c.accent2, Style.c.magenta, Style.c.accent, Style.c.mint, "transparent"];
            for (var i = 0; i < stops.length; i++)
                g.addColorStop(i / (stops.length - 1), stops[i]);
            ctx.fillStyle = g;
            ctx.fillRect(0, 0, width, height);
        }
        onWidthChanged: requestPaint()
        onVisibleChanged: if (visible)
            requestPaint()
    }

    // hover rim: acid for hot tiles, ice otherwise (mock .tile:hover)
    Rectangle {
        anchors.fill: parent
        radius: tile.radius
        color: "transparent"
        border.width: 1
        border.color: Style.tone(tile.hot ? Style.c.accent : Style.c.accent2, 0.35)
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
