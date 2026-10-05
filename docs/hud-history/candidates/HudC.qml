import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland
import QtQuick.Shapes
import QtQuick.Effects
import qs.Commons
import qs.Ui
import "../"

// NEXUS HUD v2 — full-screen telemetry cockpit.
//
// One PanelWindow per screen on the wlr "bottom" layer: above the wallpaper,
// below normal windows. The whole screen is the canvas: a corner-bracketed
// frame, a left rail (SYSTEM + MEMORY), a center reactor dial flanked by
// sparkline traces with a top-procs strip under it, a right rail (GPU0 Arc /
// GPU1 AMD / STORAGE), and a bottom strip (NETWORK / AGENTS / STATUS).
//
// A single persistent `collect.sh stream` process feeds every screen —
// "key<TAB>value" lines terminated by "batch\t<n>" frame sentinels at ~1s
// cadence — plus a `probe` process for static keys (host/kernel/gpu names).
// Nothing else is spawned per frame; sparklines and the dial are Canvas-drawn
// and repaint once per telemetry frame.
//
// Collapse state is session-only and shared across all monitors: clicking a
// panel header folds that panel on every screen. Clicking the NEXUS title
// plate, or `omarchy-shell nexuslink.hud toggleAll`, folds/unfolds all.
Item {
  id: root

  // Injected by omarchy-shell (scoped PluginShellApi + public manifest copy).
  property var shell: null
  property var manifest: null

  // ------------------------------------------------------------- palette
  readonly property color cCyan:    "#00e5ff"
  readonly property color cAccent:  "#35e0ff"
  readonly property color cGreen:   "#39ff14"
  readonly property color cMagenta: "#ff2bd6"
  readonly property color cAmber:   "#ffb300"
  readonly property color cAlert:   "#ff3b4e"
  readonly property color cTxt:     "#c9f2fb"
  readonly property color cMuted:   "#5e93a6"
  readonly property color cLine:    "#0d4a61"
  readonly property color cPanel:   Util.alpha(Color.background, 0.84)
  readonly property color cPlate:   "#040e16"

  // Path of this file's directory, resolved from the component URL so the
  // plugin works wherever the registry mounts it.
  readonly property string collectScript:
    decodeURIComponent(String(Qt.resolvedUrl("collect.sh")).replace(/^file:\/\//, ""))

  // -------------------------------------------------------------- state
  property var stats: ({})
  property string hostName: ""
  property string kernelName: ""
  property string gpuKind: "none"
  property string gpuName: ""
  property var gpuList: []
  property date now: new Date()
  property bool blink: true
  property var collapsedMap: ({})
  property int batchSeq: 0
  property double lastBatchMs: 0

  // delta bookkeeping for cpu% and net rates
  property double prevIdle: -1
  property double prevTotal: -1
  property double prevRx: -1
  property double prevTx: -1
  property double lastPollMs: 0

  property real cpuPct: -1
  property real rxRate: 0
  property real txRate: 0
  property string pendingFrame: ""

  // 60-sample rolling histories for the sparkline traces
  property var histCpu:  []
  property var histGpuW: []
  property var histRx:   []
  property var histTx:   []
  property var histDisk: []

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
    var v = num(t)
    return v >= 85 ? cAlert : v >= 70 ? cAmber : cAccent
  }

  // Paints one sparkline series. Newest sample at the right edge; NaN gaps
  // are skipped so a missing sensor reads as a gap, not a spike to zero.
  // vmax <= 0 auto-scales to the series peak with 15% headroom.
  function paintTrace(ctx, w, h, pts, colStr, vmax) {
    var n = pts.length
    if (n === 0) return
    var peak = vmax > 0 ? vmax : 0
    if (!(vmax > 0)) {
      for (var i = 0; i < n; i++) {
        var pv = pts[i]
        if (isFinite(pv) && pv > peak) peak = pv
      }
      peak *= 1.15
    }
    if (peak <= 0) return
    var step = w / 59
    ctx.strokeStyle = colStr
    ctx.lineWidth = Math.max(1.2, 1.4)
    ctx.shadowColor = colStr
    ctx.shadowBlur = 4
    ctx.beginPath()
    var started = false
    for (var j = 0; j < n; j++) {
      var v = pts[j]
      if (!isFinite(v)) continue
      var x = w - (n - 1 - j) * step
      var y = h - 2 - (Math.min(v, peak) / peak) * (h - 6)
      if (started) ctx.lineTo(x, y)
      else ctx.moveTo(x, y)
      started = true
    }
    ctx.stroke()
    ctx.shadowBlur = 0
  }

  // ------------------------------------------------------------ collapse
  readonly property var sectionIds: ["system", "memory", "gpu", "gpu2", "storage", "network", "agents"]

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
    if (!streamProc.running) streamProc.running = true
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
      else if (k === "gpu_kind") gpuKind = v
      else if (k === "gpu_name") gpuName = v
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

  function histPush(arr, v) {
    var a = arr.slice(-59)
    a.push(v)
    return a
  }

  function applyFrame(text) {
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

    // push one sample onto each sparkline history before `stats` rebinds, so
    // the canvases repaint once with everything fresh
    histCpu  = histPush(histCpu,  cpuPct >= 0 ? cpuPct : 0)
    histGpuW = histPush(histGpuW, m.i_pwr_w !== undefined ? num(m.i_pwr_w) : NaN)
    histRx   = histPush(histRx,   rxRate)
    histTx   = histPush(histTx,   txRate)
    histDisk = histPush(histDisk, num(m.disk_read_bps))

    stats = m
  }

  Process {
    id: probeProc
    running: true
    command: ["bash", root.collectScript, "probe"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyProbe(text)
    }
  }

  // Persistent stats stream: collect.sh dispatches to the Rust `hud-collect`
  // binary when present (one process, ~1s cadence, in-daemon deltas) and falls
  // back to a bash poll loop otherwise. A "batch\t<n>" line ends each frame.
  Process {
    id: streamProc
    running: true
    command: ["bash", root.collectScript, "stream", "auto"]
    stdout: SplitParser {
      onRead: data => {
        var line = String(data)
        if (line.indexOf("batch\t") === 0) {
          var n = parseInt(line.substring(6))
          if (isFinite(n)) root.batchSeq = n
          root.applyFrame(root.pendingFrame)
          root.pendingFrame = ""
          root.lastBatchMs = Date.now()
        } else root.pendingFrame += line + "\n"
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text).trim() !== "") console.warn("nexuslink.hud:", String(text).trim())
    }
  }

  // Watchdog: the stream is meant to run forever; if it dies (collector
  // crash, script removed mid-update) bring it back on the next tick.
  Timer {
    interval: 4000
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
    interval: 650
    running: true
    repeat: true
    onTriggered: root.blink = !root.blink
  }

  // Re-probe occasionally so a GPU appearing/disappearing (hotplug, driver
  // reload) is picked up without a shell restart.
  Timer {
    interval: 300000
    running: true
    repeat: true
    onTriggered: if (!probeProc.running) probeProc.running = true
  }

  // -------------------------------------------------------- derived stats
  readonly property bool linkOk: lastBatchMs > 0 && (now.getTime() - lastBatchMs) < 4000

  readonly property string uptimeText: fmtUptime(stats.uptime_s)
  readonly property string cpuText: cpuPct >= 0 ? Math.round(cpuPct) + "%" : "--"
  readonly property real cpuFrac: cpuPct >= 0 ? cpuPct / 100 : -1
  readonly property string loadText: has("load1")
      ? stats.load1 + "  " + stats.load5 + "  " + stats.load15 : "--"

  // Per-core busy% keys arrive as cpu_core_0..N; count them from the frame
  // rather than trusting cpu_cores so the matrix draws whatever showed up.
  readonly property int coreCount: {
    var n = 0
    while (stats["cpu_core_" + n] !== undefined) n++
    return n
  }

  readonly property real memFrac: {
    var t = num(stats.mem_total_kb)
    return t > 0 ? (t - num(stats.mem_avail_kb)) / t : -1
  }
  readonly property string memText: memFrac >= 0
      ? fmtKiBtoGiB(num(stats.mem_total_kb) - num(stats.mem_avail_kb))
        + " / " + fmtKiBtoGiB(stats.mem_total_kb) + " GB"
        + "  (" + Math.round(memFrac * 100) + "%)"
      : "n/a"
  readonly property real swapFrac: num(stats.swap_total_kb) > 0
      ? (num(stats.swap_total_kb) - num(stats.swap_free_kb)) / num(stats.swap_total_kb)
      : -1
  readonly property string swapText: swapFrac >= 0
      ? fmtKiBtoGiB(num(stats.swap_total_kb) - num(stats.swap_free_kb))
        + " / " + fmtKiBtoGiB(stats.swap_total_kb) + " GB"
      : "n/a"

  // GPU0 — Intel Arc B580 (i_* keys)
  readonly property real iPwrFrac: has("i_pwr_w") && num(stats.i_pwr_cap_w) > 0
      ? num(stats.i_pwr_w) / num(stats.i_pwr_cap_w) : -1
  readonly property real iVramFrac: num(stats.i_vram_total) > 0
      ? num(stats.i_vram_used) / num(stats.i_vram_total) : -1
  readonly property real iUtilFrac: has("i_util") ? num(stats.i_util) / 100 : -1
  // legacy single-GPU keys (nvidia/amd fallback path)
  readonly property real gpuUtilFrac: has("gpu_util") ? num(stats.gpu_util) / 100 : -1
  readonly property real gpuVramFrac: num(stats.gpu_vram_total) > 0
      ? num(stats.gpu_vram_used) / num(stats.gpu_vram_total) : -1
  // GPU1 — AMD iGPU (a_* keys)
  readonly property real aUtilFrac: has("a_util") ? num(stats.a_util) / 100 : -1
  readonly property real aVramFrac: num(stats.a_vram_total) > 0
      ? num(stats.a_vram_used) / num(stats.a_vram_total) : -1

  readonly property string gpu0Title: gpuList.length > 0 && gpuList[0].name !== ""
      ? "GPU0 · " + String(gpuList[0].name).toUpperCase() : "GPU0"
  readonly property string gpu1Title: gpuList.length > 1 && gpuList[1].name !== ""
      ? "GPU1 · " + String(gpuList[1].name).toUpperCase() : "GPU1"
  readonly property bool gpu0Shown: gpuList.length > 0 || has("i_temp_pkg")
      || has("i_pwr_w") || hasGpuUtil || hasGpuVram || hasGpuTemp
  readonly property bool gpu1Shown: gpuList.length > 1 || has("a_util") || has("a_temp")
  readonly property bool hasGpuUtil: has("gpu_util")
  readonly property bool hasGpuVram: has("gpu_vram_total") && num(stats.gpu_vram_total) > 0
  readonly property bool hasGpuTemp: has("gpu_temp")

  function fsFrac(tag)  { return has("fs_" + tag + "_pct") ? num(stats["fs_" + tag + "_pct"]) / 100 : -1 }
  function fsLabel(tag) { return has("fs_" + tag + "_target") ? String(stats["fs_" + tag + "_target"]) : (tag === "root" ? "/" : "/home") }
  function fsText(tag)  {
    return fsFrac(tag) >= 0
      ? Math.round(num(stats["fs_" + tag + "_pct"])) + "%  ·  "
        + fmtBtoGiB(stats["fs_" + tag + "_used"]) + "/" + fmtBtoGiB(stats["fs_" + tag + "_size"]) + "G"
      : "n/a"
  }

  // Frame-wide alert: any reported temperature over 85C or memory over 90%
  // flips the frame and dial ticks to cAlert.
  readonly property real maxTemp: {
    var t = -1
    var keys = ["cpu_temp", "i_temp_pkg", "i_temp_vram", "i_temp_mctrl",
                "i_temp_pcie", "a_temp", "gpu_temp"]
    for (var i = 0; i < keys.length; i++)
      if (has(keys[i])) t = Math.max(t, num(stats[keys[i]]))
    return t
  }
  readonly property bool alert: maxTemp > 85 || (memFrac >= 0 && memFrac > 0.9)
  readonly property color frameCol: alert ? cAlert : cCyan

  function procName(i) { return has("proc" + i + "_name") ? String(stats["proc" + i + "_name"]) : "" }
  function procCpu(i)  { return has("proc" + i + "_cpu")  ? num(stats["proc" + i + "_cpu"]) : 0 }

  readonly property string hotText: {
    var parts = []
    for (var i = 0; i < 3; i++)
      if (procName(i) !== "") parts.push(procName(i))
    return parts.length ? parts.join(" · ") : "--"
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
        gpu: root.gpuKind,
        rx: root.fmtRate(root.rxRate),
        tx: root.fmtRate(root.txRate),
        frame: root.batchSeq,
        alert: root.alert
      })
    }
  }

  // -------------------------------------------------- reusable components
  // Monospace label in the cockpit palette. Sizes are set per use site
  // scaled by the panel's ux.
  component TLabel: Text {
    color: root.cTxt
    font.family: Style.font.family
  }

  // One L-shaped corner mark; rotate for the other three corners.
  component Bracket: Item {
    property color col: root.frameCol
    property real ux: 1
    width: 13 * ux
    height: 13 * ux
    Rectangle { width: parent.width; height: Math.max(1.5, 2 * ux); color: parent.col }
    Rectangle { width: Math.max(1.5, 2 * ux); height: parent.height; color: parent.col }
  }

  // Cockpit panel: chamfered dark fill, accent hairline, clickable title row
  // that folds the body (animated) when `collapsible`. `shrink` false keeps
  // the panel's footprint when folded — used for the bottom strip where a
  // collapsing height would leave a hole.
  component CPanel: Item {
    id: cp
    property string title: ""
    property color accent: root.cCyan
    property real ux: 1
    property bool collapsible: true
    property bool collapsed: false
    property bool shrink: true
    property bool shown: true
    property real contentH: 60
    signal toggled()
    default property alias body: cpInner.data

    readonly property real titleH: Math.max(16, 22 * ux)
    readonly property real chamfer: 10 * ux

    visible: shown
    height: shown ? (collapsed && shrink ? titleH + 2 : titleH + contentH) : 0
    clip: true
    Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

    Shape {
      anchors.fill: parent
      ShapePath {
        fillColor: root.cPanel
        strokeColor: cp.collapsed ? root.cLine : cp.accent
        strokeWidth: 1
        startX: cp.chamfer; startY: 0
        PathLine { x: cp.width; y: 0 }
        PathLine { x: cp.width; y: cp.height - cp.chamfer }
        PathLine { x: cp.width - cp.chamfer; y: cp.height }
        PathLine { x: 0; y: cp.height }
        PathLine { x: 0; y: cp.chamfer }
        PathLine { x: cp.chamfer; y: 0 }
      }
    }

    // top-right and bottom-left corner brackets — every corner gets exactly
    // one treatment, matching the chamfered corners on the other diagonal
    Bracket {
      ux: cp.ux
      col: cp.collapsed ? root.cMuted : cp.accent
      anchors { right: parent.right; top: parent.top; margins: 3 * cp.ux }
      rotation: 90
    }
    Bracket {
      ux: cp.ux
      col: cp.collapsed ? root.cMuted : cp.accent
      anchors { left: parent.left; bottom: parent.bottom; margins: 3 * cp.ux }
      rotation: 270
    }

    Item {
      id: cpHead
      anchors { top: parent.top; left: parent.left; right: parent.right }
      height: cp.titleH

      Row {
        id: cpHeadRow
        anchors { left: parent.left; leftMargin: 9 * cp.ux; verticalCenter: parent.verticalCenter }
        spacing: 6 * cp.ux
        TLabel {
          visible: cp.collapsible
          text: cp.collapsed ? "▸" : "▾"
          color: cp.accent
          font.pixelSize: 10 * cp.ux
        }
        TLabel {
          text: cp.title
          color: cpHeadMa.containsMouse ? cp.accent : root.cTxt
          font.pixelSize: 11 * cp.ux
          font.bold: true
          font.letterSpacing: 2.2 * cp.ux
        }
      }

      Rectangle {
        anchors {
          left: cpHeadRow.right; right: parent.right
          leftMargin: 9 * cp.ux; rightMargin: 9 * cp.ux
          verticalCenter: parent.verticalCenter
        }
        height: 1
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0.0; color: Util.alpha(cp.accent, 0.55) }
          GradientStop { position: 1.0; color: "transparent" }
        }
      }

      MouseArea {
        id: cpHeadMa
        anchors.fill: parent
        enabled: cp.collapsible
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: cp.toggled()
      }
    }

    Item {
      id: cpClip
      anchors {
        top: cpHead.bottom; left: parent.left
        right: parent.right; bottom: parent.bottom
        leftMargin: 9 * cp.ux; rightMargin: 9 * cp.ux; bottomMargin: 8 * cp.ux
      }
      clip: true
      // non-shrinking panels (bottom strip) fold by hiding the body while
      // keeping their footprint; shrinking panels let the height animation
      // + outer clip do the folding
      visible: cp.shrink ? true : !cp.collapsed
      Item { id: cpInner; anchors.fill: parent }
    }
  }

  // Small bordered temperature readout for the GPU temp grid.
  component TempBox: Rectangle {
    property string label: ""
    property real value: NaN
    property real ux: 1
    readonly property color valueColor: isNaN(value) ? root.cMuted
        : value >= 85 ? root.cAlert : value >= 70 ? root.cAmber : root.cAccent
    color: Util.alpha(root.cCyan, 0.06)
    border.width: 1
    border.color: root.cLine
    TLabel {
      anchors { left: parent.left; leftMargin: 5 * parent.ux; top: parent.top; topMargin: 3 * parent.ux }
      text: parent.label
      color: root.cMuted
      font.pixelSize: 8.5 * parent.ux
      font.letterSpacing: 1.2 * parent.ux
    }
    TLabel {
      anchors { left: parent.left; leftMargin: 5 * parent.ux; bottom: parent.bottom; bottomMargin: 2 * parent.ux }
      text: isNaN(parent.value) ? "--" : Math.round(parent.value * 10) / 10 + "°C"
      color: parent.valueColor
      font.pixelSize: 12.5 * parent.ux
    }
  }

  // Sparkline canvas: faint midline, one or two series, repaint per frame.
  component TraceCanvas: Canvas {
    property var pts: []
    property var pts2: []
    property color col: root.cCyan
    property color col2: root.cMagenta
    property real vmax: 0
    onPtsChanged: requestPaint()
    onPts2Changed: requestPaint()
    onColChanged: requestPaint()
    onCol2Changed: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.strokeStyle = "rgba(13,74,97,0.45)"
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(0, height * 0.5); ctx.lineTo(width, height * 0.5)
      ctx.moveTo(0, 0.5);          ctx.lineTo(width, 0.5)
      ctx.moveTo(0, height - 0.5); ctx.lineTo(width, height - 0.5)
      ctx.stroke()
      var peak = vmax
      if (!(peak > 0)) {
        for (var i = 0; i < pts.length; i++)
          if (isFinite(pts[i]) && pts[i] > peak) peak = pts[i]
        for (var k = 0; k < pts2.length; k++)
          if (isFinite(pts2[k]) && pts2[k] > peak) peak = pts2[k]
      }
      root.paintTrace(ctx, width, height, pts, String(col), peak)
      if (pts2.length > 0)
        root.paintTrace(ctx, width, height, pts2, String(col2), peak)
    }
  }

  // Label + current value + trace, one telemetry series in a box.
  component SparkBox: Item {
    property string label: ""
    property string val: ""
    property var pts: []
    property color col: root.cCyan
    property real vmax: 0
    property real ux: 1
    TLabel {
      id: sbLabel
      anchors { left: parent.left; top: parent.top }
      text: parent.label
      color: root.cMuted
      font.pixelSize: 9 * parent.ux
      font.letterSpacing: 1.6 * parent.ux
    }
    TLabel {
      anchors { right: parent.right; top: parent.top }
      text: parent.val
      color: parent.col
      font.pixelSize: 10 * parent.ux
    }
    TraceCanvas {
      anchors { left: parent.left; right: parent.right; top: sbLabel.bottom; topMargin: 3 * parent.ux; bottom: parent.bottom }
      pts: parent.pts
      col: parent.col
      vmax: parent.vmax
    }
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

      // Only the drawn panels accept pointer input; every other pixel of
      // this screen-sized surface passes clicks through to the desktop.
      mask: Region {
        regions: [
          Region { item: titlePlate },
          Region { item: sysPanel },
          Region { item: memPanel },
          Region { item: gpu0Panel },
          Region { item: gpu1Panel },
          Region { item: storPanel },
          Region { item: sparkLPanel },
          Region { item: sparkRPanel },
          Region { item: procPanel },
          Region { item: dialBox },
          Region { item: netPanel },
          Region { item: agentsPanel },
          Region { item: statusPanel }
        ]
      }

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

      // ------------------------------------------------- layout constants
      // Everything scales by ux so the cockpit lays out proportionally on
      // any monitor size and never overflows its frame.
      readonly property real ux: Math.max(0.7, Math.min(width / 1600, height / 900))
      readonly property real pad: 14 * ux
      readonly property real gap: 12 * ux
      readonly property real titleZoneH: 34 * ux
      readonly property real stripH: 138 * ux
      readonly property real railTop: pad + titleZoneH
      readonly property real leftW: width * 0.20
      readonly property real rightW: width * 0.22

      // ------------------------------------------------------- the frame
      Rectangle {
        id: frameLine
        anchors { fill: parent; margins: win.pad }
        color: "transparent"
        border.color: root.frameCol
        border.width: 1
        opacity: 0.8
      }
      Bracket { ux: win.ux; col: root.frameCol; x: win.pad - width / 2;  y: win.pad - height / 2 }
      Bracket { ux: win.ux; col: root.frameCol; x: win.width - win.pad - width / 2; y: win.pad - height / 2; rotation: 90 }
      Bracket { ux: win.ux; col: root.frameCol; x: win.width - win.pad - width / 2; y: win.height - win.pad - height / 2; rotation: 180 }
      Bracket { ux: win.ux; col: root.frameCol; x: win.pad - width / 2;  y: win.height - win.pad - height / 2; rotation: 270 }

      // ---------------------------------------------------- title plate
      // Straddles the top hairline like a label on a fieldset; clicking it
      // folds/unfolds every collapsible panel.
      Item {
        id: titlePlate
        width: plateRow.width + 30 * win.ux
        height: 26 * win.ux
        anchors.horizontalCenter: parent.horizontalCenter
        y: win.pad - height / 2
        Rectangle {
          anchors.fill: parent
          color: root.cPlate
          border.color: root.frameCol
          border.width: 1
        }
        Row {
          id: plateRow
          anchors.centerIn: parent
          spacing: 10 * win.ux
          TLabel {
            text: "◢◤ NEXUS"
            color: root.cCyan
            font.pixelSize: 12.5 * win.ux
            font.bold: true
            font.letterSpacing: 3 * win.ux
          }
          TLabel {
            text: "//" + (root.hostName !== "" ? root.hostName : "?")
            color: root.cGreen
            font.pixelSize: 11.5 * win.ux
            font.bold: true
          }
          TLabel {
            text: "TELEMETRY COCKPIT"
            color: root.cMuted
            font.pixelSize: 9 * win.ux
            font.letterSpacing: 2 * win.ux
          }
          TLabel {
            text: "▮"
            color: root.cCyan
            opacity: root.blink ? 1.0 : 0.15
            font.pixelSize: 10 * win.ux
          }
        }
        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.toggleAll()
        }
      }

      // ------------------------------------------------------- left rail
      Column {
        id: leftCol
        x: win.pad
        y: win.railTop
        width: win.leftW
        height: bottomStrip.y - win.gap - win.railTop
        clip: true
        spacing: win.gap
        move: Transition { NumberAnimation { properties: "y"; duration: 140; easing.type: Easing.OutCubic } }

        CPanel {
          id: sysPanel
          width: leftCol.width
          ux: win.ux
          title: "◈ SYSTEM"
          accent: root.cCyan
          collapsed: root.isCollapsed("system")
          onToggled: root.toggleSection("system")
          contentH: 216 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 5 * win.ux

            // aggregate CPU: big number + compact facts column
            Item {
              width: parent.width
              height: 44 * win.ux
              TLabel {
                id: bigCpu
                anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                text: root.cpuPct >= 0 ? Math.round(root.cpuPct) + "%" : "--"
                color: root.cpuFrac >= 0.9 ? root.cAlert
                     : root.cpuFrac >= 0.7 ? root.cAmber : root.cCyan
                font.pixelSize: 36 * win.ux
                font.bold: true
                layer.enabled: true
                layer.effect: MultiEffect {
                  shadowEnabled: true
                  shadowColor: bigCpu.color
                  shadowBlur: 0.8
                  shadowOpacity: 0.65
                }
              }
              Column {
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                spacing: 1
                TLabel {
                  text: "CPU TOTAL"
                  color: root.cMuted
                  font.pixelSize: 8.5 * win.ux
                  font.letterSpacing: 2 * win.ux
                }
                TLabel {
                  text: (root.has("cpu_count") ? String(root.stats.cpu_count) : "--") + " CORES"
                  color: root.cTxt
                  font.pixelSize: 11 * win.ux
                }
                TLabel {
                  text: "L1 " + (root.has("load1") ? String(root.stats.load1) : "--")
                  color: root.cMuted
                  font.pixelSize: 10 * win.ux
                }
              }
            }

            // per-core bar matrix: one thin vertical bar per core, coloured
            // green -> amber -> magenta by load
            Item {
              width: parent.width
              height: 78 * win.ux
              visible: root.coreCount > 0
              TLabel {
                id: cmLabel
                text: "CORE MATRIX"
                color: root.cMuted
                font.pixelSize: 8.5 * win.ux
                font.letterSpacing: 2 * win.ux
              }
              Item {
                id: coreBars
                anchors { left: parent.left; right: parent.right; top: cmLabel.bottom; topMargin: 4 * win.ux; bottom: parent.bottom }
                readonly property int n: root.coreCount
                readonly property real bgap: Math.max(1, 2 * win.ux)
                readonly property real bw: n > 0 ? Math.max(1, (width - bgap * (n - 1)) / n) : 0
                Repeater {
                  model: coreBars.n
                  delegate: Item {
                    required property int index
                    x: index * (coreBars.bw + coreBars.bgap)
                    width: coreBars.bw
                    height: coreBars.height
                    readonly property real frac: Math.min(1, root.num(root.stats["cpu_core_" + index]) / 100)
                    Rectangle { anchors.fill: parent; color: Qt.rgba(0.05, 0.29, 0.38, 0.20) }
                    Rectangle {
                      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                      height: Math.max(1, parent.height * parent.frac)
                      color: parent.frac >= 0.85 ? root.cMagenta
                           : parent.frac >= 0.55 ? root.cAmber : root.cGreen
                    }
                  }
                }
              }
            }

            HudRow { label: "LOAD";   value: root.loadText }
            HudRow {
              label: "TEMP"
              value: String(root.stats.cpu_temp) + "°C"
              accent: root.tempColor(root.stats.cpu_temp)
              valueColor: root.tempColor(root.stats.cpu_temp)
              visible: root.has("cpu_temp")
            }
            HudRow { label: "UPTIME"; value: root.uptimeText }
          }
        }

        // flexible spacer: pushes MEMORY toward the bottom of the rail so
        // the panels spread across the full height instead of clumping at
        // the top
        Item {
          width: 1
          height: Math.max(0, leftCol.height - sysPanel.height - memPanel.height - 2 * leftCol.spacing)
        }

        CPanel {
          id: memPanel
          width: leftCol.width
          ux: win.ux
          title: "▤ MEMORY"
          accent: root.cGreen
          collapsed: root.isCollapsed("memory")
          onToggled: root.toggleSection("memory")
          contentH: 62 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 4 * win.ux
            HudRow { label: "RAM";  value: root.memText;  fraction: root.memFrac;  accent: root.gaugeColor(root.memFrac) }
            HudRow { label: "SWAP"; value: root.swapText; fraction: root.swapFrac; accent: root.gaugeColor(root.swapFrac); visible: root.swapFrac >= 0 }
          }
        }
      }

      // ------------------------------------------------------ right rail
      Column {
        id: rightCol
        x: win.width - win.pad - win.rightW
        y: win.railTop
        width: win.rightW
        height: bottomStrip.y - win.gap - win.railTop
        clip: true
        spacing: win.gap
        move: Transition { NumberAnimation { properties: "y"; duration: 140; easing.type: Easing.OutCubic } }

        // GPU0 — Intel Arc B580: full xe telemetry surface
        CPanel {
          id: gpu0Panel
          width: rightCol.width
          ux: win.ux
          title: "◉ " + root.gpu0Title
          accent: root.cMagenta
          collapsed: root.isCollapsed("gpu")
          onToggled: root.toggleSection("gpu")
          shown: root.gpu0Shown
          contentH: 290 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 4 * win.ux

            HudRow {
              label: "PWR"
              value: root.has("i_pwr_w")
                  ? root.stats.i_pwr_w + " W" + (root.has("i_pwr_cap_w") ? " / " + root.stats.i_pwr_cap_w + "W" : "")
                  : (root.has("i_pwr_cap_w") ? "cap " + root.stats.i_pwr_cap_w + " W" : "--")
              fraction: root.iPwrFrac
              accent: root.gaugeColor(root.iPwrFrac)
              visible: root.has("i_pwr_w") || root.has("i_pwr_cap_w")
            }

            // temperature grid: package / vram / mem-ctrl / pcie
            Item {
              width: parent.width
              height: 74 * win.ux
              visible: root.has("i_temp_pkg") || root.has("i_temp_vram")
                  || root.has("i_temp_mctrl") || root.has("i_temp_pcie")
              Grid {
                id: tempGrid
                anchors { left: parent.left; right: parent.right; top: parent.top }
                columns: 2
                columnSpacing: 4 * win.ux
                rowSpacing: 4 * win.ux
                TempBox {
                  ux: win.ux
                  width: (tempGrid.width - tempGrid.columnSpacing) / 2
                  height: 34 * win.ux
                  label: "PKG"
                  value: root.has("i_temp_pkg") ? root.num(root.stats.i_temp_pkg) : NaN
                  visible: root.has("i_temp_pkg")
                }
                TempBox {
                  ux: win.ux
                  width: (tempGrid.width - tempGrid.columnSpacing) / 2
                  height: 34 * win.ux
                  label: "VRAM"
                  value: root.has("i_temp_vram") ? root.num(root.stats.i_temp_vram) : NaN
                  visible: root.has("i_temp_vram")
                }
                TempBox {
                  ux: win.ux
                  width: (tempGrid.width - tempGrid.columnSpacing) / 2
                  height: 34 * win.ux
                  label: "MCTRL"
                  value: root.has("i_temp_mctrl") ? root.num(root.stats.i_temp_mctrl) : NaN
                  visible: root.has("i_temp_mctrl")
                }
                TempBox {
                  ux: win.ux
                  width: (tempGrid.width - tempGrid.columnSpacing) / 2
                  height: 34 * win.ux
                  label: "PCIE"
                  value: root.has("i_temp_pcie") ? root.num(root.stats.i_temp_pcie) : NaN
                  visible: root.has("i_temp_pcie")
                }
              }
            }

            HudRow { label: "VRM CH"; value: "max " + root.stats.i_vram_ch_max + "° · avg " + root.stats.i_vram_ch_avg + "°"; accent: root.cAmber; visible: root.has("i_vram_ch_max") }
            HudRow { label: "FAN";    value: root.stats.i_fan_rpm + " RPM"; accent: root.cCyan; visible: root.has("i_fan_rpm") }
            HudRow { label: "VRAM";   value: root.num(root.stats.i_vram_used) + " / " + root.num(root.stats.i_vram_total) + " MiB"; fraction: root.iVramFrac; accent: root.gaugeColor(root.iVramFrac); visible: root.has("i_vram_total") }
            HudRow { label: "UTIL";   value: Math.round(root.num(root.stats.i_util)) + "%"; fraction: root.iUtilFrac; accent: root.gaugeColor(root.iUtilFrac); visible: root.has("i_util") }
            HudRow { label: "FREQ";   value: root.stats.i_freq_mhz + " MHz"; accent: root.cCyan; visible: root.has("i_freq_mhz") }

            // legacy single-GPU fallback keys
            HudRow { label: "UTIL"; value: Math.round(root.num(root.stats.gpu_util)) + "%"; fraction: root.gpuUtilFrac; accent: root.gaugeColor(root.gpuUtilFrac); visible: root.hasGpuUtil }
            HudRow { label: "VRAM"; value: root.num(root.stats.gpu_vram_used) + " / " + root.num(root.stats.gpu_vram_total) + " MiB"; fraction: root.gpuVramFrac; accent: root.gaugeColor(root.gpuVramFrac); visible: root.hasGpuVram }
            HudRow { label: "TEMP"; value: String(root.stats.gpu_temp) + "°C"; accent: root.tempColor(root.stats.gpu_temp); valueColor: root.tempColor(root.stats.gpu_temp); visible: root.hasGpuTemp }
          }
        }

        // flexible spacers distribute the three panels down the rail
        Item {
          width: 1
          height: Math.max(0, (rightCol.height - gpu0Panel.height - gpu1Panel.height - storPanel.height - 4 * rightCol.spacing) / 2)
        }

        // GPU1 — AMD iGPU: util / vram / temp / power / freq
        CPanel {
          id: gpu1Panel
          width: rightCol.width
          ux: win.ux
          title: "◉ " + root.gpu1Title
          accent: root.cCyan
          collapsed: root.isCollapsed("gpu2")
          onToggled: root.toggleSection("gpu2")
          shown: root.gpu1Shown
          contentH: 140 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 4 * win.ux
            HudRow { label: "UTIL"; value: root.stats.a_util + "%"; fraction: root.aUtilFrac; accent: root.gaugeColor(root.aUtilFrac); visible: root.has("a_util") }
            HudRow { label: "VRAM"; value: root.stats.a_vram_used + " / " + root.stats.a_vram_total + " MiB"; fraction: root.aVramFrac; accent: root.gaugeColor(root.aVramFrac); visible: root.has("a_vram_total") }
            HudRow { label: "TEMP"; value: root.stats.a_temp + "°C"; accent: root.tempColor(root.stats.a_temp); valueColor: root.tempColor(root.stats.a_temp); visible: root.has("a_temp") }
            HudRow { label: "PWR";  value: root.stats.a_pwr_w + " W"; accent: root.cGreen; visible: root.has("a_pwr_w") }
            HudRow { label: "FREQ"; value: root.stats.a_freq_mhz + " MHz"; accent: root.cCyan; visible: root.has("a_freq_mhz") }
          }
        }

        Item {
          width: 1
          height: Math.max(0, (rightCol.height - gpu0Panel.height - gpu1Panel.height - storPanel.height - 4 * rightCol.spacing) / 2)
        }

        CPanel {
          id: storPanel
          width: rightCol.width
          ux: win.ux
          title: "▣ STORAGE"
          accent: root.cAccent
          collapsed: root.isCollapsed("storage")
          onToggled: root.toggleSection("storage")
          contentH: 120 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 4 * win.ux
            HudRow { label: root.fsLabel("root"); value: root.fsText("root"); fraction: root.fsFrac("root"); accent: root.gaugeColor(root.fsFrac("root")) }
            // /home row hides itself when $HOME lives on the same mount as /
            HudRow { label: root.fsLabel("home"); value: root.fsText("home"); fraction: root.fsFrac("home"); accent: root.gaugeColor(root.fsFrac("home")); visible: root.fsFrac("home") >= 0 && root.fsLabel("home") !== root.fsLabel("root") }
            HudRow { label: "▼ READ";  value: root.fmtRate(root.stats.disk_read_bps);  accent: root.cGreen;   valueColor: root.cGreen;   visible: root.has("disk_read_bps") }
            HudRow { label: "▲ WRITE"; value: root.fmtRate(root.stats.disk_write_bps); accent: root.cMagenta; valueColor: root.cMagenta; visible: root.has("disk_write_bps") }
          }
        }
      }

      // ---------------------------------------------------- center stage
      Item {
        id: centerZone
        anchors {
          left: leftCol.right; right: rightCol.left
          top: parent.top; bottom: bottomStrip.top
          leftMargin: win.gap; rightMargin: win.gap
          topMargin: win.railTop; bottomMargin: win.gap
        }

        readonly property real procH: 54 * win.ux
        readonly property real legendH: 20 * win.ux
        readonly property real dialD: Math.max(
            80 * win.ux,
            Math.min(win.height * 0.38,
                     height - procH - legendH - 3 * win.gap,
                     width * 0.60))
        readonly property real flankW: Math.max(0, (width - dialD - 2 * win.gap) / 2)
        readonly property real vShift: -(procH + legendH + 2 * win.gap) / 2

        // left flank traces: cpu% (fixed 0-100) + gpu0 power watts
        CPanel {
          id: sparkLPanel
          anchors { left: parent.left; verticalCenter: parent.verticalCenter; verticalCenterOffset: centerZone.vShift }
          width: centerZone.flankW
          ux: win.ux
          collapsible: false
          shrink: false
          title: "∿ CORE TRACE"
          accent: root.cAccent
          contentH: Math.max(40, centerZone.dialD - titleH - 4 * win.ux)

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 5 * win.ux
            SparkBox {
              width: parent.width
              height: (sparkLPanel.contentH - 5 * win.ux) / 2
              ux: win.ux
              label: "CPU %"
              val: root.cpuText
              pts: root.histCpu
              col: root.cCyan
              vmax: 100
            }
            SparkBox {
              width: parent.width
              height: (sparkLPanel.contentH - 5 * win.ux) / 2
              ux: win.ux
              label: "GPU0 PWR"
              val: root.has("i_pwr_w") ? Math.round(root.num(root.stats.i_pwr_w)) + " W" : "--"
              pts: root.histGpuW
              col: root.cMagenta
            }
          }
        }

        // right flank traces: network rx rate + disk read rate
        CPanel {
          id: sparkRPanel
          anchors { right: parent.right; verticalCenter: parent.verticalCenter; verticalCenterOffset: centerZone.vShift }
          width: centerZone.flankW
          ux: win.ux
          collapsible: false
          shrink: false
          title: "∿ IO TRACE"
          accent: root.cGreen
          contentH: Math.max(40, centerZone.dialD - titleH - 4 * win.ux)

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 5 * win.ux
            SparkBox {
              width: parent.width
              height: (sparkRPanel.contentH - 5 * win.ux) / 2
              ux: win.ux
              label: "NET RX"
              val: root.fmtRate(root.rxRate)
              pts: root.histRx
              col: root.cGreen
            }
            SparkBox {
              width: parent.width
              height: (sparkRPanel.contentH - 5 * win.ux) / 2
              ux: win.ux
              label: "DISK READ"
              val: root.fmtRate(root.stats.disk_read_bps)
              pts: root.histDisk
              col: root.cAmber
            }
          }
        }

        // the reactor: three concentric 270° arcs — outer CPU%, middle GPU0
        // power fraction, inner memory fraction — around a live centre readout
        Item {
          id: dialBox
          anchors { horizontalCenter: parent.horizontalCenter; verticalCenter: parent.verticalCenter; verticalCenterOffset: centerZone.vShift }
          width: centerZone.dialD
          height: width

          Canvas {
            id: dialCanvas
            anchors.fill: parent
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              var cx = width / 2, cy = height / 2
              var a0 = Math.PI * 0.75, span = Math.PI * 1.5
              var rOut = width * 0.44, rMid = width * 0.355, rIn = width * 0.27
              var lw = Math.max(2.5, width * 0.032)
              var rTick = width * 0.485
              // tick ring, major tick every 10% of the sweep
              for (var i = 0; i <= 72; i++) {
                var a = a0 + span * i / 72
                var major = (i % 12 === 0)
                ctx.strokeStyle = major ? String(root.frameCol) : String(root.cLine)
                ctx.lineWidth = major ? Math.max(1.4, 1.8 * win.ux) : 1
                var r1 = rTick
                var r2 = r1 + (major ? width * 0.030 : width * 0.014)
                ctx.beginPath()
                ctx.moveTo(cx + r1 * Math.cos(a), cy + r1 * Math.sin(a))
                ctx.lineTo(cx + r2 * Math.cos(a), cy + r2 * Math.sin(a))
                ctx.stroke()
              }
              function ring(r, frac, colStr) {
                ctx.lineWidth = lw
                ctx.shadowBlur = 0
                ctx.strokeStyle = String(root.cLine)
                ctx.beginPath()
                ctx.arc(cx, cy, r, a0, a0 + span)
                ctx.stroke()
                if (frac > 0) {
                  var f = Math.min(frac, 1)
                  ctx.strokeStyle = colStr
                  ctx.shadowColor = colStr
                  ctx.shadowBlur = 8 * win.ux
                  ctx.beginPath()
                  ctx.arc(cx, cy, r, a0, a0 + span * f)
                  ctx.stroke()
                  ctx.shadowBlur = 0
                  var ae = a0 + span * f
                  ctx.fillStyle = colStr
                  ctx.beginPath()
                  ctx.arc(cx + r * Math.cos(ae), cy + r * Math.sin(ae), lw * 0.62, 0, Math.PI * 2)
                  ctx.fill()
                }
              }
              var cpuF = root.cpuFrac  >= 0 ? root.cpuFrac  : 0
              var gpuF = root.iPwrFrac >= 0 ? root.iPwrFrac : 0
              var memF = root.memFrac  >= 0 ? root.memFrac  : 0
              ring(rOut, cpuF, String(cpuF >= 0.9 ? root.cAlert : cpuF >= 0.7 ? root.cAmber : root.cCyan))
              ring(rMid, gpuF, String(gpuF >= 0.9 ? root.cAlert : gpuF >= 0.7 ? root.cAmber : root.cMagenta))
              ring(rIn,  memF, String(memF >= 0.9 ? root.cAlert : memF >= 0.7 ? root.cAmber : root.cGreen))
              // soft core glow behind the centre text
              var g = ctx.createRadialGradient(cx, cy, 0, cx, cy, rIn * 0.95)
              g.addColorStop(0, "rgba(53,224,255,0.13)")
              g.addColorStop(0.7, "rgba(53,224,255,0.045)")
              g.addColorStop(1, "rgba(0,0,0,0)")
              ctx.fillStyle = g
              ctx.fillRect(cx - rIn, cy - rIn, 2 * rIn, 2 * rIn)
            }
            Connections {
              target: root
              function onStatsChanged() { dialCanvas.requestPaint() }
              function onFrameColChanged() { dialCanvas.requestPaint() }
            }
          }

          // static dashed ring between the inner arc and the readout — an
          // idle instrument still looks powered; painted once, never animates
          Repeater {
            model: 36
            delegate: Rectangle {
              required property int index
              readonly property real a: index * 2 * Math.PI / 36
              readonly property real rad: dialBox.width * 0.205
              width: Math.max(2, 2 * Math.PI * rad / 36 * 0.42)
              height: Math.max(1, 1.3 * win.ux)
              color: root.cLine
              opacity: 0.5
              x: dialBox.width / 2 + rad * Math.cos(a) - width / 2
              y: dialBox.height / 2 + rad * Math.sin(a) - height / 2
              rotation: index * 10 + 90
            }
          }

          Column {
            anchors.centerIn: parent
            width: parent.width * 0.42
            spacing: 2 * win.ux
            TLabel {
              anchors.horizontalCenter: parent.horizontalCenter
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              text: root.hostName !== "" ? root.hostName.toUpperCase() : "NEXUS"
              color: root.cMuted
              font.pixelSize: Math.max(8, dialBox.width * 0.032)
              font.letterSpacing: 3 * win.ux
            }
            TLabel {
              id: clockText
              anchors.horizontalCenter: parent.horizontalCenter
              text: Qt.formatDateTime(root.now, "HH:mm:ss")
              color: "#eafcff"
              font.pixelSize: Math.max(14, dialBox.width * 0.075)
              font.bold: true
              font.letterSpacing: 1.5 * win.ux
              layer.enabled: true
              layer.effect: MultiEffect {
                shadowEnabled: true
                shadowColor: root.cAccent
                shadowBlur: 1.0
                shadowOpacity: 0.7
              }
            }
            TLabel {
              anchors.horizontalCenter: parent.horizontalCenter
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              text: "sys " + (root.kernelName !== "" ? root.kernelName : "?")
              color: root.cMuted
              font.pixelSize: Math.max(8, dialBox.width * 0.026)
            }
            TLabel {
              anchors.horizontalCenter: parent.horizontalCenter
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              text: "out " + String(win.modelData.name)
                  + (win.wsLabel !== "" ? "  ·  ws " + win.wsLabel : "")
              color: root.cMuted
              font.pixelSize: Math.max(8, dialBox.width * 0.026)
            }
          }
        }

        // ring legend under the dial
        Row {
          anchors { top: dialBox.bottom; topMargin: 4 * win.ux; horizontalCenter: parent.horizontalCenter }
          spacing: 16 * win.ux
          Repeater {
            model: [
              { t: "CPU",     c: root.cCyan },
              { t: "GPU PWR", c: root.cMagenta },
              { t: "MEM",     c: root.cGreen }
            ]
            delegate: Row {
              required property var modelData
              spacing: 5 * win.ux
              Rectangle {
                width: 9 * win.ux
                height: 3
                color: parent.modelData.c
                anchors.verticalCenter: parent.verticalCenter
              }
              TLabel {
                text: parent.modelData.t
                color: root.cMuted
                font.pixelSize: 9 * win.ux
                font.letterSpacing: 1.6 * win.ux
              }
            }
          }
        }

        // marquee row of top-CPU processes under the dial
        CPanel {
          id: procPanel
          anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
          ux: win.ux
          collapsible: false
          shrink: false
          title: "▣ TOP PROCS"
          accent: root.cMagenta
          contentH: 30 * win.ux

          Row {
            id: procRow
            anchors { fill: parent; leftMargin: 2 * win.ux }
            Repeater {
              model: 6
              delegate: Item {
                required property int index
                visible: root.has("proc" + index + "_name")
                width: procRow.width / 6
                height: procRow.height
                Row {
                  anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 6 * win.ux }
                  spacing: 5 * win.ux
                  TLabel {
                    text: "▸"
                    color: root.cMuted
                    font.pixelSize: 9.5 * win.ux
                  }
                  TLabel {
                    width: Math.max(10, procRow.width / 6 - 62 * win.ux)
                    text: root.procName(index)
                    color: root.cTxt
                    font.pixelSize: 10.5 * win.ux
                    elide: Text.ElideRight
                  }
                  TLabel {
                    text: Math.round(root.procCpu(index)) + "%"
                    color: root.procCpu(index) >= 60 ? root.cMagenta
                         : root.procCpu(index) >= 25 ? root.cAmber : root.cAccent
                    font.pixelSize: 10.5 * win.ux
                  }
                }
                Rectangle {
                  visible: index < 5
                  anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                  width: 1
                  height: parent.height * 0.55
                  color: root.cLine
                }
              }
            }
          }
        }
      }

      // ------------------------------------------------------ bottom strip
      Item {
        id: bottomStrip
        anchors {
          left: parent.left; right: parent.right; bottom: parent.bottom
          leftMargin: win.pad; rightMargin: win.pad; bottomMargin: win.pad
        }
        height: win.stripH

        Row {
          anchors.fill: parent
          spacing: win.gap

          CPanel {
            id: netPanel
            ux: win.ux
            width: Math.max(120, (bottomStrip.width - 2 * win.gap) * 0.40)
            shrink: false
            title: "⇅ NETWORK"
            accent: root.cGreen
            collapsed: root.isCollapsed("network")
            onToggled: root.toggleSection("network")
            contentH: win.stripH - 22 * win.ux

            Item {
              anchors.fill: parent
              Column {
                id: netRates
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                width: 118 * win.ux
                spacing: 3 * win.ux
                TLabel { text: "▼ RX"; color: root.cMuted; font.pixelSize: 9 * win.ux; font.letterSpacing: 1.6 * win.ux }
                TLabel { text: root.fmtRate(root.rxRate); color: root.cGreen; font.pixelSize: 15 * win.ux; font.bold: true }
                Item { width: 1; height: 4 * win.ux }
                TLabel { text: "▲ TX"; color: root.cMuted; font.pixelSize: 9 * win.ux; font.letterSpacing: 1.6 * win.ux }
                TLabel { text: root.fmtRate(root.txRate); color: root.cMagenta; font.pixelSize: 15 * win.ux; font.bold: true }
              }
              TraceCanvas {
                anchors { left: netRates.right; right: parent.right; top: parent.top; bottom: parent.bottom; leftMargin: 8 * win.ux }
                pts: root.histRx
                pts2: root.histTx
                col: root.cGreen
                col2: root.cMagenta
              }
            }
          }

          CPanel {
            id: agentsPanel
            ux: win.ux
            width: Math.max(100, (bottomStrip.width - 2 * win.gap) * 0.34)
            shrink: false
            title: "◉ AGENTS"
            accent: root.cMagenta
            collapsed: root.isCollapsed("agents")
            onToggled: root.toggleSection("agents")
            contentH: win.stripH - 22 * win.ux

            Column {
              anchors { left: parent.left; right: parent.right; top: parent.top }
              spacing: 4 * win.ux
              HudRow { label: "TMUX";   value: root.has("agents_tmux")  ? String(root.stats.agents_tmux) + " sessions" : "--" }
              HudRow { label: "AGENTS"; value: root.has("agents_procs") ? String(root.stats.agents_procs) + " procs"   : "--" }
              HudRow { label: "HOT";    value: root.hotText; accent: root.cAmber }
              HudRow { label: "LINK";   value: "ONLINE"; accent: root.cGreen; valueColor: root.cGreen; visible: root.linkOk }
            }
          }

          CPanel {
            id: statusPanel
            ux: win.ux
            width: Math.max(100, bottomStrip.width - 2 * win.gap - netPanel.width - agentsPanel.width)
            shrink: false
            collapsible: false
            title: "▮ STATUS"
            accent: root.cAccent
            contentH: win.stripH - 22 * win.ux

            Column {
              anchors { left: parent.left; right: parent.right; top: parent.top }
              spacing: 4 * win.ux
              Row {
                spacing: 6 * win.ux
                TLabel {
                  text: root.alert ? "⚠ ALERT" : (root.linkOk ? "LINK ▮▮▮" : "LINK LOST")
                  color: root.alert ? root.cAlert : (root.linkOk ? root.cGreen : root.cAlert)
                  font.pixelSize: 12 * win.ux
                  font.bold: true
                  font.letterSpacing: 1.5 * win.ux
                }
                TLabel {
                  text: "▮"
                  color: root.cCyan
                  opacity: root.blink ? 1.0 : 0.15
                  font.pixelSize: 10 * win.ux
                }
              }
              TLabel {
                text: "FRAME " + root.batchSeq + (root.alert ? "  ·  OVERTEMP/MEM" : "")
                color: root.alert ? root.cAlert : root.cMuted
                font.pixelSize: 9.5 * win.ux
                font.letterSpacing: 1 * win.ux
              }
              TLabel {
                text: Qt.formatDateTime(root.now, "ddd dd MMM yyyy")
                color: root.cMuted
                font.pixelSize: 9.5 * win.ux
              }
              TLabel {
                text: "out " + String(win.modelData.name)
                    + (win.wsLabel !== "" ? " · ws " + win.wsLabel : "")
                color: root.cMuted
                font.pixelSize: 9.5 * win.ux
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }
        }
      }

      // -------------------------------------------- scanlines + vignette
      // Painted once per resize — a static texture, not an animation.
      Canvas {
        id: fxCanvas
        anchors.fill: parent
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var g = ctx.createRadialGradient(width / 2, height * 0.45,
                                           Math.min(width, height) * 0.35,
                                           width / 2, height * 0.5,
                                           Math.max(width, height) * 0.72)
          g.addColorStop(0, "rgba(0,0,0,0)")
          g.addColorStop(1, "rgba(0,0,0,0.28)")
          ctx.fillStyle = g
          ctx.fillRect(0, 0, width, height)
          ctx.strokeStyle = "rgba(0,0,0,0.07)"
          ctx.lineWidth = 1
          ctx.beginPath()
          for (var y = 0.5; y < height; y += 3) {
            ctx.moveTo(0, y)
            ctx.lineTo(width, y)
          }
          ctx.stroke()
        }
      }
    }
  }
}
