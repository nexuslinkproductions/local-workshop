import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland
import QtQuick.Shapes
import QtQuick.Effects
import qs.Commons
import qs.Ui


// NEXUS HUD v2.1 — full-screen telemetry cockpit, smooth-motion rework.
//
// One PanelWindow per screen on the wlr "bottom" layer: above the wallpaper,
// below normal windows. The whole screen is the canvas: a corner-bracketed
// double frame, a left rail (SYSTEM + MEMORY), a center reactor dial flanked
// by sparkline traces with a top-procs strip under it, a right rail (GPU0 Arc
// / GPU1 AMD / STORAGE), and a bottom strip (NETWORK / AGENTS / STATUS).
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
    interval: 33        // ~30 Hz — smooth glide at half the repaint budget
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

  // ------------------------------------------------------------ IPC
  IpcHandler {
    target: "nexuslink.hud"

    function toggleAll(): string { return root.toggleAll() }
    function refresh(): string { root.refresh(); return "ok" }
    function section(id): string { root.toggleSection(String(id)); return "ok" }
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

    readonly property real titleH: Math.max(16, 22 * ux)
    readonly property real chamfer: 10 * ux

    visible: shown
    height: shown ? (collapsed && shrink ? titleH + 2 : titleH + contentH) : 0
    clip: true
    Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

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
        enabled: cp.collapsible
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: cp.toggled()
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
            text: "TELEMETRY COCKPIT"
            color: root.cMuted
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
            HudRow { label: "RAM";  value: root.memText;  fraction: root.s("mem");  accent: root.gaugeColor(root.s("mem")) }
            HudRow { label: "SWAP"; value: root.swapText; fraction: root.s("swap"); accent: root.gaugeColor(root.s("swap")); visible: root.swapFrac >= 0 }
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
            HudRow { label: "UTIL"; value: root.stats.a_util + "%"; fraction: root.s("autil"); accent: root.gaugeColor(root.s("autil")); visible: root.has("a_util") }
            HudRow { label: "VRAM"; value: root.stats.a_vram_used + " / " + root.stats.a_vram_total + " MiB"; fraction: root.s("avram"); accent: root.gaugeColor(root.s("avram")); visible: root.has("a_vram_total") }
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
            HudRow { label: root.fsLabel("root"); value: root.fsText("root"); fraction: root.s("fsR"); accent: root.gaugeColor(root.s("fsR")) }
            // /home row hides itself when $HOME lives on the same mount as /
            HudRow { label: root.fsLabel("home"); value: root.fsText("home"); fraction: root.s("fsH"); accent: root.gaugeColor(root.s("fsH")); visible: root.fsFrac("home") >= 0 && root.fsLabel("home") !== root.fsLabel("root") }
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
    }
  }
}
