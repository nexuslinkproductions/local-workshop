import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland
import QtQuick.Shapes
import QtQuick.Effects
import qs.Commons
import qs.Ui

// NEXUS HUD v2 — full-screen telemetry cockpit.
//
// One PanelWindow per screen on the wlr "bottom" layer: above the wallpaper,
// below normal windows. A single collector process (collect.sh, polled every
// ~1s) feeds every screen, so multi-monitor cost stays trivial.
//
// Collapse state is session-only and shared across all monitors: clicking a
// section header anywhere folds that section on every screen. Clicking the
// NEXUS header block, or `omarchy-shell nexuslink.hud toggleAll`, toggles all
// sections at once.
Item {
  id: root

  // Injected by omarchy-shell (scoped PluginShellApi + public manifest copy).
  property var shell: null
  property var manifest: null

  // ------------------------------------------------------------- palette
  readonly property color cCyan:    "#00e5ff"
  readonly property color cCyan2:   "#35e0ff"
  readonly property color cGreen:   "#39ff14"
  readonly property color cMagenta: "#ff2bd6"
  readonly property color cAmber:   "#ffb300"
  readonly property color cAlert:   "#ff3b4e"
  readonly property color cText:    "#c9f2fb"
  readonly property color cMuted:   "#5e93a6"
  readonly property color cHair:    "#0d4a61"
  readonly property color cPanel:   Util.alpha(Color.background, 0.84)
  readonly property color cBorder:  Util.alpha(cCyan, 0.45)

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
  property date now: new Date()
  property bool blink: true
  property var collapsedMap: ({})

  // delta bookkeeping for cpu% and net rates
  property double prevIdle: -1
  property double prevTotal: -1
  property double prevRx: -1
  property double prevTx: -1
  property double lastPollMs: 0

  property real cpuPct: -1
  property real rxRate: 0
  property real txRate: 0
  property var gpuList: []
  property string pendingPoll: ""

  // 60-point history buffers for sparklines
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
    return cCyan2
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

    // push history
    var hc = histCpu.slice(-59); hc.push(cpuPct >= 0 ? cpuPct : 0); histCpu = hc
    var hg = histGpuW.slice(-59); hg.push(num(m.i_pwr_w)); histGpuW = hg
    var hn = histNetRx.slice(-59); hn.push(rxRate); histNetRx = hn
    var hd = histDiskR.slice(-59); hd.push(num(m.disk_read_bps)); histDiskR = hd
  }

  Process {
    id: probeProc
    command: ["bash", root.collectScript, "probe"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyProbe(text)
    }
  }

  // Persistent stats stream: collect.sh dispatches to the Rust `hud-collect`
  // binary when present (one process, ~1s cadence, in-daemon deltas) and falls
  // back to a bash poll loop otherwise. A "batch\t<n>" line ends each batch.
  Process {
    id: pollProc
    command: ["bash", root.collectScript, "stream", root.gpuKind]
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

  // Re-probe occasionally so a GPU appearing/disappearing (hotplug, driver
  // reload) is picked up without a shell restart.
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
  readonly property real cpuFrac: cpuPct >= 0 ? cpuPct / 100 : -1
  readonly property string loadText: has("load1")
      ? stats.load1 + "  " + stats.load5 + "  " + stats.load15 : "--"

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

  readonly property bool hasGpuUtil:  has("gpu_util")
  readonly property bool hasGpuVram:  has("gpu_vram_total") && num(stats.gpu_vram_total) > 0
  readonly property bool hasGpuTemp:  has("gpu_temp")
  readonly property real gpuUtilFrac: hasGpuUtil ? num(stats.gpu_util) / 100 : -1
  readonly property real gpuVramFrac: hasGpuVram ? num(stats.gpu_vram_used) / num(stats.gpu_vram_total) : -1
  readonly property string gpuUtilText: hasGpuUtil ? Math.round(num(stats.gpu_util)) + "%" : "n/a"
  readonly property string gpuVramText: hasGpuVram
      ? num(stats.gpu_vram_used).toFixed(0) + " / " + num(stats.gpu_vram_total).toFixed(0) + " MiB"
      : "n/a"

  function fsFrac(tag)  { return has("fs_" + tag + "_pct") ? num(stats["fs_" + tag + "_pct"]) / 100 : -1 }
  function fsLabel(tag) { return has("fs_" + tag + "_target") ? String(stats["fs_" + tag + "_target"]) : (tag === "root" ? "/" : "/home") }
  function fsText(tag)  {
    return fsFrac(tag) >= 0
      ? Math.round(num(stats["fs_" + tag + "_pct"])) + "%  ·  "
        + fmtBtoGiB(stats["fs_" + tag + "_used"]) + "/" + fmtBtoGiB(stats["fs_" + tag + "_size"]) + "G"
      : "n/a"
  }

  // GPU0 (Intel Arc) derived
  readonly property real gpu0PwrFrac: has("i_pwr_w") && num(stats.i_pwr_cap_w) > 0
      ? num(stats.i_pwr_w) / num(stats.i_pwr_cap_w) : -1
  readonly property real gpu0VramFrac: num(stats.i_vram_total) > 0
      ? num(stats.i_vram_used) / num(stats.i_vram_total) : -1
  readonly property string gpu0Name: gpuList.length > 0 && gpuList[0].name !== ""
      ? gpuList[0].name : "Arc B580"

  // GPU1 (AMD iGPU) derived
  readonly property real gpu1VramFrac: num(stats.a_vram_total) > 0
      ? num(stats.a_vram_used) / num(stats.a_vram_total) : -1
  readonly property string gpu1Name: gpuList.length > 1 && gpuList[1].name !== ""
      ? gpuList[1].name : "AMD iGPU"

  // Alert state: any temp > 85C or mem > 90%
  readonly property bool alertState: {
    if (memFrac >= 0.9) return true
    if (num(stats.cpu_temp) >= 85) return true
    if (num(stats.i_temp_pkg) >= 85) return true
    if (num(stats.i_temp_vram) >= 85) return true
    if (num(stats.i_temp_mctrl) >= 85) return true
    if (num(stats.i_temp_pcie) >= 85) return true
    if (num(stats.a_temp) >= 85) return true
    return false
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
        tx: root.fmtRate(root.txRate)
      })
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
      // Only the HUD panels accept pointer input; every other pixel of
      // this screen-sized surface passes clicks through to the desktop.
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

      // ---------------------------------------------------------- cockpit
      Item {
        id: cockpitRoot
        anchors.fill: parent

        readonly property real ux: Math.max(0.7, Math.min(width / 1600, height / 900))
        readonly property real m: 12 * ux

        // ---------------------------------------------------------- frame
        Rectangle {
          id: frame
          anchors.fill: parent
          anchors.margins: cockpitRoot.m
          color: "transparent"
          border.color: root.alertState ? root.cAlert : root.cBorder
          border.width: 1
        }

        // corner brackets
        CornerBracket { anchors.left: frame.left; anchors.top: frame.top; rotation: 0 }
        CornerBracket { anchors.right: frame.right; anchors.top: frame.top; rotation: 90 }
        CornerBracket { anchors.right: frame.right; anchors.bottom: frame.bottom; rotation: 180 }
        CornerBracket { anchors.left: frame.left; anchors.bottom: frame.bottom; rotation: 270 }

        // subtle scanlines
        Repeater {
          model: Math.ceil(cockpitRoot.height / 4)
          delegate: Rectangle {
            x: 0
            y: index * 4
            width: cockpitRoot.width
            height: 1
            color: Qt.rgba(1, 1, 1, 0.018)
          }
        }

        // ---------------------------------------------------------- layout
        readonly property real leftW: width * 0.20
        readonly property real rightW: width * 0.22
        readonly property real centerW: width - leftW - rightW - 4 * m
        readonly property real bottomH: 120 * ux

        // ---------------------------------------------------------- left rail
        Column {
          id: leftRail
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: bottomStrip.top
          anchors.margins: cockpitRoot.m
          anchors.bottomMargin: cockpitRoot.m
          width: cockpitRoot.leftW
          spacing: cockpitRoot.m

          // SYSTEM panel
          HudPanel {
            title: "SYSTEM"
            accent: root.cCyan
            collapsed: root.isCollapsed("system")
            onToggled: root.toggleSection("system")
            width: parent.width

            Column {
              width: parent.width
              spacing: 6 * cockpitRoot.ux

              // big CPU number
              Item {
                width: parent.width
                height: 64 * cockpitRoot.ux
                Text {
                  anchors.centerIn: parent
                  text: root.cpuText
                  color: root.gaugeColor(root.cpuFrac)
                  font.family: Style.font.family
                  font.pixelSize: 42 * cockpitRoot.ux
                  font.bold: true
                }
              }

              // per-core bar matrix
              Item {
                width: parent.width
                height: 48 * cockpitRoot.ux
                readonly property int cores: root.has("cpu_cores") ? root.num(root.stats.cpu_cores) : 0
                Row {
                  anchors.fill: parent
                  spacing: 1
                  Repeater {
                    model: parent.cores
                    delegate: Rectangle {
                      required property int index
                      readonly property real load: root.num(root.stats["cpu_core_" + index]) / 100
                      width: (parent.width - (parent.cores - 1) * 1) / Math.max(parent.cores, 1)
                      height: parent.height
                      color: "transparent"
                      Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: Math.max(1, parent.height * load)
                        color: load > 0.9 ? root.cMagenta : load > 0.7 ? root.cAmber : root.cGreen
                      }
                    }
                  }
                }
              }

              HudRow { label: "LOAD"; value: root.loadText }
              HudRow { label: "TEMP"; value: root.has("cpu_temp") ? root.stats.cpu_temp + "°C" : "--"; accent: root.tempColor(root.num(root.stats.cpu_temp)) }
              HudRow { label: "UPTIME"; value: root.uptimeText }
            }
          }

          // MEMORY panel
          HudPanel {
            title: "MEMORY"
            accent: root.cGreen
            collapsed: root.isCollapsed("memory")
            onToggled: root.toggleSection("memory")
            width: parent.width

            Column {
              width: parent.width
              spacing: 6 * cockpitRoot.ux

              HudRow { label: "RAM"; value: root.memText; fraction: root.memFrac; accent: root.gaugeColor(root.memFrac) }
              HudRow { label: "SWAP"; value: root.swapText; fraction: root.swapFrac; accent: root.gaugeColor(root.swapFrac); visible: root.swapFrac >= 0 }
            }
          }
        }

        // ---------------------------------------------------------- center
        Item {
          id: centerStage
          anchors.left: leftRail.right
          anchors.right: rightRail.left
          anchors.top: parent.top
          anchors.bottom: bottomStrip.top
          anchors.margins: cockpitRoot.m
          anchors.bottomMargin: cockpitRoot.m

          // reactor dial
          Item {
            id: reactor
            anchors.centerIn: parent
            width: Math.min(parent.width, parent.height * 0.72)
            height: width

            readonly property real dialR: width * 0.38
            readonly property real ringW: width * 0.028

            // outer ring: CPU%
            Shape {
              anchors.fill: parent
              ShapePath {
                strokeColor: root.cHair
                strokeWidth: reactor.ringW
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                  centerX: reactor.width / 2
                  centerY: reactor.height / 2
                  radiusX: reactor.dialR
                  radiusY: reactor.dialR
                  startAngle: -225
                  sweepAngle: 270
                }
              }
              ShapePath {
                strokeColor: root.gaugeColor(root.cpuFrac)
                strokeWidth: reactor.ringW
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                  centerX: reactor.width / 2
                  centerY: reactor.height / 2
                  radiusX: reactor.dialR
                  radiusY: reactor.dialR
                  startAngle: -225
                  sweepAngle: 270 * Math.max(0, Math.min(root.cpuFrac, 1))
                }
              }
            }

            // middle ring: GPU0 power fraction
            Shape {
              anchors.fill: parent
              ShapePath {
                strokeColor: root.cHair
                strokeWidth: reactor.ringW * 0.8
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                  centerX: reactor.width / 2
                  centerY: reactor.height / 2
                  radiusX: reactor.dialR * 0.82
                  radiusY: reactor.dialR * 0.82
                  startAngle: -225
                  sweepAngle: 270
                }
              }
              ShapePath {
                strokeColor: root.gpu0PwrFrac >= 0.9 ? root.cAlert : root.gpu0PwrFrac >= 0.7 ? root.cAmber : root.cCyan2
                strokeWidth: reactor.ringW * 0.8
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                  centerX: reactor.width / 2
                  centerY: reactor.height / 2
                  radiusX: reactor.dialR * 0.82
                  radiusY: reactor.dialR * 0.82
                  startAngle: -225
                  sweepAngle: 270 * Math.max(0, Math.min(root.gpu0PwrFrac, 1))
                }
              }
            }

            // inner ring: mem fraction
            Shape {
              anchors.fill: parent
              ShapePath {
                strokeColor: root.cHair
                strokeWidth: reactor.ringW * 0.6
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                  centerX: reactor.width / 2
                  centerY: reactor.height / 2
                  radiusX: reactor.dialR * 0.64
                  radiusY: reactor.dialR * 0.64
                  startAngle: -225
                  sweepAngle: 270
                }
              }
              ShapePath {
                strokeColor: root.gaugeColor(root.memFrac)
                strokeWidth: reactor.ringW * 0.6
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                  centerX: reactor.width / 2
                  centerY: reactor.height / 2
                  radiusX: reactor.dialR * 0.64
                  radiusY: reactor.dialR * 0.64
                  startAngle: -225
                  sweepAngle: 270 * Math.max(0, Math.min(root.memFrac, 1))
                }
              }
            }

            // center text
            Column {
              anchors.centerIn: parent
              spacing: 2 * cockpitRoot.ux
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.hostName !== "" ? root.hostName : "NEXUS"
                color: root.cCyan
                font.family: Style.font.family
                font.pixelSize: 18 * cockpitRoot.ux
                font.bold: true
                font.letterSpacing: 2
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Qt.formatDateTime(root.now, "HH:mm:ss")
                color: root.cText
                font.family: Style.font.family
                font.pixelSize: 32 * cockpitRoot.ux
                font.bold: true
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.kernelName !== "" ? root.kernelName : "?"
                color: root.cMuted
                font.family: Style.font.family
                font.pixelSize: 11 * cockpitRoot.ux
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: String(win.modelData.name) + (win.wsLabel !== "" ? "  ·  ws " + win.wsLabel : "")
                color: root.cMuted
                font.family: Style.font.family
                font.pixelSize: 11 * cockpitRoot.ux
              }
            }
          }

          // sparklines around the dial
          Sparkline {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: cockpitRoot.m
            width: parent.width * 0.28
            height: 48 * cockpitRoot.ux
            samples: root.histCpu
            lineColor: root.cGreen
            label: "CPU %"
          }
          Sparkline {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: cockpitRoot.m
            width: parent.width * 0.28
            height: 48 * cockpitRoot.ux
            samples: root.histGpuW
            lineColor: root.cCyan2
            label: "GPU W"
          }
          Sparkline {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: cockpitRoot.m
            width: parent.width * 0.28
            height: 48 * cockpitRoot.ux
            samples: root.histNetRx
            lineColor: root.cMagenta
            label: "NET RX"
          }
          Sparkline {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: cockpitRoot.m
            width: parent.width * 0.28
            height: 48 * cockpitRoot.ux
            samples: root.histDiskR
            lineColor: root.cAmber
            label: "DISK R"
          }

          // top procs marquee under the dial
          Item {
            anchors.top: reactor.bottom
            anchors.topMargin: cockpitRoot.m
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width * 0.8
            height: 28 * cockpitRoot.ux

            Row {
              anchors.centerIn: parent
              spacing: 18 * cockpitRoot.ux
              Repeater {
                model: 6
                delegate: Text {
                  required property int index
                  readonly property string pname: root.stats["proc" + index + "_name"] || ""
                  readonly property string pcpu: root.stats["proc" + index + "_cpu"] || ""
                  visible: pname !== ""
                  text: pname + " " + pcpu + "%"
                  color: root.cMuted
                  font.family: Style.font.family
                  font.pixelSize: 11 * cockpitRoot.ux
                }
              }
            }
          }
        }

        // ---------------------------------------------------------- right rail
        Column {
          id: rightRail
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: bottomStrip.top
          anchors.margins: cockpitRoot.m
          anchors.bottomMargin: cockpitRoot.m
          width: cockpitRoot.rightW
          spacing: cockpitRoot.m

          // GPU0 panel
          HudPanel {
            title: "GPU0 · " + root.gpu0Name
            accent: root.cMagenta
            collapsed: root.isCollapsed("gpu0")
            onToggled: root.toggleSection("gpu0")
            width: parent.width
            visible: root.gpuList.length > 0 && root.gpuList[0].kind !== "none"

            Column {
              width: parent.width
              spacing: 6 * cockpitRoot.ux

              HudRow {
                label: "PWR"
                value: root.has("i_pwr_w")
                    ? root.stats.i_pwr_w + " W" + (root.has("i_pwr_cap_w") ? " / " + root.stats.i_pwr_cap_w + "W" : "")
                    : "--"
                fraction: root.gpu0PwrFrac
                accent: root.gpu0PwrFrac >= 0.9 ? root.cAlert : root.gpu0PwrFrac >= 0.7 ? root.cAmber : root.cCyan2
              }
              HudRow { label: "PKG"; value: root.stats.i_temp_pkg + "°C"; accent: root.tempColor(root.num(root.stats.i_temp_pkg)); visible: root.has("i_temp_pkg") }
              HudRow { label: "VRAM"; value: root.stats.i_temp_vram + "°C"; accent: root.tempColor(root.num(root.stats.i_temp_vram)); visible: root.has("i_temp_vram") }
              HudRow { label: "MCTRL"; value: root.stats.i_temp_mctrl + "°C"; accent: root.tempColor(root.num(root.stats.i_temp_mctrl)); visible: root.has("i_temp_mctrl") }
              HudRow { label: "PCIE"; value: root.stats.i_temp_pcie + "°C"; accent: root.tempColor(root.num(root.stats.i_temp_pcie)); visible: root.has("i_temp_pcie") }
              HudRow { label: "VRM CH"; value: "max " + root.stats.i_vram_ch_max + "°C · avg " + root.stats.i_vram_ch_avg + "°C"; accent: root.cAmber; visible: root.has("i_vram_ch_max") }
              HudRow { label: "FAN"; value: root.stats.i_fan_rpm + " RPM"; accent: root.cCyan; visible: root.has("i_fan_rpm") }
              HudRow {
                label: "VRAM"
                value: root.num(root.stats.i_vram_used) + " / " + root.num(root.stats.i_vram_total) + " MiB"
                fraction: root.gpu0VramFrac
                accent: root.gaugeColor(root.gpu0VramFrac)
                visible: root.has("i_vram_total")
              }
              HudRow { label: "UTIL"; value: root.gpuUtilText; fraction: root.gpuUtilFrac; accent: root.gaugeColor(root.gpuUtilFrac); visible: root.hasGpuUtil }
            }
          }

          // GPU1 panel
          HudPanel {
            title: "GPU1 · " + root.gpu1Name
            accent: root.cCyan
            collapsed: root.isCollapsed("gpu1")
            onToggled: root.toggleSection("gpu1")
            width: parent.width
            visible: root.gpuList.length > 1

            Column {
              width: parent.width
              spacing: 6 * cockpitRoot.ux

              HudRow { label: "UTIL"; value: root.stats.a_util + "%"; fraction: root.num(root.stats.a_util) / 100; accent: root.gaugeColor(root.num(root.stats.a_util) / 100); visible: root.has("a_util") }
              HudRow { label: "VRAM"; value: root.stats.a_vram_used + " / " + root.stats.a_vram_total + " MiB"; fraction: root.gpu1VramFrac; accent: root.gaugeColor(root.gpu1VramFrac); visible: root.has("a_vram_total") }
              HudRow { label: "TEMP"; value: root.stats.a_temp + "°C"; accent: root.tempColor(root.num(root.stats.a_temp)); visible: root.has("a_temp") }
              HudRow { label: "PWR"; value: root.stats.a_pwr_w + " W"; accent: root.cGreen; visible: root.has("a_pwr_w") }
              HudRow { label: "FREQ"; value: root.stats.a_freq_mhz + " MHz"; accent: root.cCyan; visible: root.has("a_freq_mhz") }
            }
          }

          // STORAGE panel
          HudPanel {
            title: "STORAGE"
            accent: root.cCyan
            collapsed: root.isCollapsed("storage")
            onToggled: root.toggleSection("storage")
            width: parent.width

            Column {
              width: parent.width
              spacing: 6 * cockpitRoot.ux

              HudRow { label: root.fsLabel("root"); value: root.fsText("root"); fraction: root.fsFrac("root"); accent: root.gaugeColor(root.fsFrac("root")) }
              HudRow { label: root.fsLabel("home"); value: root.fsText("home"); fraction: root.fsFrac("home"); accent: root.gaugeColor(root.fsFrac("home")); visible: root.fsFrac("home") >= 0 && root.fsLabel("home") !== root.fsLabel("root") }
              HudRow { label: "READ"; value: root.fmtRate(root.num(root.stats.disk_read_bps)); accent: root.cAmber }
              HudRow { label: "WRITE"; value: root.fmtRate(root.num(root.stats.disk_write_bps)); accent: root.cMagenta }
            }
          }
        }

        // ---------------------------------------------------------- bottom strip
        Item {
          id: bottomStrip
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.margins: cockpitRoot.m
          height: cockpitRoot.bottomH

          Row {
            anchors.fill: parent
            spacing: cockpitRoot.m

            // NETWORK panel
            HudPanel {
              title: "NETWORK"
              accent: root.cGreen
              collapsed: root.isCollapsed("network")
              onToggled: root.toggleSection("network")
              width: parent.width * 0.35
              height: parent.height

              Column {
                width: parent.width
                spacing: 4 * cockpitRoot.ux

                HudRow { label: "▼ RX"; value: root.fmtRate(root.rxRate); accent: root.cGreen; valueColor: root.cGreen }
                HudRow { label: "▲ TX"; value: root.fmtRate(root.txRate); accent: root.cMagenta; valueColor: root.cMagenta }

                // dual sparkline
                Item {
                  width: parent.width
                  height: 40 * cockpitRoot.ux
                  Canvas {
                    anchors.fill: parent
                    onPaint: {
                      var ctx = getContext("2d")
                      ctx.reset()
                      ctx.strokeStyle = "rgba(13,74,97,0.5)"
                      ctx.lineWidth = 1
                      ctx.beginPath()
                      for (var yy = 1; yy < 3; yy++) { ctx.moveTo(0, height * yy / 3); ctx.lineTo(width, height * yy / 3) }
                      ctx.stroke()
                      var peak = 1
                      for (var i = 0; i < root.histNetRx.length; i++) if (root.histNetRx[i] > peak) peak = root.histNetRx[i]
                      peak *= 1.1
                      function line(arr, col) {
                        ctx.strokeStyle = col
                        ctx.lineWidth = 1.4
                        ctx.beginPath()
                        var started = false
                        for (var j = 0; j < arr.length; j++) {
                          var v = arr[j]
                          var x = width - (arr.length - 1 - j) * (width / 60)
                          var y = height - (v / peak) * (height - 4) - 2
                          started ? ctx.lineTo(x, y) : ctx.moveTo(x, y)
                          started = true
                        }
                        ctx.stroke()
                      }
                      line(root.histNetRx, String(root.cGreen))
                    }
                    Connections {
                      target: root
                      function onHistNetRxChanged() { requestPaint() }
                    }
                  }
                }
              }
            }

            // AGENTS panel
            HudPanel {
              title: "AGENTS"
              accent: root.cMagenta
              collapsed: root.isCollapsed("agents")
              onToggled: root.toggleSection("agents")
              width: parent.width * 0.35
              height: parent.height

              Column {
                width: parent.width
                spacing: 4 * cockpitRoot.ux

                HudRow { label: "TMUX"; value: root.has("agents_tmux") ? String(root.stats.agents_tmux) + " sessions" : "--" }
                HudRow { label: "AGENTS"; value: root.has("agents_procs") ? String(root.stats.agents_procs) + " procs" : "--" }
                HudRow { label: "LINK"; value: "ONLINE"; valueColor: root.cGreen }
              }
            }

            // status line
            HudPanel {
              title: "STATUS"
              accent: root.cCyan
              width: parent.width * 0.3 - 2 * cockpitRoot.m
              height: parent.height

              Item {
                anchors.fill: parent
                anchors.margins: 8 * cockpitRoot.ux

                Text {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: (root.alertState ? "⚠ ALERT" : "SYSTEMS NOMINAL") + "  ▮"
                  color: root.alertState ? root.cAlert : root.cGreen
                  font.family: Style.font.family
                  font.pixelSize: 12 * cockpitRoot.ux
                  font.letterSpacing: 1.5
                  opacity: root.blink ? 1.0 : 0.7
                }
              }
            }
          }
        }
      }
    }
  }

  // ---------------------------------------------------------- components
  component CornerBracket: Item {
    width: 14 * cockpitRoot.ux
    height: 14 * cockpitRoot.ux
    Rectangle { width: parent.width; height: 2; color: root.alertState ? root.cAlert : root.cCyan }
    Rectangle { width: 2; height: parent.height; color: root.alertState ? root.cAlert : root.cCyan }
  }

  component HudPanel: Item {
    id: panel
    property string title: ""
    property color accent: root.cCyan
    property bool collapsed: false
    signal toggled()
    default property alias content: inner.data

    readonly property real chamfer: 10 * cockpitRoot.ux

    implicitHeight: collapsed ? header.height : header.height + inner.implicitHeight + 8 * cockpitRoot.ux
    height: implicitHeight

    // background shape
    Shape {
      anchors.fill: parent
      ShapePath {
        fillColor: root.cPanel
        strokeColor: root.alertState ? root.cAlert : root.cHair
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

    // corner brackets
    CornerBracket { anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 2; rotation: 90 }
    CornerBracket { anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: 2; rotation: 270 }

    // header
    Item {
      id: header
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: 28 * cockpitRoot.ux

      Row {
        anchors.left: parent.left
        anchors.leftMargin: 10 * cockpitRoot.ux
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6 * cockpitRoot.ux

        Text {
          text: panel.collapsed ? "▸" : "▾"
          color: panel.accent
          font.family: Style.font.family
          font.pixelSize: 11 * cockpitRoot.ux
        }
        Text {
          text: panel.title
          color: headerMa.containsMouse ? panel.accent : root.cText
          font.family: Style.font.family
          font.pixelSize: 11 * cockpitRoot.ux
          font.bold: true
          font.letterSpacing: 2
        }
      }

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 10 * cockpitRoot.ux
        anchors.rightMargin: 10 * cockpitRoot.ux
        height: 1
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0.0; color: Util.alpha(panel.accent, 0.55) }
          GradientStop { position: 1.0; color: "transparent" }
        }
      }

      MouseArea {
        id: headerMa
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: panel.toggled()
      }
    }

    // body
    Item {
      id: inner
      anchors.top: header.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: 10 * cockpitRoot.ux
      anchors.topMargin: 4 * cockpitRoot.ux
      implicitHeight: childrenRect.height
      visible: !panel.collapsed
    }
  }

  component Sparkline: Item {
    id: spark
    property var samples: []
    property color lineColor: root.cCyan
    property string label: ""

    Rectangle {
      anchors.fill: parent
      color: Util.alpha(root.cPanel, 0.5)
      border.color: root.cHair
      border.width: 1
    }

    Text {
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.margins: 4 * cockpitRoot.ux
      text: spark.label
      color: root.cMuted
      font.family: Style.font.family
      font.pixelSize: 9 * cockpitRoot.ux
      font.letterSpacing: 1
    }

    Canvas {
      anchors.fill: parent
      anchors.margins: 2
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var arr = spark.samples
        if (arr.length < 2) return
        var peak = 1
        for (var i = 0; i < arr.length; i++) if (arr[i] > peak) peak = arr[i]
        peak *= 1.1
        ctx.strokeStyle = String(spark.lineColor)
        ctx.lineWidth = 1.4
        ctx.beginPath()
        for (var j = 0; j < arr.length; j++) {
          var x = width - (arr.length - 1 - j) * (width / 60)
          var y = height - (arr[j] / peak) * (height - 4) - 2
          j === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y)
        }
        ctx.stroke()
      }
      Connections {
        target: spark
        function onSamplesChanged() { requestPaint() }
      }
    }
  }
}
