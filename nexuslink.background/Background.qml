import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"

  property string currentBackground: ""
  property string displayedBackground: ""
  property string incomingBackground: ""
  property string oldBackground: ""
  property bool finishingTransition: false
  property int backgroundVersion: 0
  property int revealStartedVersion: -1
  property int pendingThemeVersion: -1
  property string pendingColorsRaw: ""
  property string pendingShellRaw: ""
  property real revealProgress: 1

  // ------------------------------------------------------------------- NEXUS
  // NEXUS: v5 ownership rule. On an output the HUD owns this clone creates no
  // NEXUS: wallpaper surface at all (PanelWindow visible false), so the stock
  // NEXUS: wallpaper never draws or composites there. Everything else is stock.

  // NEXUS: read once at startup, same semantics as HudV4's v5Enabled flag.
  FileView {
    id: hudFlagFile
    path: root.home + "/.config/nexuslink/hud-v5"
    blockLoading: true
    watchChanges: false
    printErrors: false
  }

  // NEXUS: second switch for deck B (main-live): env NEXUSLINK_HUD_V5 in
  // NEXUS: {1, true, on}. Read once at startup like the flag file.
  readonly property string hudEnvSwitch: String(Quickshell.env("NEXUSLINK_HUD_V5") || "").trim().toLowerCase()
  readonly property bool hudSwitchOn: hudFlagFile.loaded
    || hudEnvSwitch === "1" || hudEnvSwitch === "true" || hudEnvSwitch === "on"

  // NEXUS: runtime evidence that the HUD plugin instantiated. The plugin API
  // NEXUS: cannot read another plugin's service (shell.pluginServiceFor only
  // NEXUS: returns the caller's own service), so the HUD writes one output name
  // NEXUS: per line here from its PanelWindow onCompleted (hud-ready-marker.patch).
  // NEXUS: Empty or missing file means not confirmed: the wallpaper is drawn.
  readonly property string hudReadyPath: stateHome + "/omarchy/nexuslink-hud-v5-ready"
  property var hudReadyOutputs: []

  FileView {
    id: hudReadyFile
    path: root.hudReadyPath
    blockLoading: false
    watchChanges: true
    printErrors: false
    onLoaded: root.hudReadyOutputs = String(text() || "").split("\n").map(function(line) { return line.trim() }).filter(function(line) { return line !== "" })
    onLoadFailed: root.hudReadyOutputs = []
    // NEXUS: text() is stale inside onFileChanged, so reload and parse in onLoaded.
    onFileChanged: reload()
  }

  // NEXUS: a marker left by an earlier shell run must not confirm a HUD that
  // NEXUS: did not start in this run. Removed once at clone start; the HUD
  // NEXUS: rewrites it when its own window comes up.
  Process {
    id: staleHudReadyProc
    command: ["rm", "-f", root.hudReadyPath]
  }

  // NEXUS: the HUD plugin must be listed in plugins[]; watched so disabling it
  // NEXUS: brings the wallpaper back immediately.
  FileView {
    id: omarchyShellJsonFile
    path: root.home + "/.config/omarchy/shell.json"
    blockLoading: true
    watchChanges: true
    printErrors: false
    onLoaded: root.hudEnabled = root.shellJsonListsHud(text())
    onLoadFailed: root.hudEnabled = false
    // NEXUS: text() is stale inside onFileChanged, so reload and parse in onLoaded.
    onFileChanged: reload()
  }

  property bool hudEnabled: false

  // NEXUS: true only when plugins[] contains an entry whose id is nexuslink.hud.
  function shellJsonListsHud(raw) {
    try {
      var config = JSON.parse(String(raw || ""))
      var plugins = config && Array.isArray(config.plugins) ? config.plugins : []
      for (var i = 0; i < plugins.length; i++) {
        var entry = plugins[i]
        var id = entry && typeof entry === "object" ? String(entry.id || "") : ""
        if (id === "nexuslink.hud") return true
      }
    } catch (error) {
      return false
    }
    return false
  }

  // NEXUS: same rule as ScreenRoles.js roleForScreen: model + serialNumber,
  // NEXUS: lowercased, substring xreal or nreal. Null safe.
  function isGlasses(screen) {
    if (screen === null || screen === undefined) return false
    var parts = []
    if (screen.model !== undefined && screen.model !== null && String(screen.model) !== "")
      parts.push(String(screen.model))
    if (screen.serialNumber !== undefined && screen.serialNumber !== null && String(screen.serialNumber) !== "")
      parts.push(String(screen.serialNumber))
    var identity = parts.join(" ").toLowerCase()
    return identity.indexOf("xreal") >= 0 || identity.indexOf("nreal") >= 0
  }

  // NEXUS: an output is HUD owned when a v5 switch is on (flag file or env),
  // NEXUS: the HUD plugin is enabled, the HUD has confirmed its window on this
  // NEXUS: output (marker), and the output is not the glasses.
  function hudConfirmedOn(screen) {
    var name = screen && screen.name ? String(screen.name) : ""
    return name !== "" && hudReadyOutputs.indexOf(name) >= 0
  }

  function hudOwns(screen) {
    return hudSwitchOn && hudEnabled && hudConfirmedOn(screen) && !isGlasses(screen)
  }

  // NEXUS: geometry evidence, grep journalctl --user -b for nexuslink.background.
  function logOutput(panel) {
    var screen = panel ? panel.screen : null
    var name = screen && screen.name ? String(screen.name) : "unknown"
    if (hudOwns(screen)) {
      console.log("nexuslink.background: output=" + name + " wallpaper=suppressed (HUD owns the output)")
    } else {
      console.log("nexuslink.background: output=" + name + " wallpaper=drawn exclusion=Ignore size="
        + (panel ? panel.width : 0) + "x" + (panel ? panel.height : 0))
    }
  }

  function imageUrl(path) {
    return Util.fileUrl(path)
  }

  function refreshBackground() {
    if (!readlinkProc.running) readlinkProc.running = true
  }

  function setBackground(path, instant) {
    transitionBackground("", path, path, instant, false)
  }

  function transitionBackground(fromPath, path, finalPath, instant, force) {
    path = String(path || "").trim()
    finalPath = String(finalPath || path).trim()
    fromPath = String(fromPath || "").trim()
    if (!path || (!force && finalPath === currentBackground)) return
    currentBackground = finalPath
    backgroundVersion += 1
    revealStartedVersion = -1

    revealAnimation.stop()
    finishingTransition = false

    if (instant || !displayedBackground) {
      oldBackground = ""
      incomingBackground = ""
      displayedBackground = path
      revealProgress = 1
      return
    }

    oldBackground = fromPath || displayedBackground
    incomingBackground = path
    revealProgress = 0
  }

  function setPendingTheme(colorsB64, shellB64) {
    pendingColorsRaw = Util.decodeBase64(colorsB64)
    pendingShellRaw = Util.decodeBase64(shellB64)
    pendingThemeVersion = backgroundVersion
    pendingThemeFallbackTimer.restart()
  }

  function applyPendingTheme() {
    // Background polling can advance backgroundVersion while a theme switch is
    // pending; the latest theme payload should still apply.
    if (pendingThemeVersion < 0) return
    pendingThemeFallbackTimer.stop()
    Commons.Color.loadColors(pendingColorsRaw)
    // Commons.Color.loadShell also refreshes Style so the type scale flips with the
    // background reveal instead of waiting for a separate reload path.
    Commons.Color.loadShell(pendingShellRaw)
    Style.scheduleRefresh()
    pendingThemeVersion = -1
    pendingColorsRaw = ""
    pendingShellRaw = ""
  }

  function transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64) {
    transitionBackground(fromPath, path, finalPath, false, true)
    setPendingTheme(colorsB64, shellB64)
    if (!incomingBackground || revealProgress >= 1) applyPendingTheme()
  }

  function startReveal(panel) {
    if (!incomingBackground) return
    panel.maskReady = true
    if (revealStartedVersion === backgroundVersion) return
    revealStartedVersion = backgroundVersion
    applyPendingTheme()
    revealAnimation.restart()
  }

  function openSelector() {
    if (!bgSwitchProc.running) bgSwitchProc.running = true
  }

  function openThemeSwitcher() {
    if (!themeSwitchProc.running) themeSwitchProc.running = true
  }

  Process {
    id: bgSwitchProc
    command: ["bash", "-c", "background=$(omarchy-theme-bg-switcher); [[ -n $background ]] && omarchy-theme-bg-set \"$background\""]
    onExited: root.refreshBackground()
  }

  Process {
    id: themeSwitchProc
    command: ["bash", "-c", "theme=$(omarchy-theme-switcher); [[ -n $theme ]] && omarchy-theme-set \"$theme\" >/dev/null 2>&1 &"]
    onExited: root.refreshBackground()
  }

  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.currentBackgroundLink]
    stdout: StdioCollector {
      onStreamFinished: root.setBackground(String(text || "").trim(), false)
    }
  }

  IpcHandler {
    target: "background"

    function refresh(): void {
      root.refreshBackground()
    }

    function set(path: string): void {
      root.setBackground(path, false)
    }

    function setInstant(path: string): void {
      root.setBackground(path, true)
    }

    function transition(fromPath: string, path: string): void {
      root.transitionBackground(fromPath, path, path, false, false)
    }

    function themeTransition(fromPath: string, path: string, finalPath: string, colorsB64: string, shellB64: string): void {
      root.transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64)
    }
  }

  Timer {
    id: pendingThemeFallbackTimer
    interval: 300
    repeat: false
    onTriggered: root.applyPendingTheme()
  }

  NumberAnimation {
    id: revealAnimation
    target: root
    property: "revealProgress"
    from: 0
    to: 1
    duration: 420
    easing.type: Easing.InOutCubic
    onFinished: {
      if (root.incomingBackground) {
        root.displayedBackground = root.currentBackground || root.incomingBackground
        root.finishingTransition = true
      }
      root.revealProgress = 1
    }
  }

  // NEXUS: clear a stale marker first, then read the live one.
  Component.onCompleted: {
    staleHudReadyProc.running = true
    refreshBackground()
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      // NEXUS: no wallpaper surface on an output the HUD owns.
      visible: !remapGuard.remapping && !root.hudOwns(modelData)
      anchors { top: true; bottom: true; left: true; right: true }

      ScreenMoveRemap {
        id: remapGuard
        window: panel
      }
      color: "transparent"
      // Keep render updates enabled. The background layer has been observed to
      // lose its committed buffer while parked with updatesEnabled=false,
      // leaving a black desktop until omarchy-shell is restarted. The wallpaper
      // itself is static, so this favors correctness over a small render-loop
      // optimization.
      updatesEnabled: true

      property bool maskReady: false

      // NEXUS: one geometry line per output, and again when ownership changes.
      readonly property bool hudOwned: root.hudOwns(modelData)
      onHudOwnedChanged: root.logOutput(panel)
      Component.onCompleted: root.logOutput(panel)

      // NEXUS: the surface has no size until the compositor configures it, so
      // NEXUS: log the real geometry once it is known (window height proves the
      // NEXUS: exclusive zone is ignored: 1440, not 1414).
      property bool sizeLogged: false
      onWidthChanged: {
        if (!sizeLogged && width > 0 && height > 0) {
          sizeLogged = true
          root.logOutput(panel)
        }
      }

      function maybeStartReveal() {
        if (!root.incomingBackground || root.revealProgress !== 0 || maskReady) return
        if (incomingFrame.status !== Image.Ready) return
        Qt.callLater(function() {
          if (!root.incomingBackground || root.revealProgress !== 0 || maskReady) return
          if (incomingFrame.status !== Image.Ready) return
          root.startReveal(panel)
        })
      }

      WlrLayershell.namespace: "omarchy-background"
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      Image {
        id: base
        anchors.fill: parent
        source: root.imageUrl(root.displayedBackground)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        onStatusChanged: {
          if (status === Image.Ready && root.finishingTransition) {
            root.incomingBackground = ""
            root.oldBackground = ""
            root.finishingTransition = false
          }
        }
      }

      Image {
        id: oldFrame
        anchors.fill: parent
        source: root.imageUrl(root.oldBackground)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        smooth: true
        mipmap: true
        visible: root.oldBackground !== "" && root.revealProgress < 1
        onStatusChanged: panel.maybeStartReveal()
      }

      Item {
        id: incomingLayer
        anchors.fill: parent
        visible: root.incomingBackground !== "" && incomingFrame.status === Image.Ready && (root.revealProgress >= 1 || panel.maskReady)
        layer.enabled: root.incomingBackground !== "" && root.revealProgress < 1
        layer.smooth: true
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: revealMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 0.02
        }

        Image {
          id: incomingFrame
          anchors.fill: parent
          source: root.imageUrl(root.incomingBackground)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          smooth: true
          mipmap: true
          onStatusChanged: panel.maybeStartReveal()
        }
      }

      Item {
        id: revealMask
        anchors.fill: parent
        visible: false
        layer.enabled: true

        readonly property real slant: -0.18
        readonly property real centerTop: width / 2 - slant * height / 2
        readonly property real centerBottom: width / 2 + slant * height / 2
        readonly property real reach: width / 2 + Math.abs(slant) * height / 2 + 4
        readonly property real spread: reach * root.revealProgress

        Shape {
          anchors.fill: parent
          antialiasing: true
          preferredRendererType: Shape.CurveRenderer
          ShapePath {
            fillColor: "white"
            strokeColor: "transparent"
            startX: revealMask.centerTop - revealMask.spread; startY: 0
            PathLine { x: revealMask.centerTop + revealMask.spread; y: 0 }
            PathLine { x: revealMask.centerBottom + revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerBottom - revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerTop - revealMask.spread; y: 0 }
          }
        }
      }

      Connections {
        target: root
        function onIncomingBackgroundChanged() {
          panel.maskReady = false
          panel.maybeStartReveal()
        }
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onDoubleClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) root.openThemeSwitcher()
          else root.openSelector()
          mouse.accepted = true
        }
      }
    }
  }
}
