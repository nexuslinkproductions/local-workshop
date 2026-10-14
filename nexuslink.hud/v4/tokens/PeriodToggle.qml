pragma ComponentBehavior: Bound

import QtQuick
import ".."

// PeriodToggle.qml — hairline segmented control for the tokens deck
// (DAY | WEEK). Each segment sizes to its text plus padding; the active
// segment gets an acid keyline + tinted plate. Hover brightens (never
// darkens). `picked(v)` fires on click; the host persists the choice.
Item {
    id: root

    // segments: [{ "v": "day", "label": "DAY" }, ...] — fixed order
    property var segments: []
    property string value: ""
    signal picked(string v)

    implicitWidth: row.width
    implicitHeight: 26

    Row {
        id: row
        spacing: 0
        Repeater {
            model: root.segments
            delegate: Item {
                id: seg
                required property int index
                required property var modelData
                readonly property bool on: String(modelData.v) === root.value
                width: segTx.implicitWidth + 26
                height: root.implicitHeight

                Rectangle {
                    anchors.fill: parent
                    color: seg.on ? FuiTokens.tone(FuiTokens.acid, 0.10)
                         : ma.containsMouse ? FuiTokens.tone(FuiTokens.ice, 0.10)
                         : FuiTokens.tone(FuiTokens.ice, 0.03)
                    border.width: 1
                    border.color: seg.on ? FuiTokens.tone(FuiTokens.acid, 0.85)
                                : ma.containsMouse ? FuiTokens.tone(FuiTokens.ice, 0.65)
                                : FuiTokens.hair3
                }
                Rectangle {
                    anchors { left: parent.left; right: parent.right
                              bottom: parent.bottom }
                    height: 2
                    color: FuiTokens.acid
                    visible: seg.on
                }
                Tx {
                    id: segTx
                    anchors.centerIn: parent
                    role: "tag"
                    text: String(seg.modelData.label)
                    color: seg.on ? FuiTokens.acid
                         : ma.containsMouse ? FuiTokens.white : FuiTokens.dim
                }
                // full-bounds click target — background-layer decks get no
                // implicit hit area, the MouseArea must cover the segment
                MouseArea {
                    id: ma
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.picked(String(seg.modelData.v))
                }
            }
        }
    }
}
