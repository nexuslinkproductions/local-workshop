import QtQuick

// Frosted glass readout pane (mock .glass + .holo edge light).
//   1px gradient rim, glass fill, top frost sheen, inner glow ring,
//   cheap offset shadow plate, optional pulsing `busy` border.
// Children land inside the face via the default `contentData` alias.
Item {
    id: pane

    default property alias contentData: content.data
    property real padding: 0
    property real radius: Style.r.glass
    property bool busy: false               // lit rim while data is in flight
    property color busyColor: Style.c.accent
    property color glow: Style.tone(Style.c.azure, 0.10)  // transparent disables
    property bool holo: false               // iridescent top edge light
    property bool dropShadow: true
    property int edgeWidth: 1

    // implicit size = content extent + chrome. Bound via `delayed` Binding:
    // `content` receives consumer children through the `contentData` alias,
    // and children anchored to opposite edges of `content` (e.g. CommandHub's
    // masthead rows) make `childrenRect` a function of the pane's own size.
    // A direct binding re-entered mid-evaluation — reading childrenRect
    // resolved those pending anchor bindings, whose geometry writes marked
    // childrenRect dirty while the implicitWidth binding was still running —
    // Qt reports "Binding loop detected for property implicitWidth" per pane.
    // `delayed` defers first evaluation until those bindings have settled;
    // the binding stays live afterwards (implicit size still tracks content).
    Binding {
        target: pane
        property: "implicitWidth"
        value: Math.ceil(content.childrenRect.width + 2 * pane.padding + 2 * pane.edgeWidth)
        delayed: true
    }
    Binding {
        target: pane
        property: "implicitHeight"
        value: Math.ceil(content.childrenRect.height + 2 * pane.padding + 2 * pane.edgeWidth)
        delayed: true
    }

    onBusyChanged: if (!busy)
        busyRim.opacity = 0

    // cheap drop shadow: static offset plate, no filters
    Rectangle {
        anchors.fill: parent
        anchors.topMargin: 4
        anchors.bottomMargin: -4
        radius: pane.radius + 1
        color: Style.shadow(Qt.rgba(0, 0, 0, 1), 18)
        visible: pane.dropShadow
    }

    // 1px gradient edge (outer rim shows around the inset face)
    Rectangle {
        id: edge
        anchors.fill: parent
        radius: pane.radius
        color: "transparent"
        gradient: Gradient {
            GradientStop {
                position: 0.0
                color: Qt.rgba(0.92, 0.96, 0.99, 0.28)
            }
            GradientStop {
                position: 0.4
                color: Style.c.glassLine
            }
            GradientStop {
                position: 1.0
                color: Qt.rgba(0, 0, 0, 0.5)
            }
        }
    }

    Rectangle {
        id: face
        anchors.fill: parent
        anchors.margins: pane.edgeWidth
        radius: Math.max(0, pane.radius - pane.edgeWidth)
        clip: true
        color: "transparent"
        gradient: Gradient {
            GradientStop {
                position: 0.0
                color: Style.c.glassHi
            }
            GradientStop {
                position: 0.3
                color: Style.c.pane
            }
            GradientStop {
                position: 1.0
                color: Style.c.glassDeep
            }
        }

        // frost sheen over the top 38%
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: Math.round(parent.height * 0.38)
            radius: face.radius
            color: "transparent"
            gradient: Gradient {
                GradientStop {
                    position: 0.0
                    color: Qt.rgba(0.92, 0.96, 0.99, 0.10)
                }
                GradientStop {
                    position: 1.0
                    color: "transparent"
                }
            }
        }

        // inner glow ring
        Rectangle {
            anchors.fill: parent
            anchors.margins: 1
            radius: Math.max(0, face.radius - 1)
            color: "transparent"
            border.width: 1
            border.color: pane.glow
            visible: pane.glow.a > 0
        }

        Item {
            id: content
            anchors.fill: parent
            anchors.margins: pane.padding
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
        visible: pane.holo
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

    // busy rim: pulses only while busy, so an idle pane costs nothing
    Rectangle {
        id: busyRim
        anchors.fill: parent
        radius: pane.radius
        color: "transparent"
        border.width: 1
        border.color: pane.busyColor
        opacity: 0
        visible: opacity > 0
        SequentialAnimation on opacity {
            running: pane.busy && pane.visible
            loops: Animation.Infinite
            NumberAnimation {
                to: 1.0
                duration: 620
                easing.type: Easing.InOutSine
            }
            NumberAnimation {
                to: 0.35
                duration: 620
                easing.type: Easing.InOutSine
            }
        }
    }
}
