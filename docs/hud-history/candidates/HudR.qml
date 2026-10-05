import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland
import QtQuick.Shapes
import QtQuick.Effects
import qs.Commons
import qs.Ui

// NEXUS HUD · Lane R / pass 3
// Three intentionally distinct consoles, fed by one additive-only collector:
// DP-1 mission control; DP-2 hardware telemetry; HDMI-A-3 agentic operations.
// A 30 Hz eased store drives the meters, histories, highlights and ambient field.
Item {
  id: root
  property var shell: null
  property var manifest: null

  readonly property color cCyan: "#00e5ff"
  readonly property color cGreen: "#39ff14"
  readonly property color cMagenta: "#ff2bd6"
  readonly property color cAmber: "#ffb300"
  readonly property color cAlert: "#ff3b4e"
  readonly property color cPlate: "#040e16"
  readonly property color cText: "#c9f2fb"
  readonly property color cMuted: "#5e93a6"
  readonly property color cLine: "#0d4a61"
  readonly property string collectScript: decodeURIComponent(String(Qt.resolvedUrl("collect.sh")).replace(/^file:\/\//, ""))

  property var stats: ({})
  property string hostName: ""
  property string kernelName: ""
  property var gpuList: []
  property date now: new Date()
  property var collapsedMap: ({})
  property string pendingFrame: ""
  property int batchSeq: 0
  property double lastBatchMs: 0
  property double prevIdle: -1
  property double prevTotal: -1
  property double prevRx: -1
  property double prevTx: -1
  property double lastPollMs: 0
  property real cpuPct: -1
  property real rxRate: 0
  property real txRate: 0
  property double animT: 0
  property double lastTickMs: 0
  property int tickSeq: 0
  property double batchPeriod: 1.2
  property real scrollPhase: 0
  property var histCpu: []
  property var histLoad: []
  property var histRx: []
  property var histTx: []
  property var histPsiCpu: []
  property var histPsiMem: []
  property var histPsiIo: []
  property var histDisk: []
  property var dspCpu: []
  property var dspLoad: []
  property var dspRx: []
  property var dspTx: []
  property var dspPsiCpu: []
  property var dspPsiMem: []
  property var dspPsiIo: []
  property var dspDisk: []
  property var sv: ({})

  readonly property real pulse: 0.5 + 0.5 * Math.sin(animT * 2.4)
  readonly property bool linkOk: lastBatchMs > 0 && now.getTime() - lastBatchMs < 4000
  readonly property real memFrac: {
    var t = num(stats.mem_total_kb)
    return t > 0 ? (t - num(stats.mem_avail_kb)) / t : -1
  }
  readonly property real swapFrac: num(stats.swap_total_kb) > 0
      ? (num(stats.swap_total_kb) - num(stats.swap_free_kb)) / num(stats.swap_total_kb) : -1
  readonly property int coreCount: {
    var n = 0
    while (stats["cpu_core_" + n] !== undefined) n++
    return n
  }
  readonly property int batCount: Math.max(0, Math.min(4, num(stats.bat_count)))
  readonly property int winCount: Math.max(0, num(stats.win_count))
  readonly property int wsCount: Math.max(0, num(stats.ws_count))
  readonly property int ghEvCount: Math.max(0, Math.min(8, num(stats.ghev_count)))
  readonly property int devsessCount: Math.max(0, Math.min(6, num(stats.devsess_count)))
  readonly property int tmuxCount: Math.max(0, Math.min(6, num(stats.tmux_n)))
  readonly property int ghUnread: Math.max(0, num(stats.gh_unread))
  readonly property bool ghOk: num(stats.gh_ok) > 0
  readonly property real maxTemp: {
    var keys = ["cpu_temp", "i_temp_pkg", "i_temp_vram", "i_temp_mctrl", "i_temp_pcie", "a_temp", "gpu_temp"]
    var t = -1
    for (var i = 0; i < keys.length; i++) if (has(keys[i])) t = Math.max(t, num(stats[keys[i]]))
    for (var j = 0; j < Math.min(4, num(stats.nvme_count)); j++)
      if (has("nvme" + j + "_temp")) t = Math.max(t, num(stats["nvme" + j + "_temp"]))
    return t
  }
  readonly property bool alert: maxTemp > 85 || (memFrac > 0.9)
  readonly property real alertMix: {
    var a = sv.alert
    return a === undefined || !isFinite(a) ? 0 : Math.max(0, Math.min(1, a))
  }

  function num(v) { var n = Number(v); return isFinite(n) ? n : 0 }
  function has(k) { return stats[k] !== undefined && stats[k] !== "" }
  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function ease(prev, target, k) {
    if (!isFinite(target) || target < 0) return -1
    target = clamp(target, 0, 1)
    if (prev === undefined || !isFinite(prev) || prev < 0) return 0
    return prev + (target - prev) * k
  }
  function s(k, fallback) { var v = sv[k]; return v === undefined || !isFinite(v) ? (fallback === undefined ? -1 : fallback) : v }
  function core(i) { var a = sv.core; return a && i < a.length && isFinite(a[i]) ? a[i] : 0 }
  function fmtUptime(sec) {
    var n = Math.max(0, Math.floor(num(sec))), d = Math.floor(n / 86400), h = Math.floor(n % 86400 / 3600), m = Math.floor(n % 3600 / 60)
    function p(x) { return (x < 10 ? "0" : "") + x }
    return d > 0 ? d + "d " + p(h) + "h " + p(m) + "m" : h > 0 ? h + "h " + p(m) + "m" : m + "m"
  }
  function fmtRate(v) {
    var n = Math.max(0, num(v))
    if (n >= 1073741824) return (n / 1073741824).toFixed(2) + " GB/s"
    if (n >= 1048576) return (n / 1048576).toFixed(1) + " MB/s"
    if (n >= 1024) return (n / 1024).toFixed(1) + " KB/s"
    return Math.round(n) + " B/s"
  }
  function fmtGiB(kb) { return (num(kb) / 1048576).toFixed(1) }
  function fmtAge(v) {
    var n = num(v)
    return n < 60 ? Math.round(n) + "s" : n < 3600 ? Math.round(n / 60) + "m" : n < 86400 ? Math.round(n / 3600) + "h" : Math.round(n / 86400) + "d"
  }
  function procName(i) { return has("proc" + i + "_name") ? String(stats["proc" + i + "_name"]) : "" }
  function procCpu(i) { return has("proc" + i + "_cpu") ? num(stats["proc" + i + "_cpu"]) : 0 }
  function loadText() { return has("load1") ? String(stats.load1) + " / " + String(stats.load5) + " / " + String(stats.load15) : "collector idle" }
  function cpuText() { return cpuPct >= 0 ? Math.round(cpuPct) + "%" : "--" }
  function memText() { return memFrac >= 0 ? fmtGiB(num(stats.mem_total_kb) - num(stats.mem_avail_kb)) + " / " + fmtGiB(stats.mem_total_kb) + " GB · " + Math.round(memFrac * 100) + "%" : "n/a" }
  function fsLabel(tag) { return has("fs_" + tag + "_target") ? String(stats["fs_" + tag + "_target"]) : (tag === "root" ? "/" : "/home") }
  function fsFrac(tag) { return has("fs_" + tag + "_pct") ? num(stats["fs_" + tag + "_pct"]) / 100 : -1 }
  function fsText(tag) { return fsFrac(tag) >= 0 ? Math.round(num(stats["fs_" + tag + "_pct"])) + "% · " + (num(stats["fs_" + tag + "_used"]) / 1073741824).toFixed(0) + "/" + (num(stats["fs_" + tag + "_size"]) / 1073741824).toFixed(0) + " GB" : "n/a" }
  function tempColor(t) { return num(t) >= 88 ? cAlert : num(t) >= 80 ? cAmber : cCyan }
  function heatColor(f) { return f < 0 ? cMuted : f > 0.9 ? cAlert : f > 0.7 ? cAmber : f > 0.45 ? cCyan : cGreen }
  function rgbOf(c) { return "rgb(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + ")" }
  function rgbaOf(c, a) { return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")" }
  function frac(key, total) { return num(stats[total]) > 0 ? num(stats[key]) / num(stats[total]) : -1 }
  function toggleSection(id) { var m = {}; for (var k in collapsedMap) m[k] = collapsedMap[k]; m[id] = collapsedMap[id] !== true; collapsedMap = m }
  function isCollapsed(id) { return collapsedMap[id] === true }
  readonly property var sectionIds: ["system", "memory", "gpu", "gpu2", "storage", "network", "agents", "matrix", "sensors", "periph", "windows", "repo", "procs", "launch", "actions", "traces"]
  function toggleAll() {
    var open = false
    for (var i = 0; i < sectionIds.length; i++) if (!isCollapsed(sectionIds[i])) { open = true; break }
    var m = {}; for (var k in collapsedMap) m[k] = collapsedMap[k]
    for (var j = 0; j < sectionIds.length; j++) m[sectionIds[j]] = open
    collapsedMap = m
    return open ? "collapsed" : "expanded"
  }
  function histPush(a, v) { var b = a.slice(-59); b.push(v); return b }
  function easeHist(a, target, k) {
    while (a.length > target.length) a.shift()
    while (a.length < target.length) a.push(a.length ? a[a.length - 1] : 0)
    for (var i = 0; i < a.length; i++) if (isFinite(target[i])) a[i] += (target[i] - a[i]) * k
  }
  function tick() {
    var t = Date.now(), dt = lastTickMs > 0 ? (t - lastTickMs) / 1000 : 0.033
    lastTickMs = t
    if (!(dt > 0) || dt > 0.5) dt = 0.033
    animT += dt
    scrollPhase = Math.min(1.5, scrollPhase + dt / Math.max(0.4, batchPeriod))
    var k = Math.min(1, dt * 5), o = sv, n = {}
    n.cpu = ease(o.cpu, cpuPct >= 0 ? cpuPct / 100 : -1, k)
    n.mem = ease(o.mem, memFrac, k)
    n.load = ease(o.load, has("load1") ? num(stats.load1) / Math.max(1, num(stats.cpu_count)) : -1, k)
    n.gpup = ease(o.gpup, has("i_pwr_w") && num(stats.i_pwr_cap_w) > 0 ? num(stats.i_pwr_w) / num(stats.i_pwr_cap_w) : -1, k)
    n.iutil = ease(o.iutil, has("i_util") ? num(stats.i_util) / 100 : -1, k)
    n.psi = ease(o.psi, has("psi_mem_some") ? num(stats.psi_mem_some) / 100 : -1, k)
    n.alert = (o.alert || 0) + ((alert ? 1 : 0) - (o.alert || 0)) * Math.min(1, dt * 2.4)
    var cores = new Array(coreCount)
    for (var i = 0; i < coreCount; i++) {
      var target = clamp(num(stats["cpu_core_" + i]) / 100, 0, 1), prev = o.core && o.core[i] !== undefined ? o.core[i] : 0
      cores[i] = prev + (target - prev) * k
    }
    n.core = cores
    sv = n
    easeHist(dspCpu, histCpu, k); easeHist(dspLoad, histLoad, k)
    easeHist(dspRx, histRx, k); easeHist(dspTx, histTx, k); easeHist(dspDisk, histDisk, k)
    easeHist(dspPsiCpu, histPsiCpu, k); easeHist(dspPsiMem, histPsiMem, k); easeHist(dspPsiIo, histPsiIo, k)
    tickSeq++
  }
  function applyProbe(text) {
    var lines = String(text || "").split("\n"), g = {}
    for (var i = 0; i < lines.length; i++) {
      var p = lines[i].indexOf("\t"); if (p <= 0) continue
      var key = lines[i].substr(0, p), val = lines[i].substr(p + 1)
      if (key === "host") hostName = val
      else if (key === "kernel") kernelName = val
      else {
        var m = /^gpu(\d+)_(kind|name)$/.exec(key)
        if (m) { if (!g[m[1]]) g[m[1]] = {}; g[m[1]][m[2]] = val }
      }
    }
    var a = []; for (var j in g) a.push({ kind: g[j].kind || "", name: g[j].name || "" })
    gpuList = a
  }
  function applyFrame(text) {
    var m = {}, lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) { var p = lines[i].indexOf("\t"); if (p > 0) m[lines[i].substr(0, p)] = lines[i].substr(p + 1) }
    var t = Date.now(), dt = lastPollMs > 0 ? (t - lastPollMs) / 1000 : 0
    if (dt > 0.2 && dt < 8) batchPeriod = batchPeriod * 0.75 + dt * 0.25
    scrollPhase = 0
    var idle = num(m.cpu_idle), total = num(m.cpu_total)
    if (prevTotal >= 0 && total > prevTotal) cpuPct = clamp(100 * (1 - (idle - prevIdle) / (total - prevTotal)), 0, 100)
    prevIdle = idle; prevTotal = total
    var rx = num(m.net_rx), tx = num(m.net_tx)
    if (prevRx >= 0 && dt > 0) { rxRate = Math.max(0, (rx - prevRx) / dt); txRate = Math.max(0, (tx - prevTx) / dt) }
    prevRx = rx; prevTx = tx; lastPollMs = t
    histCpu = histPush(histCpu, cpuPct >= 0 ? cpuPct : 0)
    histLoad = histPush(histLoad, num(m.load1))
    histRx = histPush(histRx, rxRate); histTx = histPush(histTx, txRate)
    histDisk = histPush(histDisk, num(m.disk_read_bps))
    histPsiCpu = histPush(histPsiCpu, num(m.psi_cpu_some))
    histPsiMem = histPush(histPsiMem, num(m.psi_mem_some))
    histPsiIo = histPush(histPsiIo, num(m.psi_io_some))
    stats = m
  }
  function refresh() { if (!streamProc.running) streamProc.running = true }

  Timer { interval: 33; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.tick() }
  Timer { interval: 1000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.now = new Date() }
  Timer { interval: 4000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
  Timer { interval: 300000; running: true; repeat: true; triggeredOnStart: true; onTriggered: if (!probeProc.running) probeProc.running = true }
  Process {
    id: probeProc; running: true; command: ["bash", root.collectScript, "probe"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyProbe(text) }
  }
  Process {
    id: streamProc; running: true; command: ["bash", root.collectScript, "stream", "auto"]
    stdout: SplitParser {
      onRead: data => {
        var line = String(data)
        if (line.indexOf("batch\t") === 0) {
          var seq = parseInt(line.substring(6)); if (isFinite(seq)) root.batchSeq = seq
          root.applyFrame(root.pendingFrame); root.pendingFrame = ""; root.lastBatchMs = Date.now()
        } else root.pendingFrame += line + "\n"
      }
    }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (String(text).trim() !== "") console.warn("nexuslink.hud:", String(text).trim()) }
  }
  IpcHandler {
    target: "nexuslink.hud"
    function toggleAll(): string { return root.toggleAll() }
    function refresh(): string { root.refresh(); return "ok" }
    function section(id: string): string { root.toggleSection(id); return "ok" }
    function status(): string { return JSON.stringify({ cpu: root.cpuText(), mem: root.memText(), rx: root.fmtRate(root.rxRate), tx: root.fmtRate(root.txRate), frame: root.batchSeq, alert: root.alert }) }
    function stats(): string { return JSON.stringify({ cpu: root.cpuText(), mem: root.memText(), uptime: root.fmtUptime(root.stats.uptime_s), frame: root.batchSeq, alert: root.alert }) }
  }

  component Label: Text {
    color: root.cText
    font.family: "monospace"
    font.pixelSize: 11
    elide: Text.ElideRight
  }
  component Panel: Item {
    id: panel
    property string title: ""
    property string meta: ""
    property color accent: root.cCyan
    property real ux: 1
    property real bodyH: 100
    property string sectionId: ""
    readonly property bool folded: sectionId !== "" && root.isCollapsed(sectionId)
    property bool collapsible: true
    default property alias body: bodyItem.data
    height: head.height + (folded ? 0 : bodyH + 10 * ux)
    clip: true
    Rectangle { anchors.fill: parent; color: "#d9040e16"; border.color: panel.folded ? root.cLine : panel.accent; border.width: 1 }
    Rectangle { x: 0; y: 0; width: 3 * panel.ux; height: parent.height; color: panel.accent; opacity: 0.8 }
    Item {
      id: head
      x: 10 * panel.ux; y: 2 * panel.ux; width: parent.width - 20 * panel.ux; height: 25 * panel.ux
      Label { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: (panel.collapsible ? (panel.folded ? "▸ " : "▾ ") : "") + panel.title; color: panel.accent; font.bold: true; font.pixelSize: 10 * panel.ux; font.letterSpacing: 1.2 * panel.ux }
      Label { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; width: parent.width * 0.45; text: panel.meta; color: root.cMuted; font.pixelSize: 8 * panel.ux; horizontalAlignment: Text.AlignRight }
      MouseArea { anchors.fill: parent; enabled: panel.collapsible && panel.sectionId !== ""; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleSection(panel.sectionId) }
    }
    Item { id: bodyItem; x: 10 * panel.ux; y: head.height + 5 * panel.ux; width: parent.width - 20 * panel.ux; height: panel.bodyH; visible: !panel.folded; clip: true }
    Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
  }
  component CommandChip: Rectangle {
    id: chip
    property string label: "OPEN"
    property string glyph: "›"
    property color accent: root.cCyan
    property var argv: []
    property real ux: 1
    width: Math.max(78 * ux, labelText.implicitWidth + 25 * ux); height: 26 * ux
    color: hit.containsMouse ? Qt.rgba(accent.r, accent.g, accent.b, 0.18) : Qt.rgba(accent.r, accent.g, accent.b, 0.06)
    border.color: hit.containsMouse ? accent : Qt.rgba(accent.r, accent.g, accent.b, 0.42); border.width: 1
    Row { anchors.centerIn: parent; spacing: 5 * chip.ux; Label { text: chip.glyph; color: chip.accent; font.bold: true; font.pixelSize: 10 * chip.ux }; Label { id: labelText; text: chip.label; color: root.cText; font.bold: true; font.pixelSize: 8 * chip.ux; font.letterSpacing: 0.5 * chip.ux } }
    Process { id: p; command: chip.argv.length ? chip.argv : ["true"]; running: false; onExited: running = false }
    MouseArea { id: hit; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { p.running = false; p.running = true } }
  }
  component Meter: Item {
    id: meter
    property string label: "CPU"
    property string value: "--"
    property real amount: -1
    property color accent: root.cCyan
    property real ux: 1
    property bool second: false
    property string valueKey: "cpu"
    property string secondKey: "mem"
    property string secondLabel: "MEM"
    property real amount2: -1
    property color accent2: root.cMagenta
    width: 112 * ux; height: width
    Canvas {
      id: face; anchors.fill: parent
      onWidthChanged: requestPaint(); onHeightChanged: requestPaint()
      Connections { target: root; function onTickSeqChanged() { face.requestPaint() } }
      onPaint: {
        var c = getContext("2d"); c.reset(); var cx = width / 2, cy = height / 2, r = Math.min(width, height) * 0.40
        function arc(v, color, radius, line) {
          c.beginPath(); c.strokeStyle = "rgba(13,74,97,0.78)"; c.lineWidth = line; c.arc(cx, cy, radius, -Math.PI * 0.75, Math.PI * 0.75); c.stroke()
          if (v >= 0) { c.beginPath(); c.strokeStyle = root.rgbaOf(color, 0.22); c.lineWidth = line * 2.6; c.arc(cx, cy, radius, -Math.PI * 0.75, -Math.PI * 0.75 + Math.PI * 1.5 * Math.min(1, v)); c.stroke(); c.beginPath(); c.strokeStyle = root.rgbOf(color); c.lineWidth = line; c.arc(cx, cy, radius, -Math.PI * 0.75, -Math.PI * 0.75 + Math.PI * 1.5 * Math.min(1, v)); c.stroke() }
        }
        arc(root.s(meter.valueKey), meter.accent, r, Math.max(3, width * 0.055))
        if (meter.second) arc(root.s(meter.secondKey), meter.accent2, r * 0.78, Math.max(2, width * 0.035))
        c.strokeStyle = "rgba(0,229,255,0.25)"; c.lineWidth = 1
        for (var i = 0; i <= 20; i++) { var a = -Math.PI * .75 + Math.PI * 1.5 * i / 20; var rr = r * 1.16; c.beginPath(); c.moveTo(cx + Math.cos(a) * rr, cy + Math.sin(a) * rr); c.lineTo(cx + Math.cos(a) * (rr + (i % 5 === 0 ? 5 : 2)), cy + Math.sin(a) * (rr + (i % 5 === 0 ? 5 : 2))); c.stroke() }
      }
    }
    Column { anchors.centerIn: parent; spacing: 2; Label { anchors.horizontalCenter: parent.horizontalCenter; text: meter.label; color: root.cMuted; font.pixelSize: 8 * meter.ux; font.letterSpacing: 1.2 * meter.ux }; Label { anchors.horizontalCenter: parent.horizontalCenter; text: meter.value; color: meter.accent; font.bold: true; font.pixelSize: 21 * meter.ux }; Label { visible: meter.second; anchors.horizontalCenter: parent.horizontalCenter; text: meter.secondLabel + " " + (root.s(meter.secondKey) >= 0 ? Math.round(root.s(meter.secondKey) * 100) + "%" : "—"); color: meter.accent2; font.pixelSize: 8 * meter.ux } }
  }
  component Trace: Canvas {
    id: trace
    property var points: []
    property var points2: []
    property color color1: root.cCyan
    property color color2: root.cMagenta
    property real scaleMax: 0
    property bool split: false
    onWidthChanged: requestPaint(); onHeightChanged: requestPaint()
    Connections { target: root; function onTickSeqChanged() { if (trace.visible) trace.requestPaint() } }
    onPaint: {
      var c = getContext("2d"); c.reset(); if (width < 2 || height < 2) return
      c.strokeStyle = "rgba(13,74,97,0.50)"; c.lineWidth = 1
      c.beginPath(); for (var g = 1; g < 4; g++) { var x = Math.floor(width * g / 4) + .5; c.moveTo(x, 0); c.lineTo(x, height) }; c.moveTo(0, height / 2); c.lineTo(width, height / 2); c.stroke()
      function series(a, col, down) {
        if (!a || !a.length) return
        var max = trace.scaleMax
        if (!(max > 0)) { for (var j = 0; j < a.length; j++) max = Math.max(max, isFinite(a[j]) ? a[j] : 0); max = Math.max(1, max * 1.18) }
        c.beginPath(); c.strokeStyle = root.rgbOf(col); c.lineWidth = 1.7; c.lineJoin = "round"
        var started = false
        for (var i = 0; i < a.length; i++) {
          var px = width - (a.length - 1 - i + root.scrollPhase) * width / 59
          var f = Math.max(0, Math.min(1, a[i] / max)), py = down ? height * .5 + f * (height * .44) : height - 3 - f * (height - 7)
          if (!started) { c.moveTo(px, py); started = true } else c.lineTo(px, py)
        }
        c.stroke()
        if (started) { c.fillStyle = root.rgbOf(col); c.beginPath(); c.arc(width - root.scrollPhase * width / 59, down ? height * .5 + Math.max(0, Math.min(1, a[a.length - 1] / max)) * height * .44 : height - 3 - Math.max(0, Math.min(1, a[a.length - 1] / max)) * (height - 7), 2, 0, Math.PI * 2); c.fill() }
      }
      series(points, color1, false)
      if (split) { c.strokeStyle = "rgba(255,255,255,0.15)"; c.beginPath(); c.moveTo(0, height * .5); c.lineTo(width, height * .5); c.stroke(); series(points2, color2, true) }
    }
  }
  component HeatCell: Rectangle {
    property real load: 0
    property string label: ""
    property real ux: 1
    color: root.heatColor(load)
    opacity: 0.22 + 0.78 * Math.max(0.15, load)
    border.color: Qt.rgba(0.82, 0.96, 1, 0.32); border.width: 1; radius: 2 * ux
    Label { anchors.centerIn: parent; text: parent.label; color: root.cPlate; font.pixelSize: 7 * parent.ux; font.bold: true; visible: parent.width > 23 * parent.ux }
    Behavior on color { ColorAnimation { duration: 220 } }
  }
  component DataRow: Item {
    id: row
    property string label: ""
    property string value: ""
    property color accent: root.cCyan
    property real amount: -1
    property real ux: 1
    width: parent ? parent.width : 0; height: 20 * ux
    Label { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; width: parent.width * 0.31; text: row.label; color: root.cMuted; font.pixelSize: 8 * row.ux; font.letterSpacing: .3 * row.ux }
    Rectangle { visible: row.amount >= 0; x: parent.width * .34; y: parent.height * .43; width: parent.width * .27; height: 4 * row.ux; color: "#173240"; Rectangle { width: parent.width * root.clamp(row.amount, 0, 1); height: parent.height; color: row.accent; Behavior on width { NumberAnimation { duration: 300 } } } }
    Label { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; width: parent.width * .36; text: row.value; color: row.accent; font.pixelSize: 8 * row.ux; horizontalAlignment: Text.AlignRight }
  }

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
      readonly property string role: String(modelData.name) === "DP-2" ? "hardware" : String(modelData.name) === "HDMI-A-3" ? "ops" : "command"
      readonly property bool isCommand: role === "command"
      readonly property bool isHardware: role === "hardware"
      readonly property bool isOps: role === "ops"
      readonly property real ux: Math.max(.65, Math.min(width / 1600, height / 900))
      readonly property real pad: 22 * ux
      readonly property real gap: 12 * ux
      readonly property real headY: 74 * ux
      readonly property real footH: 76 * ux
      readonly property real contentY: headY
      readonly property real contentH: height - headY - footH - 3 * gap
      readonly property string roleName: isCommand ? "MISSION CONTROL" : isHardware ? "HARDWARE TELEMETRY" : "AGENTIC OPERATIONS"
      property var activeMonitor: {
        try { return Hyprland.monitorFor(modelData) } catch (e) { return null }
      }
      readonly property int activeWsId: activeMonitor && activeMonitor.activeWorkspace ? activeMonitor.activeWorkspace.id : -99999
      readonly property string activeWs: activeMonitor && activeMonitor.activeWorkspace ? String(activeMonitor.activeWorkspace.name) : "—"

      mask: Region {
        regions: [Region { item: titlePlate }, Region { item: win.isCommand ? alertZone : null },
          Region { item: win.isCommand ? clockPanel : null }, Region { item: win.isCommand ? dialsPanel : null },
          Region { item: win.isCommand ? netPanel : null }, Region { item: win.isCommand ? historyPanel : null },
          Region { item: win.isCommand ? agentMiniPanel : null }, Region { item: win.isCommand ? overviewStatus : null },
          Region { item: win.isCommand ? launchPanel : null },
          Region { item: win.isHardware ? corePanel : null }, Region { item: win.isHardware ? gpuPanel : null },
          Region { item: win.isHardware ? storagePanel : null }, Region { item: win.isHardware ? sensorPanel : null },
          Region { item: win.isHardware ? resourcePanel : null },
          Region { item: win.isOps ? navPanel : null }, Region { item: win.isOps ? procPanel : null },
          Region { item: win.isOps ? agentsPanel : null }, Region { item: win.isOps ? repoPanel : null },
          Region { item: win.isOps ? launchOps : null }, Region { item: footerPanel }]
      }
      ScreenMoveRemap { id: remapGuard; window: win }
      ShaderEffect {
        id: ambientField; anchors.fill: parent
        readonly property real uTime: root.animT
        readonly property real uLoad: Math.max(0, root.s("cpu", 0))
        readonly property real uMem: Math.max(0, root.s("mem", 0))
        readonly property real uAlert: root.alertMix
        readonly property real uPulse: root.pulse
        readonly property vector2d uRes: Qt.vector2d(Math.max(1, width), Math.max(1, height))
        fragmentShader: "ambient.qsb"
      }
      Rectangle { anchors.fill: parent; anchors.margins: win.pad; color: "transparent"; border.color: Qt.rgba(root.cCyan.r, root.cCyan.g, root.cCyan.b, .30); border.width: 1 }
      Rectangle { anchors.fill: parent; anchors.margins: win.pad + 5 * win.ux; color: "transparent"; border.color: Qt.rgba(root.cLine.r, root.cLine.g, root.cLine.b, .32); border.width: 1 }
      Item {
        id: titlePlate; y: win.pad + 5 * win.ux; width: titleRow.implicitWidth + 26 * win.ux; height: 32 * win.ux; anchors.horizontalCenter: parent.horizontalCenter
        Rectangle { anchors.fill: parent; color: root.cPlate; border.color: root.cCyan; border.width: 1 }
        Row { id: titleRow; anchors.centerIn: parent; spacing: 12 * win.ux
          Label { text: "NEXUS // " + (root.hostName || "SYSTEM"); color: root.cCyan; font.bold: true; font.pixelSize: 12 * win.ux; font.letterSpacing: 1.4 * win.ux }
          Label { text: win.roleName; color: win.isHardware ? root.cAmber : win.isOps ? root.cGreen : root.cText; font.bold: true; font.pixelSize: 9 * win.ux; font.letterSpacing: 1.2 * win.ux }
          Label { text: String(win.modelData.name); color: root.cMuted; font.pixelSize: 8 * win.ux }
        }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleAll() }
      }

      // The primary screen is intentionally dense: command rhythm and live
      // readiness, not repeated hardware sheets. Each instrument has a distinct form.
      Item {
        id: alertZone; visible: win.isCommand; x: win.pad; y: win.headY; width: parent.width - 2 * win.pad; height: 36 * win.ux
        Rectangle { anchors.fill: parent; color: root.alert ? Qt.rgba(1, .12, .19, .10 + .10 * root.pulse) : Qt.rgba(0, .9, 1, .035); border.color: root.alert ? root.cAlert : root.cLine; border.width: 1; Behavior on color { ColorAnimation { duration: 160 } } }
        Row { anchors.fill: parent; anchors.leftMargin: 12 * win.ux; anchors.rightMargin: 12 * win.ux; spacing: 12 * win.ux
          Label { anchors.verticalCenter: parent.verticalCenter; text: root.alert ? "▲ ALERT / THRESHOLD EXCEEDED" : root.linkOk ? "● SYSTEM NOMINAL" : "◇ COLLECTOR LINK LOST"; color: root.alert ? root.cAlert : root.linkOk ? root.cGreen : root.cAmber; font.bold: true; font.pixelSize: 9 * win.ux; font.letterSpacing: 1 * win.ux; opacity: root.alert ? .55 + .45 * root.pulse : 1 }
          Label { anchors.verticalCenter: parent.verticalCenter; text: root.alert ? "Peak sensor " + Math.round(root.maxTemp) + "°C · memory " + Math.round(root.memFrac * 100) + "%" : "STREAM " + (root.linkOk ? "LIVE" : "WAITING") + " · FRAME " + root.batchSeq; color: root.cText; font.pixelSize: 8 * win.ux }
          Item { width: 1; height: 1 }
          Label { anchors.verticalCenter: parent.verticalCenter; text: Qt.formatDateTime(root.now, "ddd dd MMM · HH:mm:ss"); color: root.cCyan; font.pixelSize: 9 * win.ux }
        }
      }

      Item {
        id: commandPage; visible: win.isCommand; x: win.pad; y: win.headY + 44 * win.ux; width: parent.width - 2 * win.pad; height: win.contentH - 44 * win.ux
        readonly property real colGap: 10 * win.ux
        // Mission panel row
        Panel { id: clockPanel; x: 0; y: 0; width: commandPage.width * .275; ux: win.ux; title: "FLIGHT CLOCK / LOAD"; sectionId: "system"; meta: root.linkOk ? "LIVE" : "STALE"; accent: root.cCyan; bodyH: 132 * win.ux
          Column { anchors.fill: parent; spacing: 5 * win.ux
            Label { text: Qt.formatDateTime(root.now, "HH:mm:ss"); color: "#eafcff"; font.bold: true; font.pixelSize: 32 * win.ux; font.letterSpacing: 1 * win.ux }
            Row { spacing: 18 * win.ux; Label { text: "UP " + root.fmtUptime(root.stats.uptime_s); color: root.cGreen; font.pixelSize: 9 * win.ux }; Label { text: "UTC " + Qt.formatDateTime(root.now, "ddd dd MMM"); color: root.cMuted; font.pixelSize: 8 * win.ux } }
            Rectangle { width: parent.width; height: 1; color: root.cLine }
            Row { spacing: 7 * win.ux; Label { text: "LOAD"; color: root.cMuted; font.pixelSize: 8 * win.ux }; Label { text: root.loadText(); color: root.cAmber; font.bold: true; font.pixelSize: 11 * win.ux }; Label { text: (root.has("cpu_count") ? String(root.stats.cpu_count) : "--") + " THREADS"; color: root.cMuted; font.pixelSize: 7 * win.ux } }
            Label { text: "KERNEL  " + (root.kernelName || "probe pending"); color: root.cMuted; font.pixelSize: 7 * win.ux }
          }
        }
        Panel { id: dialsPanel; x: clockPanel.x + clockPanel.width + commandPage.colGap; y: 0; width: commandPage.width * .37; ux: win.ux; title: "SYSTEM CAPACITY"; sectionId: "memory"; meta: "CPU + MEMORY"; accent: root.cGreen; bodyH: 132 * win.ux
          Row { anchors.centerIn: parent; spacing: 12 * win.ux
            Meter { ux: win.ux; label: "CPU"; value: root.cpuText(); amount: root.s("cpu"); accent: root.cCyan; second: true; amount2: root.s("mem"); accent2: root.cGreen }
          }
        }
        Panel { id: netPanel; x: dialsPanel.x + dialsPanel.width + commandPage.colGap; y: 0; width: commandPage.width - netPanel.x; ux: win.ux; title: "NETWORK / THROUGHPUT"; sectionId: "network"; meta: "RX ↑  ·  TX ↓"; accent: root.cGreen; bodyH: 132 * win.ux
          Column { anchors.fill: parent; spacing: 4 * win.ux
            Row { width: parent.width; height: 38 * win.ux; spacing: 7 * win.ux
              Rectangle { width: (parent.width - parent.spacing) / 2; height: parent.height; color: Qt.rgba(0.22, 1, .08, .08); border.color: Qt.rgba(0.22, 1, .08, .28); Label { anchors.left: parent.left; anchors.leftMargin: 7 * win.ux; anchors.top: parent.top; text: "RX / IN"; color: root.cMuted; font.pixelSize: 7 * win.ux }; Label { anchors.left: parent.left; anchors.leftMargin: 7 * win.ux; anchors.bottom: parent.bottom; text: root.fmtRate(root.rxRate); color: root.cGreen; font.bold: true; font.pixelSize: 11 * win.ux } }
              Rectangle { width: (parent.width - parent.spacing) / 2; height: parent.height; color: Qt.rgba(1, .17, .84, .06); border.color: Qt.rgba(1, .17, .84, .26); Label { anchors.left: parent.left; anchors.leftMargin: 7 * win.ux; anchors.top: parent.top; text: "TX / OUT"; color: root.cMuted; font.pixelSize: 7 * win.ux }; Label { anchors.left: parent.left; anchors.leftMargin: 7 * win.ux; anchors.bottom: parent.bottom; text: root.fmtRate(root.txRate); color: root.cMagenta; font.bold: true; font.pixelSize: 11 * win.ux } }
            }
            Trace { width: parent.width; height: parent.height - 44 * win.ux; points: root.dspRx; points2: root.dspTx; split: true; color1: root.cGreen; color2: root.cMagenta }
          }
        }
        // Distinct ticker histories and operational side panels fill the rest.
        Panel { id: historyPanel; x: 0; y: clockPanel.height + commandPage.colGap; width: commandPage.width * .34; height: (commandPage.height - y - 2 * commandPage.colGap) * .57; ux: win.ux; title: "LOAD / SIGNAL TAPE"; sectionId: "traces"; meta: "60-SAMPLE ROLLING"; accent: root.cAmber; bodyH: height - 36 * win.ux
          Column { anchors.fill: parent; spacing: 8 * win.ux
            Row { width: parent.width; height: 18 * win.ux; spacing: 6 * win.ux; Label { text: "LOAD1"; color: root.cMuted; font.pixelSize: 8 * win.ux }; Label { text: root.has("load1") ? String(root.stats.load1) : "—"; color: root.cAmber; font.bold: true; font.pixelSize: 9 * win.ux }; Label { text: "CPU"; color: root.cMuted; font.pixelSize: 8 * win.ux }; Label { text: root.cpuText(); color: root.cCyan; font.bold: true; font.pixelSize: 9 * win.ux } }
            // tick-tape: each cell is an eased load sample, not a generic progress bar
            Row { width: parent.width; height: 23 * win.ux; spacing: 2 * win.ux
              Repeater { model: 40; delegate: Rectangle { required property int index; width: (historyPanel.width - 50 * win.ux) / 40; height: 23 * win.ux; anchors.bottom: parent.bottom; color: root.heatColor(root.histLoad.length > 0 ? root.clamp(root.histLoad[Math.max(0, root.histLoad.length - 40 + index)] / Math.max(1, root.num(root.stats.cpu_count)), 0, 1) : -1); opacity: .18 + .82 * ((index + root.tickSeq / 8) % 9) / 9; border.color: Qt.rgba(0.8, 1, 1, .18); border.width: 1 } }
            }
            Label { text: "LOAD AVERAGE / 1-MINUTE TREND"; color: root.cMuted; font.pixelSize: 7 * win.ux; font.letterSpacing: 1 * win.ux }
            Trace { width: parent.width; height: Math.max(28 * win.ux, parent.height - 67 * win.ux); points: root.dspLoad; color1: root.cAmber }
            Row { width: parent.width; spacing: 8 * win.ux; Label { text: "5M " + (root.has("load5") ? root.stats.load5 : "—"); color: root.cMuted; font.pixelSize: 8 * win.ux }; Label { text: "15M " + (root.has("load15") ? root.stats.load15 : "—"); color: root.cMuted; font.pixelSize: 8 * win.ux } }
          }
        }
        Panel { id: agentMiniPanel; x: historyPanel.x + historyPanel.width + commandPage.colGap; y: historyPanel.y; width: commandPage.width * .38; height: historyPanel.height; ux: win.ux; title: "AGENT ACTIVITY"; sectionId: "agents"; meta: agentLiveCount + " LIVE"; accent: root.cMagenta; bodyH: height - 36 * win.ux
          readonly property int agentLiveCount: { var n = 0; var hs = ["devin", "opencode", "hermes", "october", "claude", "codex", "haze", "build"]; for (var i = 0; i < hs.length; i++) n += root.num(root.stats["ag_" + hs[i] + "_procs"]) > 0 ? 1 : 0; return n }
          Grid { anchors.fill: parent; columns: 4; rows: 2; columnSpacing: 5 * win.ux; rowSpacing: 5 * win.ux
            Repeater { model: ["devin", "opencode", "hermes", "october", "claude", "codex", "haze", "build"]; delegate: Rectangle { required property string modelData; width: (agentMiniPanel.width - 55 * win.ux) / 4; height: (agentMiniPanel.bodyH - 8 * win.ux) / 2; property int count: root.num(root.stats["ag_" + modelData + "_procs"]); color: count > 0 ? Qt.rgba(1, .17, .84, .12 + .12 * root.pulse) : Qt.rgba(.4, .58, .65, .035); border.color: count > 0 ? root.cMagenta : root.cLine; border.width: 1; Label { anchors.left: parent.left; anchors.leftMargin: 5 * win.ux; anchors.top: parent.top; anchors.topMargin: 4 * win.ux; text: modelData.toUpperCase(); color: parent.count > 0 ? root.cMagenta : root.cMuted; font.bold: true; font.pixelSize: 7 * win.ux }; Label { anchors.left: parent.left; anchors.leftMargin: 5 * win.ux; anchors.bottom: parent.bottom; anchors.bottomMargin: 4 * win.ux; text: parent.count > 0 ? parent.count + " PROCESS" : "STANDBY"; color: parent.count > 0 ? root.cText : root.cMuted; font.pixelSize: 7 * win.ux } } }
          }
        }
        Panel { id: overviewStatus; x: agentMiniPanel.x + agentMiniPanel.width + commandPage.colGap; y: historyPanel.y; width: commandPage.width - overviewStatus.x; height: historyPanel.height; ux: win.ux; title: "MISSION LOG"; collapsible: false; meta: "FRAME " + root.batchSeq; accent: root.cCyan; bodyH: height - 36 * win.ux
          Column { anchors.fill: parent; spacing: 7 * win.ux
            Label { width: parent.width; text: "OUT  " + String(win.modelData.name) + "   ·   WS " + win.activeWs; color: root.cText; font.pixelSize: 8 * win.ux }
            Label { width: parent.width; text: "SESSION  " + root.fmtUptime(root.stats.uptime_s) + "   ·   " + (root.linkOk ? "TELEMETRY ONLINE" : "COLLECTOR IDLE"); color: root.cGreen; font.pixelSize: 8 * win.ux }
            Rectangle { width: parent.width; height: 1; color: root.cLine }
            Label { width: parent.width; text: root.alert ? "CHECK ALERT BANNER" : "NO ACTIVE SYSTEM ALERTS"; color: root.alert ? root.cAlert : root.cMuted; font.pixelSize: 8 * win.ux; font.bold: root.alert }
            Label { width: parent.width; text: "HOST / " + (root.hostName || "probing") + "\nKERNEL / " + (root.kernelName || "probing"); color: root.cMuted; font.pixelSize: 7 * win.ux; lineHeight: 1.2; wrapMode: Text.Wrap }
          }
        }
        Panel { id: launchPanel; x: 0; y: agentMiniPanel.y + agentMiniPanel.height + commandPage.colGap; width: commandPage.width; height: Math.max(54 * win.ux, commandPage.height - y); ux: win.ux; title: "LAUNCH RAIL / QUICK ACTIONS"; sectionId: "launch"; meta: "DETACHED DISPATCH"; accent: root.cCyan; bodyH: height - 36 * win.ux
          Flow { anchors.fill: parent; spacing: 6 * win.ux
            CommandChip { ux: win.ux; label: "DEVIN"; glyph: "◆"; accent: root.cMagenta; argv: ["gtk-launch", "devin-desktop"] }
            CommandChip { ux: win.ux; label: "OCTOBER"; glyph: "◉"; accent: root.cCyan; argv: ["gtk-launch", "october"] }
            CommandChip { ux: win.ux; label: "TERMINAL"; glyph: "›"; accent: root.cGreen; argv: ["gtk-launch", "foot"] }
            CommandChip { ux: win.ux; label: "FILES"; glyph: "▣"; accent: root.cAmber; argv: ["gtk-launch", "org.gnome.Nautilus"] }
            CommandChip { ux: win.ux; label: "WEB"; glyph: "◎"; accent: root.cCyan; argv: ["gtk-launch", "chromium"] }
            CommandChip { ux: win.ux; label: "MUSIC"; glyph: "♫"; accent: root.cGreen; argv: ["gtk-launch", "spotify"] }
            CommandChip { ux: win.ux; label: "COFFEE"; glyph: "◐"; accent: root.cAmber; argv: ["omarchy-shell", "idle", "toggle"] }
            CommandChip { ux: win.ux; label: "NIGHTLIGHT"; glyph: "☾"; accent: root.cCyan; argv: ["omarchy-shell", "nightlight", "toggle"] }
            CommandChip { ux: win.ux; label: "LOCK"; glyph: "⏻"; accent: root.cAlert; argv: ["omarchy-shell", "lock", "lock"] }
          }
        }
      }

      // DP-2 owns every detailed silicon, core, memory, and storage reading.
      Item {
        id: hardwarePage; visible: win.isHardware; x: win.pad; y: win.contentY; width: parent.width - 2 * win.pad; height: win.contentH
        readonly property real colGap: 10 * win.ux
        Panel { id: corePanel; x: 0; y: 0; width: hardwarePage.width * .30; height: hardwarePage.height * .46; ux: win.ux; title: "CPU CORE LOAD HEATMAP"; sectionId: "matrix"; meta: root.coreCount + " CORES"; accent: root.cCyan; bodyH: height - 38 * win.ux
          Column { anchors.fill: parent; spacing: 6 * win.ux
            Row { width: parent.width; height: 18 * win.ux; spacing: 10 * win.ux; Label { text: "CPU " + root.cpuText(); color: root.cCyan; font.bold: true; font.pixelSize: 10 * win.ux }; Label { text: root.has("cpu_temp") ? Math.round(root.num(root.stats.cpu_temp)) + "°C" : "TEMP —"; color: root.tempColor(root.stats.cpu_temp); font.pixelSize: 9 * win.ux }; Label { text: "CLK " + (root.has("cpu_mhz_avg") ? Math.round(root.num(root.stats.cpu_mhz_avg)) + " / " + Math.round(root.num(root.stats.cpu_mhz_max)) + " MHz" : "—"); color: root.cMuted; font.pixelSize: 7 * win.ux } }
            Grid { width: parent.width; height: parent.height - 53 * win.ux; columns: Math.max(4, Math.ceil(Math.sqrt(root.coreCount))); rowSpacing: 5 * win.ux; columnSpacing: 5 * win.ux
              Repeater { model: root.coreCount; delegate: HeatCell { required property int index; ux: win.ux; width: (corePanel.width - 50 * win.ux) / Math.max(4, Math.ceil(Math.sqrt(root.coreCount))); height: Math.max(22 * win.ux, (corePanel.bodyH - 100 * win.ux) / Math.max(1, Math.ceil(root.coreCount / Math.max(4, Math.ceil(Math.sqrt(root.coreCount)))))); load: root.core(index); label: "C" + index + " " + Math.round(root.core(index) * 100) } }
            }
            Trace { width: parent.width; height: Math.max(30 * win.ux, 35 * win.ux); points: root.dspCpu; scaleMax: 100; color1: root.cCyan }
          }
        }
        Panel { id: gpuPanel; x: corePanel.x + corePanel.width + hardwarePage.colGap; y: 0; width: hardwarePage.width * .42; height: hardwarePage.height; ux: win.ux; title: "GPU SENSOR SHEETS"; sectionId: "gpu"; meta: "ALL GPU KEYS · HARDWARE HOME"; accent: root.cMagenta; bodyH: height - 38 * win.ux
          Flickable { anchors.fill: parent; contentWidth: width; contentHeight: gpuSheets.implicitHeight; clip: true
            Column { id: gpuSheets; width: parent.width; spacing: 8 * win.ux
              Label { text: (root.gpuList.length ? "GPU0 · " + root.gpuList[0].name : "GPU0 · DISCRETE") + (root.has("i_pwr_w") ? " · " + root.stats.i_pwr_w + " W" : ""); color: root.cMagenta; font.bold: true; font.pixelSize: 9 * win.ux }
              Row { width: parent.width; spacing: 8 * win.ux
                Column { width: parent.width * .49; spacing: 3 * win.ux
                  Meter { ux: win.ux; width: 88 * win.ux; height: width; x: (parent.width - width) / 2; label: "GPU PWR"; value: root.has("i_pwr_w") ? Math.round(root.num(root.stats.i_pwr_w)) + "W" : "—"; valueKey: "gpup"; accent: root.cMagenta; second: true; secondKey: "iutil"; secondLabel: "UTIL"; accent2: root.cCyan }
                  DataRow { ux: win.ux; label: "POWER / CAP"; value: (root.has("i_pwr_w") ? root.stats.i_pwr_w : "—") + " / " + (root.has("i_pwr_cap_w") ? root.stats.i_pwr_cap_w : "—") + " W"; amount: root.s("gpup"); accent: root.heatColor(root.s("gpup")) }
                  DataRow { ux: win.ux; label: "UTILIZATION"; value: root.has("i_util") ? root.stats.i_util + "%" : "—"; amount: root.has("i_util") ? root.num(root.stats.i_util) / 100 : -1; accent: root.cCyan }
                  DataRow { ux: win.ux; label: "VRAM"; value: root.num(root.stats.i_vram_used) + " / " + root.num(root.stats.i_vram_total) + " MiB"; amount: root.frac("i_vram_used", "i_vram_total"); accent: root.cMagenta }
                  DataRow { ux: win.ux; label: "FREQUENCY"; value: root.has("i_freq_mhz") ? root.stats.i_freq_mhz + " MHz" : "—" }
                  DataRow { ux: win.ux; label: "FAN / ENERGY"; value: (root.has("i_fan_rpm") ? root.stats.i_fan_rpm + " rpm" : "—") + " · " + (root.has("i_energy_uj") ? (root.num(root.stats.i_energy_uj) / 1000000).toFixed(1) + " J" : "—") }
                }
                Column { width: parent.width * .47; spacing: 4 * win.ux
                  Grid { width: parent.width; columns: 2; rowSpacing: 4 * win.ux; columnSpacing: 4 * win.ux
                    Repeater { model: [{k:"i_temp_pkg",n:"PACKAGE"},{k:"i_temp_vram",n:"VRAM"},{k:"i_temp_mctrl",n:"MEM CTRL"},{k:"i_temp_pcie",n:"PCIE"}]; delegate: Rectangle { required property var modelData; width: (parent.width - 4 * win.ux) / 2; height: 36 * win.ux; color: Qt.rgba(0, .9, 1, .045); border.color: root.tempColor(root.stats[modelData.k]); Label { anchors.left: parent.left; anchors.leftMargin: 4 * win.ux; anchors.top: parent.top; text: modelData.n; color: root.cMuted; font.pixelSize: 6.5 * win.ux }; Label { anchors.left: parent.left; anchors.leftMargin: 4 * win.ux; anchors.bottom: parent.bottom; text: root.has(modelData.k) ? Math.round(root.num(root.stats[modelData.k])) + " °C" : "—"; color: root.tempColor(root.stats[modelData.k]); font.bold: true; font.pixelSize: 9 * win.ux } } }
                  }
                  Label { text: "VRAM CHANNEL TEMPERATURE / AVG · PEAK"; color: root.cMuted; font.pixelSize: 7 * win.ux }
                  Row { width: parent.width; height: 35 * win.ux; spacing: 8 * win.ux
                    Column { width: (parent.width - 8 * win.ux) / 2; height: parent.height; Label { text: "CHANNEL AVG"; color: root.cMuted; font.pixelSize: 6.5 * win.ux }; Rectangle { width: parent.width; height: 9 * win.ux; color: "#173240"; Rectangle { width: parent.width * root.clamp(root.num(root.stats.i_vram_ch_avg) / 110, 0, 1); height: parent.height; color: root.tempColor(root.stats.i_vram_ch_avg); Behavior on width { NumberAnimation { duration: 320 } } } }; Label { text: root.has("i_vram_ch_avg") ? Math.round(root.num(root.stats.i_vram_ch_avg)) + "°C" : "—"; color: root.tempColor(root.stats.i_vram_ch_avg); font.bold: true; font.pixelSize: 7 * win.ux } }
                    Column { width: (parent.width - 8 * win.ux) / 2; height: parent.height; Label { text: "CHANNEL PEAK"; color: root.cMuted; font.pixelSize: 6.5 * win.ux }; Rectangle { width: parent.width; height: 9 * win.ux; color: "#173240"; Rectangle { width: parent.width * root.clamp(root.num(root.stats.i_vram_ch_max) / 110, 0, 1); height: parent.height; color: root.tempColor(root.stats.i_vram_ch_max); Behavior on width { NumberAnimation { duration: 320 } } } }; Label { text: root.has("i_vram_ch_max") ? Math.round(root.num(root.stats.i_vram_ch_max)) + "°C" : "—"; color: root.tempColor(root.stats.i_vram_ch_max); font.bold: true; font.pixelSize: 7 * win.ux } }
                  }
                }
              }
              Rectangle { width: parent.width; height: 1; color: root.cLine }
              Label { text: (root.gpuList.length > 1 ? "GPU1 · " + root.gpuList[1].name : "GPU1 · INTEGRATED"); color: root.cCyan; font.bold: true; font.pixelSize: 9 * win.ux }
              Row { width: parent.width; spacing: 6 * win.ux
                DataRow { width: parent.width * .49; ux: win.ux; label: "UTIL"; value: root.has("a_util") ? root.stats.a_util + "%" : "—"; amount: root.has("a_util") ? root.num(root.stats.a_util) / 100 : -1; accent: root.cCyan }
                DataRow { width: parent.width * .49; ux: win.ux; label: "VRAM"; value: root.num(root.stats.a_vram_used) + " / " + root.num(root.stats.a_vram_total) + " MiB"; amount: root.frac("a_vram_used", "a_vram_total"); accent: root.cMagenta }
              }
              Row { width: parent.width; spacing: 6 * win.ux
                DataRow { width: parent.width * .49; ux: win.ux; label: "TEMP"; value: root.has("a_temp") ? root.stats.a_temp + "°C" : "—"; accent: root.tempColor(root.stats.a_temp) }
                DataRow { width: parent.width * .49; ux: win.ux; label: "POWER / FREQ"; value: (root.has("a_pwr_w") ? root.stats.a_pwr_w + " W" : "—") + " · " + (root.has("a_freq_mhz") ? root.stats.a_freq_mhz + " MHz" : "—"); accent: root.cCyan }
              }
              DataRow { ux: win.ux; label: "LEGACY GPU"; value: root.has("gpu_util") ? root.stats.gpu_util + "% · " + root.stats.gpu_temp + "°C · " + root.stats.gpu_vram_used + "/" + root.stats.gpu_vram_total + " MiB" : "no fallback sensor"; amount: root.has("gpu_util") ? root.num(root.stats.gpu_util) / 100 : -1; accent: root.cAmber }
            }
          }
        }
        Panel { id: storagePanel; x: gpuPanel.x + gpuPanel.width + hardwarePage.colGap; y: 0; width: hardwarePage.width - storagePanel.x - hardwarePage.colGap; height: hardwarePage.height * .46; ux: win.ux; title: "FILESYSTEM / DISK I/O"; sectionId: "storage"; meta: root.fsText("root"); accent: root.cAmber; bodyH: height - 38 * win.ux
          Column { anchors.fill: parent; spacing: 4 * win.ux
            DataRow { ux: win.ux; label: root.fsLabel("root"); value: root.fsText("root"); amount: root.fsFrac("root"); accent: root.cCyan }
            DataRow { ux: win.ux; label: root.fsLabel("home"); value: root.fsText("home"); amount: root.fsFrac("home"); accent: root.cGreen; visible: root.fsLabel("home") !== root.fsLabel("root") && root.fsFrac("home") >= 0 }
            Row { width: parent.width; height: 26 * win.ux; spacing: 6 * win.ux; Label { text: "READ  " + root.fmtRate(root.stats.disk_read_bps); color: root.cGreen; font.pixelSize: 8 * win.ux }; Label { text: "WRITE  " + root.fmtRate(root.stats.disk_write_bps); color: root.cMagenta; font.pixelSize: 8 * win.ux } }
            Trace { width: parent.width; height: parent.height - 80 * win.ux; points: root.dspDisk; color1: root.cAmber }
          }
        }
        Panel { id: sensorPanel; x: 0; y: corePanel.y + corePanel.height + hardwarePage.colGap; width: corePanel.width; height: hardwarePage.height - sensorPanel.y; ux: win.ux; title: "THERMAL / PRESSURE"; sectionId: "sensors"; meta: "CPU · NVME · DIMM · CCD"; accent: root.cAmber; bodyH: height - 38 * win.ux
          Flickable { anchors.fill: parent; contentHeight: sensorRows.implicitHeight; clip: true
            Column { id: sensorRows; width: parent.width; spacing: 3 * win.ux
              DataRow { ux: win.ux; label: "CPU"; value: root.has("cpu_temp") ? root.stats.cpu_temp + "°C" : "—"; accent: root.tempColor(root.stats.cpu_temp) }
              Repeater { model: Math.min(4, root.num(root.stats.nvme_count)); delegate: DataRow { required property int index; ux: win.ux; label: "NVME" + index; value: (root.has("nvme" + index + "_model") ? String(root.stats["nvme" + index + "_model"]).substr(0, 14) + " · " : "") + (root.has("nvme" + index + "_temp") ? Math.round(root.num(root.stats["nvme" + index + "_temp"])) + "°" + (root.has("nvme" + index + "_temp2") ? " / " + Math.round(root.num(root.stats["nvme" + index + "_temp2"])) + "°" : "") + "C" : "—"); accent: root.tempColor(root.stats["nvme" + index + "_temp"]) } }
              Repeater { model: Math.min(6, root.num(root.stats.dimm_count)); delegate: DataRow { required property int index; ux: win.ux; label: "DIMM " + index; value: root.has("dimm" + index + "_temp") ? root.stats["dimm" + index + "_temp"] + "°C" : "—"; accent: root.tempColor(root.stats["dimm" + index + "_temp"]) } }
              DataRow { ux: win.ux; label: "CCD 1 / 2"; value: (root.has("cpu_tccd1") ? root.stats.cpu_tccd1 + "°" : "—") + " / " + (root.has("cpu_tccd2") ? root.stats.cpu_tccd2 + "°C" : "—"); accent: root.cAmber }
              Label { text: "PSI PRESSURE · SOME / FULL"; color: root.cMuted; font.pixelSize: 7 * win.ux }
              Repeater { model: [{n:"CPU",k:"cpu"},{n:"MEM",k:"mem"},{n:"I/O",k:"io"}]; delegate: Row { required property var modelData; width: sensorRows.width; height: 20 * win.ux; spacing: 5 * win.ux; Label { width: 26 * win.ux; text: modelData.n; color: root.cMuted; font.pixelSize: 7 * win.ux }; Trace { width: sensorRows.width * .42; height: parent.height; points: modelData.k === "cpu" ? root.dspPsiCpu : modelData.k === "mem" ? root.dspPsiMem : root.dspPsiIo; scaleMax: 100; color1: root.cAmber }; Label { width: 56 * win.ux; text: root.has("psi_" + modelData.k + "_some") ? root.stats["psi_" + modelData.k + "_some"] + "/" + (root.has("psi_" + modelData.k + "_full") ? root.stats["psi_" + modelData.k + "_full"] : "0") + "%" : "—"; color: root.cAmber; font.pixelSize: 7 * win.ux } } }
            }
          }
        }
        Panel { id: resourcePanel; x: storagePanel.x; y: storagePanel.height + hardwarePage.colGap; width: storagePanel.width; height: hardwarePage.height - resourcePanel.y; ux: win.ux; title: "MEMORY / REMOVABLE MEDIA"; sectionId: "memory"; meta: root.memText(); accent: root.cGreen; bodyH: height - 38 * win.ux
          Column { anchors.fill: parent; spacing: 5 * win.ux
            DataRow { ux: win.ux; label: "RAM"; value: root.memText(); amount: root.s("mem"); accent: root.cGreen }
            DataRow { ux: win.ux; label: "SWAP"; value: root.swapFrac >= 0 ? root.fmtGiB(root.num(root.stats.swap_total_kb) - root.num(root.stats.swap_free_kb)) + " / " + root.fmtGiB(root.stats.swap_total_kb) + " GB" : "n/a"; amount: root.swapFrac; accent: root.cAmber }
            DataRow { ux: win.ux; label: "ZRAM"; value: root.has("zram_used_mb") ? root.stats.zram_used_mb + " / " + root.stats.zram_orig_mb + " MB · " + (root.has("zram_ratio") ? root.stats.zram_ratio + "×" : "ratio n/a") : "not reported"; accent: root.cCyan }
            Rectangle { width: parent.width; height: 1; color: root.cLine }
            Label { text: "PERIPHERAL BATTERIES"; color: root.cMuted; font.pixelSize: 7 * win.ux }
            Repeater { model: root.batCount; delegate: DataRow { required property int index; ux: win.ux; label: root.has("bat" + index + "_name") ? String(root.stats["bat" + index + "_name"]) : "DEVICE " + index; value: root.has("bat" + index + "_pct") ? root.stats["bat" + index + "_pct"] + "% · " + (root.stats["bat" + index + "_state"] || "unknown") : "n/a"; amount: root.has("bat" + index + "_pct") ? root.num(root.stats["bat" + index + "_pct"]) / 100 : -1; accent: root.num(root.stats["bat" + index + "_pct"]) < 20 ? root.cAlert : root.cGreen } }
            Label { visible: root.batCount === 0; text: "◇ no peripherals reported"; color: root.cMuted; font.pixelSize: 8 * win.ux }
            Row { width: parent.width; spacing: 4 * win.ux
              Repeater { model: Math.min(4, root.num(root.stats.media_count)); delegate: Rectangle { required property int index; width: Math.max(70 * win.ux, mediaName.implicitWidth + 14 * win.ux); height: 22 * win.ux; color: Qt.rgba(1, .17, .84, .07); border.color: root.cMagenta; Label { id: mediaName; anchors.centerIn: parent; text: root.stats["media" + index + "_name"]; color: root.cMagenta; font.pixelSize: 7 * win.ux } } }
              Label { visible: root.num(root.stats.media_count) === 0; text: "◇ no removable media"; color: root.cMuted; font.pixelSize: 7 * win.ux }
            }
          }
        }
      }

      // HDMI-A-3: only screen for agent detail, repo feed, windows and processes.
      Item {
        id: opsPage; visible: win.isOps; x: win.pad; y: win.contentY; width: parent.width - 2 * win.pad; height: win.contentH
        readonly property real colGap: 10 * win.ux
        Panel { id: navPanel; x: 0; y: 0; width: opsPage.width * .31; height: opsPage.height * .63; ux: win.ux; title: "WORKSPACE / WINDOW CONTROL"; sectionId: "windows"; meta: root.winCount + " WINDOWS"; accent: root.cGreen; bodyH: height - 38 * win.ux
          Flickable { anchors.fill: parent; contentHeight: navColumn.implicitHeight; clip: true
            Column { id: navColumn; width: parent.width; spacing: 6 * win.ux
              Label { text: "WORKSPACES · CLICK TO JUMP"; color: root.cMuted; font.pixelSize: 7 * win.ux }
              Flow { width: parent.width; spacing: 4 * win.ux
                Repeater { model: root.wsCount; delegate: Rectangle { id: wsChip; required property int index; property string wid: String(root.stats["ws" + index + "_id"]); width: Math.max(48 * win.ux, wsLabel.implicitWidth + 16 * win.ux); height: 23 * win.ux; color: Number(wid) === win.activeWsId ? Qt.rgba(.22, 1, .08, .15) : Qt.rgba(0, .9, 1, .04); border.color: Number(wid) === win.activeWsId ? root.cGreen : root.cLine; Label { id: wsLabel; anchors.centerIn: parent; text: String(root.stats["ws" + index + "_name"] || wid) + " · " + root.stats["ws" + index + "_wins"]; color: Number(wid) === win.activeWsId ? root.cGreen : root.cText; font.pixelSize: 7 * win.ux }; Process { id: wsProc; command: ["hyprctl", "dispatch", "workspace", wsChip.wid]; running: false; onExited: running = false }; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: wsProc.running = true } } }
              }
              Rectangle { width: parent.width; height: 1; color: root.cLine }
              Label { text: "CLIENTS · CLICK TO FOCUS"; color: root.cMuted; font.pixelSize: 7 * win.ux }
              Repeater { model: Math.min(12, root.winCount); delegate: Item { required property int index; width: navColumn.width; height: 39 * win.ux
                Rectangle { anchors.fill: parent; color: hit.containsMouse ? Qt.rgba(0, .9, 1, .10) : "transparent"; border.color: hit.containsMouse ? root.cCyan : "transparent" }
                Column { anchors.left: parent.left; anchors.leftMargin: 5 * win.ux; anchors.verticalCenter: parent.verticalCenter; width: parent.width - 70 * win.ux; Label { width: parent.width; text: String(root.stats["win" + index + "_class"] || "unknown"); color: root.cText; font.bold: true; font.pixelSize: 8 * win.ux }; Label { width: parent.width; text: String(root.stats["win" + index + "_title"] || ""); color: root.cMuted; font.pixelSize: 7 * win.ux } }
                Label { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: "WS " + root.stats["win" + index + "_ws"]; color: root.cGreen; font.pixelSize: 7 * win.ux }
                Process { id: focusProc; command: ["hyprctl", "dispatch", "focuswindow", "address:" + root.stats["win" + index + "_addr"]]; running: false; onExited: running = false }
                MouseArea { id: hit; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: focusProc.running = true }
              } }
              Label { visible: root.winCount === 0; text: "◇ no clients reported · collector idle"; color: root.cMuted; font.pixelSize: 8 * win.ux }
            }
          }
        }
        Panel { id: procPanel; x: 0; y: navPanel.y + navPanel.height + opsPage.colGap; width: navPanel.width; height: opsPage.height - y; ux: win.ux; title: "TOP PROCESSES · %CPU (1s)"; sectionId: "procs"; meta: "RAW CPU SHARE"; accent: root.cMagenta; bodyH: height - 38 * win.ux
          Column { anchors.fill: parent; spacing: 2 * win.ux
            Repeater { model: 6; delegate: Row { required property int index; visible: root.procName(index) !== ""; width: parent.width; height: 24 * win.ux; spacing: 5 * win.ux
              Label { width: 18 * win.ux; text: index < 9 ? "0" + (index + 1) : String(index + 1); color: root.cMuted; font.pixelSize: 7 * win.ux }
              Label { width: parent.width * .40; text: root.procName(index); color: root.cText; font.pixelSize: 8 * win.ux }
              Rectangle { width: parent.width * .27; height: 5 * win.ux; anchors.verticalCenter: parent.verticalCenter; color: "#173240"; Rectangle { width: parent.width * root.clamp(root.procCpu(index) / 100, 0, 1); height: parent.height; color: root.procCpu(index) > 60 ? root.cMagenta : root.procCpu(index) > 25 ? root.cAmber : root.cCyan } }
              Label { width: parent.width * .20; text: root.procCpu(index).toFixed(1) + "% cpu"; color: root.procCpu(index) > 60 ? root.cMagenta : root.cCyan; font.bold: true; font.pixelSize: 7 * win.ux; horizontalAlignment: Text.AlignRight }
            } }
            Label { visible: root.procName(0) === ""; text: "◇ no process samples"; color: root.cMuted; font.pixelSize: 8 * win.ux }
          }
        }
        Panel { id: agentsPanel; x: navPanel.x + navPanel.width + opsPage.colGap; y: 0; width: opsPage.width * .36; height: opsPage.height; ux: win.ux; title: "AGENTIC ACTIVITY"; sectionId: "agents"; meta: root.num(root.stats.agents_procs) + " PROCS"; accent: root.cMagenta; bodyH: height - 38 * win.ux
          Flickable { anchors.fill: parent; contentHeight: agentColumn.implicitHeight; clip: true
            Column { id: agentColumn; width: parent.width; spacing: 6 * win.ux
              Grid { width: parent.width; columns: 4; rowSpacing: 5 * win.ux; columnSpacing: 5 * win.ux
                Repeater { model: ["devin", "opencode", "hermes", "october", "claude", "codex", "haze", "build"]; delegate: Rectangle { required property string modelData; property int n: root.num(root.stats["ag_" + modelData + "_procs"]); width: (agentsPanel.width - 55 * win.ux) / 4; height: 42 * win.ux; color: n > 0 ? Qt.rgba(1, .17, .84, .12) : Qt.rgba(.4, .58, .65, .035); border.color: n > 0 ? root.cMagenta : root.cLine; Label { anchors.left: parent.left; anchors.leftMargin: 4 * win.ux; anchors.top: parent.top; text: modelData.toUpperCase(); color: parent.n > 0 ? root.cMagenta : root.cMuted; font.bold: true; font.pixelSize: 6.5 * win.ux }; Label { anchors.left: parent.left; anchors.leftMargin: 4 * win.ux; anchors.bottom: parent.bottom; text: parent.n > 0 ? parent.n + " · " + Math.round(root.num(root.stats["ag_" + modelData + "_cpu"])) + "%" : "idle"; color: parent.n > 0 ? root.cText : root.cMuted; font.pixelSize: 7 * win.ux } } }
              }
              Row { spacing: 5 * win.ux
                Rectangle { width: acpText.implicitWidth + 12 * win.ux; height: 23 * win.ux; color: Qt.rgba(1, .17, .84, .10); border.color: root.cMagenta; Label { id: acpText; anchors.centerIn: parent; text: "DEVIN ACP " + root.num(root.stats.ag_devin_acp); color: root.cMagenta; font.pixelSize: 7 * win.ux } }
                Rectangle { width: acpText2.implicitWidth + 12 * win.ux; height: 23 * win.ux; color: Qt.rgba(0, .9, 1, .06); border.color: root.cLine; Label { id: acpText2; anchors.centerIn: parent; text: "USAGE RECORDS " + root.num(root.stats.aguse_count); color: root.cCyan; font.pixelSize: 7 * win.ux } }
              }
              Label { text: "DEVIN SESSION LOCKS · LIVE / STALE"; color: root.cMuted; font.pixelSize: 7 * win.ux }
              Row { width: parent.width; spacing: 3 * win.ux
                Repeater { model: root.devsessCount; delegate: Rectangle { required property int index; property bool live: root.num(root.stats["devsess" + index + "_live"]) > 0; width: (agentsPanel.width - 55 * win.ux) / 6; height: 29 * win.ux; color: live ? Qt.rgba(.22, 1, .08, .12 + .10 * root.pulse) : Qt.rgba(.4, .58, .65, .035); border.color: live ? root.cGreen : root.cLine; Label { anchors.centerIn: parent; text: String(root.stats["devsess" + index + "_name"] || "session").substr(0, 8) + (parent.live ? " ●" : " ○"); color: parent.live ? root.cGreen : root.cMuted; font.pixelSize: 6.5 * win.ux } } }
                Label { visible: root.devsessCount === 0; text: "◇ no session locks"; color: root.cMuted; font.pixelSize: 7 * win.ux }
              }
              Label { text: "TMUX · CLICK TO ATTACH"; color: root.cMuted; font.pixelSize: 7 * win.ux }
              Repeater { model: root.tmuxCount; delegate: Rectangle { required property int index; width: parent.width; height: 25 * win.ux; color: tm.containsMouse ? Qt.rgba(.22, 1, .08, .12) : "transparent"; border.color: root.cLine; Row { anchors.fill: parent; anchors.leftMargin: 6 * win.ux; spacing: 8 * win.ux; Label { anchors.verticalCenter: parent.verticalCenter; text: "› " + root.stats["tmux" + index + "_name"] + " · " + root.stats["tmux" + index + "_win"] + " windows"; color: root.cText; font.pixelSize: 7 * win.ux }; Label { anchors.verticalCenter: parent.verticalCenter; text: root.num(root.stats["tmux" + index + "_att"]) > 0 ? "ATTACHED" : "DETACHED"; color: root.num(root.stats["tmux" + index + "_att"]) > 0 ? root.cGreen : root.cMuted; font.pixelSize: 6.5 * win.ux } }; Process { id: attachProc; command: ["foot", "tmux", "attach", "-t", String(root.stats["tmux" + index + "_name"])]; running: false; onExited: running = false }; MouseArea { id: tm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: attachProc.running = true } } }
              Label { visible: root.tmuxCount === 0; text: "◇ no tmux sessions"; color: root.cMuted; font.pixelSize: 7 * win.ux }
              Label { text: "AGENT USAGE / TOKENS"; color: root.cMuted; font.pixelSize: 7 * win.ux }
              Repeater { model: Math.min(4, root.num(root.stats.aguse_count)); delegate: Row { required property int index; width: parent.width; height: 20 * win.ux; Label { width: parent.width * .34; text: String(root.stats["aguse" + index + "_id"] || "agent").toUpperCase(); color: root.cCyan; font.pixelSize: 7 * win.ux }; Label { width: parent.width * .35; text: String(root.stats["aguse" + index + "_status"] || "unknown"); color: root.cText; font.pixelSize: 7 * win.ux }; Label { width: parent.width * .30; text: root.stats["aguse" + index + "_tokens"] || "—"; color: root.cAmber; font.pixelSize: 7 * win.ux; horizontalAlignment: Text.AlignRight } } }
            }
          }
        }
        Panel { id: repoPanel; x: agentsPanel.x + agentsPanel.width + opsPage.colGap; y: 0; width: opsPage.width - repoPanel.x; height: opsPage.height * .55; ux: win.ux; title: "REPO ACTIVITY"; sectionId: "repo"; meta: root.ghUnread + " UNREAD"; accent: root.cGreen; bodyH: height - 38 * win.ux
          Column { anchors.fill: parent; spacing: 4 * win.ux
            Row { width: parent.width; height: 22 * win.ux; Label { anchors.verticalCenter: parent.verticalCenter; text: root.ghOk ? "GITHUB · " + String(root.stats.gh_user || "CONNECTED") : "GITHUB · OFFLINE"; color: root.ghOk ? root.cGreen : root.cAlert; font.bold: true; font.pixelSize: 8 * win.ux }; Label { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: "◉ " + root.ghUnread; color: root.ghUnread > 0 ? root.cMagenta : root.cMuted; font.pixelSize: 8 * win.ux; opacity: root.ghUnread > 0 ? .55 + .45 * root.pulse : 1 } }
            Repeater { model: root.ghEvCount; delegate: Item { required property int index; width: parent.width; height: 26 * win.ux
              readonly property string typ: String(root.stats["ghev" + index + "_type"] || "EVENT").replace("Event", "").toUpperCase().substr(0, 5)
              readonly property string glyph: typ.indexOf("PUSH") >= 0 ? "⇧" : typ.indexOf("PULL") >= 0 ? "⑂" : typ.indexOf("ISSUE") >= 0 ? "●" : typ.indexOf("REL") >= 0 ? "◆" : "·"
              Label { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; width: 46 * win.ux; text: parent.glyph + " " + parent.typ; color: parent.typ.indexOf("PUSH") >= 0 ? root.cGreen : parent.typ.indexOf("PULL") >= 0 ? root.cMagenta : root.cAmber; font.bold: true; font.pixelSize: 7 * win.ux }
              Label { anchors.left: parent.left; anchors.leftMargin: 50 * win.ux; anchors.right: age.left; anchors.verticalCenter: parent.verticalCenter; text: String(root.stats["ghev" + index + "_repo"] || "unknown/repo"); color: root.cText; font.pixelSize: 7 * win.ux; elide: Text.ElideRight }
              Label { id: age; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: root.fmtAge(root.stats["ghev" + index + "_age_s"]); color: root.cCyan; font.pixelSize: 7 * win.ux }
            } }
            Label { visible: !root.ghOk; text: "◇ collector idle · gh_ok=0"; color: root.cMuted; font.pixelSize: 8 * win.ux }
            Label { visible: root.ghOk && root.ghEvCount === 0; text: "◇ no recent events"; color: root.cMuted; font.pixelSize: 8 * win.ux }
          }
        }
        Panel { id: launchOps; x: repoPanel.x; y: repoPanel.y + repoPanel.height + opsPage.colGap; width: repoPanel.width; height: opsPage.height - y; ux: win.ux; title: "LAUNCH / QUICK ACTIONS"; sectionId: "launch"; meta: "APP IDS VERIFIED"; accent: root.cCyan; bodyH: height - 38 * win.ux
          Flow { anchors.fill: parent; spacing: 5 * win.ux
            CommandChip { ux: win.ux; label: "DEVIN"; glyph: "◆"; accent: root.cMagenta; argv: ["gtk-launch", "devin-desktop"] }
            CommandChip { ux: win.ux; label: "OCTOBER"; glyph: "◉"; accent: root.cCyan; argv: ["gtk-launch", "october"] }
            CommandChip { ux: win.ux; label: "TERMINAL"; glyph: "›"; accent: root.cGreen; argv: ["gtk-launch", "foot"] }
            CommandChip { ux: win.ux; label: "FILES"; glyph: "▣"; accent: root.cAmber; argv: ["gtk-launch", "org.gnome.Nautilus"] }
            CommandChip { ux: win.ux; label: "WEB"; glyph: "◎"; accent: root.cCyan; argv: ["gtk-launch", "chromium"] }
            CommandChip { ux: win.ux; label: "MUSIC"; glyph: "♫"; accent: root.cGreen; argv: ["gtk-launch", "spotify"] }
            CommandChip { ux: win.ux; label: "COFFEE"; glyph: "◐"; accent: root.cAmber; argv: ["omarchy-shell", "idle", "toggle"] }
            CommandChip { ux: win.ux; label: "NIGHTLIGHT"; glyph: "☾"; accent: root.cCyan; argv: ["omarchy-shell", "nightlight", "toggle"] }
            CommandChip { ux: win.ux; label: "CLEAR NOTIFS"; glyph: "×"; accent: root.cMuted; argv: ["omarchy-shell", "notifications", "clear"] }
            CommandChip { ux: win.ux; label: "LOCK"; glyph: "⏻"; accent: root.cAlert; argv: ["omarchy-shell", "lock", "lock"] }
          }
        }
      }

      // Single compact footer acts as context/status only; no duplicated graphs.
      Panel {
        id: footerPanel; x: win.pad; y: parent.height - win.pad - win.footH; width: parent.width - 2 * win.pad; height: win.footH; ux: win.ux; title: "STATUS / CONTEXT"; meta: win.roleName; accent: root.cCyan; bodyH: height - 38 * win.ux; collapsible: false
        Row { anchors.fill: parent; spacing: 10 * win.ux
          Label { anchors.verticalCenter: parent.verticalCenter; text: root.alert ? "▲ ALERT" : root.linkOk ? "● STREAM" : "◇ IDLE"; color: root.alert ? root.cAlert : root.linkOk ? root.cGreen : root.cAmber; font.bold: true; font.pixelSize: 8 * win.ux }
          Label { anchors.verticalCenter: parent.verticalCenter; text: "FRAME " + root.batchSeq; color: root.cMuted; font.pixelSize: 8 * win.ux }
          Label { anchors.verticalCenter: parent.verticalCenter; text: win.isOps ? "GPU DATA → DP-2" : win.isHardware ? "AGENT CONSOLE → HDMI-A-3" : "SILICON DETAIL → DP-2"; color: root.cMuted; font.pixelSize: 7 * win.ux }
          Label { anchors.verticalCenter: parent.verticalCenter; text: "WS " + win.activeWs; color: root.cCyan; font.pixelSize: 8 * win.ux }
          Label { anchors.verticalCenter: parent.verticalCenter; text: "UP " + root.fmtUptime(root.stats.uptime_s); color: root.cText; font.pixelSize: 8 * win.ux }
          Label { anchors.verticalCenter: parent.verticalCenter; text: "COLLECTOR " + (root.linkOk ? "LIVE" : "IDLE"); color: root.linkOk ? root.cGreen : root.cAmber; font.pixelSize: 7 * win.ux }
        }
      }
    }
  }
}
