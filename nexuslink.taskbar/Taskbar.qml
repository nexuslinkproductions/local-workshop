import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Widgets
import qs.Commons
import qs.Ui

// NEXUS Taskbar — a persistent Windows/macOS-style window list inside the
// Omarchy bar. One entry per open window; click focuses (even grouped or
// off-workspace windows), middle-click closes. The bar is built per monitor,
// so each screen's instance shows the windows on its own workspaces unless
// "perMonitor" is turned off in shell.json.
//
// Model: Hyprland.workspaces[].toplevels — event-driven over the Hyprland IPC
// socket (same path the workspaces widget uses for occupancy). Each entry's
// .wayland handle gives the ext-foreign-toplevel Toplevel for
// activate()/close()/appId. (Hyprland.toplevels is only a refresh-driven
// snapshot, so it is not used as the model source.)
BarWidget {
  id: root
  moduleName: "nexuslink.taskbar"

  // Which screen this particular bar instance renders on. The shared `bar`
  // host is a singleton across monitors, so the screen is resolved from the
  // widget's own window — same trick Bar.qml's slotScreenName() uses.
  readonly property string screenName: {
    var window = root.QsWindow ? root.QsWindow.window : null
    return window && window.screen ? String(window.screen.name || "") : ""
  }

  readonly property bool perMonitor: setting("perMonitor", true) === true
  readonly property bool showTitles: setting("titles", true) === true
  readonly property int maxTitleWidth: Number(setting("maxTitleWidth", 150))
  readonly property int maxWidth: Number(setting("maxWidth", 640))

  // Hyprland-side handle for a wayland Toplevel — the attached
  // HyprlandToplevel resolves live over IPC. Returns null until the window's
  // address has been reported.
  function hyprOf(toplevel) {
    if (!toplevel) return null
    var attached = toplevel.HyprlandToplevel
    return attached ? (attached.handle || attached) : null
  }

  function workspaceIdOf(hlToplevel) {
    var workspace = hlToplevel ? hlToplevel.workspace : null
    return workspace ? workspace.id : 0
  }

  function appIdOf(hlToplevel) {
    var wayland = hlToplevel ? hlToplevel.wayland : null
    return wayland ? String(wayland.appId || "") : ""
  }

  // Windows shown on this bar: every toplevel on every workspace — including
  // special/scratchpad workspaces (dimmed, tagged "scratch"), since
  // scratchpad-hidden windows are exactly the ones that get lost — minus
  // other monitors' workspaces when perMonitor is on. Sorted by workspace id
  // so entries don't jump around as focus changes.
  function windowsForBar() {
    var workspaces = Hyprland.workspaces ? Hyprland.workspaces.values : []
    var out = []
    var seen = {}
    for (var i = 0; i < workspaces.length; i++) {
      var workspace = workspaces[i]
      if (root.perMonitor && root.screenName !== "") {
        var monitor = workspace.monitor
        var monitorName = monitor && monitor.name ? String(monitor.name) : ""
        if (monitorName !== "" && monitorName !== root.screenName) continue
      }
      var toplevels = workspace.toplevels ? workspace.toplevels.values : []
      for (var j = 0; j < toplevels.length; j++) {
        var hl = toplevels[j]
        var key = String(hl.address || hl.title || "")
        if (key !== "" && seen[key]) continue
        seen[key] = true
        out.push(hl)
      }
    }
    // Second pass: scratchpad/special-workspace windows don't appear in
    // workspace.toplevels, so pull them from the live wayland list instead.
    // They float between monitors when summoned, so every bar shows them
    // dimmed rather than guessing an owner.
    var all = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    for (var k = 0; k < all.length; k++) {
      var hl2 = root.hyprOf(all[k])
      if (!hl2 || root.workspaceIdOf(hl2) >= 0) continue
      var key2 = String(hl2.address || hl2.title || "")
      if (key2 !== "" && seen[key2]) continue
      seen[key2] = true
      out.push(hl2)
    }
    out.sort(function(a, b) {
      var wa = root.workspaceIdOf(a)
      var wb = root.workspaceIdOf(b)
      if (wa !== wb) return wa - wb
      return root.appIdOf(a).localeCompare(root.appIdOf(b))
    })
    return out
  }

  // appId -> themed icon. Desktop-entry lookup first (covers ids that don't
  // match icon names), then direct themed paths, then a generic fallback.
  function iconFor(appId) {
    var id = String(appId || "").trim()
    var fallback = Quickshell.iconPath("application-x-executable", true)
    if (id.length === 0) return fallback
    try {
      var entry = null
      if (DesktopEntries.byId) entry = DesktopEntries.byId(id) || DesktopEntries.byId(id.toLowerCase())
      if (!entry && DesktopEntries.heuristicLookup) entry = DesktopEntries.heuristicLookup(id)
      if (entry && entry.icon) {
        var entryIcon = Quickshell.iconPath(String(entry.icon), true)
        if (entryIcon.length > 0) return entryIcon
      }
    } catch (e) {}
    var themed = Quickshell.iconPath(id, true)
    if (themed.length > 0) return themed
    themed = Quickshell.iconPath(id.toLowerCase(), true)
    return themed.length > 0 ? themed : fallback
  }

  Component.onCompleted: {
    var wins = windowsForBar()
    var tags = []
    for (var i = 0; i < wins.length; i++) tags.push("ws" + root.workspaceIdOf(wins[i]) + ":" + root.appIdOf(wins[i]))
    console.log("nexuslink.taskbar screen=" + root.screenName + " windows=" + wins.length + " [" + tags.join(", ") + "]")
  }

  visible: repeater.count > 0 && !vertical
  implicitWidth: visible ? Math.min(root.maxWidth, row.implicitWidth) : 0
  implicitHeight: root.barSize

  Item {
    anchors.fill: parent
    clip: true

    Row {
      id: row
      height: parent.height
      spacing: Style.spaceReal(1)

      Repeater {
        id: repeater
        model: root.windowsForBar()

        Item {
          id: entry
          required property var modelData

          readonly property var hlToplevel: modelData
          readonly property var toplevel: hlToplevel ? hlToplevel.wayland : null
          readonly property bool isActive: hlToplevel !== null && (hlToplevel.activated === true
            || (entry.toplevel !== null && entry.toplevel === ToplevelManager.activeToplevel))
          readonly property string label: {
            var title = hlToplevel ? String(hlToplevel.title || "") : ""
            if (title !== "") return title
            if (entry.toplevel) return String(entry.toplevel.title || entry.toplevel.appId || "")
            return ""
          }
          readonly property bool scratch: root.workspaceIdOf(hlToplevel) < 0
          readonly property string workspaceTag: {
            var id = root.workspaceIdOf(hlToplevel)
            return id > 0 ? "ws" + id : (id < 0 ? "scratch" : "")
          }

          opacity: scratch ? 0.55 : 1
          implicitHeight: root.barSize
          implicitWidth: content.implicitWidth + Style.spaceReal(4)

          Rectangle {
            anchors.fill: parent
            radius: 4
            color: mouseArea.containsMouse ? Util.alpha(Color.foreground, 0.09) : "transparent"
          }

          Row {
            id: content
            anchors.centerIn: parent
            spacing: Style.spaceReal(1.5)

            IconImage {
              anchors.verticalCenter: parent.verticalCenter
              implicitSize: Math.round(root.barSize * 0.5)
              source: root.iconFor(root.appIdOf(entry.hlToplevel))
            }

            Text {
              visible: root.showTitles
              anchors.verticalCenter: parent.verticalCenter
              text: entry.label
              color: entry.isActive ? (root.bar ? root.bar.urgent : Color.urgent)
                                    : (root.bar ? root.bar.barForeground : Color.foreground)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
              width: Math.min(implicitWidth, root.maxTitleWidth)
            }
          }

          Rectangle {
            visible: entry.isActive
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - Style.spaceReal(4)
            height: 2
            radius: 1
            color: root.bar ? root.bar.urgent : Color.urgent
          }

          MouseArea {
            id: mouseArea
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
            cursorShape: Qt.PointingHandCursor

            onClicked: function(mouse) {
              if (!entry.toplevel) return
              if (mouse.button === Qt.LeftButton) entry.toplevel.activate()
              else if (mouse.button === Qt.MiddleButton) entry.toplevel.close()
            }
            onEntered: {
              if (root.bar) {
                var tip = entry.label
                if (entry.workspaceTag !== "") tip = entry.workspaceTag + " — " + tip
                root.bar.showTooltip(entry, tip)
              }
            }
            onExited: if (root.bar) root.bar.hideTooltip(entry)
          }
        }
      }
    }
  }
}
