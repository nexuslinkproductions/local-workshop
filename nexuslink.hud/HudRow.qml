import QtQuick
import qs.Commons

// One stat line inside a HudSection body: a small caps label on the left, an
// optional thin gauge in the middle, and a right-aligned value.
// Set `fraction` to 0..1 to show the gauge; -1 (default) hides it.
Item {
  id: row

  property string label: ""
  property string value: ""
  property real fraction: -1
  property color accent: "#00e5ff"
  // Transparent by default -> falls back to Color.foreground.
  property color valueColor: Qt.rgba(0, 0, 0, 0)

  width: parent ? parent.width : implicitWidth
  implicitHeight: Math.max(lbl.implicitHeight, val.implicitHeight, 8)
  height: implicitHeight

  Text {
    id: lbl
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: 66
    text: row.label
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.letterSpacing: 1.2
    elide: Text.ElideRight
  }

  Rectangle {
    id: track
    visible: row.fraction >= 0
    anchors.left: lbl.right
    anchors.leftMargin: 8
    anchors.right: val.left
    anchors.rightMargin: 10
    anchors.verticalCenter: parent.verticalCenter
    height: 5
    color: Util.alpha(Color.foreground, 0.08)

    Rectangle {
      height: parent.height
      width: parent.width * Util.clamp(row.fraction, 0, 1)
      color: row.accent
      Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    }
  }

  Text {
    id: val
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    text: row.value
    color: row.valueColor.a > 0 ? row.valueColor : Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    horizontalAlignment: Text.AlignRight
    elide: Text.ElideRight
  }
}
