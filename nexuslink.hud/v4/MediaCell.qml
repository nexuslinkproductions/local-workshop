pragma ComponentBehavior: Bound

import QtQuick

// MediaCell.qml — MPRIS dock cell body (lane G2, compact workbench dock).
// Left ~square album-art thumb + the usual label / value / sub column.
// The art Image is async + Qt url-cached and only refetches when `artUrl`
// actually changes; while no art exists (or it is still decoding / failed)
// a muted glyph sits in the thumb well instead — never a dead black box.
// The cell is intentionally timer-free: the host dock's existing mediaPoll
// cadence (~2 s) is the only clock, and artUrl rides along in that JSON.
Item {
    id: cell

    property string label: ""
    property string value: ""      // rich-text line — dock.cellValue("media")
    property string sub: ""        // plain line — dock.cellSub("media")
    property string artUrl: ""     // mpris:artUrl; "" disables the fetch entirely

    // thumb edge: square, bounded so a tall cell can't grow a giant cover
    readonly property real side: Math.max(28, Math.min(height - 4, 62))

    Row {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: 2
        anchors.rightMargin: 2
        spacing: 10

        // thumb well — recessed square, rounded corners, clipped art
        Rectangle {
            id: well
            width: cell.side
            height: cell.side
            anchors.verticalCenter: parent.verticalCenter
            radius: 7
            color: Style.c.recess
            border.color: Style.c.edge
            border.width: 1
            clip: true

            Image {
                id: art
                anchors.fill: parent
                asynchronous: true
                cache: true                       // Qt url cache — refetch only on source change
                fillMode: Image.PreserveAspectCrop
                // decode near display size (~2x for density), not source size
                sourceSize: Qt.size(Math.round(cell.side * 2), Math.round(cell.side * 2))
                source: cell.artUrl
                visible: cell.artUrl !== "" && status === Image.Ready
            }
            Text {
                anchors.centerIn: parent
                visible: !art.visible
                text: "♪"
                color: Style.c.faint
                font.family: Style.f.mono
                font.pixelSize: Math.round(cell.side * 0.42)
            }
        }

        Column {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, parent.width - well.width - parent.spacing)
            spacing: 4

            Text {
                width: parent.width
                elide: Text.ElideRight
                text: cell.label
                color: Style.c.mute
                font.family: Style.f.mono
                font.pixelSize: Style.f.pxTag
                font.letterSpacing: 1.6
            }
            Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.RichText
                text: cell.value
                color: Style.c.txt
                font.family: Style.f.mono
                font.pixelSize: 12
            }
            Text {
                width: parent.width
                elide: Text.ElideRight
                visible: cell.sub !== ""
                text: cell.sub
                color: Style.c.faint
                font.family: Style.f.mono
                font.pixelSize: 9
            }
        }
    }
}
