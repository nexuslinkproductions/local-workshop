import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// NEXUS HUD v2 — full-screen telemetry cockpit.
//
// One PanelWindow per screen on the wlr "bottom" layer: the whole screen is
// the canvas. A single collector process (collect.sh stream, ~1s cadence)
// feeds every monitor. Panels collapse on header click; state is session-only
// and shared across all monitors.
Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null

  // ------------------------------------------------------------- palette
  readonly property color cCyan:    "#00e5ff"
  readonly property color cCyanHi:  "#35e0ff"
  readonly property color cGreen:   "#39ff14"
  readonly property color cMagenta: "#ff2bd6"
  readonly property color cAmber:   "#ffb300"
  readonly property color cAlert:   "#ff3b4e"
  readonly property color cText:    "#c9f2fb"
  readonly property color cMuted:   "#5e93a6"
  readonly property color cLine:    "#0d4a61"
  readonly property color cPanel:   Util.alpha(Color.background, 0.84)
  readonly property color cPanelIn: Qt.rgba(0.024, 0.11, 0.18, 0.62)

  // Path of this file's directory, resolved from the component URL.
  readonly property string collectScript:
    decodeURIComponent(String(Qt.resolvedUrl("collect.sh")).replace(/^file:\/\//, ""))

  // -------------------------------------------------------------- state
  property var stats: ({})
  property string hostName: ""
  property string kernelName: ""
  property var gpuList: []
  property date now: new Date()
  property bool blink: true
  property var collapsedMap: ({})

  // delta bookkeeping
  property double prevIdle: -1
  property double prevTotal: -1
  property double prevRx: -1
  property double prevTx: -1
  property double lastPollMs: 0

  property real cpuPct: -1
  property real rxRate: 0
  property real txRate: 0
  property string pendingPoll: ""

  // 60-point history ring buffers for sparklines
  property var histCpu: []
  property var histGpuW: []
  property var histNetRx: []
  property var histDiskR: []

  // ----------------------------------------------------------- formatting
  function num(v) { var n = Number(v); return isFinite(n) ? n : 0 }
  function has(key) { return stats[key] !== undefined && stats[key] !== "" }

  function fmtUptime(sec) {
    var s = Math.max(0, Math.floor(num(sec)))
    var d = Math.floor(s / 86400)
    var h = Math.floor((s % 86400) / 3600)
    var m = Math.floor((s % 3600) / 60)
    function p2(x) { return (x < 10 ? "0" : "") + x }
    if (d > 0) return d + "d " + p2(h) + "h " + p2(m) + "m"
    if (h > 0) return h + "h " + p2(m) + "m"
    return m + "m"
  }

  function fmtRate(bps) {
    var n = Math.max(0, num(bps))
    if (n >= 1073741824) return (n / 1073741824).toFixed(2) + " GB/s"
    if (n >= 1048576)    return (n / 1048576).toFixed(1) + " MB/s"
    if (n >= 1024)       return (n / 1024).toFixed(1) + " KB/s"
    return Math.round(n) + " B/s"
  }

  function fmtKiBtoGiB(kb) { return (num(kb) / 1048576).toFixed(1) }
  function fmtBtoGiB(b)    { return (num(b) / 1073741824).toFixed(0) }

  function gaugeColor(f) {
    if (f >= 0.9) return cMagenta
    if (f >= 0.7) return cAmber
    return cGreen
  }

  function tempColor(t) {
    if (t >= 85) return cAlert
    if (t >= 70) return cAmber
    return cCyanHi
  }

  // ------------------------------------------------------------ collapse
  readonly property var sectionIds: ["system", "memory", "gpu0", "gpu1", "storage", "network", "agents"]

  function isCollapsed(id) { return collapsedMap[id] === true }

  function toggleSection(id) {
    var m = {}
    for (var k in collapsedMap) m[k] = collapsedMap[k]
    m[id] = !isCollapsed(id)
    collapsedMap = m
  }

  function toggleAll() {
    var anyOpen = false
    for (var i = 0; i < sectionIds.length; i++)
      if (!isCollapsed(sectionIds[i])) { anyOpen = true; break }
    var m = {}
    for (var k in collapsedMap) m[k] = collapsedMap[k]
    for (var j = 0; j < sectionIds.length; j++) m[sectionIds[j]] = anyOpen
    collapsedMap = m
    return anyOpen ? "collapsed" : "expanded"
  }

  // ----------------------------------------------------------- collectors
  function refresh() {
    if (!pollProc.running) pollProc.running = true
  }

  function applyProbe(text) {
    var lines = String(text || "").split("\n")
    var g = {}
    for (var i = 0; i < lines.length; i++) {
      var tab = lines[i].indexOf("\t")
      if (tab <= 0) continue
      var k = lines[i].substr(0, tab)
      var v = lines[i].substr(tab + 1)
      if (k === "host") hostName = v
      else if (k === "kernel") kernelName = v
      else {
        var mm = /^gpu(\d+)_(kind|name)$/.exec(k)
        if (mm) {
          if (!g[mm[1]]) g[mm[1]] = {}
          g[mm[1]][mm[2]] = v
        }
      }
    }
    var list = []
    for (var idx in g) list.push({ kind: g[idx].kind || "", name: g[idx].name || "" })
    gpuList = list
  }

  function pushHist(arr, v) {
    var a = arr.slice(-59)
    a.push(v)
    return a
  }

  function applyPoll(text) {
    var m = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var tab = lines[i].indexOf("\t")
      if (tab <= 0) continue
      m[lines[i].substr(0, tab)] = lines[i].substr(tab + 1)
    }

    var t = Date.now()
    var dt = lastPollMs > 0 ? (t - lastPollMs) / 1000 : 0

    var idle = num(m.cpu_idle), total = num(m.cpu_total)
    if (prevTotal >= 0 && total > prevTotal)
      cpuPct = Util.clamp(100 * (1 - (idle - prevIdle) / (total - prevTotal)), 0, 100)
    prevIdle = idle
    prevTotal = total

    var rx = num(m.net_rx), tx = num(m.net_tx)
    if (prevRx >= 0 && dt > 0) {
      rxRate = Math.max(0, (rx - prevRx) / dt)
      txRate = Math.max(0, (tx - prevTx) / dt)
    }
    prevRx = rx
    prevTx = tx
    lastPollMs = t

    stats = m

    // append to history buffers
    histCpu  = pushHist(histCpu,  cpuPct >= 0 ? cpuPct : 0)
    histGpuW = pushHist(histGpuW, num(m.i_pwr_w))
    histNetRx = pushHist(histNetRx, rxRate)
    histDiskR = pushHist(histDiskR, num(m.disk_read_bps))
  }

  Process {
    id: probeProc
    command: ["bash", root.collectScript, "probe"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyProbe(text)
    }
  }

  Process {
    id: pollProc
    command: ["bash", root.collectScript, "stream"]
    stdout: SplitParser {
      onRead: data => {
        if (String(data).indexOf("batch\t") === 0) {
          root.applyPoll(root.pendingPoll)
          root.pendingPoll = ""
        } else root.pendingPoll += data + "\n"
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text).trim() !== "") console.warn("nexuslink.hud:", String(text).trim())
    }
  }

  Timer {
    interval: 1500
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.now = new Date()
  }

  Timer {
    interval: 700
    running: true
    repeat: true
    onTriggered: root.blink = !root.blink
  }

  Timer {
    interval: 300000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!probeProc.running) probeProc.running = true
  }

  // -------------------------------------------------------- derived stats
  readonly property string uptimeText: fmtUptime(stats.uptime_s)
  readonly property string cpuText: cpuPct >= 0 ? Math.round(cpuPct) + "%" : "--"
  readonly property real cpuFrac: cpuPct >= 0 ? cpuPct / 100 : 0
  readonly property string loadText: has("load1")
      ? stats.load1 + "  " + stats.load5 + "  " + stats.load15 : "--"

  readonly property real memFrac: {
    var t = num(stats.mem_total_kb)
    return t > 0 ? (t - num(stats.mem_avail_kb)) / t : 0
  }
  readonly property string memText: memFrac > 0
      ? fmtKiBtoGiB(num(stats.mem_total_kb) - num(stats.mem_avail_kb))
        + " / " + fmtKiBtoGiB(stats.mem_total_kb) + " GB"
      : "n/a"
  readonly property real swapFrac: num(stats.swap_total_kb) > 0
      ? (num(stats.swap_total_kb) - num(stats.swap_free_kb)) / num(stats.swap_total_kb)
      : 0
  readonly property string swapText: swapFrac > 0
      ? fmtKiBtoGiB(num(stats.swap_total_kb) - num(stats.swap_free_kb))
        + " / " + fmtKiBtoGiB(stats.swap_total_kb) + " GB"
      : "n/a"

  // GPU0 (Intel Arc)
  readonly property real gpu0PwrFrac: num(stats.i_pwr_cap_w) > 0 ? num(stats.i_pwr_w) / num(stats.i_pwr_cap_w) : 0
  readonly property string gpu0PwrText: has("i_pwr_w")
      ? stats.i_pwr_w + "W" + (has("i_pwr_cap_w") ? " / " + stats.i_pwr_cap_w + "W" : "")
      : "--"
  readonly property real gpu0VramFrac: num(stats.i_vram_total) > 0 ? num(stats.i_vram_used) / num(stats.i_vram_total) : 0
  readonly property string gpu0VramText: has("i_vram_total")
      ? num(stats.i_vram_used).toFixed(0) + " / " + num(stats.i_vram_total).toFixed(0) + " MiB"
      : "--"

  // GPU1 (AMD iGPU)
  readonly property real gpu1UtilFrac: has("a_util") ? num(stats.a_util) / 100 : 0
  readonly property real gpu1VramFrac: num(stats.a_vram_total) > 0 ? num(stats.a_vram_used) / num(stats.a_vram_total) : 0

  // Filesystems
  function fsFrac(tag)  { return has("fs_" + tag + "_pct") ? num(stats["fs_" + tag + "_pct"]) / 100 : 0 }
  function fsLabel(tag) { return has("fs_" + tag + "_target") ? String(stats["fs_" + tag + "_target"]) : (tag === "root" ? "/" : "/home") }
  function fsText(tag)  {
    return fsFrac(tag) > 0
      ? Math.round(num(stats["fs_" + tag + "_pct"])) + "%  "
        + fmtBtoGiB(stats["fs_" + tag + "_used"]) + "/" + fmtBtoGiB(stats["fs_" + tag + "_size"]) + "G"
      : "n/a"
  }

  // Alert state: any temp > 85 or mem > 90%
  readonly property bool alert: {
    if (num(stats.cpu_temp) > 85) return true
    if (num(stats.i_temp_pkg) > 85) return true
    if (num(stats.i_temp_vram) > 85) return true
    if (num(stats.a_temp) > 85) return true
    if (memFrac > 0.9) return true
    return false
  }

  // Per-core busy percentages (cpu_core_0..23)
  readonly property int coreCount: {
    var n = 0
    while (stats["cpu_core_" + n] !== undefined) n++
    return n
  }

  // ------------------------------------------------------------ IPC
  IpcHandler {
    target: "nexuslink.hud"

    function toggleAll(): string { return root.toggleAll() }
    function refresh(): string { root.refresh(); return "ok" }
    function status(): string {
      return JSON.stringify({
        cpu: root.cpuText,
        mem: root.memText,
        gpu0: root.gpuList.length > 0 ? root.gpuList[0].name : "none",
        rx: root.fmtRate(root.rxRate),
        tx: root.fmtRate(root.txRate),
        alert: root.alert
      })
    }
  }

  // -------------------------------------------------- inline components

  // Monospace label, the cockpit's single text atom.
  component TLabel: Text {
    color: root.cText
    font.family: Style.font.family
    font.pixelSize: 13
  }

  // One L-shaped corner mark; rotate for the other corners.
  component Bracket: Item {
    property color col: root.alert ? root.cAlert : root.cCyan
    property real bs: 12
    width: bs; height: bs
    Rectangle { width: parent.width; height: 2; color: parent.col }
    Rectangle { width: 2; height: parent.height; color: parent.col }
  }

  // Chamfered dark panel with corner brackets, a title and a fading rule.
  // Content lands in `inner` via the default-property alias.
  component HudPanel: Item {
    id: panel
    property string title: ""
    property color accent: root.cCyan
    default property alias content: inner.data
    readonly property real chamfer: 14

    Shape {
      anchors.fill: parent
      asynchronous: false
      ShapePath {
        fillColor: root.cPanelIn
        strokeColor: root.alert ? root.cAlert : root.cLine
        strokeWidth: 1
        startX: panel.chamfer; startY: 0
        PathLine { x: panel.width; y: 0 }
        PathLine { x: panel.width; y: panel.height - panel.chamfer }
        PathLine { x: panel.width - panel.chamfer; y: panel.height }
        PathLine { x: 0; y: panel.height }
        PathLine { x: 0; y: panel.chamfer }
        PathLine { x: panel.chamfer; y: 0 }
      }
    }
    Bracket { anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 3; rotation: 90; bs: 10 }
    Bracket { anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: 3; rotation: 270; bs: 10 }
    TLabel {
      id: titleText
      text: panel.title
      color: panel.accent
      font.pixelSize: 12
      font.bold: true
      font.letterSpacing: 3
      anchors { top: parent.top; left: parent.left; right: parent.right
                topMargin: 8; leftMargin: 10; rightMargin: 10 }
      elide: Text.ElideRight
    }
    Rectangle {
      anchors { top: titleText.bottom; topMargin: 4
                left: parent.left; leftMargin: 10 }
      width: parent.width * 0.5; height: 1
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0; color: panel.accent }
        GradientStop { position: 1; color: "transparent" }
      }
    }
    Item {
      id: inner
      anchors { fill: parent; topMargin: 30
                leftMargin: 10; rightMargin: 10; bottomMargin: 8 }
    }
  }

  // Collapsible panel: same chrome as HudPanel, but the body folds away on
  // header click. Content lands in `inner` via the default-property alias.
  component HudPanelC: Item {
    id: panelC
    property string title: ""
    property color accent: root.cCyan
    property bool collapsed: false
    signal toggled()
    default property alias content: innerC.data
    readonly property real chamfer: 14
    // When collapsed the panel shrinks to just its header strip.
    readonly property real headerH: 30

    Shape {
      anchors.fill: parent
      asynchronous: false
      ShapePath {
        fillColor: root.cPanelIn
        strokeColor: root.alert ? root.cAlert : root.cLine
        strokeWidth: 1
        startX: panelC.chamfer; startY: 0
        PathLine { x: panelC.width; y: 0 }
        PathLine { x: panelC.width; y: panelC.height - panelC.chamfer }
        PathLine { x: panelC.width - panelC.chamfer; y: panelC.height }
        PathLine { x: 0; y: panelC.height }
        PathLine { x: 0; y: panelC.chamfer }
        PathLine { x: panelC.chamfer; y: 0 }
      }
    }
    Bracket { anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 3; rotation: 90; bs: 10 }
    Bracket { anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: 3; rotation: 270; bs: 10 }

    TLabel {
      id: chevron
      text: panelC.collapsed ? "▸" : "▾"
      color: panelC.accent
      font.pixelSize: 11
      anchors { left: parent.left; leftMargin: 10; top: parent.top; topMargin: 9 }
    }
    TLabel {
      id: titleTextC
      text: panelC.title
      color: headerMaC.containsMouse ? panelC.accent : root.cText
      font.pixelSize: 12
      font.bold: true
      font.letterSpacing: 3
      anchors { left: chevron.right; leftMargin: 6; top: parent.top; topMargin: 8
                right: parent.right; rightMargin: 10 }
      elide: Text.ElideRight
    }
    Rectangle {
      anchors { top: titleTextC.bottom; topMargin: 4
                left: parent.left; leftMargin: 10 }
      width: parent.width * 0.5; height: 1
      visible: !panelC.collapsed
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0; color: panelC.accent }
        GradientStop { position: 1; color: "transparent" }
      }
    }
    MouseArea {
      id: headerMaC
      anchors { left: parent.left; right: parent.right; top: parent.top }
      height: panelC.headerH
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: panelC.toggled()
    }
    Item {
      id: bodyClipC
      anchors { fill: parent; topMargin: panelC.headerH
                leftMargin: 10; rightMargin: 10; bottomMargin: 8 }
      clip: true
      visible: !panelC.collapsed
      Item {
        id: innerC
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: bodyClipC.height
      }
    }
  }

  // 60-point sparkline trace drawn on a Canvas. Cheap: one requestPaint per
  // data push, not per segment.
  component Sparkline: Canvas {
    id: spark
    property var points: []
    property color col: root.cCyanHi
    property real vmax: -1   // -1 = auto-scale to peak
    onPointsChanged: requestPaint()
    onColChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      if (points.length < 2) return
      var peak = vmax > 0 ? vmax : 0
      if (peak <= 0) {
        for (var i = 0; i < points.length; i++) if (points[i] > peak) peak = points[i]
        peak *= 1.15
        if (peak <= 0) peak = 1
      }
      // grid
      ctx.strokeStyle = "rgba(13,74,97,0.4)"
      ctx.lineWidth = 1
      ctx.beginPath()
      for (var yy = 1; yy < 3; yy++) { ctx.moveTo(0, height * yy / 3); ctx.lineTo(width, height * yy / 3) }
      ctx.stroke()
      // trace
      ctx.strokeStyle = String(col)
      ctx.lineWidth = 1.4
      ctx.shadowColor = String(col)
      ctx.shadowBlur = 4
      ctx.beginPath()
      var step = width / 59
      for (var j = 0; j < points.length; j++) {
        var x = width - (points.length - 1 - j) * step
        var y = height - Math.min(points[j] / peak, 1) * (height - 3) - 1.5
        j === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y)
      }
      ctx.stroke()
      ctx.shadowBlur = 0
    }
  }

  // Horizontal gauge bar with label and value.
  component Meter: Item {
    id: meterRoot
    property string label: ""
    property string valueText: "--"
    property real frac: 0
    property color barColor: root.cCyanHi
    height: 22
    TLabel { text: meterRoot.label; color: root.cMuted; font.pixelSize: 10; font.letterSpacing: 1.5 }
    TLabel {
      anchors.right: parent.right
      text: meterRoot.valueText; color: root.cText; font.pixelSize: 10
    }
    Rectangle {
      anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
      height: 6
      color: "transparent"; border.width: 1; border.color: root.cLine
      Rectangle {
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: 1 }
        width: Math.max(0, (parent.width - 2) * Math.min(meterRoot.frac, 1))
        color: meterRoot.barColor
        Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
      }
    }
  }

  // Label + value row, dim label left, bright value right.
  component KvRow: Item {
    property string k: ""
    property string v: "--"
    property color vc: root.cCyanHi
    width: parent ? parent.width : 100
    height: 18
    TLabel { text: parent.k; color: root.cMuted; font.pixelSize: 11 }
    TLabel { anchors.right: parent.right; text: parent.v; color: parent.vc; font.pixelSize: 11 }
  }

  // ------------------------------------------------------------ windows
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData

      screen: modelData
      visible: !remapGuard.remapping
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "omarchy-hud"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      // Only drawn panels accept pointer input; every other pixel passes
      // through to the desktop.
      mask: Region { item: cockpitRoot }

      ScreenMoveRemap { id: remapGuard; window: win }

      // Hyprland's view of this output, for the active workspace label.
      readonly property var hmonitor: {
        try {
          var m = Hyprland.monitorFor(modelData)
          if (m) return m
        } catch (e) {}
        var ms = []
        try { ms = Hyprland.monitors ? Hyprland.monitors.values : [] } catch (e2) {}
        for (var i = 0; i < ms.length; i++)
          if (String(ms[i].name) === String(modelData.name)) return ms[i]
        return null
      }
      readonly property string wsLabel: win.hmonitor && win.hmonitor.activeWorkspace
          ? String(win.hmonitor.activeWorkspace.name) : ""

      // The whole screen is the canvas.
      Item {
        id: cockpitRoot
        anchors.fill: parent

        // Scale factor: everything derives from this.
        readonly property real ux: Math.max(0.7, Math.min(width / 1600, height / 900))
        readonly property real m: 14 * ux
        readonly property real frameInset: 12 * ux

        // ------------------------------------------------ background grid
        Canvas {
          anchors.fill: parent
          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            // deep space base
            ctx.fillStyle = "#020a12"
            ctx.fillRect(0, 0, width, height)
            // subtle radial glow at center
            var grd = ctx.createRadialGradient(width / 2, height * 0.45, 0,
                                               width / 2, height * 0.45, width * 0.55)
            grd.addColorStop(0, "rgba(10,43,71,0.35)")
            grd.addColorStop(0.6, "rgba(4,20,31,0.15)")
            grd.addColorStop(1, "rgba(2,10,18,0)")
            ctx.fillStyle = grd
            ctx.fillRect(0, 0, width, height)
            // grid lines
            ctx.strokeStyle = "rgba(13,74,97,0.12)"
            ctx.lineWidth = 1
            var step = 40 * cockpitRoot.ux
            ctx.beginPath()
            for (var x = step; x < width; x += step) { ctx.moveTo(x, 0); ctx.lineTo(x, height) }
            for (var y = step; y < height; y += step) { ctx.moveTo(0, y); ctx.lineTo(width, y) }
            ctx.stroke()
          }
          onWidthChanged: requestPaint()
          onHeightChanged: requestPaint()
        }

        // ------------------------------------------------ frame hairline
        Rectangle {
          anchors.fill: parent
          anchors.margins: cockpitRoot.frameInset
          color: "transparent"
          border.width: 1
          border.color: root.alert ? root.cAlert : Util.alpha(root.cCyan, 0.35)
        }

        // Corner brackets at the frame inset.
        Bracket {
          x: cockpitRoot.frameInset - 1; y: cockpitRoot.frameInset - 1
          bs: 14 * cockpitRoot.ux
          col: root.alert ? root.cAlert : root.cCyan
        }
        Bracket {
          x: parent.width - cockpitRoot.frameInset - width + 1; y: cockpitRoot.frameInset - 1
          bs: 14 * cockpitRoot.ux; rotation: 90
          col: root.alert ? root.cAlert : root.cCyan
        }
        Bracket {
          x: cockpitRoot.frameInset - 1; y: parent.height - cockpitRoot.frameInset - height + 1
          bs: 14 * cockpitRoot.ux; rotation: 270
          col: root.alert ? root.cAlert : root.cCyan
        }
        Bracket {
          x: parent.width - cockpitRoot.frameInset - width + 1; y: parent.height - cockpitRoot.frameInset - height + 1
          bs: 14 * cockpitRoot.ux; rotation: 180
          col: root.alert ? root.cAlert : root.cCyan
        }

        // ---------------------------------------------------- layout anchors
        // Left rail ~20%, center ~55%, right rail ~22%, bottom strip fixed h.
        readonly property real railW: 280 * ux
        readonly property real bottomH: 180 * ux
        readonly property real railGap: 10 * ux

        // ------------------------------------------------------ LEFT RAIL
        Item {
          id: leftRail
          anchors { left: parent.left; top: parent.top; bottom: bottomStrip.top
                    leftMargin: cockpitRoot.m + cockpitRoot.frameInset
                    topMargin: cockpitRoot.m + cockpitRoot.frameInset
                    bottomMargin: cockpitRoot.railGap }
          width: cockpitRoot.railW

          // SYSTEM panel
          HudPanelC {
            id: systemPanel
            anchors { left: parent.left; right: parent.right; top: parent.top }
            title: "SYSTEM"
            accent: root.cCyan
            collapsed: root.isCollapsed("system")
            onToggled: root.toggleSection("system")
            height: collapsed ? headerH : parent.height * 0.58

            // Big CPU% number
            TLabel {
              id: cpuBig
              anchors { top: parent.top; topMargin: 4; horizontalCenter: parent.horizontalCenter }
              text: root.cpuText
              color: root.gaugeColor(root.cpuFrac)
              font.pixelSize: 42 * cockpitRoot.ux
              font.bold: true
            }
            TLabel {
              anchors { top: cpuBig.bottom; horizontalCenter: parent.horizontalCenter }
              text: "CPU LOAD"
              color: root.cMuted
              font.pixelSize: 9 * cockpitRoot.ux
              font.letterSpacing: 2
            }

            // Per-core bar matrix
            Item {
              id: coreMatrix
              anchors { top: cpuBig.bottom; topMargin: 22 * cockpitRoot.ux
                        left: parent.left; right: parent.right }
              height: 52 * cockpitRoot.ux
              readonly property real gap: 2
              readonly property real bw: (width - gap * (root.coreCount - 1)) / Math.max(root.coreCount, 1)
              Repeater {
                model: root.coreCount
                Item {
                  x: index * (coreMatrix.bw + coreMatrix.gap)
                  width: coreMatrix.bw
                  height: coreMatrix.height
                  readonly property real busy: root.num(root.stats["cpu_core_" + index]) / 100
                  Rectangle {
                    anchors.fill: parent
                    color: Qt.rgba(0.05, 0.29, 0.38, 0.22)
                  }
                  Rectangle {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: Math.max(1, parent.height * Math.min(parent.busy, 1))
                    color: parent.busy > 0.85 ? root.cMagenta
                         : parent.busy > 0.6 ? root.cAmber : root.cGreen
                    Behavior on height { NumberAnimation { duration: 300 } }
                  }
                }
              }
            }

            // Load / temp / uptime rows
            Column {
              anchors { top: coreMatrix.bottom; topMargin: 10 * cockpitRoot.ux
                        left: parent.left; right: parent.right }
              spacing: 4 * cockpitRoot.ux
              KvRow { k: "LOAD"; v: root.loadText }
              KvRow { k: "CORES"; v: root.has("cpu_count") ? String(root.stats.cpu_count) : "--" }
              KvRow { k: "TEMP"; v: root.has("cpu_temp") ? root.stats.cpu_temp + "°C" : "--"
                      vc: root.tempColor(root.num(root.stats.cpu_temp)) }
              KvRow { k: "UPTIME"; v: root.uptimeText }
            }
          }

          // MEMORY panel
          HudPanelC {
            id: memoryPanel
            anchors { left: parent.left; right: parent.right; top: systemPanel.bottom
                      topMargin: cockpitRoot.railGap; bottom: parent.bottom }
            title: "MEMORY"
            accent: root.cGreen
            collapsed: root.isCollapsed("memory")
            onToggled: root.toggleSection("memory")

            Column {
              anchors { top: parent.top; topMargin: 4; left: parent.left; right: parent.right }
              spacing: 8 * cockpitRoot.ux
              Meter {
                width: parent.width
                label: "RAM"
                valueText: root.memText
                frac: root.memFrac
                barColor: root.gaugeColor(root.memFrac)
              }
              Meter {
                width: parent.width
                label: "SWAP"
                valueText: root.swapText
                frac: root.swapFrac
                barColor: root.gaugeColor(root.swapFrac)
                visible: root.swapFrac > 0
              }
              KvRow { k: "USED"; v: Math.round(root.memFrac * 100) + "%" }
            }
          }
        }

        // ------------------------------------------------------ CENTER
        Item {
          id: centerStage
          anchors { left: leftRail.right; right: rightRail.left
                    top: parent.top; bottom: bottomStrip.top
                    leftMargin: cockpitRoot.railGap; rightMargin: cockpitRoot.railGap
                    topMargin: cockpitRoot.m + cockpitRoot.frameInset
                    bottomMargin: cockpitRoot.railGap }

          readonly property real dialD: Math.min(width * 0.52, height * 0.52)

          // Reactor dial: three concentric rings.
          //   outer = CPU%, middle = GPU0 power fraction, inner = mem fraction
          Canvas {
            id: reactorRing
            anchors { horizontalCenter: parent.horizontalCenter
                      top: parent.top; topMargin: 8 * cockpitRoot.ux }
            width: centerStage.dialD
            height: width
            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              var cx = width / 2, cy = height / 2
              var a0 = Math.PI * 0.75, span = Math.PI * 1.5

              // tick ring
              var rTick = width * 0.46
              for (var i = 0; i <= 60; i++) {
                var a = a0 + span * i / 60
                var major = (i % 10 === 0)
                var r1 = rTick
                var r2 = r1 + (major ? width * 0.028 : width * 0.014)
                ctx.strokeStyle = major ? String(root.cCyan) : String(root.cLine)
                ctx.lineWidth = major ? 1.6 : 1
                ctx.beginPath()
                ctx.moveTo(cx + r1 * Math.cos(a), cy + r1 * Math.sin(a))
                ctx.lineTo(cx + r2 * Math.cos(a), cy + r2 * Math.sin(a))
                ctx.stroke()
              }

              // helper to draw one arc ring
              function ring(r, frac, col, lw) {
                ctx.lineWidth = lw
                ctx.strokeStyle = String(root.cLine)
                ctx.beginPath(); ctx.arc(cx, cy, r, a0, a0 + span); ctx.stroke()
                if (frac > 0) {
                  ctx.strokeStyle = String(col)
                  ctx.shadowColor = String(col)
                  ctx.shadowBlur = 8
                  ctx.beginPath(); ctx.arc(cx, cy, r, a0, a0 + span * Math.min(frac, 1)); ctx.stroke()
                  ctx.shadowBlur = 0
                }
              }

              var lw = width * 0.022
              // outer: CPU
              ring(width * 0.40, root.cpuFrac, root.gaugeColor(root.cpuFrac), lw)
              // middle: GPU0 power
              ring(width * 0.40 - lw * 1.6, root.gpu0PwrFrac,
                   root.gpu0PwrFrac > 0.9 ? root.cAlert : root.gpu0PwrFrac > 0.7 ? root.cAmber : root.cMagenta, lw)
              // inner: memory
              ring(width * 0.40 - lw * 3.2, root.memFrac, root.gaugeColor(root.memFrac), lw)

              // core glow
              var g2 = ctx.createRadialGradient(cx, cy, 0, cx, cy, width * 0.28)
              g2.addColorStop(0.4, "rgba(3,16,29,0)")
              g2.addColorStop(0.65, "rgba(234,252,255,0.18)")
              g2.addColorStop(0.85, "rgba(53,224,255,0.10)")
              g2.addColorStop(1, "rgba(0,0,0,0)")
              ctx.fillStyle = g2
              ctx.fillRect(cx - width * 0.28, cy - width * 0.28, width * 0.56, width * 0.56)
            }
            Connections {
              target: root
              function onStatsChanged() { reactorRing.requestPaint() }
              function onCpuPctChanged() { reactorRing.requestPaint() }
            }
          }

          // Center text inside the dial: hostname, clock, kernel, workspace
          Column {
            anchors.centerIn: reactorRing
            spacing: 2
            TLabel {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.hostName !== "" ? root.hostName.toUpperCase() : "NEXUS"
              color: root.cCyanHi
              font.pixelSize: 15 * cockpitRoot.ux
              font.bold: true
              font.letterSpacing: 3
            }
            TLabel {
              anchors.horizontalCenter: parent.horizontalCenter
              text: Qt.formatDateTime(root.now, "HH:mm:ss")
              color: "#eafcff"
              font.pixelSize: 30 * cockpitRoot.ux
              font.bold: true
              font.letterSpacing: 2
            }
            TLabel {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.kernelName !== "" ? root.kernelName : "--"
              color: root.cMuted
              font.pixelSize: 10 * cockpitRoot.ux
              font.letterSpacing: 1
            }
            TLabel {
              anchors.horizontalCenter: parent.horizontalCenter
              text: String(win.modelData.name) + (win.wsLabel !== "" ? " · ws " + win.wsLabel : "")
              color: root.cMuted
              font.pixelSize: 10 * cockpitRoot.ux
            }
          }

          // Ring legend below the dial
          Row {
            anchors { top: reactorRing.bottom; topMargin: 4 * cockpitRoot.ux
                      horizontalCenter: parent.horizontalCenter }
            spacing: 18 * cockpitRoot.ux
            Row { spacing: 4
              Rectangle { width: 10; height: 3; color: root.gaugeColor(root.cpuFrac); anchors.verticalCenter: parent.verticalCenter }
              TLabel { text: "CPU " + root.cpuText; color: root.cMuted; font.pixelSize: 10 * cockpitRoot.ux } }
            Row { spacing: 4
              Rectangle { width: 10; height: 3; color: root.cMagenta; anchors.verticalCenter: parent.verticalCenter }
              TLabel { text: "GPU " + root.gpu0PwrText; color: root.cMuted; font.pixelSize: 10 * cockpitRoot.ux } }
            Row { spacing: 4
              Rectangle { width: 10; height: 3; color: root.gaugeColor(root.memFrac); anchors.verticalCenter: parent.verticalCenter }
              TLabel { text: "MEM " + Math.round(root.memFrac * 100) + "%"; color: root.cMuted; font.pixelSize: 10 * cockpitRoot.ux } }
          }

          // Sparkline traces around the dial: 2x2 grid
          readonly property real sparkW: (width - dialD) / 2 - 20 * cockpitRoot.ux
          readonly property real sparkH: 64 * cockpitRoot.ux

          // top-left: CPU history
          Item {
            anchors { left: parent.left; top: parent.top; topMargin: 20 * cockpitRoot.ux }
            width: centerStage.sparkW; height: centerStage.sparkH + 16
            TLabel { text: "CPU %"; color: root.cMuted; font.pixelSize: 9 * cockpitRoot.ux; font.letterSpacing: 1.5 }
            Sparkline {
              anchors { top: parent.top; topMargin: 14; left: parent.left; right: parent.right }
              height: centerStage.sparkH
              points: root.histCpu; col: root.cGreen; vmax: 100
            }
          }
          // top-right: GPU power history
          Item {
            anchors { right: parent.right; top: parent.top; topMargin: 20 * cockpitRoot.ux }
            width: centerStage.sparkW; height: centerStage.sparkH + 16
            TLabel { anchors.right: parent.right; text: "GPU W"; color: root.cMuted; font.pixelSize: 9 * cockpitRoot.ux; font.letterSpacing: 1.5 }
            Sparkline {
              anchors { top: parent.top; topMargin: 14; left: parent.left; right: parent.right }
              height: centerStage.sparkH
              points: root.histGpuW; col: root.cMagenta
            }
          }
          // mid-left: net rx history
          Item {
            anchors { left: parent.left; verticalCenter: reactorRing.verticalCenter }
            width: centerStage.sparkW; height: centerStage.sparkH + 16
            TLabel { text: "NET RX"; color: root.cMuted; font.pixelSize: 9 * cockpitRoot.ux; font.letterSpacing: 1.5 }
            Sparkline {
              anchors { top: parent.top; topMargin: 14; left: parent.left; right: parent.right }
              height: centerStage.sparkH
              points: root.histNetRx; col: root.cCyanHi
            }
          }
          // mid-right: disk read history
          Item {
            anchors { right: parent.right; verticalCenter: reactorRing.verticalCenter }
            width: centerStage.sparkW; height: centerStage.sparkH + 16
            TLabel { anchors.right: parent.right; text: "DISK R"; color: root.cMuted; font.pixelSize: 9 * cockpitRoot.ux; font.letterSpacing: 1.5 }
            Sparkline {
              anchors { top: parent.top; topMargin: 14; left: parent.left; right: parent.right }
              height: centerStage.sparkH
              points: root.histDiskR; col: root.cAmber
            }
          }

          // Top procs marquee under the dial
          Item {
            anchors { bottom: parent.bottom; left: parent.left; right: parent.right
                      bottomMargin: 4 * cockpitRoot.ux }
            height: 40 * cockpitRoot.ux
            TLabel {
              id: procsTitle
              text: "TOP PROCS"
              color: root.cMuted
              font.pixelSize: 9 * cockpitRoot.ux
              font.letterSpacing: 2
            }
            Row {
              anchors { top: procsTitle.bottom; topMargin: 3; left: parent.left; right: parent.right }
              spacing: 16 * cockpitRoot.ux
              Repeater {
                model: 6
                TLabel {
                  property string pname: root.has("proc" + index + "_name") ? String(root.stats["proc" + index + "_name"]) : ""
                  property string pcpu:  root.has("proc" + index + "_cpu")  ? String(root.stats["proc" + index + "_cpu"])  : ""
                  visible: pname !== ""
                  text: pname + " " + pcpu + "%"
                  color: root.num(pcpu) > 50 ? root.cAmber : root.cText
                  font.pixelSize: 10 * cockpitRoot.ux
                  elide: Text.ElideRight
                }
              }
            }
          }
        }

        // ------------------------------------------------------ RIGHT RAIL
        Item {
          id: rightRail
          anchors { right: parent.right; top: parent.top; bottom: bottomStrip.top
                    rightMargin: cockpitRoot.m + cockpitRoot.frameInset
                    topMargin: cockpitRoot.m + cockpitRoot.frameInset
                    bottomMargin: cockpitRoot.railGap }
          width: cockpitRoot.railW

          // GPU0 panel (Intel Arc B580)
          HudPanelC {
            id: gpu0Panel
            anchors { left: parent.left; right: parent.right; top: parent.top }
            title: root.gpuList.length > 0 && root.gpuList[0].name !== ""
                ? "GPU0 · " + root.gpuList[0].name.toUpperCase() : "GPU0"
            accent: root.cMagenta
            collapsed: root.isCollapsed("gpu0")
            onToggled: root.toggleSection("gpu0")
            visible: root.gpuList.length > 0 && root.gpuList[0].kind !== "none"
            height: collapsed ? headerH : parent.height * 0.42

            Column {
              anchors { top: parent.top; topMargin: 2; left: parent.left; right: parent.right }
              spacing: 5 * cockpitRoot.ux

              // Power bar with cap
              Meter {
                width: parent.width
                label: "POWER"
                valueText: root.gpu0PwrText
                frac: root.gpu0PwrFrac
                barColor: root.gpu0PwrFrac > 0.9 ? root.cAlert
                        : root.gpu0PwrFrac > 0.7 ? root.cAmber : root.cMagenta
              }

              // Temp grid: 2x2
              Grid {
                width: parent.width
                columns: 2
                columnSpacing: 6 * cockpitRoot.ux
                rowSpacing: 4 * cockpitRoot.ux
                KvRow { width: (parent.width - 6 * cockpitRoot.ux) / 2
                        k: "PKG"; v: root.has("i_temp_pkg") ? root.stats.i_temp_pkg + "°C" : "--"
                        vc: root.tempColor(root.num(root.stats.i_temp_pkg)) }
                KvRow { width: (parent.width - 6 * cockpitRoot.ux) / 2
                        k: "VRAM"; v: root.has("i_temp_vram") ? root.stats.i_temp_vram + "°C" : "--"
                        vc: root.tempColor(root.num(root.stats.i_temp_vram)) }
                KvRow { width: (parent.width - 6 * cockpitRoot.ux) / 2
                        k: "MCTRL"; v: root.has("i_temp_mctrl") ? root.stats.i_temp_mctrl + "°C" : "--"
                        vc: root.tempColor(root.num(root.stats.i_temp_mctrl)) }
                KvRow { width: (parent.width - 6 * cockpitRoot.ux) / 2
                        k: "PCIE"; v: root.has("i_temp_pcie") ? root.stats.i_temp_pcie + "°C" : "--"
                        vc: root.tempColor(root.num(root.stats.i_temp_pcie)) }
              }

              KvRow { k: "VRM CH"; v: root.has("i_vram_ch_max")
                      ? "max " + root.stats.i_vram_ch_max + "° avg " + root.stats.i_vram_ch_avg + "°" : "--" }
              KvRow { k: "FAN"; v: root.has("i_fan_rpm") ? root.stats.i_fan_rpm + " RPM" : "--" }

              Meter {
                width: parent.width
                label: "VRAM"
                valueText: root.gpu0VramText
                frac: root.gpu0VramFrac
                barColor: root.gaugeColor(root.gpu0VramFrac)
              }
            }
          }

          // GPU1 panel (AMD iGPU)
          HudPanelC {
            id: gpu1Panel
            anchors { left: parent.left; right: parent.right; top: gpu0Panel.bottom
                      topMargin: cockpitRoot.railGap }
            title: root.gpuList.length > 1 && root.gpuList[1].name !== ""
                ? "GPU1 · " + root.gpuList[1].name.toUpperCase() : "GPU1"
            accent: root.cCyan
            collapsed: root.isCollapsed("gpu1")
            onToggled: root.toggleSection("gpu1")
            visible: root.gpuList.length > 1
            height: collapsed ? headerH : parent.height * 0.28

            Column {
              anchors { top: parent.top; topMargin: 2; left: parent.left; right: parent.right }
              spacing: 5 * cockpitRoot.ux
              Meter {
                width: parent.width
                label: "UTIL"
                valueText: root.has("a_util") ? root.stats.a_util + "%" : "--"
                frac: root.gpu1UtilFrac
                barColor: root.gaugeColor(root.gpu1UtilFrac)
              }
              Meter {
                width: parent.width
                label: "VRAM"
                valueText: root.has("a_vram_total")
                    ? root.stats.a_vram_used + " / " + root.stats.a_vram_total + " MiB" : "--"
                frac: root.gpu1VramFrac
                barColor: root.gaugeColor(root.gpu1VramFrac)
              }
              KvRow { k: "TEMP"; v: root.has("a_temp") ? root.stats.a_temp + "°C" : "--"
                      vc: root.tempColor(root.num(root.stats.a_temp)) }
              KvRow { k: "PWR"; v: root.has("a_pwr_w") ? root.stats.a_pwr_w + " W" : "--" }
              KvRow { k: "FREQ"; v: root.has("a_freq_mhz") ? root.stats.a_freq_mhz + " MHz" : "--" }
            }
          }

          // STORAGE panel
          HudPanelC {
            id: storagePanel
            anchors { left: parent.left; right: parent.right
                      top: gpu1Panel.visible ? gpu1Panel.bottom : gpu0Panel.bottom
                      topMargin: cockpitRoot.railGap; bottom: parent.bottom }
            title: "STORAGE"
            accent: root.cCyan
            collapsed: root.isCollapsed("storage")
            onToggled: root.toggleSection("storage")

            Column {
              anchors { top: parent.top; topMargin: 2; left: parent.left; right: parent.right }
              spacing: 5 * cockpitRoot.ux
              Meter {
                width: parent.width
                label: root.fsLabel("root")
                valueText: root.fsText("root")
                frac: root.fsFrac("root")
                barColor: root.gaugeColor(root.fsFrac("root"))
              }
              Meter {
                width: parent.width
                label: root.fsLabel("home")
                valueText: root.fsText("home")
                frac: root.fsFrac("home")
                barColor: root.gaugeColor(root.fsFrac("home"))
                visible: root.fsFrac("home") > 0 && root.fsLabel("home") !== root.fsLabel("root")
              }
              KvRow { k: "READ"; v: root.fmtRate(root.num(root.stats.disk_read_bps)) }
              KvRow { k: "WRITE"; v: root.fmtRate(root.num(root.stats.disk_write_bps)) }
            }
          }
        }

        // ---------------------------------------------------- BOTTOM STRIP
        Item {
          id: bottomStrip
          anchors { left: parent.left; right: parent.right; bottom: parent.bottom
                    leftMargin: cockpitRoot.m + cockpitRoot.frameInset
                    rightMargin: cockpitRoot.m + cockpitRoot.frameInset
                    bottomMargin: cockpitRoot.m + cockpitRoot.frameInset }
          height: cockpitRoot.bottomH

          // NETWORK panel
          HudPanelC {
            id: networkPanel
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            width: parent.width * 0.38
            title: "NETWORK"
            accent: root.cGreen
            collapsed: root.isCollapsed("network")
            onToggled: root.toggleSection("network")

            Column {
              anchors { top: parent.top; topMargin: 2; left: parent.left; right: parent.right }
              spacing: 4 * cockpitRoot.ux
              Row {
                width: parent.width
                TLabel { text: "▼ RX"; color: root.cMuted; font.pixelSize: 11 * cockpitRoot.ux }
                TLabel { anchors.right: parent.right; text: root.fmtRate(root.rxRate)
                         color: root.cGreen; font.pixelSize: 13 * cockpitRoot.ux; font.bold: true }
              }
              Row {
                width: parent.width
                TLabel { text: "▲ TX"; color: root.cMuted; font.pixelSize: 11 * cockpitRoot.ux }
                TLabel { anchors.right: parent.right; text: root.fmtRate(root.txRate)
                         color: root.cMagenta; font.pixelSize: 13 * cockpitRoot.ux; font.bold: true }
              }
              // dual sparkline: rx in green, tx in magenta
              Item {
                width: parent.width; height: 52 * cockpitRoot.ux
                Sparkline {
                  anchors.fill: parent
                  points: root.histNetRx; col: root.cGreen
                }
              }
            }
          }

          // AGENTS panel
          HudPanelC {
            id: agentsPanel
            anchors { left: networkPanel.right; leftMargin: cockpitRoot.railGap
                      top: parent.top; bottom: parent.bottom }
            width: parent.width * 0.28
            title: "AGENTS"
            accent: root.cMagenta
            collapsed: root.isCollapsed("agents")
            onToggled: root.toggleSection("agents")

            Column {
              anchors { top: parent.top; topMargin: 2; left: parent.left; right: parent.right }
              spacing: 4 * cockpitRoot.ux
              KvRow { k: "TMUX"; v: root.has("agents_tmux") ? root.stats.agents_tmux + " sessions" : "--" }
              KvRow { k: "PROCS"; v: root.has("agents_procs") ? root.stats.agents_procs + " running" : "--" }
              KvRow { k: "LINK"; v: "ONLINE"; vc: root.cGreen }
            }
          }

          // Status line panel
          HudPanel {
            id: statusPanel
            anchors { left: agentsPanel.right; leftMargin: cockpitRoot.railGap
                      right: parent.right; top: parent.top; bottom: parent.bottom }
            title: "STATUS"
            accent: root.alert ? root.cAlert : root.cCyan

            Column {
              anchors { top: parent.top; topMargin: 4; left: parent.left; right: parent.right }
              spacing: 4 * cockpitRoot.ux
              TLabel {
                text: root.alert ? "⚠ THERMAL / MEMORY ALERT ⚠" : "SYSTEMS NOMINAL"
                color: root.alert ? root.cAlert : root.cGreen
                font.pixelSize: 13 * cockpitRoot.ux
                font.bold: true
                font.letterSpacing: 2
                SequentialAnimation on opacity {
                  running: root.alert; loops: Animation.Infinite
                  NumberAnimation { to: 0.3; duration: 450 }
                  NumberAnimation { to: 1.0; duration: 450 }
                }
              }
              TLabel {
                text: Qt.formatDateTime(root.now, "ddd dd MMM yyyy")
                color: root.cMuted
                font.pixelSize: 11 * cockpitRoot.ux
              }
              Row {
                spacing: 6
                TLabel {
                  text: "◢◤ NEXUS"
                  color: root.cCyan
                  font.pixelSize: 12 * cockpitRoot.ux
                  font.bold: true
                  font.letterSpacing: 2
                }
                TLabel {
                  text: "▮"
                  color: root.cCyan
                  opacity: root.blink ? 1.0 : 0.15
                  font.pixelSize: 12 * cockpitRoot.ux
                }
              }
              // Click to toggle all panels
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleAll()
              }
            }
          }
        }
      }
    }
  }
}
