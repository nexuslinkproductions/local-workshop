import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland
import QtQuick.Shapes
import QtQuick.Effects
import qs.Commons
import qs.Ui


// NEXUS HUD v2.3 — per-monitor roles, ambient shader field, masked input,
// FREE-CANVAS layout: every panel lives on a 12 px snap grid inside the bezel
// frame. Press-and-drag >8 px anywhere on a panel bezel moves it; click on a
// header without dragging still toggles collapse. On drop the panel snaps to
// the grid and any panel it covers eases to the nearest free space (morph).
// A grip on each panel's bottom-right corner edge-resizes it (grid snapped,
// min-size enforced). A gear chip on the title plate opens a mouse-only
// settings sheet: per-panel visibility toggles, accent palette presets,
// ambient shader on/off + intensity, tick rate, and reset layout. Layout +
// settings persist to ~/.config/omarchy/nexuslink/hud-state.json with
// layoutMode:"free", keyed by screen name.
//
// One PanelWindow per screen on the wlr "bottom" layer: above the wallpaper,
// below normal windows. `modelData.name` picks the role:
//
//   DP-1      "command"  — THE COMMAND COCKPIT: reactor dial centre stage,
//                          hero stats, traces, NETWORK/AGENTS/STATUS strip,
//                          compact launch rail top-right.
//   DP-2      "hardware" — HARDWARE DETAIL: enlarged per-core matrix, full
//                          GPU0 B580 + GPU1 Raphael sensor sheets, STORAGE,
//                          PERIPHERALS batteries, MEMORY, extra sensors.
//   HDMI-A-3  "ops"      — OPS/DEV console: clickable WINDOWS/NAV (workspace
//                          chips + focus-on-click window list), AGENTS
//                          expanded (per-harness chips, devin ACP, devin
//                          session locks, tmux), REPO ACTIVITY feed with
//                          unread badge, TOP PROCS, LAUNCH rail, omarchy
//                          quick-action chips.
//
// Under everything sits a GLSL 440 ShaderEffect ambient field driven by the
// eased telemetry store (u_load, u_mem, u_alert): a drifting circuit/hex
// grid with travelling pulses and two slow plasma blooms. If it fails to
// compile at runtime it renders nothing and the panels are unaffected.
//
// Interactivity is pointer-masked: only drawn panel rects are inside the
// window `mask:` region list — every other pixel passes clicks through to
// the desktop. All launchers/focus dispatchers spawn detached `hyprctl`,
// `gtk-launch` or `omarchy-shell` Processes (running:false → true pulses).
//
// A single persistent `collect.sh stream` process feeds every screen —
// "key<TAB>value" lines terminated by "batch\t<n>" frame sentinels at ~1s
// cadence — plus a `probe` process for static keys (host/kernel/gpu names).
// Nothing else is spawned per frame.
//
// CONTINUOUS MOTION: one shared ~30 Hz clock (animClock) advances `animT`,
// eases every animated scalar toward its telemetry target into `sv`, keeps
// per-series eased display copies of the trace histories (`dsp*`), and bumps
// `tickSeq`, which every animated Canvas repaints on. Traces therefore glide
// — the whole curve scrolls by the fractional progress into the current
// sampling interval (`scrollPhase`) instead of stepping once per batch —
// gauges sweep, the dial ticks orbit and the alert palette lerps instead of
// snapping.
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
  // Accent presets recolor the global accent surfaces: frame line, dial
  // comet, glows, and every accent that references cCyan/cAccent. The alert
  // colour and the semantic per-panel hues (green/magenta/amber) stay fixed.
  property string accentName: "cyan"
  readonly property var accentPresets: ({
    cyan:    { main: "#00e5ff", lite: "#35e0ff" },
    green:   { main: "#39ff14", lite: "#8dff70" },
    magenta: { main: "#ff2bd6", lite: "#ff6be4" },
    amber:   { main: "#ffb300", lite: "#ffd24d" }
  })
  function accentPair() {
    var p = accentPresets[accentName]
    return p ? p : accentPresets.cyan
  }
  readonly property color cCyan:    accentPair().main
  readonly property color cAccent:  accentPair().lite
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

  // ----------------------------------------------------- settings + persist
  // Global settings shared by every screen's settings sheet, plus the
  // per-screen free-canvas layout/hidden-panel maps. All of it persists to
  // ~/.config/omarchy/nexuslink/hud-state.json under layoutMode:"free" so a
  // slot-based merge lane can distinguish the map format.
  property bool shaderOn: true
  property real shaderIntensity: 1.0
  property int  tickHz: 30

  readonly property string stateDir: Quickshell.env("HOME") + "/.config/omarchy/nexuslink/"
  readonly property string statePath: stateDir + "hud-state.json"
  property var persistScreens: ({})   // screen name -> { panels: {...}, hidden: [...] }
  property bool persistLoaded: false

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState("")
  }

  Process {
    id: stateMkdirProc
    command: ["mkdir", "-p", root.stateDir]
    running: false
  }

  // Writes are debounced: every layout/settings change restarts this timer
  // so a drag session produces one file write at the end, not one per frame.
  Timer {
    id: saveTimer
    interval: 500
    repeat: false
    onTriggered: stateFile.setText(JSON.stringify(root.buildState(), null, 2) + "\n")
  }

  function loadState(raw) {
    // FileView may fire onLoaded more than once at startup (implicit preload
    // plus the explicit reload below) — hydrate once.
    if (persistLoaded) return
    persistLoaded = true
    var data = null
    try { data = JSON.parse(String(raw || "")) } catch (e) { data = null }
    if (data === null || typeof data !== "object") return
    var g = data.global
    if (g && typeof g === "object") {
      if (typeof g.accent === "string" && accentPresets[g.accent] !== undefined)
        accentName = g.accent
      if (typeof g.shaderOn === "boolean") shaderOn = g.shaderOn
      var si = Number(g.shaderIntensity)
      if (isFinite(si)) shaderIntensity = Util.clamp(si, 0, 1)
      var hz = Number(g.tickHz)
      if (hz === 15 || hz === 30 || hz === 60) tickHz = hz
    }
    var sc = data.screens
    if (sc && typeof sc === "object") persistScreens = sc
  }

  function screenState(name) {
    var s = persistScreens[String(name)]
    return (s && typeof s === "object") ? s : null
  }

  // A screen delegate calls this whenever its layout or hidden set changes;
  // entries are {panels: {id: {fx,fy,fw,fh?}}, hidden: [ids]}.
  function mergeScreenState(name, entry) {
    var m = {}
    for (var k in persistScreens) m[k] = persistScreens[k]
    m[String(name)] = entry
    persistScreens = m
    scheduleSave()
  }

  function buildState() {
    return {
      version: 3,
      layoutMode: "free",
      global: {
        accent: accentName,
        shaderOn: shaderOn,
        shaderIntensity: shaderIntensity,
        tickHz: tickHz
      },
      screens: persistScreens
    }
  }

  function scheduleSave() {
    if (!persistLoaded) return
    saveTimer.restart()
  }

  // If FileView never signals (pathological mount failure), treat the state
  // as empty rather than leaving every screen uninitialised forever.
  Timer {
    id: persistWatchdog
    interval: 1200
    repeat: false
    running: true
    onTriggered: { if (!root.persistLoaded) root.persistLoaded = true }
  }

  Component.onCompleted: {
    stateMkdirProc.running = true
    // give mkdir a tick, then load whatever the last session persisted
    Qt.callLater(function() { stateFile.reload() })
  }

  // -------------------------------------------------------------- state
  property var stats: ({})
  property string hostName: ""
  property string kernelName: ""
  property string gpuKind: "none"
  property string gpuName: ""
  property var gpuList: []
  property date now: new Date()
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

  // 60-sample rolling histories for the sparkline traces (raw targets)
  property var histCpu:  []
  property var histGpuW: []
  property var histRx:   []
  property var histTx:   []
  property var histDisk: []

  // -------------------------------------------------- animation engine
  // One clock for the whole cockpit. A Timer is used instead of
  // FrameAnimation because the plugin root Item lives outside any
  // QQuickWindow (the PanelWindows are separate windows); FrameAnimation
  // only ticks when its own window produces frames.
  property double animT: 0.0         // seconds since start
  property double lastTickMs: 0
  property int    tickSeq: 0         // repaint signal for animated canvases
  property real   scrollPhase: 0     // 0..1+ progress into the current batch interval
  property double batchPeriod: 1.2   // smoothed seconds between stream batches

  // Eased scalar store — reassigned once per tick so QML bindings on it
  // re-evaluate at animation rate. Keys: cpu, gpup, mem, iutil, gutil,
  // ivram, autil, avram, swap, fsR, fsH, alert, core[].
  property var sv: ({})

  // Eased display copies of the trace histories; mutated in place by tick()
  // and read by canvases during paint (no bindings needed).
  property var dspCpu:  []
  property var dspGpuW: []
  property var dspRx:   []
  property var dspTx:   []
  property var dspDisk: []

  // Smooth 0..1 pulse replacing the old hard blink — cursor bars, glows and
  // the alert halo breathe on this.
  readonly property real pulse: 0.5 + 0.5 * Math.sin(animT * 2.4)

  Timer {
    id: animClock
    // user-selectable tick rate (15/30/60 Hz) from the settings sheet;
    // 30 Hz is the default — smooth glide at half the repaint budget
    interval: Math.max(8, Math.round(1000 / Math.max(5, root.tickHz)))
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.tick()
  }

  function tick() {
    var t = Date.now()
    var dt = lastTickMs > 0 ? (t - lastTickMs) / 1000 : 0.033
    lastTickMs = t
    if (!(dt > 0) || dt > 0.5) dt = 0.033
    animT += dt

    // The trace viewport scrolls one sample-slot per measured batch period;
    // it is allowed to overrun a little so a late batch still drifts instead
    // of freezing, then a new sample slides in on the next frame.
    scrollPhase = Math.min(1.6, scrollPhase + dt / Math.max(0.4, batchPeriod))

    var o = sv
    var k = Math.min(1, dt * 5.0)          // ~0.25 s convergence
    var ka = Math.min(1, dt * 2.4)         // alert palette lerps slower, more dramatic
    var nv = {}

    nv.cpu   = easeFrac(o.cpu,   cpuFrac,   k)
    nv.gpup  = easeFrac(o.gpup,  iPwrFrac,  k)
    nv.mem   = easeFrac(o.mem,   memFrac,   k)
    nv.iutil = easeFrac(o.iutil, iUtilFrac, k)
    nv.gutil = easeFrac(o.gutil, gpuUtilFrac, k)
    nv.ivram = easeFrac(o.ivram, iVramFrac, k)
    nv.autil = easeFrac(o.autil, aUtilFrac, k)
    nv.avram = easeFrac(o.avram, aVramFrac, k)
    nv.swap  = easeFrac(o.swap,  swapFrac,  k)
    nv.fsR   = easeFrac(o.fsR,   fsFrac("root"), k)
    nv.fsH   = easeFrac(o.fsH,   fsFrac("home"), k)

    var prevAlert = (o.alert !== undefined && isFinite(o.alert)) ? o.alert : 0
    nv.alert = prevAlert + ((alert ? 1 : 0) - prevAlert) * ka

    // per-core eased fractions
    var cn = coreCount
    var prevC = o.core
    var nc = new Array(cn)
    for (var i = 0; i < cn; i++) {
      var tgt = Math.min(1, Math.max(0, num(stats["cpu_core_" + i]) / 100))
      var pv = (prevC && i < prevC.length) ? prevC[i] : undefined
      nc[i] = (pv === undefined || !isFinite(pv)) ? 0 : pv + (tgt - pv) * k
    }
    nv.core = nc

    sv = nv

    // ease the trace display copies toward the raw histories
    easeHist(dspCpu,  histCpu,  k)
    easeHist(dspGpuW, histGpuW, k)
    easeHist(dspRx,   histRx,   k)
    easeHist(dspTx,   histTx,   k)
    easeHist(dspDisk, histDisk, k)

    tickSeq++
  }

  // Ease a 0..1 fraction toward target; -1/NaN targets stay -1 (gauge hides),
  // first sighting spools up from 0 which reads as a deliberate power-on sweep.
  function easeFrac(prev, target, k) {
    if (!isFinite(target) || target < 0) return -1
    target = Math.min(1, target)
    if (prev === undefined || !isFinite(prev) || prev < 0) return 0
    return prev + (target - prev) * k
  }

  // Read an eased scalar for bindings; missing keys yield `def`.
  function s(key, def) {
    var v = sv[key]
    return (v === undefined || !isFinite(v)) ? (def === undefined ? -1 : def) : v
  }
  function svCore(i) {
    var c = sv.core
    return (c && i < c.length && isFinite(c[i])) ? c[i] : 0
  }

  // Keep a display array aligned with its history and ease every element.
  // Newest slot enters at the previous head height, then eases — so the head
  // of the trace rises/falls smoothly rather than jumping on each batch.
  function easeHist(d, h, k) {
    while (d.length > h.length) d.shift()
    while (d.length < h.length)
      d.push(d.length > 0 ? d[d.length - 1] : (isFinite(h[d.length]) ? h[d.length] : 0))
    for (var i = 0; i < d.length; i++) {
      var tv = h[i]
      if (!isFinite(tv)) { d[i] = NaN; continue }
      var dv = d[i]
      d[i] = isFinite(dv) ? dv + (tv - dv) * k : tv
    }
  }

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

  // Color helpers — all palette transitions lerp, nothing snaps.
  function lerpColor(a, b, t) {
    t = Math.max(0, Math.min(1, t))
    return Qt.rgba(a.r + (b.r - a.r) * t,
                   a.g + (b.g - a.g) * t,
                   a.b + (b.b - a.b) * t,
                   a.a + (b.a - a.a) * t)
  }
  function rgbOf(c) {
    return "rgb(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + ")"
  }
  function rgbaOf(c, a) {
    return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")"
  }

  // Continuous heat ramp: base -> amber -> alert as the fraction climbs.
  function heatColor(f, base) {
    if (!isFinite(f) || f < 0) return cMuted
    if (f >= 0.92) return cAlert
    if (f >= 0.72) return lerpColor(cAmber, cAlert, (f - 0.72) / 0.20)
    if (f >= 0.58) return lerpColor(base, cAmber, (f - 0.58) / 0.14)
    return base
  }

  function gaugeColor(f) {
    if (!isFinite(f) || f < 0) return cMuted
    if (f >= 0.95) return cMagenta
    if (f >= 0.85) return lerpColor(cAmber, cMagenta, (f - 0.85) / 0.10)
    if (f >= 0.65) return lerpColor(cGreen, cAmber, (f - 0.65) / 0.20)
    return cGreen
  }

  // Smooth Celsius ramp for temp readouts: cyan -> amber over 68..78,
  // amber -> red over 80..88.
  function tempColor(t) {
    var v = num(t)
    if (v >= 88) return cAlert
    if (v >= 80) return lerpColor(cAmber, cAlert, (v - 80) / 8)
    if (v >= 68) return lerpColor(cAccent, cAmber, (v - 68) / 10)
    return cAccent
  }

  // Paints one sparkline series as a smoothed, gradient-filled curve that
  // scrolls continuously. `pts` is an eased display array (newest last);
  // `phase` is the fractional progress into the current sampling interval,
  // so every point sits at its true age — between batches the whole curve
  // glides left and the next sample slides in from the right edge.
  // NaN entries break the curve into runs (missing sensor = gap, not spike).
  function paintTrace(ctx, w, h, pts, col, peak, phase) {
    var n = pts.length
    if (n === 0 || !(peak > 0)) return
    var step = w / 59
    var y0 = h - 3
    var amp = h - 8

    // pixel positions, newest sample glued near the right edge and aging
    // leftward at `step` px per batch period
    var px = new Array(n)
    var py = new Array(n)
    for (var j = 0; j < n; j++) {
      px[j] = w - (n - 1 - j + phase) * step
      var v = pts[j]
      py[j] = isFinite(v) ? y0 - (Math.min(v, peak) / peak) * amp : NaN
    }

    var headX = 0, headY = 0, haveHead = false
    var grad = ctx.createLinearGradient(0, 0, 0, h)
    grad.addColorStop(0,    rgbaOf(col, 0.30))
    grad.addColorStop(0.75, rgbaOf(col, 0.06))
    grad.addColorStop(1,    rgbaOf(col, 0.0))

    var i = 0
    while (i < n) {
      if (!isFinite(py[i])) { i++; continue }
      var i0 = i
      while (i + 1 < n && isFinite(py[i + 1])) i++
      var i1 = i                      // run is [i0, i1] inclusive
      i++

      // smoothed path: quadratic through successive midpoints
      var runPath = function() {
        ctx.beginPath()
        ctx.moveTo(px[i0], py[i0])
        if (i1 - i0 >= 2) {
          for (var k = i0 + 1; k < i1; k++)
            ctx.quadraticCurveTo(px[k], py[k],
                                 (px[k] + px[k + 1]) / 2, (py[k] + py[k + 1]) / 2)
          ctx.lineTo(px[i1], py[i1])
        } else if (i1 > i0) {
          ctx.lineTo(px[i1], py[i1])
        }
      }

      // gradient fill under the run
      runPath()
      ctx.lineTo(px[i1], h)
      ctx.lineTo(px[i0], h)
      ctx.closePath()
      ctx.fillStyle = grad
      ctx.fill()

      // glow pass then hot core pass — layered strokes instead of shadowBlur
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      runPath()
      ctx.strokeStyle = rgbaOf(col, 0.20)
      ctx.lineWidth = 3.4
      ctx.stroke()
      runPath()
      ctx.strokeStyle = rgbOf(col)
      ctx.lineWidth = 1.5
      ctx.stroke()

      if (!haveHead && i1 === n - 1) {
        headX = px[i1]; headY = py[i1]; haveHead = true
      }
    }

    // bright head dot with a soft halo at the newest sample
    if (haveHead) {
      ctx.fillStyle = rgbaOf(col, 0.28)
      ctx.beginPath()
      ctx.arc(headX, headY, 4.6, 0, Math.PI * 2)
      ctx.fill()
      ctx.fillStyle = rgbOf(col)
      ctx.beginPath()
      ctx.arc(headX, headY, 2.3, 0, Math.PI * 2)
      ctx.fill()
      ctx.fillStyle = "rgba(234,252,255,0.9)"
      ctx.beginPath()
      ctx.arc(headX, headY, 0.9, 0, Math.PI * 2)
      ctx.fill()
    }
  }

  // ------------------------------------------------------------ collapse
  readonly property var sectionIds: ["system", "memory", "gpu", "gpu2", "storage",
                                     "network", "agents", "matrix", "sensors",
                                     "periph", "windows", "repo", "procs",
                                     "launch", "actions", "traces"]

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

  // Keep a display array aligned with its history *by sample*: when the
  // window drops the oldest sample the display copy drops it too, and the
  // incoming head element enters at the previous head height so it eases
  // vertically instead of popping.
  function dspShift(d, h) {
    if (d.length >= h.length) d.shift()
    while (d.length < h.length) {
      var pv = d.length > 0 ? d[d.length - 1] : 0
      d.push(isFinite(pv) ? pv : 0)
    }
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

    // track the real batch cadence so scrollPhase paces itself to the stream
    if (dt > 0.2 && dt < 8)
      batchPeriod = batchPeriod * 0.75 + dt * 0.25
    scrollPhase = 0

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

    // push one sample onto each sparkline history, then advance the eased
    // display copies in lock-step so index <-> sample alignment holds
    histCpu  = histPush(histCpu,  cpuPct >= 0 ? cpuPct : 0)
    histGpuW = histPush(histGpuW, m.i_pwr_w !== undefined ? num(m.i_pwr_w) : NaN)
    histRx   = histPush(histRx,   rxRate)
    histTx   = histPush(histTx,   txRate)
    histDisk = histPush(histDisk, num(m.disk_read_bps))
    dspShift(dspCpu,  histCpu)
    dspShift(dspGpuW, histGpuW)
    dspShift(dspRx,   histRx)
    dspShift(dspTx,   histTx)
    dspShift(dspDisk, histDisk)

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

  // Frame-wide alert: any reported temperature over 85C or memory over 90%.
  // `alert` is the boolean; `sv.alert` eases 0->1 so the frame, dial ticks
  // and brackets sweep cyan->red over ~half a second instead of snapping.
  readonly property real maxTemp: {
    var t = -1
    var keys = ["cpu_temp", "i_temp_pkg", "i_temp_vram", "i_temp_mctrl",
                "i_temp_pcie", "a_temp", "gpu_temp"]
    for (var i = 0; i < keys.length; i++)
      if (has(keys[i])) t = Math.max(t, num(stats[keys[i]]))
    return t
  }
  readonly property bool alert: maxTemp > 85 || (memFrac >= 0 && memFrac > 0.9)
  readonly property real alertMix: {
    var v = sv.alert
    return (v === undefined || !isFinite(v)) ? 0 : Math.max(0, Math.min(1, v))
  }
  readonly property color frameCol: lerpColor(cCyan, cAlert, alertMix)

  function procName(i) { return has("proc" + i + "_name") ? String(stats["proc" + i + "_name"]) : "" }
  function procCpu(i)  { return has("proc" + i + "_cpu")  ? num(stats["proc" + i + "_cpu"]) : 0 }

  readonly property string hotText: {
    var parts = []
    for (var i = 0; i < 3; i++)
      if (procName(i) !== "") parts.push(procName(i))
    return parts.length ? parts.join(" · ") : "--"
  }

  // ------------------------------------------- pass-2 key family helpers
  // The collector contract is additive-only; every builder below tolerates
  // missing keys and clamps to sane caps so a flood of entries cannot blow
  // a panel out.

  function fmtAge(sec) {
    var s = num(sec)
    if (s < 60)    return Math.round(s) + "s"
    if (s < 3600)  return Math.round(s / 60) + "m"
    if (s < 86400) return Math.round(s / 3600) + "h"
    return Math.round(s / 86400) + "d"
  }

  // PERIPHERALS — wireless device batteries (G502 etc.)
  readonly property int batCount: Math.min(4, Math.max(0, num(stats.bat_count)))
  function batList() {
    var a = []
    for (var i = 0; i < batCount; i++)
      a.push({
        name:  has("bat" + i + "_name")  ? String(stats["bat" + i + "_name"])  : "DEV " + i,
        pct:   Math.max(0, Math.min(100, num(stats["bat" + i + "_pct"]))),
        state: has("bat" + i + "_state") ? String(stats["bat" + i + "_state"]) : ""
      })
    return a
  }

  // REPO ACTIVITY — github event feed + notification count
  readonly property bool ghOk: num(stats.gh_ok) > 0
  readonly property int ghUnread: Math.max(0, num(stats.gh_unread))
  readonly property int ghEvCount: Math.min(8, Math.max(0, num(stats.ghev_count)))
  function ghTypeShort(t) {
    var s = String(t || "")
    var map = {
      PushEvent: "PUSH", PullRequestEvent: "PR", PullRequestReviewEvent: "REV",
      PullRequestReviewCommentEvent: "RCMT", CreateEvent: "CREATE",
      DeleteEvent: "DEL", IssuesEvent: "ISSUE", IssueCommentEvent: "CMT",
      WatchEvent: "STAR", ForkEvent: "FORK", ReleaseEvent: "REL",
      CommitCommentEvent: "CCMT", GollumEvent: "WIKI", PublicEvent: "PUB"
    }
    if (map[s] !== undefined) return map[s]
    return s.replace("Event", "").toUpperCase().substr(0, 6)
  }
  function ghevList() {
    var a = []
    for (var i = 0; i < ghEvCount; i++) {
      var repo = has("ghev" + i + "_repo") ? String(stats["ghev" + i + "_repo"]) : ""
      a.push({
        type:  ghTypeShort(stats["ghev" + i + "_type"]),
        repo:  repo !== "" ? repo : "?",
        age:   fmtAge(stats["ghev" + i + "_age_s"]),
        url:   repo !== "" ? "https://github.com/" + repo : ""
      })
    }
    return a
  }

  // AGENTS extended — per-harness chips, devin session locks, tmux sessions
  readonly property var harnessIds: ["devin", "opencode", "hermes", "october",
                                     "claude", "codex", "haze", "build"]
  function agList() {
    var a = []
    for (var i = 0; i < harnessIds.length; i++) {
      var h = harnessIds[i]
      a.push({
        id:    h,
        procs: Math.max(0, num(stats["ag_" + h + "_procs"])),
        cpu:   num(stats["ag_" + h + "_cpu"])
      })
    }
    return a
  }
  readonly property int devinAcp: Math.max(0, num(stats.ag_devin_acp))
  readonly property int devsessCount: Math.min(6, Math.max(0, num(stats.devsess_count)))
  function devsessList() {
    var a = []
    for (var i = 0; i < devsessCount; i++)
      a.push({
        name: has("devsess" + i + "_name") ? String(stats["devsess" + i + "_name"]) : "?",
        pid:  num(stats["devsess" + i + "_pid"]),
        live: num(stats["devsess" + i + "_live"]) > 0
      })
    return a
  }
  readonly property int tmuxCount: Math.min(6, Math.max(0, num(stats.tmux_n)))
  function tmuxList() {
    var a = []
    for (var i = 0; i < tmuxCount; i++)
      a.push({
        name: has("tmux" + i + "_name") ? String(stats["tmux" + i + "_name"]) : "?",
        win:  num(stats["tmux" + i + "_win"]),
        att:  num(stats["tmux" + i + "_att"]) > 0
      })
    return a
  }

  // WINDOWS/NAV — hyprland clients + workspaces (slow-lane keys)
  readonly property int winCount: Math.max(0, num(stats.win_count))
  readonly property int wsCount: Math.max(0, num(stats.ws_count))
  function wsList() {
    var n = Math.min(14, wsCount)
    var a = []
    for (var i = 0; i < n; i++)
      a.push({
        id:   num(stats["ws" + i + "_id"]),
        name: has("ws" + i + "_name") ? String(stats["ws" + i + "_name"])
                                      : String(num(stats["ws" + i + "_id"])),
        mon:  has("ws" + i + "_mon")  ? String(stats["ws" + i + "_mon"]) : "",
        wins: Math.max(0, num(stats["ws" + i + "_wins"]))
      })
    a.sort(function(x, y) { return x.id - y.id })
    return a
  }
  // Window rows, this monitor's clients first then by workspace id.
  function winList(preferMon) {
    var n = Math.min(12, winCount)
    var a = []
    for (var i = 0; i < n; i++)
      a.push({
        addr: has("win" + i + "_addr")  ? String(stats["win" + i + "_addr"])  : "",
        ws:   has("win" + i + "_ws")    ? String(stats["win" + i + "_ws"])    : "?",
        wsid: num(stats["win" + i + "_wsid"]),
        cls:  has("win" + i + "_class") ? String(stats["win" + i + "_class"]) : "?",
        title: has("win" + i + "_title") ? String(stats["win" + i + "_title"]) : "",
        mon:  has("win" + i + "_mon")   ? String(stats["win" + i + "_mon"])   : ""
      })
    a.sort(function(x, y) {
      var xm = (x.mon === preferMon) ? 0 : 1
      var ym = (y.mon === preferMon) ? 0 : 1
      if (xm !== ym) return xm - ym
      return x.wsid - y.wsid
    })
    return a
  }

  // Extra hardware sensors for the DP-2 detail page — collapses to whatever
  // the collector actually emitted.
  function sensorRows() {
    var a = []
    var i, k
    var nn = Math.min(4, Math.max(0, num(stats.nvme_count)))
    for (i = 0; i < nn; i++) {
      var model = has("nvme" + i + "_model") ? String(stats["nvme" + i + "_model"]) : ("nvme" + i)
      var tv = has("nvme" + i + "_temp") ? num(stats["nvme" + i + "_temp"]) : NaN
      var t2 = has("nvme" + i + "_temp2") ? " / " + Math.round(num(stats["nvme" + i + "_temp2"])) + "°" : ""
      a.push({ label: "NVME" + i, value: model.substr(0, 18), accent: root.cMuted })
      a.push({ label: "·TEMP", value: isNaN(tv) ? "--" : Math.round(tv) + "°C" + t2,
               accent: isNaN(tv) ? root.cMuted : root.tempColor(tv) })
    }
    var dn = Math.min(6, Math.max(0, num(stats.dimm_count)))
    if (dn > 0) {
      var dts = []
      for (i = 0; i < dn; i++)
        if (has("dimm" + i + "_temp")) dts.push(Math.round(num(stats["dimm" + i + "_temp"])) + "°")
      if (dts.length > 0) a.push({ label: "DIMM", value: dts.join("  "), accent: root.cCyan })
    }
    var ccd = []
    if (has("cpu_tccd1")) ccd.push("ccd1 " + Math.round(num(stats.cpu_tccd1)) + "°")
    if (has("cpu_tccd2")) ccd.push("ccd2 " + Math.round(num(stats.cpu_tccd2)) + "°")
    if (ccd.length > 0) a.push({ label: "CCD", value: ccd.join("  "), accent: root.tempColor(num(stats.cpu_tccd1)) })
    if (has("psi_cpu_some"))
      a.push({ label: "PSI CPU", value: "some " + String(stats.psi_cpu_some) + "% · full " + String(stats.psi_cpu_full !== undefined ? stats.psi_cpu_full : "0") + "%", accent: root.cAmber })
    if (has("psi_mem_some"))
      a.push({ label: "PSI MEM", value: "some " + String(stats.psi_mem_some) + "% · full " + String(stats.psi_mem_full !== undefined ? stats.psi_mem_full : "0") + "%", accent: root.cAmber })
    if (has("psi_io_some"))
      a.push({ label: "PSI IO",  value: "some " + String(stats.psi_io_some) + "% · full " + String(stats.psi_io_full !== undefined ? stats.psi_io_full : "0") + "%", accent: root.cAmber })
    if (has("zram_used_mb"))
      a.push({ label: "ZRAM", value: num(stats.zram_used_mb) + " / " + num(stats.zram_orig_mb) + " MB"
               + (has("zram_ratio") ? "  ·  " + String(stats.zram_ratio) + "×" : ""), accent: root.cGreen })
    if (has("cpu_mhz_avg"))
      a.push({ label: "CLOCK", value: Math.round(num(stats.cpu_mhz_avg)) + " MHz avg"
               + (has("cpu_mhz_max") ? " · " + Math.round(num(stats.cpu_mhz_max)) + " max" : ""), accent: root.cCyan })
    var mn = Math.min(4, Math.max(0, num(stats.media_count)))
    for (i = 0; i < mn; i++)
      if (has("media" + i + "_name"))
        a.push({ label: "MEDIA" + i, value: String(stats["media" + i + "_name"]), accent: root.cMagenta })
    return a
  }

  // ------------------------------------------------------------ IPC
  IpcHandler {
    target: "nexuslink.hud"

    function toggleAll(): string { return root.toggleAll() }
    function refresh(): string { root.refresh(); return "ok" }
    function section(id: string): string { root.toggleSection(id); return "ok" }
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
    function stats(): string {
      return JSON.stringify({
        cpu: root.cpuText,
        cpuFrac: root.cpuFrac,
        mem: root.memText,
        memFrac: root.memFrac,
        gpuKind: root.gpuKind,
        gpu0: root.gpu0Title,
        gpu1: root.gpu1Title,
        gpuPwrFrac: root.iPwrFrac,
        rx: root.fmtRate(root.rxRate),
        tx: root.fmtRate(root.txRate),
        uptime: root.uptimeText,
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

  // One stat line inside a panel body: small caps label, optional thin gauge,
  // right-aligned value. Set `fraction` 0..1 to show the gauge; -1 hides it.
  // Pass an eased fraction (root.s("...")) for continuous gauge motion.
  component HudRow: Item {
    id: hrow
    property string label: ""
    property string value: ""
    property real fraction: -1
    property color accent: "#00e5ff"
    property color valueColor: Qt.rgba(0, 0, 0, 0)

    width: parent ? parent.width : 0
    height: Math.max(lbl.implicitHeight, rval.implicitHeight, 10)

    TLabel {
      id: lbl
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: 66
      text: hrow.label
      color: root.cMuted
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1.2
      elide: Text.ElideRight
    }

    Rectangle {
      id: track
      visible: hrow.fraction >= 0
      anchors.left: lbl.right
      anchors.leftMargin: 8
      anchors.right: rval.left
      anchors.rightMargin: 10
      anchors.verticalCenter: parent.verticalCenter
      height: 5
      color: Qt.rgba(1, 1, 1, 0.05)
      border.color: Util.alpha(root.cLine, 0.9)
      border.width: 1

      // eased fill: gradient accent -> hot tip with a bright head cap
      Rectangle {
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: Math.max(0, (track.width - 2) * Util.clamp(hrow.fraction, 0, 1))
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0.0; color: Util.alpha(hrow.accent, 0.45) }
          GradientStop { position: 1.0; color: hrow.accent }
        }
        Rectangle {
          anchors { right: parent.right; verticalCenter: parent.verticalCenter }
          width: 2
          height: parent.height + 2
          color: "#eafcff"
          opacity: 0.85
          visible: parent.width > 3
        }
      }
    }

    TLabel {
      id: rval
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: hrow.value
      color: hrow.valueColor.a > 0 ? hrow.valueColor : root.cTxt
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
    }
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

  // Cockpit panel: a canvas-drawn bezel — chamfered dark fill with a vertical
  // accent-gradient wash, faint scanlines, a top inner highlight and a shaded
  // bottom edge — plus corner brackets and a clickable title row that folds
  // the body (animated) when `collapsible`. `shrink` false keeps the panel's
  // footprint when folded — used for the bottom strip.
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

    // ---------------------------------------------- free-canvas plumbing
    // `host` is the PanelWindow delegate owning the snap-grid field this
    // panel sits in; `panelId` is its persistence key. Panels nested inside
    // a composite chassis (the reactor cluster) leave both unset and keep
    // their anchors — the whole cluster moves as one panel.
    property string panelId: ""
    property var    host: null
    readonly property bool dragging: host !== null && host.draggingId === panelId
    readonly property bool resizing: host !== null && host.sizingId === panelId
    // masked=false drops the panel out of the window input mask mid-gesture
    // so a moving bezel can't swallow clicks meant for the desktop beneath.
    readonly property bool masked: shown && !dragging && !resizing
    readonly property real naturalH: titleH + contentH
    property real minW: 150 * ux
    property real minH: titleH + 28 * ux
    // Height override set by an edge-resize; <= 0 means hug the content.
    property real sizeH: -1

    readonly property real titleH: Math.max(16, 22 * ux)
    readonly property real chamfer: 10 * ux

    visible: shown
    height: shown ? (collapsed && shrink ? titleH + 2
                                        : (sizeH > 0 ? Math.max(minH, sizeH)
                                                     : titleH + contentH)) : 0
    clip: true
    opacity: dragging ? 0.92 : 1.0
    z: (dragging || resizing) ? 60 : 0
    Behavior on height { enabled: !cp.resizing; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    Behavior on x { enabled: cp.host !== null && cp.host.animateLayout && !cp.dragging; NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
    Behavior on y { enabled: cp.host !== null && cp.host.animateLayout && !cp.dragging; NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
    Behavior on width { enabled: cp.host !== null && cp.host.animateLayout && !cp.resizing; NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

    // Position/width ride the host's layout map except while the pointer
    // owns them (x/y while dragging, width while resizing, sizeH likewise).
    Binding on x { when: cp.host !== null && !cp.dragging; value: cp.host !== null ? cp.host.pxOf(cp.panelId) : 0 }
    Binding on y { when: cp.host !== null && !cp.dragging; value: cp.host !== null ? cp.host.pyOf(cp.panelId) : 0 }
    Binding on width { when: cp.host !== null && !cp.resizing; value: cp.host !== null ? cp.host.pwOf(cp.panelId) : 100 }
    Binding { target: cp; property: "sizeH"; when: cp.host !== null && !cp.resizing; value: cp.host !== null ? cp.host.phOf(cp.panelId) : -1 }

    // A growing/shrinking panel (dynamic content, collapse toggles) can
    // start overlapping a neighbour — tell the host to re-fit the field.
    onHeightChanged: if (cp.host !== null && cp.panelId !== "") cp.host.noteGeomChange()

    Canvas {
      id: bezel
      anchors.fill: parent
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      Connections {
        target: cp
        function onCollapsedChanged() { bezel.requestPaint() }
        function onAccentChanged()    { bezel.requestPaint() }
      }
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var w = width, h = height
        if (w < 4 || h < 4) return
        var ch = Math.min(cp.chamfer, Math.min(w, h) / 2 - 1)
        var hot = cpHeadMa.containsMouse && cp.collapsible
        var edge = cp.collapsed ? root.cLine
                 : hot ? root.lerpColor(cp.accent, Qt.rgba(1, 1, 1, 1), 0.4)
                 : cp.accent

        // chamfered silhouette
        ctx.beginPath()
        ctx.moveTo(ch, 0)
        ctx.lineTo(w, 0)
        ctx.lineTo(w, h - ch)
        ctx.lineTo(w - ch, h)
        ctx.lineTo(0, h)
        ctx.lineTo(0, ch)
        ctx.closePath()

        // machined fill: faint accent sheen at the top fading to deep plate
        var g = ctx.createLinearGradient(0, 0, 0, h)
        g.addColorStop(0,    root.rgbaOf(cp.accent, cp.collapsed ? 0.05 : 0.11))
        g.addColorStop(0.30, "rgba(7,18,28,0.87)")
        g.addColorStop(1,    "rgba(2,7,12,0.93)")
        ctx.fillStyle = g
        ctx.fill()

        // interior micro-texture, clipped to the silhouette
        ctx.save()
        ctx.clip()
        ctx.strokeStyle = "rgba(255,255,255,0.022)"
        ctx.lineWidth = 1
        ctx.beginPath()
        for (var yy = 1.5; yy < h; yy += 3) {
          ctx.moveTo(0, yy)
          ctx.lineTo(w, yy)
        }
        ctx.stroke()
        // top inner highlight — a lit edge under the bezel lip
        var hg = ctx.createLinearGradient(0, 0, w, 0)
        hg.addColorStop(0,    "rgba(255,255,255,0.0)")
        hg.addColorStop(0.15, root.rgbaOf(cp.accent, hot ? 0.55 : 0.30))
        hg.addColorStop(0.7,  "rgba(255,255,255,0.07)")
        hg.addColorStop(1,    "rgba(255,255,255,0.0)")
        ctx.strokeStyle = hg
        ctx.beginPath()
        ctx.moveTo(ch + 1, 1)
        ctx.lineTo(w - 2, 1)
        ctx.stroke()
        // bottom inner shade — the lip shadow that gives the face depth
        ctx.strokeStyle = "rgba(0,0,0,0.38)"
        ctx.beginPath()
        ctx.moveTo(2, h - 1)
        ctx.lineTo(w - ch - 1, h - 1)
        ctx.stroke()
        ctx.restore()

        // chamfered outline, brighter on the two cut diagonals
        ctx.strokeStyle = root.rgbaOf(edge, cp.collapsed ? 0.8 : 1.0)
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.moveTo(ch, 0)
        ctx.lineTo(w, 0)
        ctx.lineTo(w, h - ch)
        ctx.lineTo(w - ch, h)
        ctx.lineTo(0, h)
        ctx.lineTo(0, ch)
        ctx.closePath()
        ctx.stroke()

        ctx.strokeStyle = root.rgbaOf(cp.accent, cp.collapsed ? 0.25 : 0.9)
        ctx.lineWidth = 1.6
        ctx.beginPath()
        ctx.moveTo(ch + 1.5, 0.8)
        ctx.lineTo(0.8, ch + 1.5)
        ctx.moveTo(w - ch - 1.5, h - 0.8)
        ctx.lineTo(w - 0.8, h - ch - 1.5)
        ctx.stroke()
      }
    }

    // Whole-bezel drag surface — declared below the header row and body so
    // interactive children (chips, rows) keep their own clicks; a press on
    // any other pixel of the bezel starts a potential panel move. Disabled
    // for anchored panels nested in a composite chassis.
    MouseArea {
      id: bodyDragMa
      anchors.fill: parent
      enabled: cp.host !== null && cp.panelId !== ""
      onPressed: if (cp.host !== null) cp.host.dragPress(bodyDragMa, cp, mouse.x, mouse.y)
      onPositionChanged: if (cp.host !== null) cp.host.dragMove(bodyDragMa, cp, mouse.x, mouse.y)
      onReleased: if (cp.host !== null) cp.host.dragRelease(cp)
      onCanceled: if (cp.host !== null) cp.host.dragAbort(cp)
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

      // small accent pip before the chevron — a status LED for the section
      Rectangle {
        anchors { left: parent.left; leftMargin: 0; verticalCenter: parent.verticalCenter }
        width: 3 * cp.ux
        height: 3 * cp.ux
        rotation: 45
        color: cp.accent
        opacity: cp.collapsed ? 0.35 : 0.9
      }

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
        // enabled for drag even on non-collapsible panels; the release
        // path decides between "it was a drag" and "click -> toggle".
        enabled: cp.collapsible || (cp.host !== null && cp.panelId !== "")
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onPressed: if (cp.host !== null && cp.panelId !== "") cp.host.dragPress(cpHeadMa, cp, mouse.x, mouse.y)
        onPositionChanged: if (cp.host !== null && cp.panelId !== "") cp.host.dragMove(cpHeadMa, cp, mouse.x, mouse.y)
        onReleased: {
          var wasDrag = (cp.host !== null && cp.panelId !== "") ? cp.host.dragRelease(cp) : false
          if (!wasDrag && cp.collapsible) cp.toggled()
        }
        onCanceled: if (cp.host !== null && cp.panelId !== "") cp.host.dragAbort(cp)
        onContainsMouseChanged: bezel.requestPaint()
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

    // bottom-right edge-resize grip: a tiny elbow that lights on hover;
    // dragging it resizes the panel on the host's snap grid with the
    // panel's min size enforced. Hidden while collapsed or unhosted.
    Item {
      id: grip
      anchors { right: parent.right; bottom: parent.bottom; margins: 2 }
      width: 14 * cp.ux
      height: 14 * cp.ux
      visible: cp.host !== null && cp.panelId !== "" && !cp.collapsed
      opacity: gripMa.containsMouse || cp.resizing ? 1.0 : 0.4
      Rectangle { anchors { right: parent.right; bottom: parent.bottom } width: 1.5; height: 9 * cp.ux; color: cp.accent }
      Rectangle { anchors { right: parent.right; bottom: parent.bottom } width: 9 * cp.ux; height: 1.5; color: cp.accent }
      MouseArea {
        id: gripMa
        anchors { fill: parent; margins: -4 * cp.ux }
        hoverEnabled: true
        cursorShape: Qt.SizeFDiagCursor
        onPressed: if (cp.host !== null) cp.host.sizePress(gripMa, cp, mouse.x, mouse.y)
        onPositionChanged: if (cp.host !== null) cp.host.sizeMove(gripMa, cp, mouse.x, mouse.y)
        onReleased: if (cp.host !== null) cp.host.sizeRelease(cp)
        onCanceled: if (cp.host !== null) cp.host.sizeAbort(cp)
      }
    }
  }

  // Small bordered temperature readout for the GPU temp grid.
  component TempBox: Rectangle {
    property string label: ""
    property real value: NaN
    property real ux: 1
    readonly property color valueColor: isNaN(value) ? root.cMuted
        : root.tempColor(value)
    color: Util.alpha(root.cCyan, 0.06)
    border.width: 1
    border.color: Util.alpha(valueColor, isNaN(value) ? 0.35 : 0.65)
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

  // Sparkline canvas: hairline grid, one or two smoothed series, repaints on
  // the shared clock tick. Guarded so collapsed/hidden panels cost nothing —
  // `live` lets a collapsible host panel stop repaints while folded.
  component TraceCanvas: Canvas {
    id: tc
    property var pts: []
    property var pts2: []
    property color col: root.cCyan
    property color col2: root.cMagenta
    property real vmax: 0
    property bool live: true
    property real _pk: 0

    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onColChanged: requestPaint()
    onCol2Changed: requestPaint()
    onLiveChanged: if (live) requestPaint()
    Connections {
      target: root
      function onTickSeqChanged() {
        if (tc.live && tc.visible && tc.width > 4 && tc.height > 4) tc.requestPaint()
      }
    }
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var w = width, h = height

      // hairline grid: quarter columns, faint midline, top/bottom edges and
      // a dim "input port" mark at the right edge where new samples enter
      ctx.lineWidth = 1
      ctx.strokeStyle = "rgba(13,74,97,0.38)"
      ctx.beginPath()
      for (var gx = 1; gx < 4; gx++) {
        var xg = Math.round(w * gx / 4) + 0.5
        ctx.moveTo(xg, 0); ctx.lineTo(xg, h)
      }
      var ym = Math.round(h * 0.5) + 0.5
      ctx.moveTo(0, ym); ctx.lineTo(w, ym)
      ctx.stroke()
      ctx.strokeStyle = "rgba(53,224,255,0.14)"
      ctx.beginPath()
      ctx.moveTo(0, 0.5); ctx.lineTo(w, 0.5)
      ctx.moveTo(0, h - 0.5); ctx.lineTo(w, h - 0.5)
      ctx.stroke()
      ctx.strokeStyle = root.rgbaOf(col, 0.30)
      ctx.beginPath()
      ctx.moveTo(w - 0.5, 0); ctx.lineTo(w - 0.5, h)
      ctx.stroke()

      // auto-scale off the eased samples, and ease the peak itself so a tall
      // value leaving the window doesn't snap the scale
      var peak = vmax
      if (!(peak > 0)) {
        var m = 0
        for (var i = 0; i < pts.length; i++)
          if (isFinite(pts[i]) && pts[i] > m) m = pts[i]
        for (var k2 = 0; k2 < pts2.length; k2++)
          if (isFinite(pts2[k2]) && pts2[k2] > m) m = pts2[k2]
        m *= 1.18
        if (!(m > 0)) m = 1
        tc._pk = tc._pk > 0 ? tc._pk + (m - tc._pk) * 0.18 : m
        peak = tc._pk
      }
      root.paintTrace(ctx, w, h, pts, col, peak, root.scrollPhase)
      if (pts2.length > 0)
        root.paintTrace(ctx, w, h, pts2, col2, peak, root.scrollPhase)
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

  // --------------------------------------- interactive chips + hit rows
  // Every interactive element owns a dormant Quickshell.Io.Process; a click
  // pulses `running` (false→true) which spawns the command detached. All of
  // these live inside CPanel bodies whose item rects are in the window mask,
  // so clicks never leak to the desktop.

  // Generic command chip — launcher / quick-action button.
  component CmdChip: Rectangle {
    id: cmdChip
    property string label: "APP"
    property string glyph: "▸"
    property color accent: root.cCyan
    property var argv: []
    property real ux: 1
    signal activated()

    width: chipRow.implicitWidth + 18 * ux
    height: 26 * ux
    color: cmdMa.containsMouse ? Util.alpha(accent, 0.20) : Util.alpha(accent, 0.07)
    border.color: cmdMa.containsMouse ? accent : Util.alpha(accent, 0.45)
    border.width: 1
    Behavior on color { ColorAnimation { duration: 110 } }
    Behavior on border.color { ColorAnimation { duration: 110 } }

    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: 5 * cmdChip.ux
      TLabel {
        anchors.verticalCenter: parent.verticalCenter
        text: cmdChip.glyph
        color: cmdChip.accent
        font.pixelSize: 10 * cmdChip.ux
        font.bold: true
      }
      TLabel {
        anchors.verticalCenter: parent.verticalCenter
        text: cmdChip.label
        color: cmdMa.containsMouse ? "#eafcff" : root.cTxt
        font.pixelSize: 9 * cmdChip.ux
        font.bold: true
        font.letterSpacing: 1.1 * cmdChip.ux
      }
    }
    Process {
      id: cmdProc
      command: cmdChip.argv.length > 0 ? cmdChip.argv : ["true"]
      running: false
      onExited: running = false
    }
    MouseArea {
      id: cmdMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (cmdProc.running) cmdProc.running = false
        cmdProc.running = true
        cmdChip.activated()
      }
    }
  }

  // Workspace chip — click dispatches `hyprctl dispatch workspace <id>`.
  component WsChip: Rectangle {
    id: wsChip
    property string wsId: ""
    property string wsName: ""
    property int wins: 0
    property bool active: false
    property bool onThisMon: false
    property real ux: 1

    width: wsChipRow.implicitWidth + 16 * ux
    height: 26 * ux
    color: active ? Util.alpha(root.cGreen, 0.22)
         : wsMa.containsMouse ? Util.alpha(root.cCyan, 0.16)
         : Util.alpha(root.cCyan, 0.05)
    border.color: active ? root.cGreen
                : wsMa.containsMouse ? root.cCyan
                : Util.alpha(root.cLine, onThisMon ? 1.0 : 0.6)
    border.width: active ? 2 : 1
    Behavior on color { ColorAnimation { duration: 110 } }

    Row {
      id: wsChipRow
      anchors.centerIn: parent
      spacing: 5 * wsChip.ux
      TLabel {
        anchors.verticalCenter: parent.verticalCenter
        text: wsChip.wsName
        color: wsChip.active ? root.cGreen : (wsMa.containsMouse ? "#eafcff" : root.cTxt)
        font.pixelSize: 9 * wsChip.ux
        font.bold: wsChip.active
        font.letterSpacing: 0.8 * wsChip.ux
      }
      TLabel {
        anchors.verticalCenter: parent.verticalCenter
        text: "·" + wsChip.wins
        color: wsChip.active ? root.cGreen : root.cMuted
        font.pixelSize: 8.5 * wsChip.ux
      }
    }
    Process {
      id: wsProc
      command: ["hyprctl", "dispatch", "workspace", wsChip.wsId]
      running: false
      onExited: running = false
    }
    MouseArea {
      id: wsMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (wsChip.wsId !== "") wsProc.running = true
    }
  }

  // Window row — click dispatches `hyprctl dispatch focuswindow address:<addr>`.
  component WinRow: Item {
    id: wrow
    property string addr: ""
    property string cls: ""
    property string wtitle: ""
    property string wsName: ""
    property string monName: ""
    property bool onThisScreen: false
    property bool activeWs: false
    property real ux: 1

    width: parent ? parent.width : 0
    height: 30 * ux

    Rectangle {
      anchors.fill: parent
      color: wMa.containsMouse ? Util.alpha(root.cCyan, 0.15)
           : wrow.onThisScreen ? Util.alpha(root.cCyan, 0.05)
           : "transparent"
      border.color: wMa.containsMouse ? Util.alpha(root.cCyan, 0.7)
                  : wrow.onThisScreen ? Util.alpha(root.cLine, 0.8)
                  : "transparent"
      border.width: 1
      Behavior on color { ColorAnimation { duration: 110 } }
    }
    Rectangle {
      id: wsBadge
      anchors { left: parent.left; leftMargin: 5 * wrow.ux; verticalCenter: parent.verticalCenter }
      width: 26 * wrow.ux
      height: 19 * wrow.ux
      color: wrow.activeWs ? Util.alpha(root.cGreen, 0.20) : Util.alpha(root.cCyan, 0.10)
      border.color: wrow.activeWs ? root.cGreen : Util.alpha(root.cCyan, 0.4)
      border.width: 1
      TLabel {
        anchors.centerIn: parent
        text: wrow.wsName
        color: wrow.activeWs ? root.cGreen : root.cCyan
        font.pixelSize: 8 * wrow.ux
        font.bold: true
        elide: Text.ElideRight
        width: parent.width - 2
        horizontalAlignment: Text.AlignHCenter
      }
    }
    Column {
      anchors {
        left: wsBadge.right; leftMargin: 7 * wrow.ux
        right: monLbl.left; rightMargin: 6 * wrow.ux
        verticalCenter: parent.verticalCenter
      }
      TLabel {
        width: parent.width
        text: wrow.cls
        color: wMa.containsMouse ? "#eafcff" : (wrow.activeWs ? root.cGreen : root.cTxt)
        font.pixelSize: 9 * wrow.ux
        font.bold: wrow.activeWs
        elide: Text.ElideRight
      }
      TLabel {
        width: parent.width
        text: wrow.wtitle
        color: root.cMuted
        font.pixelSize: 7.5 * wrow.ux
        elide: Text.ElideRight
      }
    }
    TLabel {
      id: monLbl
      anchors { right: parent.right; rightMargin: 6 * wrow.ux; verticalCenter: parent.verticalCenter }
      text: wrow.monName
      color: wrow.onThisScreen ? root.cGreen : root.cMuted
      font.pixelSize: 7.5 * wrow.ux
    }
    Process {
      id: focusProc
      command: ["hyprctl", "dispatch", "focuswindow", "address:" + wrow.addr]
      running: false
      onExited: running = false
    }
    MouseArea {
      id: wMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (wrow.addr !== "") focusProc.running = true
    }
  }

  // Agent harness chip — proc count + aggregate cpu; "build" styles itself
  // as an ACTIVE WORK indicator (amber pulse while compiler procs exist).
  component AgChip: Rectangle {
    id: agChip
    property string name: ""
    property int procs: 0
    property real cpu: 0
    property real ux: 1
    readonly property bool isBuild: name === "build"
    readonly property bool active: procs > 0
    readonly property color accent: isBuild ? root.cAmber : root.cMagenta

    height: 46 * ux
    color: active ? Util.alpha(accent, isBuild ? 0.10 + 0.10 * root.pulse : 0.15)
                  : Util.alpha(root.cTxt, 0.035)
    border.color: active ? Util.alpha(accent, isBuild ? 0.6 + 0.4 * root.pulse : 0.9)
                         : Util.alpha(root.cLine, 0.8)
    border.width: active ? 1.6 : 1
    Behavior on color { ColorAnimation { duration: 150 } }

    Column {
      anchors { left: parent.left; leftMargin: 8 * agChip.ux; right: parent.right; rightMargin: 6 * agChip.ux; verticalCenter: parent.verticalCenter }
      spacing: 2 * agChip.ux
      Row {
        spacing: 5 * agChip.ux
        TLabel {
          text: agChip.name.toUpperCase()
          color: agChip.active ? agChip.accent : root.cMuted
          font.pixelSize: 9 * agChip.ux
          font.bold: true
          font.letterSpacing: 1 * agChip.ux
        }
        TLabel {
          visible: agChip.isBuild && agChip.active
          text: "ACTIVE WORK"
          color: root.cAmber
          opacity: 0.45 + 0.55 * root.pulse
          font.pixelSize: 7 * agChip.ux
          font.bold: true
          font.letterSpacing: 0.8 * agChip.ux
        }
      }
      TLabel {
        text: agChip.active ? agChip.procs + " proc · " + Math.round(agChip.cpu) + "%" : "idle"
        color: agChip.active ? root.cTxt : root.cMuted
        font.pixelSize: 8.5 * agChip.ux
      }
    }
    Rectangle {
      visible: agChip.active
      anchors { right: parent.right; top: parent.top; margins: 4 * agChip.ux }
      width: 5 * agChip.ux
      height: width
      rotation: 45
      color: agChip.accent
      opacity: 0.5 + 0.5 * root.pulse
    }
  }

  // Peripheral battery row — eased bar, charging pulse, low-battery alert.
  component BatRow: Item {
    id: brow
    property string devName: ""
    property real pct: -1
    property string bstate: ""
    property real ux: 1
    readonly property bool charging: bstate === "Charging"
    readonly property bool full: bstate === "Full"
    readonly property bool low: !charging && !full && pct >= 0 && pct <= 20
    readonly property color stateCol: charging ? root.cGreen
                                  : full ? root.cGreen
                                  : low ? root.cAlert : root.cCyan

    width: parent ? parent.width : 0
    height: 32 * ux

    TLabel {
      id: bGlyph
      anchors { left: parent.left; verticalCenter: parent.verticalCenter }
      text: brow.charging ? "⌁" : "▮"
      color: brow.stateCol
      opacity: brow.charging ? 0.45 + 0.55 * root.pulse : 0.9
      font.pixelSize: 11 * brow.ux
    }
    TLabel {
      id: bName
      anchors { left: bGlyph.right; leftMargin: 7 * brow.ux; top: parent.top; topMargin: 1 * brow.ux }
      width: parent.width * 0.55
      text: brow.devName
      color: root.cTxt
      font.pixelSize: 9 * brow.ux
      font.bold: true
      elide: Text.ElideRight
    }
    TLabel {
      anchors { right: parent.right; top: parent.top; topMargin: 1 * brow.ux }
      text: brow.pct >= 0 ? Math.round(brow.pct) + "%" : "--"
      color: brow.stateCol
      font.pixelSize: 9.5 * brow.ux
      font.bold: true
    }
    Rectangle {
      id: bTrack
      anchors { left: bGlyph.right; leftMargin: 7 * brow.ux; right: parent.right; bottom: parent.bottom; bottomMargin: 4 * brow.ux }
      height: 5 * brow.ux
      color: Qt.rgba(1, 1, 1, 0.05)
      border.color: Util.alpha(root.cLine, 0.9)
      border.width: 1
      Rectangle {
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: Math.max(0, (bTrack.width - 2) * Util.clamp(brow.pct / 100, 0, 1))
        color: brow.stateCol
        opacity: brow.charging ? 0.6 + 0.4 * root.pulse : 1.0
        Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
      }
    }
    TLabel {
      anchors { right: parent.right; bottom: bTrack.top; bottomMargin: 1 }
      text: brow.bstate
      color: brow.stateCol
      opacity: brow.charging ? 0.4 + 0.6 * root.pulse : (brow.low ? 0.5 + 0.5 * root.pulse : 0.85)
      font.pixelSize: 7 * brow.ux
      font.letterSpacing: 1 * brow.ux
    }
  }

  // Repo feed row — click opens the repo page via xdg-open.
  component RepoRow: Item {
    id: rrow
    property string kind: ""
    property string repo: ""
    property string age: ""
    property string url: ""
    property real ux: 1

    width: parent ? parent.width : 0
    height: 27 * ux

    Rectangle {
      anchors.fill: parent
      color: rrMa.containsMouse ? Util.alpha(root.cGreen, 0.12) : "transparent"
      border.color: rrMa.containsMouse ? Util.alpha(root.cGreen, 0.5) : "transparent"
      border.width: 1
      Behavior on color { ColorAnimation { duration: 110 } }
    }
    Rectangle {
      anchors { left: parent.left; leftMargin: 4 * rrow.ux; verticalCenter: parent.verticalCenter }
      width: 40 * rrow.ux
      height: 17 * rrow.ux
      color: Util.alpha(root.cGreen, 0.10)
      border.color: Util.alpha(root.cGreen, 0.4)
      border.width: 1
      TLabel {
        anchors.centerIn: parent
        width: parent.width - 2
        text: rrow.kind
        color: root.cGreen
        font.pixelSize: 7.5 * rrow.ux
        font.bold: true
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
      }
    }
    TLabel {
      anchors { left: parent.left; leftMargin: 50 * rrow.ux; right: ageLbl.left; rightMargin: 6 * rrow.ux; verticalCenter: parent.verticalCenter }
      text: rrow.repo
      color: rrMa.containsMouse ? "#eafcff" : root.cTxt
      font.pixelSize: 9 * rrow.ux
      elide: Text.ElideRight
    }
    TLabel {
      id: ageLbl
      anchors { right: parent.right; rightMargin: 5 * rrow.ux; verticalCenter: parent.verticalCenter }
      text: rrow.age
      color: root.cCyan
      font.pixelSize: 8.5 * rrow.ux
    }
    Process {
      id: openProc
      command: rrow.url !== "" ? ["xdg-open", rrow.url] : ["true"]
      running: false
      onExited: running = false
    }
    MouseArea {
      id: rrMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: rrow.url !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (rrow.url !== "") openProc.running = true
    }
  }

  // One top-procs row: rank, name, eased cpu bar, percent.
  component ProcRow: Item {
    id: prow
    property int rank: 0
    property string pname: ""
    property real pcpu: 0
    property real ux: 1

    width: parent ? parent.width : 0
    height: 24 * ux

    TLabel {
      id: prk
      anchors { left: parent.left; verticalCenter: parent.verticalCenter }
      width: 16 * prow.ux
      text: prow.rank
      color: root.cMuted
      font.pixelSize: 8.5 * prow.ux
    }
    TLabel {
      id: pnm
      anchors { left: prk.right; leftMargin: 4 * prow.ux; verticalCenter: parent.verticalCenter }
      width: parent.width * 0.40
      text: prow.pname
      color: root.cTxt
      font.pixelSize: 9 * prow.ux
      elide: Text.ElideRight
    }
    Rectangle {
      id: ptrack
      anchors { left: pnm.right; leftMargin: 6 * prow.ux; right: ppct.left; rightMargin: 8 * prow.ux; verticalCenter: parent.verticalCenter }
      height: 5 * prow.ux
      color: Qt.rgba(1, 1, 1, 0.05)
      border.color: Util.alpha(root.cLine, 0.8)
      border.width: 1
      Rectangle {
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: Math.max(0, (ptrack.width - 2) * Util.clamp(prow.pcpu / 100, 0, 1))
        color: prow.pcpu >= 60 ? root.cMagenta : prow.pcpu >= 25 ? root.cAmber : root.cCyan
        Behavior on width { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }
      }
    }
    TLabel {
      id: ppct
      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
      width: 42 * prow.ux
      text: Math.round(prow.pcpu) + "%"
      horizontalAlignment: Text.AlignRight
      color: prow.pcpu >= 60 ? root.cMagenta : prow.pcpu >= 25 ? root.cAmber : root.cAccent
      font.pixelSize: 9 * prow.ux
    }
  }

  // Tmux session row — click spawns a foot terminal attached to the session.
  component TmuxRow: Item {
    id: trow
    property string sname: ""
    property int wins: 0
    property bool att: false
    property real ux: 1

    width: parent ? parent.width : 0
    height: 22 * ux

    Rectangle {
      anchors.fill: parent
      color: tmMa.containsMouse ? Util.alpha(root.cGreen, 0.12) : "transparent"
      border.color: tmMa.containsMouse ? Util.alpha(root.cGreen, 0.5) : "transparent"
      border.width: 1
      Behavior on color { ColorAnimation { duration: 110 } }
    }
    TLabel {
      anchors { left: parent.left; leftMargin: 5 * trow.ux; verticalCenter: parent.verticalCenter }
      text: "▸"
      color: trow.att ? root.cGreen : root.cMuted
      font.pixelSize: 9 * trow.ux
    }
    TLabel {
      anchors { left: parent.left; leftMargin: 18 * trow.ux; right: attBadge.left; rightMargin: 6 * trow.ux; verticalCenter: parent.verticalCenter }
      text: trow.sname + "  ·  " + trow.wins + " win"
      color: tmMa.containsMouse ? "#eafcff" : root.cTxt
      font.pixelSize: 8.5 * trow.ux
      elide: Text.ElideRight
    }
    Rectangle {
      id: attBadge
      visible: trow.att
      anchors { right: parent.right; rightMargin: 5 * trow.ux; verticalCenter: parent.verticalCenter }
      width: 34 * trow.ux
      height: 14 * trow.ux
      color: Util.alpha(root.cGreen, 0.14)
      border.color: Util.alpha(root.cGreen, 0.55)
      border.width: 1
      TLabel {
        anchors.centerIn: parent
        text: "ATT"
        color: root.cGreen
        font.pixelSize: 7 * trow.ux
        font.bold: true
      }
    }
    Process {
      id: attachProc
      command: ["foot", "tmux", "attach", "-t", trow.sname]
      running: false
      onExited: running = false
    }
    MouseArea {
      id: tmMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (trow.sname !== "") attachProc.running = true
    }
  }

  // Devin session-lock row — click opens the Devin desktop client.
  component DevRow: Item {
    id: drow
    property string sname: ""
    property int spid: 0
    property bool live: false
    property real ux: 1

    width: parent ? parent.width : 0
    height: 20 * ux

    Rectangle {
      anchors.fill: parent
      color: dvMa.containsMouse ? Util.alpha(root.cMagenta, 0.12) : "transparent"
      border.color: dvMa.containsMouse ? Util.alpha(root.cMagenta, 0.45) : "transparent"
      border.width: 1
      Behavior on color { ColorAnimation { duration: 110 } }
    }
    TLabel {
      anchors { left: parent.left; leftMargin: 5 * drow.ux; verticalCenter: parent.verticalCenter }
      text: "◆"
      color: drow.live ? root.cMagenta : root.cMuted
      opacity: drow.live ? 0.5 + 0.5 * root.pulse : 0.6
      font.pixelSize: 8 * drow.ux
    }
    TLabel {
      anchors { left: parent.left; leftMargin: 17 * drow.ux; right: pidLbl.left; rightMargin: 6 * drow.ux; verticalCenter: parent.verticalCenter }
      text: drow.sname
      color: dvMa.containsMouse ? "#eafcff" : (drow.live ? root.cTxt : root.cMuted)
      font.pixelSize: 8.5 * drow.ux
      elide: Text.ElideRight
    }
    TLabel {
      id: pidLbl
      anchors { right: parent.right; rightMargin: 5 * drow.ux; verticalCenter: parent.verticalCenter }
      text: drow.live ? "pid " + drow.spid : "stale"
      color: drow.live ? root.cGreen : root.cMuted
      font.pixelSize: 7.5 * drow.ux
    }
    Process {
      id: devProc
      command: ["gtk-launch", "devin-desktop"]
      running: false
      onExited: running = false
    }
    MouseArea {
      id: dvMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: devProc.running = true
    }
  }

  // Minimal mouse-only slider for the settings sheet: click or drag sets a
  // 0..1 value in 1/20 steps. The parent owns the value — the slider only
  // reports through moved() so its fill stays bound, never detached.
  component MiniSlider: Item {
    id: msl
    property real value: 0
    property real ux: 1
    property color accent: root.cCyan
    signal moved(real v)

    height: 20 * ux

    function setFromMouse(mx) {
      var v = Util.clamp(mx / Math.max(1, width), 0, 1)
      moved(Math.round(v * 20) / 20)
    }

    Rectangle {
      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
      height: 5 * msl.ux
      color: Qt.rgba(1, 1, 1, 0.05)
      border.color: Util.alpha(root.cLine, 0.9)
      border.width: 1
      Rectangle {
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: Math.max(0, (parent.width - 2) * Util.clamp(msl.value, 0, 1))
        color: Util.alpha(msl.accent, 0.7)
      }
    }
    Rectangle {
      x: Math.max(0, Math.min(parent.width - width, (parent.width - width) * Util.clamp(msl.value, 0, 1)))
      anchors.verticalCenter: parent.verticalCenter
      width: 8 * msl.ux
      height: 12 * msl.ux
      color: msl.accent
      border.color: "#eafcff"
      border.width: 1
    }
    MouseArea {
      anchors.fill: parent
      onPressed: msl.setFromMouse(mouse.x)
      onPositionChanged: if (pressed) msl.setFromMouse(mouse.x)
    }
  }

  // Small toggle chip for the settings sheet — click flips a boolean.
  component SetChip: Rectangle {
    id: schip
    property string label: ""
    property bool lit: false
    property color accent: root.cCyan
    property real ux: 1
    signal chosen()

    width: schipLbl.implicitWidth + 18 * ux
    height: 22 * ux
    color: lit ? Util.alpha(accent, 0.22) : Util.alpha(accent, 0.05)
    border.color: lit ? accent : Util.alpha(accent, 0.4)
    border.width: lit ? 1.6 : 1
    TLabel {
      id: schipLbl
      anchors.centerIn: parent
      text: schip.label
      color: schip.lit ? accent : (schipMa.containsMouse ? "#eafcff" : root.cMuted)
      font.pixelSize: 9 * schip.ux
      font.bold: schip.lit
      font.letterSpacing: 1 * schip.ux
    }
    MouseArea {
      id: schipMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: schip.chosen()
    }
  }

  // ------------------------------------------------------------ windows
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData

      screen: modelData

      // Role dispatch: each output renders a different page. Unknown outputs
      // fall back to the command cockpit so nothing ever renders empty.
      readonly property string role: String(modelData.name) === "DP-2" ? "hardware"
                                   : String(modelData.name) === "HDMI-A-3" ? "ops"
                                   : "command"
      readonly property bool isCommand:  role === "command"
      readonly property bool isHardware: role === "hardware"
      readonly property bool isOps:      role === "ops"
      readonly property string roleLabel: isHardware ? "HARDWARE DETAIL"
                                      : isOps ? "OPS / DEV CONSOLE"
                                      : "COMMAND COCKPIT"

      visible: !remapGuard.remapping
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "omarchy-hud"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      // Only the drawn panels accept pointer input; every other pixel of
      // this screen-sized surface passes clicks through to the desktop.
      // Role-gated: panels not on this role contribute no mask at all, and
      // `masked` additionally drops a panel's region while it is being
      // dragged or resized so a moving bezel can't eat clicks mid-flight.
      // The settings scrim covers the whole window while the sheet is open.
      mask: Region {
        regions: [
          Region { item: titlePlate },
          Region { item: win.sheetOpen ? sheetScrim : null },
          // command cockpit
          Region { item: win.isCommand && sysPanel.masked   ? sysPanel    : null },
          Region { item: win.isCommand && memPanel.masked   ? memPanel    : null },
          Region { item: win.isCommand && gpu0Panel.masked  ? gpu0Panel   : null },
          Region { item: win.isCommand && gpu1Panel.masked  ? gpu1Panel   : null },
          Region { item: win.isCommand && storPanel.masked  ? storPanel   : null },
          Region { item: win.centerShown && !win.zoneBusy ? sparkLPanel : null },
          Region { item: win.centerShown && !win.zoneBusy ? sparkRPanel : null },
          Region { item: win.centerShown && !win.zoneBusy ? procPanel   : null },
          Region { item: win.centerShown && !win.zoneBusy ? dialBox     : null },
          Region { item: win.isCommand && netPanel.masked    ? netPanel    : null },
          Region { item: win.isCommand && agentsPanel.masked ? agentsPanel : null },
          Region { item: win.isCommand && statusPanel.masked ? statusPanel : null },
          // compact launch rail (command + hardware tops)
          Region { item: !win.isOps ? topRail : null },
          // hardware detail
          Region { item: win.isHardware && hwMatrixPanel.masked   ? hwMatrixPanel   : null },
          Region { item: win.isHardware && hwSensorsPanel.masked  ? hwSensorsPanel  : null },
          Region { item: win.isHardware && hwGpu0Panel.masked     ? hwGpu0Panel     : null },
          Region { item: win.isHardware && hwGpu1Panel.masked     ? hwGpu1Panel     : null },
          Region { item: win.isHardware && hwProcsPanel.masked    ? hwProcsPanel    : null },
          Region { item: win.isHardware && hwStoragePanel.masked  ? hwStoragePanel  : null },
          Region { item: win.isHardware && hwPeriphPanel.masked   ? hwPeriphPanel   : null },
          Region { item: win.isHardware && hwMemoryPanel.masked   ? hwMemoryPanel   : null },
          Region { item: win.isHardware && hwStatusPanel.masked   ? hwStatusPanel   : null },
          Region { item: win.isHardware && hwNetPanel.masked      ? hwNetPanel      : null },
          // ops console
          Region { item: win.isOps && navPanel.masked        ? navPanel        : null },
          Region { item: win.isOps && opsProcsPanel.masked   ? opsProcsPanel   : null },
          Region { item: win.isOps && opsAgentsPanel.masked  ? opsAgentsPanel  : null },
          Region { item: win.isOps && repoPanel.masked       ? repoPanel       : null },
          Region { item: win.isOps && launchPanel.masked     ? launchPanel     : null },
          Region { item: win.isOps && opsActionsPanel.masked ? opsActionsPanel : null },
          Region { item: win.isOps && opsSysPanel.masked     ? opsSysPanel     : null },
          Region { item: win.isOps && opsPeriphPanel.masked  ? opsPeriphPanel  : null },
          Region { item: win.isOps && opsTracePanel.masked   ? opsTracePanel   : null },
          Region { item: win.isOps && opsStatusPanel.masked  ? opsStatusPanel  : null },
          Region { item: win.isOps && opsNetPanel.masked     ? opsNetPanel     : null }
        ]
      }

      ScreenMoveRemap { id: remapGuard; window: win }

      // ----------------------------------------------- ambient shader field
      // Screen-covering GLSL 440 effect UNDER all panels (first visual child).
      // A drifting hex/circuit grid with pulses travelling along its rows and
      // two slow plasma blooms, all driven by eased telemetry: u_load follows
      // sv.cpu, u_mem sv.mem, u_alert the alert lerp. Uniforms are exposed by
      // matching property names inside the std140 block. If the driver fails
      // to compile it the effect simply draws nothing — siblings unaffected.
      ShaderEffect {
        id: ambientField
        anchors.fill: parent
        visible: root.shaderOn
        opacity: Util.clamp(root.shaderIntensity, 0, 1)
        readonly property real uTime:  root.animT
        readonly property real uLoad:  Math.max(0, root.s("cpu", 0))
        readonly property real uMem:   Math.max(0, root.s("mem", 0))
        readonly property real uAlert: root.alertMix
        readonly property real uPulse: root.pulse
        readonly property vector2d uRes: Qt.vector2d(Math.max(1, width), Math.max(1, height))
        // Qt6 ShaderEffect needs a URL to a qsb shader pack — ambient.qsb is
        // precompiled from ambient.frag via /usr/lib/qt6/bin/qsb.
        fragmentShader: "ambient.qsb"
      }

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
      // Numeric id of the focused workspace on this output (for chip/row
      // highlighting); -99999 when Hyprland hasn't answered yet.
      readonly property int activeWsId: {
        try {
          if (win.hmonitor && win.hmonitor.activeWorkspace
              && win.hmonitor.activeWorkspace.id !== undefined)
            return win.hmonitor.activeWorkspace.id
        } catch (e) {}
        return -99999
      }

      // ------------------------------------------- free-canvas layout state
      // One layout map per screen: panelId -> {fx, fy, fw, fh?} expressed as
      // FRACTIONS of the `field` rect, so a monitor resize scales positions
      // instead of overflowing the bezel. fh is optional — panels hug their
      // content height until the user edge-resizes one. The whole map is a
      // single `var`: writes swap in a fresh object so bindings re-evaluate.
      property var layoutMap: ({})
      property var hiddenMap: ({})
      property bool layoutReady: false
      // Behaviors stay off until the first map lands so restoring a session
      // doesn't animate every panel in from the top-left corner.
      property bool animateLayout: false

      // gesture bookkeeping — one active gesture at a time, panel-local
      property string draggingId: ""
      property string sizingId: ""
      property string dragPendingId: ""
      property var dragSrc: null
      property var dragItem: null
      property var sizeSrc: null
      property var sizeItem: null
      property real grabDX: 0
      property real grabDY: 0
      property real pressFX: 0
      property real pressFY: 0
      property real sizeStartW: 0
      property real sizeStartH: 0
      property var ghostRect: null        // snapped drop preview, field px
      property bool sheetOpen: false
      property bool delegatesReady: false

      readonly property real grid: 12   // snap pitch in px (fixed, not ux-scaled)

      // Panels living on this screen's role, in default stacking order.
      readonly property var rolePanelIds: ({
        command:  ["system", "memory", "gpu", "gpu2", "storage", "center",
                   "network", "agents", "status"],
        hardware: ["matrix", "sensors", "gpu", "gpu2", "procs", "storage",
                   "periph", "memory", "status", "network"],
        ops:      ["windows", "procs", "agents", "repo", "launch", "actions",
                   "system", "periph", "traces", "status", "network"]
      })
      readonly property var roleIds: rolePanelIds[role] !== undefined ? rolePanelIds[role] : rolePanelIds.command
      readonly property string screenName: String(modelData.name)
      readonly property bool centerShown: isCommand && !isHidden("center")
      readonly property bool zoneBusy: draggingId === "center" || sizingId === "center"

      readonly property var panelLabels: ({
        system: "SYSTEM", memory: "MEMORY", gpu: "GPU SHEET 0",
        gpu2: "GPU SHEET 1", storage: "STORAGE", center: "REACTOR DIAL",
        network: "NETWORK", agents: "AGENTS", status: "STATUS",
        matrix: "CORE MATRIX", sensors: "SENSORS", procs: "TOP PROCS",
        periph: "PERIPHERALS", windows: "WINDOWS / NAV", repo: "REPO ACTIVITY",
        launch: "LAUNCH", actions: "OPS ACTIONS", traces: "OPS TRACE"
      })
      function panelLabel(id) {
        var t = panelLabels[id]
        return t !== undefined ? t : String(id).toUpperCase()
      }

      // id -> live item. Explicit per-role so colliding ids across roles
      // (e.g. "system" exists on command AND ops) can't overwrite each other.
      function itemFor(pid) {
        if (isHardware) {
          switch (pid) {
          case "matrix":  return hwMatrixPanel
          case "sensors": return hwSensorsPanel
          case "gpu":     return hwGpu0Panel
          case "gpu2":    return hwGpu1Panel
          case "procs":   return hwProcsPanel
          case "storage": return hwStoragePanel
          case "periph":  return hwPeriphPanel
          case "memory":  return hwMemoryPanel
          case "status":  return hwStatusPanel
          case "network": return hwNetPanel
          }
        } else if (isOps) {
          switch (pid) {
          case "windows": return navPanel
          case "procs":   return opsProcsPanel
          case "agents":  return opsAgentsPanel
          case "repo":    return repoPanel
          case "launch":  return launchPanel
          case "actions": return opsActionsPanel
          case "system":  return opsSysPanel
          case "periph":  return opsPeriphPanel
          case "traces":  return opsTracePanel
          case "status":  return opsStatusPanel
          case "network": return opsNetPanel
          }
        } else {
          switch (pid) {
          case "system":  return sysPanel
          case "memory":  return memPanel
          case "gpu":     return gpu0Panel
          case "gpu2":    return gpu1Panel
          case "storage": return storPanel
          case "center":  return centerZone
          case "network": return netPanel
          case "agents":  return agentsPanel
          case "status":  return statusPanel
          }
        }
        return null
      }

      function nh(pid) {
        var it = itemFor(pid)
        if (it === null || it === undefined) return 60 * ux
        // hidden/absent panels reserve no space, like the old column
        // positioners skipping invisible children
        if (it.shown !== undefined && it.shown === false) return 0
        if (!it.visible) return 0
        if (it.naturalH !== undefined && it.naturalH > 0) return it.naturalH
        return Math.max(20 * ux, it.height)
      }

      // ---- layout map access (fractions <-> field px) ----
      // Waits for the persisted blob: FileView load is async, so hydrating
      // late must still apply — the map isn't sealed until root.persistLoaded.
      function ensureLayout() {
        if (layoutReady || !delegatesReady || !root.persistLoaded) return
        if (field.width < 50 || field.height < 50) return
        initRetry.stop()
        var st = root.screenState(screenName)
        // hidden set first — defaultRects() consults `shown`, which reads it
        var hm = {}
        if (st && st.hidden) {
          for (var i = 0; i < st.hidden.length; i++) {
            var hid = String(st.hidden[i])
            if (roleIds.indexOf(hid) >= 0) hm[hid] = true
          }
        }
        hiddenMap = hm
        var m = (st && st.panels) ? sanitizeMap(st.panels) : null
        layoutMap = (m !== null) ? m : defaultRects()
        layoutReady = true
        reflowTimer.restart()          // clamp/resolve whatever we loaded
        animGate.start()               // enable slide animations after settle
      }

      function pxOf(id) { ensureLayout(); var r = layoutMap[id]; return r ? r.fx * field.width : 0 }
      function pyOf(id) { ensureLayout(); var r = layoutMap[id]; return r ? r.fy * field.height : 0 }
      function pwOf(id) { ensureLayout(); var r = layoutMap[id]; return r ? Math.max(40, r.fw * field.width) : 160 * ux }
      function phOf(id) { var r = layoutMap[id]; return (r && r.fh !== undefined && r.fh > 0) ? r.fh * field.height : -1 }

      function sanitizeMap(src) {
        var out = {}
        var any = false
        for (var i = 0; i < roleIds.length; i++) {
          var pid = roleIds[i]
          var e = src[pid]
          if (!e || typeof e !== "object") continue
          var fx = Number(e.fx), fy = Number(e.fy), fw = Number(e.fw)
          if (!isFinite(fx) || !isFinite(fy) || !isFinite(fw)) continue
          var r = { fx: Util.clamp(fx, 0, 1), fy: Util.clamp(fy, 0, 1),
                    fw: Util.clamp(fw, 0.04, 1) }
          var fh = Number(e.fh)
          if (isFinite(fh) && fh > 0) r.fh = Util.clamp(fh, 0, 1)
          out[pid] = r
          any = true
        }
        return any ? out : null
      }

      function mkRect(x, y, w, h) {
        var W = Math.max(1, field.width), H = Math.max(1, field.height)
        var ww = Math.min(Math.max(40, w), W)
        var hh = (h !== undefined && h > 0) ? Math.min(h, H) : -1
        var o = {
          fx: Util.clamp(x, 0, Math.max(0, W - ww)) / W,
          fy: Util.clamp(y, 0, Math.max(0, H - Math.max(0, hh))) / H,
          fw: ww / W
        }
        if (hh > 0) o.fh = hh / H
        return o
      }

      // Factory map: reproduces HudN's per-role column layout in field
      // coordinates. Panel heights read live `naturalH` so collapsed state
      // can't corrupt the defaults.
      function defaultRects() {
        var m = {}
        var W = Math.max(1, field.width), H = Math.max(1, field.height)
        var g = gap, rH = railH, sH = stripH
        if (isCommand) {
          var L = leftW, R = rightW
          var memH = nh("memory")
          var g0 = nh("gpu"), g1 = nh("gpu2"), gst = nh("storage")
          var spacer = Math.max(0, (rH - g0 - g1 - gst - 4 * g) / 2)
          m["system"]  = mkRect(0, 0, L)
          m["memory"]  = mkRect(0, Math.max(0, rH - memH), L)
          var rx = W - R
          m["gpu"]     = mkRect(rx, 0, R)
          m["gpu2"]    = mkRect(rx, g0 + g + spacer, R)
          m["storage"] = mkRect(rx, g0 + g1 + 2 * g + 2 * spacer, R)
          m["center"]  = mkRect(L + g, 0, Math.max(40, W - L - R - 2 * g), rH)
          var nw = Math.max(120, (W - 2 * g) * 0.40)
          var aw = Math.max(100, (W - 2 * g) * 0.34)
          var sw = Math.max(100, W - 2 * g - nw - aw)
          var sy = H - sH
          m["network"] = mkRect(0, sy, nw)
          m["agents"]  = mkRect(nw + g, sy, aw)
          m["status"]  = mkRect(nw + aw + 2 * g, sy, sw)
        } else if (isHardware) {
          var hL = hwLeftW, hM = hwMidW, hR = hwRightW
          var hmx = nh("matrix"), hsn = nh("sensors")
          var hg0 = nh("gpu"), hg1 = nh("gpu2"), hpr = nh("procs")
          var hst = nh("storage"), hpe = nh("periph"), hme = nh("memory")
          m["matrix"]  = mkRect(0, 0, hL)
          m["sensors"] = mkRect(0, hmx + g, hL)
          var hcx = hL + g
          m["gpu"]     = mkRect(hcx, 0, hM)
          m["gpu2"]    = mkRect(hcx, hg0 + g, hM)
          m["procs"]   = mkRect(hcx, hg0 + hg1 + 2 * g, hM)
          var hrx = W - hR
          m["storage"] = mkRect(hrx, 0, hR)
          m["periph"]  = mkRect(hrx, hst + g, hR)
          m["memory"]  = mkRect(hrx, hst + hpe + 2 * g, hR)
          var hs0 = Math.max(120, (W - g) * 0.52)
          var hs1 = Math.max(100, W - g - hs0)
          var hsy = H - sH
          m["status"]  = mkRect(0, hsy, hs0)
          m["network"] = mkRect(hs0 + g, hsy, hs1)
        } else {
          var oL = opsLeftW, oM = opsMidW, oR = opsRightW
          var onv = nh("windows"), opr = nh("procs")
          var oag = nh("agents"), orp = nh("repo")
          var oln = nh("launch"), oac = nh("actions"), osy = nh("system")
          var ope = nh("periph")
          m["windows"] = mkRect(0, 0, oL)
          m["procs"]   = mkRect(0, onv + g, oL)
          var ocx = oL + g
          m["agents"]  = mkRect(ocx, 0, oM)
          m["repo"]    = mkRect(ocx, oag + g, oM)
          var orx = W - oR
          m["launch"]  = mkRect(orx, 0, oR)
          m["actions"] = mkRect(orx, oln + g, oR)
          m["system"]  = mkRect(orx, oln + oac + 2 * g, oR)
          m["periph"]  = mkRect(orx, oln + oac + osy + 3 * g, oR)
          m["traces"]  = mkRect(orx, oln + oac + osy + ope + 4 * g, oR)
          var os0 = Math.max(120, (W - g) * 0.52)
          var os1 = Math.max(100, W - g - os0)
          var osy2 = H - sH
          m["status"]  = mkRect(0, osy2, os0)
          m["network"] = mkRect(os0 + g, osy2, os1)
        }
        return m
      }

      // ---- geometry helpers (all in field px) ----
      function snap(v) { return Math.round(v / grid) * grid }
      function overlaps(a, b) {
        return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
      }
      function overlapsAny(r, placed) {
        for (var i = 0; i < placed.length; i++) if (overlaps(r, placed[i])) return true
        return false
      }
      function clampRect(r) {
        r.x = Util.clamp(r.x, 0, Math.max(0, field.width - r.w))
        r.y = Util.clamp(r.y, 0, Math.max(0, field.height - r.h))
        return r
      }
      function rectOf(pid) {
        // committed rect in field px — map fractions + live height (or fh)
        var e = layoutMap[pid]
        var it = itemFor(pid)
        var w = e ? e.fw * field.width : (it !== null ? it.width : 120 * ux)
        var h
        if (e && e.fh !== undefined && e.fh > 0) h = e.fh * field.height
        else h = it !== null ? it.height : 80 * ux
        return { x: e ? e.fx * field.width : 0,
                 y: e ? e.fy * field.height : 0,
                 w: w, h: Math.max(10, h) }
      }
      // Nearest snapped position to r's centre clearing everything placed.
      // Deterministic scan of the 12 px grid; a packed field falls back to
      // the clamped original so a morph never teleports a panel away.
      function nearestFree(r, placed) {
        var maxX = Math.max(0, field.width - r.w)
        var maxY = Math.max(0, field.height - r.h)
        var cx0 = r.x + r.w / 2, cy0 = r.y + r.h / 2
        var best = null, bestScore = -1
        for (var gy = 0; gy <= maxY + 0.5; gy += grid) {
          var yy = Math.min(gy, maxY)
          for (var gx = 0; gx <= maxX + 0.5; gx += grid) {
            var xx = Math.min(gx, maxX)
            var cand = { x: xx, y: yy, w: r.w, h: r.h }
            if (overlapsAny(cand, placed)) continue
            var dx = xx + r.w / 2 - cx0, dy = yy + r.h / 2 - cy0
            var s = dx * dx + dy * dy
            if (best === null || s < bestScore) { best = cand; bestScore = s }
          }
        }
        return best !== null ? best : clampRect({ x: r.x, y: r.y, w: r.w, h: r.h })
      }

      // Morph pass: with `anchorId` the just-dropped/resized panel keeps its
      // rect and everything it overlaps eases to the nearest free space;
      // with "" it's a tidy-up (dynamic heights, unhide, load-time sanitize).
      function resolveLayout(anchorId) {
        if (!layoutReady) return
        var W = field.width, H = field.height
        if (W < 50 || H < 50) return
        var i, pid
        var rest = []
        for (i = 0; i < roleIds.length; i++) {
          pid = roleIds[i]
          if (pid === anchorId || isHidden(pid)) continue
          var it = itemFor(pid)
          if (it === null || it === undefined) continue
          if (!it.visible) continue
          rest.push(pid)
        }
        rest.sort(function(a, b) {
          var ra = rectOf(a), rb = rectOf(b)
          return (ra.y !== rb.y) ? ra.y - rb.y : ra.x - rb.x
        })
        var order = []
        var anchor = anchorId !== "" && !isHidden(anchorId) ? itemFor(anchorId) : null
        if (anchor !== null) order.push(anchorId)
        for (i = 0; i < rest.length; i++) order.push(rest[i])

        var placed = []
        var nm = {}
        for (var k in layoutMap) nm[k] = layoutMap[k]
        for (i = 0; i < order.length; i++) {
          pid = order[i]
          var r = clampRect(rectOf(pid))
          if (overlapsAny(r, placed)) r = nearestFree(r, placed)
          placed.push(r)
          var e = layoutMap[pid]
          var ne = { fx: r.x / W, fy: r.y / H, fw: r.w / W }
          if (e && e.fh !== undefined && e.fh > 0) ne.fh = r.h / H
          nm[pid] = ne
        }
        layoutMap = nm
      }

      // ---- drag lifecycle (shared by panel bezels and the reactor chassis)
      function dragPress(src, item, pid, mx, my) {
        if (draggingId !== "" || sizingId !== "") return
        dragSrc = src; dragItem = item; dragPendingId = pid
        var fp = src.mapToItem(field, mx, my)
        pressFX = fp.x; pressFY = fp.y
        grabDX = fp.x - item.x; grabDY = fp.y - item.y
      }
      function dragMove(src, item, mx, my) {
        if (item !== dragItem || src !== dragSrc) return
        var fp = src.mapToItem(field, mx, my)
        if (draggingId === "" && dragPendingId !== "") {
          if (Math.abs(fp.x - pressFX) > 8 || Math.abs(fp.y - pressFY) > 8) {
            draggingId = dragPendingId   // >8 px press-and-drag starts a move
            dragPendingId = ""
          }
        }
        if (draggingId === "") return
        var nx = Util.clamp(fp.x - grabDX, 0, Math.max(0, field.width - item.width))
        var ny = Util.clamp(fp.y - grabDY, 0, Math.max(0, field.height - item.height))
        item.x = nx
        item.y = ny
        ghostRect = { x: snap(nx), y: snap(ny), w: item.width, h: item.height }
      }
      // returns true when the gesture was a drag — header releases use it to
      // suppress the collapse toggle
      function dragRelease(item) {
        if (item !== dragItem) return false
        var did = draggingId
        if (did !== "") {
          commitRect(did, item.x, item.y)
          draggingId = ""
          resolveLayout(did)
          persist()
        }
        dragPendingId = ""; dragItem = null; dragSrc = null; ghostRect = null
        return did !== ""
      }
      function dragAbort(item) {
        if (item !== dragItem) return
        draggingId = ""; dragPendingId = ""
        dragItem = null; dragSrc = null; ghostRect = null
        // bindings re-engage -> the panel animates back to its committed rect
      }

      // ---- bottom-right edge-resize lifecycle ----
      function sizePress(src, item, pid, mx, my) {
        if (draggingId !== "" || sizingId !== "") return
        sizeSrc = src; sizeItem = item; sizingId = pid
        var fp = src.mapToItem(field, mx, my)
        pressFX = fp.x; pressFY = fp.y
        sizeStartW = item.width; sizeStartH = item.height
      }
      function sizeMove(src, item, mx, my) {
        if (item !== sizeItem || src !== sizeSrc || sizingId === "") return
        var fp = src.mapToItem(field, mx, my)
        var mW = item.minW !== undefined ? item.minW : 140 * ux
        var mH = item.minH !== undefined ? item.minH : 50 * ux
        var nw = Util.clamp(snap(sizeStartW + (fp.x - pressFX)),
                            mW, Math.max(mW, field.width - item.x))
        var nht = Util.clamp(snap(sizeStartH + (fp.y - pressFY)),
                             mH, Math.max(mH, field.height - item.y))
        item.width = nw
        if (item.sizeH !== undefined) item.sizeH = nht
        else item.height = nht
      }
      function sizeRelease(item) {
        if (item !== sizeItem) return
        var pid = sizingId
        sizingId = ""; sizeSrc = null; sizeItem = null
        commitRect(pid, item.x, item.y, item.width, item.height)
        resolveLayout(pid)
        persist()
      }
      function sizeAbort(item) {
        if (item !== sizeItem) return
        sizingId = ""; sizeSrc = null; sizeItem = null
      }

      function commitRect(pid, x, y, w, h) {
        var W = Math.max(1, field.width), H = Math.max(1, field.height)
        var it = itemFor(pid)
        var e = layoutMap[pid]
        var ww = (w !== undefined && w > 0) ? w : (e ? e.fw * W : (it !== null ? it.width : 120 * ux))
        var hh = (h !== undefined && h > 0) ? h
               : (e && e.fh !== undefined && e.fh > 0 ? e.fh * H
                  : (it !== null ? it.height : 80 * ux))
        var ne = {
          fx: Util.clamp(snap(x), 0, Math.max(0, W - ww)) / W,
          fy: Util.clamp(snap(y), 0, Math.max(0, H - hh)) / H,
          fw: ww / W
        }
        // an explicit h arg (resize) introduces or replaces the fh override;
        // a plain move keeps whatever the entry already had
        if (h !== undefined && h > 0) ne.fh = hh / H
        else if (e && e.fh !== undefined && e.fh > 0) ne.fh = e.fh
        var m = {}
        for (var k in layoutMap) m[k] = layoutMap[k]
        m[pid] = ne
        layoutMap = m
      }

      // ---- hidden-panel set + reset + persistence entry ----
      function isHidden(pid) { return hiddenMap[pid] === true }
      function toggleHidden(pid) {
        var m = {}
        for (var k in hiddenMap) m[k] = hiddenMap[k]
        if (isHidden(pid)) delete m[pid]; else m[pid] = true
        hiddenMap = m
        persist()
        reflowTimer.restart()
      }
      function resetLayout() {
        layoutMap = defaultRects()
        reflowTimer.restart()
        persist()
      }
      function persist() {
        if (!layoutReady) return
        var hidden = []
        for (var k in hiddenMap) if (hiddenMap[k] === true) hidden.push(k)
        root.mergeScreenState(screenName, { panels: layoutMap, hidden: hidden })
      }
      function noteGeomChange() { if (layoutReady) reflowTimer.restart() }

      Timer {
        id: reflowTimer
        interval: 280
        repeat: false
        onTriggered: {
          if (win.draggingId === "" && win.sizingId === "" && win.layoutReady)
            win.resolveLayout("")
        }
      }
      Timer {
        id: animGate
        interval: 450
        repeat: false
        onTriggered: win.animateLayout = true
      }
      // Startup watchdog: poll until the persisted blob lands (or the root
      // watchdog forces persistLoaded), then hydrate the layout map once.
      Timer {
        id: initRetry
        interval: 140
        repeat: true
        running: true
        onTriggered: win.ensureLayout()
      }

      Connections {
        target: root
        function onPersistLoadedChanged() { win.ensureLayout() }
      }

      Component.onCompleted: { win.delegatesReady = true; win.ensureLayout() }

      // ------------------------------------------------- layout constants
      // Everything scales by ux so the cockpit lays out proportionally on
      // any monitor size and never overflows its frame.
      readonly property real ux: Math.max(0.7, Math.min(width / 1600, height / 900))
      readonly property real pad: 14 * ux
      readonly property real gap: 12 * ux
      // deep enough that the centred title plate clears the omarchy bar
      readonly property real titleZoneH: 58 * ux
      readonly property real stripH: 138 * ux
      readonly property real railTop: pad + titleZoneH
      readonly property real railH: height - railTop - pad - gap - stripH
      readonly property real leftW: width * 0.20
      readonly property real rightW: width * 0.22
      // role column widths — tuned so the three columns tile the inner frame
      readonly property real hwLeftW: width * 0.26
      readonly property real hwMidW: width * 0.40
      readonly property real hwRightW: width * 0.28
      readonly property real opsLeftW: width * 0.30
      readonly property real opsMidW: width * 0.335
      readonly property real opsRightW: width * 0.315

      // ------------------------------------------------------- the frame
      // Double bezel: an outer hairline plus a recessed inner line, lerped
      // cyan -> alert red via alertMix. In alert a second, breathing halo
      // rect fades in around it — pure opacity, no per-frame repaint.
      Rectangle {
        id: frameLine
        anchors { fill: parent; margins: win.pad }
        color: "transparent"
        border.color: root.frameCol
        border.width: 1
        opacity: 0.8
      }
      Rectangle {
        id: frameInner
        anchors { fill: parent; margins: win.pad + 4 * win.ux }
        color: "transparent"
        border.color: root.lerpColor(root.cLine, root.cAlert, root.alertMix * 0.6)
        border.width: 1
        opacity: 0.35
      }
      Rectangle {
        id: frameHalo
        anchors { fill: parent; margins: win.pad - 2 * win.ux }
        color: "transparent"
        border.color: root.cAlert
        border.width: 1
        opacity: root.alertMix * (0.18 + 0.30 * root.pulse)
        visible: root.alertMix > 0.02
      }
      Bracket { ux: win.ux; col: root.frameCol; x: win.pad - width / 2;  y: win.pad - height / 2 }
      Bracket { ux: win.ux; col: root.frameCol; x: win.width - win.pad - width / 2; y: win.pad - height / 2; rotation: 90 }
      Bracket { ux: win.ux; col: root.frameCol; x: win.width - win.pad - width / 2; y: win.height - win.pad - height / 2; rotation: 180 }
      Bracket { ux: win.ux; col: root.frameCol; x: win.pad - width / 2;  y: win.height - win.pad - height / 2; rotation: 270 }
      // mid-edge tick marks — the "machined bezel" index notches, centred on
      // the frame line on each of the four sides
      Repeater {
        model: [
          { h: true, f: 0.0 },
          { h: true, f: 1.0 },
          { h: false, f: 0.0 },
          { h: false, f: 1.0 }
        ]
        delegate: Rectangle {
          required property var modelData
          width: modelData.h ? 14 * win.ux : 1
          height: modelData.h ? 1 : 14 * win.ux
          color: root.frameCol
          opacity: 0.55
          x: modelData.h ? win.width / 2 - width / 2
             : modelData.f === 0 ? win.pad - width / 2
             : win.width - win.pad - width / 2
          y: modelData.h ? (modelData.f === 0 ? win.pad : win.height - win.pad) - height / 2
             : win.height / 2 - height / 2
        }
      }

      // slow scan sweep — one faint band drifting down the screen every ~50 s,
      // moved by transform so it never repaints anything
      Rectangle {
        id: scanSweep
        width: parent.width - 2 * win.pad
        height: 90 * win.ux
        x: win.pad
        y: win.pad + ((root.animT * 20) % (win.height + 180 * win.ux)) - 90 * win.ux
        opacity: 0.55
        gradient: Gradient {
          GradientStop { position: 0.0; color: "transparent" }
          GradientStop { position: 0.5; color: Qt.rgba(0, 0.9, 1, 0.035) }
          GradientStop { position: 1.0; color: "transparent" }
        }
      }

      // ---------------------------------------------------- title plate
      // Straddles the top hairline like a label on a fieldset; clicking it
      // folds/unfolds every collapsible panel.
      Item {
        id: titlePlate
        width: plateRow.width + 34 * win.ux + gearChip.width
        height: 26 * win.ux
        anchors.horizontalCenter: parent.horizontalCenter
        // dropped below the omarchy bar / top frame line instead of
        // straddling it (was y: win.pad - height / 2)
        y: win.pad + 28 * win.ux
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
            layer.enabled: true
            layer.effect: MultiEffect {
              shadowEnabled: true
              shadowColor: root.cCyan
              shadowBlur: 0.7
              shadowOpacity: 0.45 + 0.30 * root.pulse
            }
          }
          TLabel {
            text: "//" + (root.hostName !== "" ? root.hostName : "?")
            color: root.cGreen
            font.pixelSize: 11.5 * win.ux
            font.bold: true
          }
          TLabel {
            text: win.roleLabel
            color: win.isOps ? root.cGreen : (win.isHardware ? root.cAmber : root.cMuted)
            font.pixelSize: 9 * win.ux
            font.letterSpacing: 2 * win.ux
          }
          TLabel {
            text: "▮"
            color: root.cCyan
            opacity: 0.30 + 0.70 * root.pulse
            font.pixelSize: 10 * win.ux
          }
        }
        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.toggleAll()
        }
        // settings gear — sits above the toggle-all MouseArea so its click
        // opens the sheet instead of folding every panel
        Rectangle {
          id: gearChip
          anchors { right: parent.right; top: parent.top; bottom: parent.bottom; margins: 2 }
          width: 26 * win.ux
          color: gearMa.containsMouse ? Util.alpha(root.cCyan, 0.18) : Util.alpha(root.cCyan, 0.05)
          border.color: gearMa.containsMouse ? root.cCyan : Util.alpha(root.cLine, 0.9)
          border.width: 1
          TLabel {
            anchors.centerIn: parent
            text: "⚙"
            color: gearMa.containsMouse ? "#eafcff" : root.cCyan
            font.pixelSize: 12 * win.ux
          }
          MouseArea {
            id: gearMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: win.sheetOpen = true
          }
        }
      }

      // --------------------------------------------- compact launch rail
      // Small chip row tucked into the top-right of the frame on the command
      // and hardware pages (ops gets a full LAUNCH panel instead).
      Row {
        id: topRail
        visible: !win.isOps
        anchors { right: parent.right; rightMargin: win.pad + 8 * win.ux }
        y: win.pad + 26 * win.ux
        height: 26 * win.ux
        spacing: 6 * win.ux
        TLabel {
          anchors.verticalCenter: parent.verticalCenter
          text: "⏻"
          color: root.cMuted
          font.pixelSize: 11 * win.ux
        }
        CmdChip { ux: win.ux; label: "DEVIN";   glyph: "◆"; accent: root.cMagenta; argv: ["gtk-launch", "devin-desktop"] }
        CmdChip { ux: win.ux; label: "TERM";    glyph: "▸"; accent: root.cGreen;   argv: ["gtk-launch", "foot"] }
        CmdChip { ux: win.ux; label: "FILES";   glyph: "▣"; accent: root.cAmber;   argv: ["gtk-launch", "org.gnome.Nautilus"] }
        CmdChip { ux: win.ux; label: "WEB";     glyph: "◉"; accent: root.cCyan;    argv: ["gtk-launch", "chromium"] }
        CmdChip { ux: win.ux; label: "LOCK";    glyph: "⏻"; accent: root.cAlert;   argv: ["omarchy-shell", "lock", "lock"] }
      }

      // ------------------------------------------------- free-canvas field
      // Every panel lives flat inside `field` — the area inside the bezel
      // frame, below the title zone. Positions come from win.layoutMap
      // (fractions of this rect) through the pxOf/pyOf/pwOf bindings inside
      // CPanel; drags, snaps and morph-reflow all work in field coordinates.
      Item {
        id: field
        x: win.pad
        y: win.railTop
        width: parent.width - 2 * win.pad
        height: parent.height - win.railTop - win.pad
        clip: true
        opacity: win.layoutReady ? 1 : 0
        onWidthChanged: if (!win.layoutReady) win.ensureLayout()
        onHeightChanged: if (!win.layoutReady) win.ensureLayout()

        CPanel {
          id: sysPanel
          host: win
          panelId: "system"
          shown: win.isCommand && !win.isHidden("system")
          ux: win.ux
          title: "◈ SYSTEM"
          accent: root.cCyan
          collapsed: root.isCollapsed("system")
          onToggled: root.toggleSection("system")
          contentH: 216 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 5 * win.ux

            // aggregate CPU: big eased number + compact facts column
            Item {
              width: parent.width
              height: 44 * win.ux
              TLabel {
                id: bigCpu
                anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                text: root.s("cpu") >= 0 ? Math.round(root.s("cpu") * 100) + "%" : "--"
                color: root.heatColor(root.s("cpu"), root.cCyan)
                font.pixelSize: 36 * win.ux
                font.bold: true
                layer.enabled: true
                layer.effect: MultiEffect {
                  shadowEnabled: true
                  shadowColor: bigCpu.color
                  shadowBlur: 0.8
                  shadowOpacity: 0.5 + 0.25 * root.pulse
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

            // per-core bar matrix: thin vertical bars, eased heights,
            // colour ramping green -> amber -> magenta with load
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
                    readonly property real frac: root.svCore(index)
                    Rectangle { anchors.fill: parent; color: Qt.rgba(0.05, 0.29, 0.38, 0.20) }
                    Rectangle {
                      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                      height: Math.max(1, parent.height * parent.frac)
                      color: root.gaugeColor(parent.frac)
                      Rectangle {
                        anchors { left: parent.left; right: parent.right; top: parent.top }
                        height: 1
                        color: "#eafcff"
                        opacity: 0.45
                        visible: parent.height > 4
                      }
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

        CPanel {
          id: memPanel
          host: win
          panelId: "memory"
          shown: win.isCommand && !win.isHidden("memory")
          ux: win.ux
          title: "▤ MEMORY"
          accent: root.cGreen
          collapsed: root.isCollapsed("memory")
          onToggled: root.toggleSection("memory")
          contentH: 62 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 4 * win.ux
            HudRow { label: "RAM";  value: root.memText;  fraction: root.s("mem");  accent: root.gaugeColor(root.s("mem")) }
            HudRow { label: "SWAP"; value: root.swapText; fraction: root.s("swap"); accent: root.gaugeColor(root.s("swap")); visible: root.swapFrac >= 0 }
          }
        }

        // ---------------------------------------------------- right rail
        // GPU0 — Intel Arc B580: full xe telemetry surface
        CPanel {
          id: gpu0Panel
          host: win
          panelId: "gpu"
          shown: win.isCommand && root.gpu0Shown && !win.isHidden("gpu")
          ux: win.ux
          title: "◉ " + root.gpu0Title
          accent: root.cMagenta
          collapsed: root.isCollapsed("gpu")
          onToggled: root.toggleSection("gpu")
          contentH: 290 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 4 * win.ux

            HudRow {
              label: "PWR"
              value: root.has("i_pwr_w")
                  ? root.stats.i_pwr_w + " W" + (root.has("i_pwr_cap_w") ? " / " + root.stats.i_pwr_cap_w + "W" : "")
                  : (root.has("i_pwr_cap_w") ? "cap " + root.stats.i_pwr_cap_w + " W" : "--")
              fraction: root.s("gpup")
              accent: root.gaugeColor(root.s("gpup"))
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
            HudRow { label: "VRAM";   value: root.num(root.stats.i_vram_used) + " / " + root.num(root.stats.i_vram_total) + " MiB"; fraction: root.s("ivram"); accent: root.gaugeColor(root.s("ivram")); visible: root.has("i_vram_total") }
            HudRow { label: "UTIL";   value: Math.round(root.num(root.stats.i_util)) + "%"; fraction: root.s("iutil"); accent: root.gaugeColor(root.s("iutil")); visible: root.has("i_util") }
            HudRow { label: "FREQ";   value: root.stats.i_freq_mhz + " MHz"; accent: root.cCyan; visible: root.has("i_freq_mhz") }

            // legacy single-GPU fallback keys
            HudRow { label: "UTIL"; value: Math.round(root.num(root.stats.gpu_util)) + "%"; fraction: root.s("gutil"); accent: root.gaugeColor(root.s("gutil")); visible: root.hasGpuUtil }
            HudRow { label: "VRAM"; value: root.num(root.stats.gpu_vram_used) + " / " + root.num(root.stats.gpu_vram_total) + " MiB"; fraction: root.gpuVramFrac; accent: root.gaugeColor(root.gpuVramFrac); visible: root.hasGpuVram }
            HudRow { label: "TEMP"; value: String(root.stats.gpu_temp) + "°C"; accent: root.tempColor(root.stats.gpu_temp); valueColor: root.tempColor(root.stats.gpu_temp); visible: root.hasGpuTemp }
          }
        }

        // GPU1 — AMD iGPU: util / vram / temp / power / freq
        CPanel {
          id: gpu1Panel
          host: win
          panelId: "gpu2"
          shown: win.isCommand && root.gpu1Shown && !win.isHidden("gpu2")
          ux: win.ux
          title: "◉ " + root.gpu1Title
          accent: root.cCyan
          collapsed: root.isCollapsed("gpu2")
          onToggled: root.toggleSection("gpu2")
          contentH: 140 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 4 * win.ux
            HudRow { label: "UTIL"; value: root.stats.a_util + "%"; fraction: root.s("autil"); accent: root.gaugeColor(root.s("autil")); visible: root.has("a_util") }
            HudRow { label: "VRAM"; value: root.stats.a_vram_used + " / " + root.stats.a_vram_total + " MiB"; fraction: root.s("avram"); accent: root.gaugeColor(root.s("avram")); visible: root.has("a_vram_total") }
            HudRow { label: "TEMP"; value: root.stats.a_temp + "°C"; accent: root.tempColor(root.stats.a_temp); valueColor: root.tempColor(root.stats.a_temp); visible: root.has("a_temp") }
            HudRow { label: "PWR";  value: root.stats.a_pwr_w + " W"; accent: root.cGreen; visible: root.has("a_pwr_w") }
            HudRow { label: "FREQ"; value: root.stats.a_freq_mhz + " MHz"; accent: root.cCyan; visible: root.has("a_freq_mhz") }
          }
        }

        CPanel {
          id: storPanel
          host: win
          panelId: "storage"
          shown: win.isCommand && !win.isHidden("storage")
          ux: win.ux
          title: "▣ STORAGE"
          accent: root.cAccent
          collapsed: root.isCollapsed("storage")
          onToggled: root.toggleSection("storage")
          contentH: 120 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 4 * win.ux
            HudRow { label: root.fsLabel("root"); value: root.fsText("root"); fraction: root.s("fsR"); accent: root.gaugeColor(root.s("fsR")) }
            // /home row hides itself when $HOME lives on the same mount as /
            HudRow { label: root.fsLabel("home"); value: root.fsText("home"); fraction: root.s("fsH"); accent: root.gaugeColor(root.s("fsH")); visible: root.fsFrac("home") >= 0 && root.fsLabel("home") !== root.fsLabel("root") }
            HudRow { label: "▼ READ";  value: root.fmtRate(root.stats.disk_read_bps);  accent: root.cGreen;   valueColor: root.cGreen;   visible: root.has("disk_read_bps") }
            HudRow { label: "▲ WRITE"; value: root.fmtRate(root.stats.disk_write_bps); accent: root.cMagenta; valueColor: root.cMagenta; visible: root.has("disk_write_bps") }
          }
        }

        // -------------------------------------------------- center stage
        // The reactor cluster — dial + flank traces + legend + proc marquee —
        // is ONE free-canvas unit: its internal anchoring survives so the
        // composite morphs to fit whatever rect it lands in.
        Item {
          id: centerZone
          visible: win.centerShown
          property real minW: 260 * win.ux
          property real minH: 200 * win.ux
          readonly property bool zdrag: win.draggingId === "center"
          readonly property bool zsize: win.sizingId === "center"

          z: (zdrag || zsize) ? 60 : 0
          opacity: zdrag ? 0.92 : 1.0
          Binding on x { when: !centerZone.zdrag; value: win.pxOf("center") }
          Binding on y { when: !centerZone.zdrag; value: win.pyOf("center") }
          Binding on width { when: !centerZone.zsize; value: win.pwOf("center") }
          Binding on height { when: !centerZone.zsize; value: Math.max(centerZone.minH, win.phOf("center")) }
          Behavior on x { enabled: win.animateLayout && !centerZone.zdrag; NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
          Behavior on y { enabled: win.animateLayout && !centerZone.zdrag; NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
          Behavior on width { enabled: win.animateLayout && !centerZone.zsize; NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
          Behavior on height { enabled: win.animateLayout && !centerZone.zsize; NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
          onHeightChanged: win.noteGeomChange()

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
              pts: root.dspCpu
              col: root.cCyan
              vmax: 100
            }
            SparkBox {
              width: parent.width
              height: (sparkLPanel.contentH - 5 * win.ux) / 2
              ux: win.ux
              label: "GPU0 PWR"
              val: root.has("i_pwr_w") ? Math.round(root.num(root.stats.i_pwr_w)) + " W" : "--"
              pts: root.dspGpuW
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
              pts: root.dspRx
              col: root.cGreen
            }
            SparkBox {
              width: parent.width
              height: (sparkRPanel.contentH - 5 * win.ux) / 2
              ux: win.ux
              label: "DISK READ"
              val: root.fmtRate(root.stats.disk_read_bps)
              pts: root.dspDisk
              col: root.cAmber
            }
          }
        }

        // the reactor: three concentric 270° arcs — outer CPU%, middle GPU0
        // power fraction, inner memory fraction — eased every frame, inside
        // a slowly orbiting tick ring with a comet on the outer track and a
        // breathing core glow around the centre readout
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
            Connections {
              target: root
              function onTickSeqChanged() {
                if (dialCanvas.visible && dialCanvas.width > 8) dialCanvas.requestPaint()
              }
            }
            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              var w = width, h = height
              if (w < 8 || h < 8) return
              var cx = w / 2, cy = h / 2
              var a0 = Math.PI * 0.75, span = Math.PI * 1.5
              var rOut = w * 0.44, rMid = w * 0.355, rIn = w * 0.27
              var lw = Math.max(2.5, w * 0.030)
              var rTick = w * 0.485
              var t = root.animT

              // breathing core glow behind the centre text
              var g = ctx.createRadialGradient(cx, cy, 0, cx, cy, rIn * 0.95)
              var gb = 0.10 + 0.05 * root.pulse
              g.addColorStop(0,   "rgba(53,224,255," + (gb + 0.04) + ")")
              g.addColorStop(0.7, "rgba(53,224,255," + (gb * 0.4) + ")")
              g.addColorStop(1,   "rgba(0,0,0,0)")
              ctx.fillStyle = g
              ctx.fillRect(cx - rIn, cy - rIn, 2 * rIn, 2 * rIn)

              // orbiting faint tick ring — the whole 360° drifts slowly CW
              var rot = t * 0.11
              ctx.strokeStyle = "rgba(13,74,97,0.45)"
              ctx.lineWidth = 1
              ctx.beginPath()
              for (var ti = 0; ti < 48; ti++) {
                var ta = rot + ti * Math.PI * 2 / 48
                ctx.moveTo(cx + rTick * Math.cos(ta), cy + rTick * Math.sin(ta))
                ctx.lineTo(cx + (rTick + w * 0.011) * Math.cos(ta), cy + (rTick + w * 0.011) * Math.sin(ta))
              }
              ctx.stroke()

              // static gauge ticks on the 270° span — majors take the
              // lerped frame colour so alerts still sweep through the dial
              var i
              ctx.strokeStyle = String(root.cLine)
              ctx.lineWidth = 1
              ctx.beginPath()
              for (i = 0; i <= 72; i++) {
                if (i % 12 === 0) continue
                var a = a0 + span * i / 72
                ctx.moveTo(cx + rTick * Math.cos(a), cy + rTick * Math.sin(a))
                ctx.lineTo(cx + (rTick + w * 0.014) * Math.cos(a), cy + (rTick + w * 0.014) * Math.sin(a))
              }
              ctx.stroke()
              ctx.strokeStyle = String(root.frameCol)
              ctx.lineWidth = Math.max(1.4, 1.8 * win.ux)
              ctx.beginPath()
              for (i = 0; i <= 72; i += 12) {
                var am = a0 + span * i / 72
                ctx.moveTo(cx + rTick * Math.cos(am), cy + rTick * Math.sin(am))
                ctx.lineTo(cx + (rTick + w * 0.030) * Math.cos(am), cy + (rTick + w * 0.030) * Math.sin(am))
              }
              ctx.stroke()

              // comet: a short bright arc with a fading tail riding just
              // inside the tick ring — continuous motion, no information
              var cometA = (t * 0.55) % (Math.PI * 2)
              var rComet = w * 0.468
              ctx.lineCap = "round"
              for (var cs = 0; cs < 7; cs++) {
                var tail = 1 - cs / 7
                ctx.strokeStyle = root.rgbaOf(root.cCyan, 0.34 * tail)
                ctx.lineWidth = Math.max(1.1, lw * 0.34 * (0.5 + 0.5 * tail))
                var a1 = cometA - cs * 0.045
                ctx.beginPath()
                ctx.arc(cx, cy, rComet, a1 - 0.055, a1)
                ctx.stroke()
              }
              ctx.lineCap = "butt"

              // eased arc rings: dim track, wide glow pass, hot core pass,
              // luminous tip dot. Colours ride the heat ramp continuously.
              function ring(r, frac, baseCol) {
                ctx.lineWidth = lw
                ctx.strokeStyle = root.rgbaOf(root.cLine, 0.85)
                ctx.beginPath()
                ctx.arc(cx, cy, r, a0, a0 + span)
                ctx.stroke()
                if (frac > 0.004) {
                  var f = Math.min(frac, 1)
                  var col = root.heatColor(f, baseCol)
                  var ae = a0 + span * f
                  ctx.strokeStyle = root.rgbaOf(col, 0.17)
                  ctx.lineWidth = lw * 2.0
                  ctx.beginPath()
                  ctx.arc(cx, cy, r, a0, ae)
                  ctx.stroke()
                  ctx.strokeStyle = root.rgbOf(col)
                  ctx.lineWidth = lw
                  ctx.beginPath()
                  ctx.arc(cx, cy, r, a0, ae)
                  ctx.stroke()
                  var tx = cx + r * Math.cos(ae), ty = cy + r * Math.sin(ae)
                  ctx.fillStyle = root.rgbaOf(col, 0.35)
                  ctx.beginPath()
                  ctx.arc(tx, ty, lw * 1.15, 0, Math.PI * 2)
                  ctx.fill()
                  ctx.fillStyle = "#eafcff"
                  ctx.beginPath()
                  ctx.arc(tx, ty, Math.max(1, lw * 0.30), 0, Math.PI * 2)
                  ctx.fill()
                }
              }
              ring(rOut, root.s("cpu"),   root.cCyan)
              ring(rMid, root.s("gpup"),  root.cMagenta)
              ring(rIn,  root.s("mem"),   root.cGreen)
            }
          }

          // two counter-rotating dashed rings between the inner arc and the
          // readout — transform-rotated by the shared clock, zero repaint
          Item {
            id: dashRingA
            anchors.centerIn: parent
            width: dialBox.width
            height: width
            rotation: (root.animT * -7) % 360
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
                x: dashRingA.width / 2 + rad * Math.cos(a) - width / 2
                y: dashRingA.height / 2 + rad * Math.sin(a) - height / 2
                rotation: index * 10 + 90
              }
            }
          }
          Item {
            id: dashRingB
            anchors.centerIn: parent
            width: dialBox.width
            height: width
            rotation: (root.animT * 12) % 360
            Repeater {
              model: 24
              delegate: Rectangle {
                required property int index
                readonly property real a: index * 2 * Math.PI / 24
                readonly property real rad: dialBox.width * 0.155
                width: Math.max(2, 2 * Math.PI * rad / 24 * 0.38)
                height: Math.max(1, 1.1 * win.ux)
                color: root.cAccent
                opacity: 0.28
                x: dashRingB.width / 2 + rad * Math.cos(a) - width / 2
                y: dashRingB.height / 2 + rad * Math.sin(a) - height / 2
                rotation: index * 15 + 90
              }
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
                shadowOpacity: 0.55 + 0.30 * root.pulse
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

        // Cluster drag surface — covers the whole chassis. Everything inside
        // is passive (traces, dial, marquee) and the nested panels' own grab
        // surfaces are disabled (unhosted), so this steals no clicks.
        MouseArea {
          id: zoneMa
          anchors.fill: parent
          onPressed: win.dragPress(zoneMa, centerZone, "center", mouse.x, mouse.y)
          onPositionChanged: win.dragMove(zoneMa, centerZone, mouse.x, mouse.y)
          onReleased: win.dragRelease(centerZone)
          onCanceled: win.dragAbort(centerZone)
        }
        // chassis resize grip, bottom-right
        Item {
          anchors { right: parent.right; bottom: parent.bottom; margins: 2 }
          width: 14 * win.ux
          height: 14 * win.ux
          opacity: zoneGrip.containsMouse || centerZone.zsize ? 1.0 : 0.35
          Rectangle { anchors { right: parent.right; bottom: parent.bottom } width: 1.5; height: 9 * win.ux; color: root.cAccent }
          Rectangle { anchors { right: parent.right; bottom: parent.bottom } width: 9 * win.ux; height: 1.5; color: root.cAccent }
          MouseArea {
            id: zoneGrip
            anchors { fill: parent; margins: -4 * win.ux }
            hoverEnabled: true
            cursorShape: Qt.SizeFDiagCursor
            onPressed: win.sizePress(zoneGrip, centerZone, "center", mouse.x, mouse.y)
            onPositionChanged: win.sizeMove(zoneGrip, centerZone, mouse.x, mouse.y)
            onReleased: win.sizeRelease(centerZone)
            onCanceled: win.sizeAbort(centerZone)
          }
        }
      }

      // ------------------------------------------------------ bottom strip
          CPanel {
            id: netPanel
            host: win
            panelId: "network"
            shown: win.isCommand && !win.isHidden("network")
            ux: win.ux
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
                pts: root.dspRx
                pts2: root.dspTx
                col: root.cGreen
                col2: root.cMagenta
                live: !root.isCollapsed("network")
              }
            }
          }

          CPanel {
            id: agentsPanel
            host: win
            panelId: "agents"
            shown: win.isCommand && !win.isHidden("agents")
            ux: win.ux
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
            host: win
            panelId: "status"
            shown: win.isCommand && !win.isHidden("status")
            ux: win.ux
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
                  opacity: 0.30 + 0.70 * root.pulse
                  font.pixelSize: 10 * win.ux
                }
              }
              TLabel {
                text: "FRAME " + root.batchSeq + (root.alert ? "  ·  OVERTEMP/MEM" : "")
                color: root.lerpColor(root.cMuted, root.cAlert, root.alertMix)
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

        // ================================================================
        // HARDWARE DETAIL page (DP-2 · HP E24i) — every sensor, no dial
        // ================================================================

        // left column: enlarged per-core matrix + extra sensor sheet
        CPanel {
          id: hwMatrixPanel
          host: win
          panelId: "matrix"
          shown: win.isHardware && !win.isHidden("matrix")
          ux: win.ux
          title: "▦ CORE MATRIX"
          accent: root.cCyan
          collapsed: root.isCollapsed("matrix")
          onToggled: root.toggleSection("matrix")
          contentH: 392 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 5 * win.ux

            Item {
              width: parent.width
              height: 42 * win.ux
              TLabel {
                id: hwBigCpu
                anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                text: root.s("cpu") >= 0 ? Math.round(root.s("cpu") * 100) + "%" : "--"
                color: root.heatColor(root.s("cpu"), root.cCyan)
                font.pixelSize: 34 * win.ux
                font.bold: true
                layer.enabled: true
                layer.effect: MultiEffect {
                  shadowEnabled: true
                  shadowColor: hwBigCpu.color
                  shadowBlur: 0.8
                  shadowOpacity: 0.5 + 0.25 * root.pulse
                }
              }
              Column {
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                spacing: 1
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
                TLabel {
                  text: root.has("cpu_temp") ? Math.round(root.num(root.stats.cpu_temp)) + "°C" : "--"
                  color: root.tempColor(root.stats.cpu_temp)
                  font.pixelSize: 10 * win.ux
                }
              }
            }

            // the enlarged matrix: ~3x taller bars + index ruler every 4
            Item {
              width: parent.width
              height: 216 * win.ux
              visible: root.coreCount > 0
              TLabel {
                id: hwCmLabel
                text: "PER-CORE BUSY · EASED 30Hz"
                color: root.cMuted
                font.pixelSize: 8.5 * win.ux
                font.letterSpacing: 2 * win.ux
              }
              Item {
                id: hwCoreBars
                anchors { left: parent.left; right: parent.right; top: hwCmLabel.bottom; topMargin: 4 * win.ux; bottom: hwRuler.top; bottomMargin: 3 * win.ux }
                readonly property int n: root.coreCount
                readonly property real bgap: Math.max(1, 2 * win.ux)
                readonly property real bw: n > 0 ? Math.max(1, (width - bgap * (n - 1)) / n) : 0
                Repeater {
                  model: hwCoreBars.n
                  delegate: Item {
                    required property int index
                    x: index * (hwCoreBars.bw + hwCoreBars.bgap)
                    width: hwCoreBars.bw
                    height: hwCoreBars.height
                    readonly property real frac: root.svCore(index)
                    Rectangle { anchors.fill: parent; color: Qt.rgba(0.05, 0.29, 0.38, 0.20) }
                    Rectangle {
                      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                      height: Math.max(1, parent.height * parent.frac)
                      color: root.gaugeColor(parent.frac)
                      Rectangle {
                        anchors { left: parent.left; right: parent.right; top: parent.top }
                        height: 1
                        color: "#eafcff"
                        opacity: 0.45
                        visible: parent.height > 4
                      }
                    }
                    TLabel {
                      visible: hwCoreBars.bw > 14
                      anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 2 }
                      text: Math.round(parent.frac * 100)
                      color: root.cTxt
                      font.pixelSize: 7.5 * win.ux
                      opacity: 0.8
                    }
                  }
                }
              }
              Row {
                id: hwRuler
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 10 * win.ux
                Repeater {
                  model: Math.ceil(hwCoreBars.n / 4)
                  delegate: TLabel {
                    required property int index
                    width: (hwCoreBars.bw + hwCoreBars.bgap) * 4
                    text: index * 4
                    color: root.cMuted
                    font.pixelSize: 7 * win.ux
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
            HudRow {
              label: "CLOCK"
              value: Math.round(root.num(root.stats.cpu_mhz_avg)) + " MHz"
                  + (root.has("cpu_mhz_max") ? " · " + Math.round(root.num(root.stats.cpu_mhz_max)) + " max" : "")
              accent: root.cCyan
              visible: root.has("cpu_mhz_avg")
            }
          }
        }

        CPanel {
          id: hwSensorsPanel
          host: win
          panelId: "sensors"
          ux: win.ux
          title: "♨ SENSORS"
          accent: root.cAmber
          collapsed: root.isCollapsed("sensors")
          onToggled: root.toggleSection("sensors")
          shown: win.isHardware && root.sensorRows().length > 0 && !win.isHidden("sensors")
          contentH: Math.min(18, root.sensorRows().length) * 19 * win.ux + 6 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 3 * win.ux
            Repeater {
              model: root.sensorRows()
              delegate: HudRow {
                required property var modelData
                label: modelData.label
                value: modelData.value
                valueColor: modelData.accent
                accent: modelData.accent
              }
            }
          }
        }

        // centre column: full GPU sheets + top procs
        CPanel {
          id: hwGpu0Panel
          host: win
          panelId: "gpu"
          ux: win.ux
          title: "◉ " + root.gpu0Title
          accent: root.cMagenta
          collapsed: root.isCollapsed("gpu")
          onToggled: root.toggleSection("gpu")
          shown: win.isHardware && root.gpu0Shown && !win.isHidden("gpu")
          contentH: 424 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 4 * win.ux

            HudRow {
              label: "PWR"
              value: root.has("i_pwr_w")
                  ? root.stats.i_pwr_w + " W" + (root.has("i_pwr_cap_w") ? " / " + root.stats.i_pwr_cap_w + "W" : "")
                  : (root.has("i_pwr_cap_w") ? "cap " + root.stats.i_pwr_cap_w + " W" : "--")
              fraction: root.s("gpup")
              accent: root.gaugeColor(root.s("gpup"))
              visible: root.has("i_pwr_w") || root.has("i_pwr_cap_w")
            }

            Item {
              width: parent.width
              height: 74 * win.ux
              visible: root.has("i_temp_pkg") || root.has("i_temp_vram")
                  || root.has("i_temp_mctrl") || root.has("i_temp_pcie")
              Grid {
                id: hwTempGrid
                anchors { left: parent.left; right: parent.right; top: parent.top }
                columns: 4
                columnSpacing: 4 * win.ux
                rowSpacing: 4 * win.ux
                TempBox {
                  ux: win.ux
                  width: (hwTempGrid.width - 3 * hwTempGrid.columnSpacing) / 4
                  height: 34 * win.ux
                  label: "PKG"
                  value: root.has("i_temp_pkg") ? root.num(root.stats.i_temp_pkg) : NaN
                  visible: root.has("i_temp_pkg")
                }
                TempBox {
                  ux: win.ux
                  width: (hwTempGrid.width - 3 * hwTempGrid.columnSpacing) / 4
                  height: 34 * win.ux
                  label: "VRAM"
                  value: root.has("i_temp_vram") ? root.num(root.stats.i_temp_vram) : NaN
                  visible: root.has("i_temp_vram")
                }
                TempBox {
                  ux: win.ux
                  width: (hwTempGrid.width - 3 * hwTempGrid.columnSpacing) / 4
                  height: 34 * win.ux
                  label: "MCTRL"
                  value: root.has("i_temp_mctrl") ? root.num(root.stats.i_temp_mctrl) : NaN
                  visible: root.has("i_temp_mctrl")
                }
                TempBox {
                  ux: win.ux
                  width: (hwTempGrid.width - 3 * hwTempGrid.columnSpacing) / 4
                  height: 34 * win.ux
                  label: "PCIE"
                  value: root.has("i_temp_pcie") ? root.num(root.stats.i_temp_pcie) : NaN
                  visible: root.has("i_temp_pcie")
                }
              }
            }

            HudRow { label: "VRM CH"; value: "max " + root.stats.i_vram_ch_max + "° · avg " + root.stats.i_vram_ch_avg + "°"; accent: root.cAmber; visible: root.has("i_vram_ch_max") }
            HudRow { label: "FAN";    value: root.stats.i_fan_rpm + " RPM"; accent: root.cCyan; visible: root.has("i_fan_rpm") }
            HudRow { label: "VRAM";   value: root.num(root.stats.i_vram_used) + " / " + root.num(root.stats.i_vram_total) + " MiB"; fraction: root.s("ivram"); accent: root.gaugeColor(root.s("ivram")); visible: root.has("i_vram_total") }
            HudRow { label: "UTIL";   value: Math.round(root.num(root.stats.i_util)) + "%"; fraction: root.s("iutil"); accent: root.gaugeColor(root.s("iutil")); visible: root.has("i_util") }
            HudRow { label: "FREQ";   value: root.stats.i_freq_mhz + " MHz"; accent: root.cCyan; visible: root.has("i_freq_mhz") }
            HudRow { label: "ENERGY"; value: (root.num(root.stats.i_energy_uj) / 1000000).toFixed(1) + " J"; accent: root.cGreen; visible: root.has("i_energy_uj") }

            HudRow { label: "UTIL"; value: Math.round(root.num(root.stats.gpu_util)) + "%"; fraction: root.s("gutil"); accent: root.gaugeColor(root.s("gutil")); visible: root.hasGpuUtil }
            HudRow { label: "VRAM"; value: root.num(root.stats.gpu_vram_used) + " / " + root.num(root.stats.gpu_vram_total) + " MiB"; fraction: root.gpuVramFrac; accent: root.gaugeColor(root.gpuVramFrac); visible: root.hasGpuVram }
            HudRow { label: "TEMP"; value: String(root.stats.gpu_temp) + "°C"; accent: root.tempColor(root.stats.gpu_temp); valueColor: root.tempColor(root.stats.gpu_temp); visible: root.hasGpuTemp }

            SparkBox {
              width: parent.width
              height: 84 * win.ux
              ux: win.ux
              label: "GPU0 PWR TRACE"
              val: root.has("i_pwr_w") ? Math.round(root.num(root.stats.i_pwr_w)) + " W" : "--"
              pts: root.dspGpuW
              col: root.cMagenta
              visible: root.has("i_pwr_w")
            }
          }
        }

        CPanel {
          id: hwGpu1Panel
          host: win
          panelId: "gpu2"
          ux: win.ux
          title: "◉ " + root.gpu1Title
          accent: root.cCyan
          collapsed: root.isCollapsed("gpu2")
          onToggled: root.toggleSection("gpu2")
          shown: win.isHardware && root.gpu1Shown && !win.isHidden("gpu2")
          contentH: 140 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 4 * win.ux
            HudRow { label: "UTIL"; value: root.stats.a_util + "%"; fraction: root.s("autil"); accent: root.gaugeColor(root.s("autil")); visible: root.has("a_util") }
            HudRow { label: "VRAM"; value: root.stats.a_vram_used + " / " + root.stats.a_vram_total + " MiB"; fraction: root.s("avram"); accent: root.gaugeColor(root.s("avram")); visible: root.has("a_vram_total") }
            HudRow { label: "TEMP"; value: root.stats.a_temp + "°C"; accent: root.tempColor(root.stats.a_temp); valueColor: root.tempColor(root.stats.a_temp); visible: root.has("a_temp") }
            HudRow { label: "PWR";  value: root.stats.a_pwr_w + " W"; accent: root.cGreen; visible: root.has("a_pwr_w") }
            HudRow { label: "FREQ"; value: root.stats.a_freq_mhz + " MHz"; accent: root.cCyan; visible: root.has("a_freq_mhz") }
          }
        }

        CPanel {
          id: hwProcsPanel
          host: win
          panelId: "procs"
          shown: win.isHardware && !win.isHidden("procs")
          ux: win.ux
          title: "▣ TOP PROCS"
          accent: root.cMagenta
          collapsed: root.isCollapsed("procs")
          onToggled: root.toggleSection("procs")
          contentH: 6 * 26 * win.ux + 8 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 2 * win.ux
            Repeater {
              model: 6
              delegate: ProcRow {
                required property int index
                ux: win.ux
                rank: index
                pname: root.procName(index)
                pcpu: root.procCpu(index)
                visible: root.has("proc" + index + "_name")
              }
            }
          }
        }
        // right column: storage detail, batteries, memory
        CPanel {
          id: hwStoragePanel
          host: win
          panelId: "storage"
          shown: win.isHardware && !win.isHidden("storage")
          ux: win.ux
          title: "▣ STORAGE"
          accent: root.cAccent
          collapsed: root.isCollapsed("storage")
          onToggled: root.toggleSection("storage")
          contentH: 196 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 4 * win.ux
            HudRow { label: root.fsLabel("root"); value: root.fsText("root"); fraction: root.s("fsR"); accent: root.gaugeColor(root.s("fsR")) }
            HudRow { label: root.fsLabel("home"); value: root.fsText("home"); fraction: root.s("fsH"); accent: root.gaugeColor(root.s("fsH")); visible: root.fsFrac("home") >= 0 && root.fsLabel("home") !== root.fsLabel("root") }
            HudRow { label: "▼ READ";  value: root.fmtRate(root.stats.disk_read_bps);  accent: root.cGreen;   valueColor: root.cGreen;   visible: root.has("disk_read_bps") }
            HudRow { label: "▲ WRITE"; value: root.fmtRate(root.stats.disk_write_bps); accent: root.cMagenta; valueColor: root.cMagenta; visible: root.has("disk_write_bps") }
            SparkBox {
              width: parent.width
              height: 74 * win.ux
              ux: win.ux
              label: "DISK READ TRACE"
              val: root.fmtRate(root.stats.disk_read_bps)
              pts: root.dspDisk
              col: root.cAmber
            }
          }
        }

        CPanel {
          id: hwPeriphPanel
          host: win
          panelId: "periph"
          ux: win.ux
          title: "⌁ PERIPHERALS"
          accent: root.cAmber
          collapsed: root.isCollapsed("periph")
          onToggled: root.toggleSection("periph")
          shown: win.isHardware && root.batCount > 0 && !win.isHidden("periph")
          contentH: Math.max(1, root.batCount) * 36 * win.ux + 8 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 4 * win.ux
            Repeater {
              model: root.batList()
              delegate: BatRow {
                required property var modelData
                ux: win.ux
                devName: modelData.name
                pct: modelData.pct
                bstate: modelData.state
              }
            }
          }
        }

        CPanel {
          id: hwMemoryPanel
          host: win
          panelId: "memory"
          shown: win.isHardware && !win.isHidden("memory")
          ux: win.ux
          title: "▤ MEMORY"
          accent: root.cGreen
          collapsed: root.isCollapsed("memory")
          onToggled: root.toggleSection("memory")
          contentH: 92 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 4 * win.ux
            HudRow { label: "RAM";  value: root.memText;  fraction: root.s("mem");  accent: root.gaugeColor(root.s("mem")) }
            HudRow { label: "SWAP"; value: root.swapText; fraction: root.s("swap"); accent: root.gaugeColor(root.s("swap")); visible: root.swapFrac >= 0 }
            HudRow {
              label: "ZRAM"
              value: root.num(root.stats.zram_used_mb) + " / " + root.num(root.stats.zram_orig_mb) + " MB"
                  + (root.has("zram_ratio") ? " · " + String(root.stats.zram_ratio) + "×" : "")
              accent: root.cCyan
              visible: root.has("zram_used_mb")
            }
          }
        }

        // hardware bottom strip: status + network
        CPanel {
          id: hwStatusPanel
          host: win
          panelId: "status"
          shown: win.isHardware && !win.isHidden("status")
          ux: win.ux
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
                  opacity: 0.30 + 0.70 * root.pulse
                  font.pixelSize: 10 * win.ux
                }
              }
              TLabel {
                text: "FRAME " + root.batchSeq
                    + (root.has("pkg_updates") ? "  ·  PKG UPD " + String(root.stats.pkg_updates) : "")
                color: root.has("pkg_updates") && root.num(root.stats.pkg_updates) > 0
                     ? root.cAmber : root.lerpColor(root.cMuted, root.cAlert, root.alertMix)
                font.pixelSize: 9.5 * win.ux
                font.letterSpacing: 1 * win.ux
              }
              TLabel {
                text: Qt.formatDateTime(root.now, "ddd dd MMM yyyy  ·  HH:mm")
                    + (root.has("weather") ? "  ·  " + String(root.stats.weather) : "")
                color: root.cMuted
                font.pixelSize: 9.5 * win.ux
                elide: Text.ElideRight
                width: parent.width
              }
              TLabel {
                text: "out " + String(win.modelData.name)
                    + (win.wsLabel !== "" ? " · ws " + win.wsLabel : "")
                    + (root.has("theme_name") ? " · " + String(root.stats.theme_name) : "")
                color: root.cMuted
                font.pixelSize: 9.5 * win.ux
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          CPanel {
            id: hwNetPanel
            host: win
            panelId: "network"
            shown: win.isHardware && !win.isHidden("network")
            ux: win.ux
            shrink: false
            title: "⇅ NETWORK"
            accent: root.cGreen
            collapsed: root.isCollapsed("network")
            onToggled: root.toggleSection("network")
            contentH: win.stripH - 22 * win.ux

            Item {
              anchors.fill: parent
              Column {
                id: hwNetRates
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
                anchors { left: hwNetRates.right; right: parent.right; top: parent.top; bottom: parent.bottom; leftMargin: 8 * win.ux }
                pts: root.dspRx
                pts2: root.dspTx
                col: root.cGreen
                col2: root.cMagenta
                live: !root.isCollapsed("network")
              }
            }
          }

        // ================================================================
        // OPS / DEV CONSOLE page (HDMI-A-3 · HP Z24n) — the work screen
        // ================================================================

        // left column: windows/nav + top procs
        CPanel {
          id: navPanel
          host: win
          panelId: "windows"
          shown: win.isOps && !win.isHidden("windows")
          ux: win.ux
          title: "≣ WINDOWS / NAV"
          accent: root.cGreen
          collapsed: root.isCollapsed("windows")
          onToggled: root.toggleSection("windows")
          // ws chips (~4/row estimate) + window rows + section labels
          contentH: (74 + Math.ceil(Math.min(14, Math.max(1, root.wsCount)) / 4) * 34
                     + Math.min(12, Math.max(1, root.winCount)) * 36) * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 6 * win.ux

            Row {
              spacing: 8 * win.ux
              TLabel {
                text: "WORKSPACES · CLICK TO JUMP"
                color: root.cMuted
                font.pixelSize: 8.5 * win.ux
                font.letterSpacing: 1.6 * win.ux
              }
              TLabel {
                text: "active " + (win.wsLabel !== "" ? win.wsLabel : "?")
                color: root.cGreen
                font.pixelSize: 8.5 * win.ux
              }
            }

            Flow {
              id: wsFlow
              width: parent.width
              height: Math.max(30 * win.ux, implicitHeight)
              spacing: 6 * win.ux
              Repeater {
                model: root.wsList()
                delegate: WsChip {
                  required property var modelData
                  ux: win.ux
                  wsId: String(modelData.id)
                  wsName: modelData.name
                  wins: modelData.wins
                  active: modelData.id === win.activeWsId
                  onThisMon: modelData.mon === String(win.modelData.name)
                }
              }
            }

            Rectangle {
              width: parent.width
              height: 1
              color: Util.alpha(root.cLine, 0.7)
            }

            Row {
              spacing: 8 * win.ux
              TLabel {
                text: "WINDOWS · CLICK TO FOCUS"
                color: root.cMuted
                font.pixelSize: 8.5 * win.ux
                font.letterSpacing: 1.6 * win.ux
              }
              TLabel {
                text: root.winCount + " clients"
                color: root.cCyan
                font.pixelSize: 8.5 * win.ux
              }
            }

            Repeater {
              model: root.winList(String(win.modelData.name))
              delegate: WinRow {
                required property var modelData
                ux: win.ux
                addr: modelData.addr
                cls: modelData.cls
                wtitle: modelData.title
                wsName: modelData.ws
                monName: modelData.mon
                onThisScreen: modelData.mon === String(win.modelData.name)
                activeWs: modelData.wsid === win.activeWsId
              }
            }

            TLabel {
              visible: root.winCount === 0
              text: "— no clients reported by collector —"
              color: root.cMuted
              font.pixelSize: 9 * win.ux
            }
          }
        }

        CPanel {
          id: opsProcsPanel
          host: win
          panelId: "procs"
          shown: win.isOps && !win.isHidden("procs")
          ux: win.ux
          title: "▣ TOP PROCS"
          accent: root.cMagenta
          collapsed: root.isCollapsed("procs")
          onToggled: root.toggleSection("procs")
          contentH: 6 * 26 * win.ux + 8 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 2 * win.ux
            Repeater {
              model: 6
              delegate: ProcRow {
                required property int index
                ux: win.ux
                rank: index
                pname: root.procName(index)
                pcpu: root.procCpu(index)
                visible: root.has("proc" + index + "_name")
              }
            }
          }
        }

        // centre column: agents expanded + repo feed
        CPanel {
          id: opsAgentsPanel
          host: win
          panelId: "agents"
          shown: win.isOps && !win.isHidden("agents")
          ux: win.ux
          title: "◉ AGENTS"
          accent: root.cMagenta
          collapsed: root.isCollapsed("agents")
          onToggled: root.toggleSection("agents")
          contentH: (172 + Math.max(1, Math.min(6, root.devsessCount)) * 27
                          + Math.max(1, Math.min(6, root.tmuxCount)) * 29) * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 6 * win.ux

            // per-harness chip grid — lit when procs are live; "build" is
            // the ACTIVE WORK indicator (amber pulse)
            Grid {
              id: agGrid
              width: parent.width
              height: 2 * 46 * win.ux + 6 * win.ux
              columns: 4
              columnSpacing: 6 * win.ux
              rowSpacing: 6 * win.ux
              Repeater {
                model: root.agList()
                delegate: AgChip {
                  required property var modelData
                  ux: win.ux
                  width: (agGrid.width - 3 * agGrid.columnSpacing) / 4
                  name: modelData.id
                  procs: modelData.procs
                  cpu: modelData.cpu
                }
              }
            }

            // live counters: devin acp sessions, session locks, tmux, procs
            Row {
              spacing: 6 * win.ux
              Rectangle {
                id: acpBadge
                width: acpLbl.implicitWidth + 14 * win.ux
                height: 22 * win.ux
                color: Util.alpha(root.cMagenta, root.devinAcp > 0 ? 0.16 + 0.10 * root.pulse : 0.06)
                border.color: Util.alpha(root.cMagenta, root.devinAcp > 0 ? 0.85 : 0.35)
                border.width: 1
                TLabel {
                  id: acpLbl
                  anchors.centerIn: parent
                  text: "DEVIN ACP " + root.devinAcp
                  color: root.devinAcp > 0 ? root.cMagenta : root.cMuted
                  font.pixelSize: 8.5 * win.ux
                  font.bold: true
                }
              }
              Rectangle {
                id: agnBadge
                width: agnLbl.implicitWidth + 14 * win.ux
                height: 22 * win.ux
                color: Util.alpha(root.cCyan, 0.06)
                border.color: Util.alpha(root.cCyan, 0.35)
                border.width: 1
                TLabel {
                  id: agnLbl
                  anchors.centerIn: parent
                  text: "PROCS " + (root.has("agents_procs") ? String(root.stats.agents_procs) : "0")
                  color: root.cTxt
                  font.pixelSize: 8.5 * win.ux
                }
              }
              Rectangle {
                id: tmxBadge
                width: tmxLbl.implicitWidth + 14 * win.ux
                height: 22 * win.ux
                color: Util.alpha(root.cGreen, 0.06)
                border.color: Util.alpha(root.cGreen, 0.35)
                border.width: 1
                TLabel {
                  id: tmxLbl
                  anchors.centerIn: parent
                  text: "TMUX " + (root.has("agents_tmux") ? String(root.stats.agents_tmux) : "0")
                  color: root.cTxt
                  font.pixelSize: 8.5 * win.ux
                }
              }
              TLabel {
                anchors.verticalCenter: parent.verticalCenter
                text: "HOT " + root.hotText
                color: root.cAmber
                font.pixelSize: 8.5 * win.ux
                elide: Text.ElideRight
                width: Math.max(30 * win.ux, parent.width - acpBadge.width - agnBadge.width - tmxBadge.width - 3 * parent.spacing)
              }
            }

            TLabel {
              text: "DEVIN SESSIONS"
              color: root.cMuted
              font.pixelSize: 8 * win.ux
              font.letterSpacing: 1.6 * win.ux
            }
            Repeater {
              model: root.devsessList()
              delegate: DevRow {
                required property var modelData
                ux: win.ux
                sname: modelData.name
                spid: modelData.pid
                live: modelData.live
              }
            }
            TLabel {
              visible: root.devsessCount === 0
              text: "— no devin session locks —"
              color: root.cMuted
              font.pixelSize: 8.5 * win.ux
            }

            TLabel {
              text: "TMUX · CLICK TO ATTACH"
              color: root.cMuted
              font.pixelSize: 8 * win.ux
              font.letterSpacing: 1.6 * win.ux
            }
            Repeater {
              model: root.tmuxList()
              delegate: TmuxRow {
                required property var modelData
                ux: win.ux
                sname: modelData.name
                wins: modelData.win
                att: modelData.att
              }
            }
            TLabel {
              visible: root.tmuxCount === 0
              text: "— no tmux sessions —"
              color: root.cMuted
              font.pixelSize: 8.5 * win.ux
            }
          }
        }

        CPanel {
          id: repoPanel
          host: win
          panelId: "repo"
          shown: win.isOps && !win.isHidden("repo")
          ux: win.ux
          title: "⎇ REPO ACTIVITY" + (root.ghUnread > 0 ? "  ·  " + root.ghUnread + " UNREAD" : "")
          accent: root.cGreen
          collapsed: root.isCollapsed("repo")
          onToggled: root.toggleSection("repo")
          contentH: (34 + Math.max(1, root.ghEvCount) * 33) * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 5 * win.ux

            Item {
              width: parent.width
              height: 22 * win.ux
              TLabel {
                anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                text: root.ghOk ? "GITHUB · " + String(root.stats.gh_user) : "GITHUB · OFFLINE"
                color: root.ghOk ? root.cGreen : root.cAlert
                font.pixelSize: 9 * win.ux
                font.bold: true
                font.letterSpacing: 0.8 * win.ux
              }
              Rectangle {
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                width: unLbl.implicitWidth + 14 * win.ux
                height: 19 * win.ux
                color: Util.alpha(root.cMagenta, root.ghUnread > 0 ? 0.16 + 0.12 * root.pulse : 0.05)
                border.color: Util.alpha(root.cMagenta, root.ghUnread > 0 ? 0.8 : 0.3)
                border.width: 1
                TLabel {
                  id: unLbl
                  anchors.centerIn: parent
                  text: "UNREAD " + root.ghUnread
                  color: root.ghUnread > 0 ? root.cMagenta : root.cMuted
                  font.pixelSize: 8 * win.ux
                  font.bold: true
                }
              }
            }

            Repeater {
              model: root.ghevList()
              delegate: RepoRow {
                required property var modelData
                ux: win.ux
                kind: modelData.type
                repo: modelData.repo
                age: modelData.age
                url: modelData.url
              }
            }

            TLabel {
              visible: !root.ghOk
              text: "— github feed offline (gh_ok=0) —"
              color: root.cAlert
              font.pixelSize: 9 * win.ux
            }
            TLabel {
              visible: root.ghOk && root.ghEvCount === 0
              text: "— no recent events —"
              color: root.cMuted
              font.pixelSize: 9 * win.ux
            }
          }
        }
        // right column: launch rail + quick actions + mini system + traces
        CPanel {
          id: launchPanel
          host: win
          panelId: "launch"
          shown: win.isOps && !win.isHidden("launch")
          ux: win.ux
          title: "⏻ LAUNCH"
          accent: root.cCyan
          collapsed: root.isCollapsed("launch")
          onToggled: root.toggleSection("launch")
          contentH: 96 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 6 * win.ux
            Row {
              spacing: 6 * win.ux
              CmdChip { ux: win.ux; label: "DEVIN";    glyph: "◆"; accent: root.cMagenta; argv: ["gtk-launch", "devin-desktop"] }
              CmdChip { ux: win.ux; label: "OCTOBER";  glyph: "◉"; accent: root.cCyan;    argv: ["gtk-launch", "october"] }
              CmdChip { ux: win.ux; label: "TERM";     glyph: "▸"; accent: root.cGreen;   argv: ["gtk-launch", "foot"] }
              CmdChip { ux: win.ux; label: "FILES";    glyph: "▣"; accent: root.cAmber;   argv: ["gtk-launch", "org.gnome.Nautilus"] }
            }
            Row {
              spacing: 6 * win.ux
              CmdChip { ux: win.ux; label: "WEB";      glyph: "◉"; accent: root.cCyan;    argv: ["gtk-launch", "chromium"] }
              CmdChip { ux: win.ux; label: "SPOTIFY";  glyph: "♫"; accent: root.cGreen;   argv: ["gtk-launch", "spotify"] }
              CmdChip { ux: win.ux; label: "OBSIDIAN"; glyph: "◈"; accent: root.cMagenta; argv: ["gtk-launch", "obsidian"] }
              CmdChip { ux: win.ux; label: "HAZE";     glyph: "▲"; accent: root.cAmber;   argv: ["gtk-launch", "devin-desktop"] }
            }
          }
        }

        CPanel {
          id: opsActionsPanel
          host: win
          panelId: "actions"
          shown: win.isOps && !win.isHidden("actions")
          ux: win.ux
          title: "⚙ OPS ACTIONS"
          accent: root.cAmber
          collapsed: root.isCollapsed("actions")
          onToggled: root.toggleSection("actions")
          contentH: 100 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 6 * win.ux
            Row {
              spacing: 6 * win.ux
              CmdChip { ux: win.ux; label: "COFFEE"; glyph: "◐"; accent: root.cAmber; argv: ["omarchy-shell", "idle", "toggle"] }
              CmdChip { ux: win.ux; label: "NIGHT";  glyph: "☾"; accent: root.cCyan;  argv: ["omarchy-shell", "nightlight", "toggle"] }
              CmdChip { ux: win.ux; label: "MEDIA";  glyph: "⏯"; accent: root.cGreen; argv: ["omarchy-shell", "media", "playPause"] }
            }
            Row {
              spacing: 6 * win.ux
              CmdChip { ux: win.ux; label: "NOTIF CLR"; glyph: "✕"; accent: root.cMuted; argv: ["omarchy-shell", "notifications", "clear"] }
              CmdChip { ux: win.ux; label: "RELOAD";    glyph: "⟳"; accent: root.cCyan; argv: ["omarchy-shell", "shell", "reloadConfig"] }
              CmdChip { ux: win.ux; label: "LOCK";      glyph: "⏻"; accent: root.cAlert; argv: ["omarchy-shell", "lock", "lock"] }
            }
          }
        }

        CPanel {
          id: opsSysPanel
          host: win
          panelId: "system"
          shown: win.isOps && !win.isHidden("system")
          ux: win.ux
          title: "◈ SYSTEM"
          accent: root.cCyan
          collapsed: root.isCollapsed("system")
          onToggled: root.toggleSection("system")
          contentH: 142 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 4 * win.ux
            HudRow { label: "CPU";  value: root.cpuText; fraction: root.s("cpu"); accent: root.heatColor(root.s("cpu"), root.cCyan) }
            HudRow { label: "MEM";  value: root.memText; fraction: root.s("mem"); accent: root.gaugeColor(root.s("mem")) }
            HudRow { label: "LOAD"; value: root.loadText }
            HudRow {
              label: "TEMP"
              value: String(root.stats.cpu_temp) + "°C"
              accent: root.tempColor(root.stats.cpu_temp)
              valueColor: root.tempColor(root.stats.cpu_temp)
              visible: root.has("cpu_temp")
            }
            HudRow { label: "UP";   value: root.uptimeText }
          }
        }

        CPanel {
          id: opsPeriphPanel
          host: win
          panelId: "periph"
          ux: win.ux
          title: "⌁ PERIPHERALS"
          accent: root.cAmber
          collapsed: root.isCollapsed("periph")
          onToggled: root.toggleSection("periph")
          shown: win.isOps && root.batCount > 0 && !win.isHidden("periph")
          contentH: Math.max(1, root.batCount) * 36 * win.ux + 8 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 4 * win.ux
            Repeater {
              model: root.batList()
              delegate: BatRow {
                required property var modelData
                ux: win.ux
                devName: modelData.name
                pct: modelData.pct
                bstate: modelData.state
              }
            }
          }
        }

        CPanel {
          id: opsTracePanel
          host: win
          panelId: "traces"
          shown: win.isOps && !win.isHidden("traces")
          ux: win.ux
          title: "∿ OPS TRACE"
          accent: root.cAccent
          collapsed: root.isCollapsed("traces")
          onToggled: root.toggleSection("traces")
          contentH: 150 * win.ux

          Column {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            spacing: 5 * win.ux
            SparkBox {
              width: parent.width
              height: 68 * win.ux
              ux: win.ux
              label: "CPU %"
              val: root.cpuText
              pts: root.dspCpu
              col: root.cCyan
              vmax: 100
            }
            SparkBox {
              width: parent.width
              height: 68 * win.ux
              ux: win.ux
              label: "NET RX"
              val: root.fmtRate(root.rxRate)
              pts: root.dspRx
              col: root.cGreen
            }
          }
        }

        // ops bottom strip: status + network
        CPanel {
          id: opsStatusPanel
          host: win
          panelId: "status"
          shown: win.isOps && !win.isHidden("status")
          ux: win.ux
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
                  opacity: 0.30 + 0.70 * root.pulse
                  font.pixelSize: 10 * win.ux
                }
                TLabel {
                  text: Qt.formatDateTime(root.now, "HH:mm:ss")
                  color: "#eafcff"
                  font.pixelSize: 12 * win.ux
                  font.bold: true
                }
              }
              TLabel {
                text: "FRAME " + root.batchSeq
                    + (root.ghUnread > 0 ? "  ·  GH UNREAD " + root.ghUnread : "")
                    + (root.has("pkg_updates") && root.num(root.stats.pkg_updates) > 0
                       ? "  ·  PKG UPD " + String(root.stats.pkg_updates) : "")
                color: root.lerpColor(root.cMuted, root.cAlert, root.alertMix)
                font.pixelSize: 9.5 * win.ux
                font.letterSpacing: 1 * win.ux
              }
              TLabel {
                text: Qt.formatDateTime(root.now, "ddd dd MMM yyyy")
                    + (root.has("weather") ? "  ·  " + String(root.stats.weather) : "")
                color: root.cMuted
                font.pixelSize: 9.5 * win.ux
                elide: Text.ElideRight
                width: parent.width
              }
              TLabel {
                text: "out " + String(win.modelData.name)
                    + (win.wsLabel !== "" ? " · ws " + win.wsLabel : "")
                    + "  ·  " + root.winCount + " clients / " + root.wsCount + " ws"
                color: root.cMuted
                font.pixelSize: 9.5 * win.ux
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

        CPanel {
          id: opsNetPanel
          host: win
          panelId: "network"
          shown: win.isOps && !win.isHidden("network")
          ux: win.ux
          shrink: false
          title: "⇅ NETWORK"
            accent: root.cGreen
            collapsed: root.isCollapsed("network")
            onToggled: root.toggleSection("network")
            contentH: win.stripH - 22 * win.ux

            Item {
              anchors.fill: parent
              Column {
                id: opsNetRates
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
                anchors { left: opsNetRates.right; right: parent.right; top: parent.top; bottom: parent.bottom; leftMargin: 8 * win.ux }
                pts: root.dspRx
                pts2: root.dspTx
                col: root.cGreen
                col2: root.cMagenta
                live: !root.isCollapsed("network")
              }
            }
          }

        // drop ghost — previews the snapped rect under the pointer while a
        // panel (or the reactor chassis) is dragged
        Rectangle {
          id: ghostBox
          visible: win.ghostRect !== null
          x: win.ghostRect ? win.ghostRect.x : 0
          y: win.ghostRect ? win.ghostRect.y : 0
          width: win.ghostRect ? win.ghostRect.w : 0
          height: win.ghostRect ? win.ghostRect.h : 0
          color: Util.alpha(root.cAccent, 0.08)
          border.color: root.cAccent
          border.width: 1
          opacity: 0.85
          z: 80
        }
      }

      // -------------------------------------------- scanlines + vignette
      // Painted once per resize — a static texture, not an animation. Adds
      // a faint vertical hairline grid so the black between panels reads as
      // graph paper rather than void.
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
          ctx.strokeStyle = "rgba(13,74,97,0.10)"
          ctx.beginPath()
          for (var x = 0.5 + 48; x < width; x += 48) {
            ctx.moveTo(x, 0)
            ctx.lineTo(x, height)
          }
          ctx.stroke()
        }
      }

      // --------------------------------------------------- settings sheet
      // Modal, mouse-only (the window takes no keyboard focus): scrim swallows
      // the click-through, the sheet carries toggles / swatches / a slider /
      // chips only. Both live inside the window mask via sheetScrim.
      Rectangle {
        id: sheetScrim
        anchors.fill: parent
        visible: win.sheetOpen
        color: Qt.rgba(0.008, 0.03, 0.05, 0.62)
        MouseArea {
          anchors.fill: parent
          onClicked: win.sheetOpen = false
        }
      }

      Rectangle {
        id: settingsSheet
        visible: win.sheetOpen
        anchors.centerIn: parent
        width: Math.min(parent.width - 60 * win.ux, 430 * win.ux)
        height: Math.min(parent.height - 100 * win.ux, sheetCol.implicitHeight + 28 * win.ux)
        color: root.cPlate
        border.color: root.frameCol
        border.width: 1
        clip: true

        // swallow dead-space clicks so they can't tunnel to the scrim's
        // close-on-click underneath
        MouseArea { anchors.fill: parent }

        // corner brackets matching the main frame language
        Bracket { ux: win.ux; col: root.frameCol; anchors { right: parent.right; top: parent.top; margins: 3 * win.ux } rotation: 90 }
        Bracket { ux: win.ux; col: root.frameCol; anchors { left: parent.left; bottom: parent.bottom; margins: 3 * win.ux } rotation: 270 }

        Column {
          id: sheetCol
          anchors { fill: parent; margins: 16 * win.ux }
          spacing: 8 * win.ux

          // header row: title + close chip
          Item {
            width: parent.width
            height: 22 * win.ux
            TLabel {
              anchors { left: parent.left; verticalCenter: parent.verticalCenter }
              text: "⚙ NEXUS HUD · " + win.roleLabel
              color: root.cCyan
              font.pixelSize: 12 * win.ux
              font.bold: true
              font.letterSpacing: 2 * win.ux
            }
            Rectangle {
              anchors { right: parent.right; verticalCenter: parent.verticalCenter }
              width: 22 * win.ux
              height: 22 * win.ux
              color: closeMa.containsMouse ? Util.alpha(root.cAlert, 0.25) : Util.alpha(root.cAlert, 0.08)
              border.color: closeMa.containsMouse ? root.cAlert : Util.alpha(root.cLine, 0.9)
              border.width: 1
              TLabel {
                anchors.centerIn: parent
                text: "✕"
                color: closeMa.containsMouse ? "#eafcff" : root.cMuted
                font.pixelSize: 10 * win.ux
                font.bold: true
              }
              MouseArea {
                id: closeMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: win.sheetOpen = false
              }
            }
          }

          Rectangle { width: parent.width; height: 1; color: Util.alpha(root.cLine, 0.8) }

          // ------------------------------------------------ panel toggles
          TLabel {
            text: "PANELS · CLICK TO TOGGLE"
            color: root.cMuted
            font.pixelSize: 8.5 * win.ux
            font.letterSpacing: 1.6 * win.ux
          }
          Flow {
            width: parent.width
            spacing: 5 * win.ux
            Repeater {
              model: win.roleIds
              delegate: Rectangle {
                id: ptog
                required property string modelData
                readonly property bool lit: !win.isHidden(modelData)
                width: prowRow.implicitWidth + 14 * win.ux
                height: 22 * win.ux
                color: lit ? Util.alpha(root.cCyan, 0.14) : Util.alpha(root.cTxt, 0.03)
                border.color: lit ? Util.alpha(root.cCyan, 0.8) : Util.alpha(root.cLine, 0.7)
                border.width: 1
                Row {
                  id: prowRow
                  anchors.centerIn: parent
                  spacing: 5 * win.ux
                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 7 * win.ux
                    height: 7 * win.ux
                    color: ptog.lit ? root.cCyan : "transparent"
                    border.color: ptog.lit ? root.cCyan : root.cMuted
                    border.width: 1
                  }
                  TLabel {
                    anchors.verticalCenter: parent.verticalCenter
                    text: win.panelLabel(ptog.modelData)
                    color: ptog.lit ? root.cTxt : root.cMuted
                    font.pixelSize: 8.5 * win.ux
                    font.letterSpacing: 0.8 * win.ux
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: win.toggleHidden(ptog.modelData)
                }
              }
            }
          }

          Rectangle { width: parent.width; height: 1; color: Util.alpha(root.cLine, 0.8) }

          // ------------------------------------------------ accent preset
          TLabel {
            text: "ACCENT PRESET · GLOBAL"
            color: root.cMuted
            font.pixelSize: 8.5 * win.ux
            font.letterSpacing: 1.6 * win.ux
          }
          Row {
            spacing: 8 * win.ux
            Repeater {
              model: ["cyan", "green", "magenta", "amber"]
              delegate: Item {
                id: swatch
                required property string modelData
                readonly property bool sel: root.accentName === modelData
                width: 52 * win.ux
                height: 26 * win.ux
                Rectangle {
                  anchors.fill: parent
                  color: swatch.sel ? Util.alpha(root.accentPresets[swatch.modelData].main, 0.18)
                                    : Util.alpha(root.accentPresets[swatch.modelData].main, 0.05)
                  border.color: swatch.sel ? root.accentPresets[swatch.modelData].main
                                           : Util.alpha(root.accentPresets[swatch.modelData].main, 0.35)
                  border.width: swatch.sel ? 2 : 1
                  Rectangle {
                    anchors { left: parent.left; leftMargin: 5 * win.ux; verticalCenter: parent.verticalCenter }
                    width: 8 * win.ux
                    height: 8 * win.ux
                    rotation: 45
                    color: root.accentPresets[swatch.modelData].main
                  }
                  TLabel {
                    anchors { right: parent.right; rightMargin: 6 * win.ux; verticalCenter: parent.verticalCenter }
                    text: swatch.modelData.toUpperCase().substr(0, 3)
                    color: root.accentPresets[swatch.modelData].main
                    font.pixelSize: 8 * win.ux
                    font.bold: true
                  }
                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.accentName = swatch.modelData; root.scheduleSave() }
                  }
                }
              }
            }
          }

          Rectangle { width: parent.width; height: 1; color: Util.alpha(root.cLine, 0.8) }

          // ------------------------------------------------ shader field
          Item {
            width: parent.width
            height: 22 * win.ux
            TLabel {
              anchors { left: parent.left; verticalCenter: parent.verticalCenter }
              text: "AMBIENT SHADER · GLOBAL"
              color: root.cMuted
              font.pixelSize: 8.5 * win.ux
              font.letterSpacing: 1.6 * win.ux
            }
            Row {
              anchors { right: parent.right; verticalCenter: parent.verticalCenter }
              spacing: 6 * win.ux
              SetChip { ux: win.ux; label: "ON";  lit: root.shaderOn;  accent: root.cGreen; onChosen: { root.shaderOn = true;  root.scheduleSave() } }
              SetChip { ux: win.ux; label: "OFF"; lit: !root.shaderOn; accent: root.cMuted; onChosen: { root.shaderOn = false; root.scheduleSave() } }
            }
          }
          Item {
            width: parent.width
            height: 20 * win.ux
            visible: root.shaderOn
            TLabel {
              anchors { left: parent.left; verticalCenter: parent.verticalCenter }
              text: "INTENSITY " + Math.round(root.shaderIntensity * 100) + "%"
              color: root.cMuted
              font.pixelSize: 8.5 * win.ux
              width: 108 * win.ux
            }
            MiniSlider {
              anchors { left: parent.left; leftMargin: 116 * win.ux; right: parent.right; verticalCenter: parent.verticalCenter }
              ux: win.ux
              value: root.shaderIntensity
              onMoved: function(v) { root.shaderIntensity = v; root.scheduleSave() }
            }
          }

          Rectangle { width: parent.width; height: 1; color: Util.alpha(root.cLine, 0.8) }

          // ------------------------------------------------ tick rate
          Item {
            width: parent.width
            height: 22 * win.ux
            TLabel {
              anchors { left: parent.left; verticalCenter: parent.verticalCenter }
              text: "TICK RATE · GLOBAL"
              color: root.cMuted
              font.pixelSize: 8.5 * win.ux
              font.letterSpacing: 1.6 * win.ux
            }
            Row {
              anchors { right: parent.right; verticalCenter: parent.verticalCenter }
              spacing: 6 * win.ux
              SetChip { ux: win.ux; label: "15 HZ"; lit: root.tickHz === 15; onChosen: { root.tickHz = 15; root.scheduleSave() } }
              SetChip { ux: win.ux; label: "30 HZ"; lit: root.tickHz === 30; onChosen: { root.tickHz = 30; root.scheduleSave() } }
              SetChip { ux: win.ux; label: "60 HZ"; lit: root.tickHz === 60; onChosen: { root.tickHz = 60; root.scheduleSave() } }
            }
          }

          Rectangle { width: parent.width; height: 1; color: Util.alpha(root.cLine, 0.8) }

          // ------------------------------------------------ reset + hint
          Row {
            spacing: 8 * win.ux
            Rectangle {
              id: rstChip
              width: rstLbl.implicitWidth + 20 * win.ux
              height: 24 * win.ux
              color: rstMa.containsMouse ? Util.alpha(root.cAmber, 0.22) : Util.alpha(root.cAmber, 0.08)
              border.color: rstMa.containsMouse ? root.cAmber : Util.alpha(root.cAmber, 0.5)
              border.width: 1
              TLabel {
                id: rstLbl
                anchors.centerIn: parent
                text: "⟲ RESET LAYOUT · THIS SCREEN"
                color: rstMa.containsMouse ? "#eafcff" : root.cAmber
                font.pixelSize: 9 * win.ux
                font.bold: true
                font.letterSpacing: 1 * win.ux
              }
              MouseArea {
                id: rstMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: win.resetLayout()
              }
            }
            TLabel {
              anchors.verticalCenter: parent.verticalCenter
              text: "drag a bezel >8px to move · corner grip resizes"
              color: root.cMuted
              font.pixelSize: 8 * win.ux
              elide: Text.ElideRight
              // sheet.width - column margins - reset chip - row spacing
              width: Math.max(20, settingsSheet.width - 32 * win.ux
                              - rstChip.width - 8 * win.ux)
            }
          }
        }
      }
    }
  }
}
