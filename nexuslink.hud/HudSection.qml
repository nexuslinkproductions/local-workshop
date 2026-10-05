import QtQuick
import qs.Commons

// Collapsible HUD section: a clickable header (chevron + title + fading rule)
// and a body that animates its height when toggled. Rows placed inside a
// HudSection land in the body via the `rows` default-property alias.
Column {
  id: section

  property string title: "SECTION"
  property color accent: "#00e5ff"
  property bool collapsed: false
  signal toggled()

  default property alias rows: bodyContent.data

  width: parent ? parent.width : 0
  spacing: 0

  // ------------------------------------------------------------- header
  Item {
    id: header
    width: parent.width
    height: headerRow.height + Style.space(10)

    Row {
      id: headerRow
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.topMargin: Style.space(4)
      spacing: Style.space(6)

      Text {
        text: section.collapsed ? "▸" : "▾"
        color: section.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        text: section.title
        color: headerMa.containsMouse ? section.accent : Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        font.letterSpacing: 2
      }
    }

    Rectangle {
      anchors.left: headerRow.right
      anchors.right: parent.right
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: headerRow.verticalCenter
      height: 1
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0.0; color: Util.alpha(section.accent, 0.55) }
        GradientStop { position: 1.0; color: "transparent" }
      }
    }

    MouseArea {
      id: headerMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: section.toggled()
    }
  }

  // ---------------------------------------------------------------- body
  Item {
    id: bodyClip
    width: parent.width
    height: section.collapsed ? 0 : bodyContent.implicitHeight
    clip: true
    visible: height > 0.5
    Behavior on height {
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    Column {
      id: bodyContent
      width: parent.width
      spacing: Style.space(4)
      topPadding: Style.space(2)
      bottomPadding: Style.space(6)
    }
  }
}
