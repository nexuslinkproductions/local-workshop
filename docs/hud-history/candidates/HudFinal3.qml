import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland
import QtQuick.Shapes
import QtQuick.Effects
import qs.Commons
import qs.Ui


// NEXUS HUD v2.5 — HudFinal3b: COMMAND-COCKPIT LAYOUT VARIANT (DP-1 only).
// Base: HudFinal + wave-4 merge. This file differs ONLY in the command
// screen's composition: the reactor chassis becomes a tall square-ish
// centrepiece (flank cards vertically centred beside the dial, TOP PROCS
// folded into a compact bottom drawer, wall clock inside the dial face),
// SYSTEM becomes a full-height left rail carrying the eased LOAD1 trace in
// its lower half, the pixel knot shrinks to a dim ~200 px watermark parked
// on the reactor's vertical axis just above the AGENTS/STATUS strips, and
// both strips sit flush with the field floor inside the open canvas.
// All free-canvas plumbing (registry, itemFor, persistence, mask) and the
// hardware/ops roles are byte-identical to HudFinal2.
//
// Original lineage — HudFinal + wave-4 merge: premium typography pass
// (design-pass.md tokens — Adwaita Sans UI / JetBrainsMono Nerd Font
// telemetry, 100/70/50/35% text-alpha ladder, hairline-not-frame panels,
// one-accent-cue rule, quiet traces and a stilled reactor), a TOKENS panel
// + ledger popup on the ops screen fed by tokens/ledger.py ->
// ~/.local/state/nexuslink/tokens.json, a `tokens` IPC method, and the
// PixelKnot celtic-knot pixel element living on the DP-2 bench as a
// draggable free-canvas decoration (panelId "knot").
//
// HudFinal3: the DP-2 STORAGE panel becomes a device tree — blk{i}
// whole-disk rows (name / model / size / temp / NVME·SATA·USB type tag)
// with their blk{i}p{j} partitions indented beneath on connector ticks,
// mounted and unmounted alike (topology, not just active mounts). The
// panelId stays "storage" and all mask/persist/settings wiring is
// unchanged — only the interior is new. The blk_* key family is
// optional: stale collectors degrade to the old fs_root/fs_home mount
// rows, and the disk R/W trace still anchors the panel bottom.
//
// FREE-CANVAS layout: every panel lives on a 12 px snap grid inside the bezel
// frame. Press-and-drag >8 px anywhere on a panel bezel moves it; click on a
// header without dragging still toggles collapse. On drop the panel snaps to
// the grid and any panel it covers eases to the nearest free space (morph).
// A grip on each panel's bottom-right corner edge-resizes it (grid snapped,
// min-size enforced). A gear chip on the title plate opens a mouse-only
// settings sheet: per-panel visibility toggles, accent palette presets,
// ambient shader on/off + intensity, tick rate, and reset layout. Layout +
// settings persist to ~/.config/omarchy/nexuslink/hud-state.json with
// layoutMode:"free", keyed by screen name. Panels added after a map was
// persisted are backfilled at their designed default rects.
//
// One PanelWindow per screen on the wlr "bottom" layer: above the wallpaper,
// below normal windows. `modelData.name` picks the role. Each metric has
// exactly ONE primary home — cross-screen references appear only as
// one-line summaries inside that screen's STATUS strip:
//
//   DP-1      "command"  — cinematic overview: reactor dial (CPU/GPU-pwr/MEM
//                          rings) centre stage, hero SYSTEM panel with eased
//                          LOAD1 trace, compact AGENTS count strip, STATUS.
//                          Compact launch rail top-right. NO per-core matrix,
//                          NO GPU sensor sheets, NO storage detail.
//   DP-2      "hardware" — sole silicon home: CORE MATRIX (enlarged, eased)
//                          + per-CCD thermal compare, SENSORS sheet (NVMe /
//                          DIMM / CCD / media + PSI some/full sparklines),
//                          GPU0 B580 sheet with power-vs-cap dial + VRAM
//                          channel bars + power trace, GPU1 sheet, STORAGE
//                          device tree (disks + partitions) + disk rw
//                          trace, PERIPHERALS batteries
//                          (designed empty state), MEMORY + zram, the
//                          PixelKnot pixel-element (decorative), STATUS.
//   HDMI-A-3  "ops"      — sole work console: WINDOWS/NAV (workspace chips +
//                          focus-on-click window list), TOP PROCESSES ·
//                          %CPU (1s) with per-row "% cpu" sub-labels, AGENTS
//                          expanded (per-harness chips, devin ACP, session
//                          locks, tmux attach, usage ledger), REPO ACTIVITY
//                          with unread badge, LAUNCH rail, OPS ACTIONS,
//                          TOKENS provider ledger (+ popup), NETWORK
//                          (dual-sided rx-up/tx-down trace), STATUS
//                          carrying GPU/battery cross-ref one-liners.
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
// cadence — plus a `probe` process for static keys (host/kernel/gpu names),
// and a 60 s `python3 tokens/ledger.py` pulse refreshing the token
// ledger FileView. Nothing else is spawned per frame.
//
// CONTINUOUS MOTION: one shared ~30 Hz clock (animClock) advances `animT`,
// eases every animated scalar toward its telemetry target into `sv`, keeps
// per-series eased display copies of the trace histories (`dsp*`), and bumps
// `tickSeq`, which every animated Canvas repaints on. Traces therefore glide
// — the whole curve scrolls by the fractional progress into the current
// sampling interval (`scrollPhase`) instead of stepping once per batch —
// gauges sweep, and the alert palette lerps instead of snapping.
//
// Collapse state is session-only and shared across all monitors: clicking a
// panel header folds that panel on every screen. Clicking the NEXUS title
// plate, or `omarchy-shell nexuslink.hud toggleAll`, folds/unfolds all.
// `omarchy-shell nexuslink.hud tokens` toggles the token-ledger sheet.
Item {
  id: root

  // Injected by omarchy-shell (scoped PluginShellApi + public manifest copy).
  property var shell: null
  property var manifest: null

  // ------------------------------------------------------------- palette
  // Accent presets recolor the global accent surfaces: frame line, dial
  // arcs, the pixel knot, and every accent that references cCyan/cAccent.
  // The alert colour and the semantic per-panel hues (green/magenta/amber)
  // stay fixed.
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

  // design-pass.md: neutral text is #d7e8ed at four deliberate alpha tiers —
  //   cTxt  100%  primary values, active selection, current clock
  //   cSub   70%  labels, row names, panel headings, action text
  //   cMuted 50%  units, timestamps, captions, secondary facts
  //   cDim   35%  disabled text, inactive legends, metadata only
  readonly property color cTxt:     "#d7e8ed"
  readonly property color cSub:     Util.alpha(cTxt, 0.70)
  readonly property color cMuted:   Util.alpha(cTxt, 0.50)
  readonly property color cDim:     Util.alpha(cTxt, 0.35)
  readonly property color cLine:    "#0d4a61"
  // hairline / divider / surface / scrim tokens straight from the pass
  readonly property color cHair:    Qt.rgba(0.537, 0.698, 0.753, 0.22)
  readonly property color cDiv:     Qt.rgba(0.537, 0.698, 0.753, 0.14)
  readonly property color cInset:   Qt.rgba(0.008, 0.035, 0.059, 0.72)
  readonly property color cRaised:  Qt.rgba(0.043, 0.098, 0.141, 0.98)
  readonly property color cScrim:   Qt.rgba(0.004, 0.027, 0.047, 0.68)
  readonly property color cPanel:   Util.alpha(Color.background, 0.84)
  readonly property color cPlate:   "#040e16"

  // Typography: installed pairing per design-pass.md — Adwaita Sans for
  // headers/labels/controls, JetBrainsMono Nerd Font for telemetry values,
  // numbers, timestamps and glyph marks.
  readonly property string fontUi:   "Adwaita Sans"
  readonly property string fontMono: "JetBrainsMono Nerd Font"

  // Path of this file's directory, resolved from the component URL so the
  // plugin works wherever the registry mounts it.
  readonly property string collectScript:
    decodeURIComponent(String(Qt.resolvedUrl("collect.sh")).replace(/^file:\/\//, ""))
  // Token ledger producer: nexuslink.hud/tokens/ledger.py, resolved the same
  // way (candidates/../tokens/ledger.py) with file:// decoded like above.
  readonly property string ledgerScript:
    decodeURIComponent(String(Qt.resolvedUrl("tokens/ledger.py")).replace(/^file:\/\//, ""))
  // Ledger output — same $HOME-anchored resilience as the state dir; the
  // HUD renders this file only, the cursor stays internal to the ledger.
  readonly property string tokStatePath:
    Quickshell.env("HOME") + "/.local/state/nexuslink/tokens.json"

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
  property int lastPaintBatch: -1   // batchSeq as of the last repaint pulse
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
  property var histLoad: []     // load1 trend — command hero trace
  property var histGpuW: []
  property var histRx:   []
  property var histTx:   []
  property var histDisk: []
  // PSI pressure series (avg10 %) — hardware sparkline rows
  property var histPsiCpu: []
  property var histPsiMem: []
  property var histPsiIo:  []

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
  property var dspLoad: []
  property var dspGpuW: []
  property var dspRx:   []
  property var dspTx:   []
  property var dspDisk: []
  property var dspPsiCpu:  []
  property var dspPsiMem:  []
  property var dspPsiIo:   []

  // Smooth 0..1 pulse replacing the old hard blink — alert surfaces and
  // live-state indicators breathe on this.
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
    // aliases for the merged panels' read names — both spellings stay live
    nv.gpuW  = nv.gpup;  nv.gpuU  = nv.iutil; nv.gpuV  = nv.ivram
    nv.gpu2U = nv.autil; nv.gpu2V = nv.avram
    nv.fs0   = nv.fsR;   nv.fs1   = nv.fsH

    // HudP staging: pressure-stall some% (0-1), CCD thermals and B580 VRAM
    // channel temps (0-1 against fixed full-scales) — all eased like the rest
    nv.psicpu = easeFrac(o.psicpu, has("psi_cpu_some") ? num(stats.psi_cpu_some) / 100 : -1, k)
    nv.psimem = easeFrac(o.psimem, has("psi_mem_some") ? num(stats.psi_mem_some) / 100 : -1, k)
    nv.psiio  = easeFrac(o.psiio,  has("psi_io_some")  ? num(stats.psi_io_some)  / 100 : -1, k)
    nv.ccd1   = easeFrac(o.ccd1,   has("cpu_tccd1")    ? num(stats.cpu_tccd1)    / 120 : -1, k)
    nv.ccd2   = easeFrac(o.ccd2,   has("cpu_tccd2")    ? num(stats.cpu_tccd2)    / 120 : -1, k)
    nv.vchavg = easeFrac(o.vchavg, has("i_vram_ch_avg") ? num(stats.i_vram_ch_avg) / 110 : -1, k)
    nv.vchmax = easeFrac(o.vchmax, has("i_vram_ch_max") ? num(stats.i_vram_ch_max) / 110 : -1, k)

    var prevAlert = (o.alert !== undefined && isFinite(o.alert)) ? o.alert : 0
    nv.alert = prevAlert + ((alert ? 1 : 0) - prevAlert) * ka

    // per-core eased fractions; largest per-element delta feeds the paint gate
    var md = 0
    var cn = coreCount
    var prevC = o.core
    var nc = new Array(cn)
    for (var i = 0; i < cn; i++) {
      var tgt = Math.min(1, Math.max(0, num(stats["cpu_core_" + i]) / 100))
      var pv = (prevC && i < prevC.length) ? prevC[i] : undefined
      var pvf = (pv === undefined || !isFinite(pv)) ? 0 : pv
      nc[i] = (pv === undefined || !isFinite(pv)) ? 0 : pv + (tgt - pv) * k
      var dc = Math.abs(nc[i] - pvf)
      if (dc > md) md = dc
    }
    nv.core = nc

    // scalar movement across every eased key — the repaint gate reads this
    var sKeys = ["cpu", "gpup", "mem", "iutil", "gutil", "ivram", "autil",
                 "avram", "swap", "fsR", "fsH", "psicpu", "psimem", "psiio",
                 "ccd1", "ccd2", "vchavg", "vchmax", "alert"]
    for (var sk = 0; sk < sKeys.length; sk++) {
      var key = sKeys[sk]
      var ov = o[key], nw = nv[key]
      if (isFinite(ov) && isFinite(nw)) {
        var dd = Math.abs(nw - ov)
        if (dd > md) md = dd
      } else if (ov !== nw) {
        md = 1              // presence/absence flip is always a repaint
      }
    }

    sv = nv

    // ease the trace display copies toward the raw histories
    var hd = easeHist(dspCpu,    histCpu,    k)
    hd = Math.max(hd, easeHist(dspLoad,   histLoad,   k))
    hd = Math.max(hd, easeHist(dspPsiCpu, histPsiCpu, k))
    hd = Math.max(hd, easeHist(dspPsiMem, histPsiMem, k))
    hd = Math.max(hd, easeHist(dspPsiIo,  histPsiIo,  k))
    hd = Math.max(hd, easeHist(dspGpuW,   histGpuW,   k))
    hd = Math.max(hd, easeHist(dspRx,     histRx,     k))
    hd = Math.max(hd, easeHist(dspTx,     histTx,     k))
    hd = Math.max(hd, easeHist(dspDisk,   histDisk,   k))
    if (hd > md) md = hd

    // Repaint gate: canvases pulse when a fresh batch landed, any eased
    // value is still gliding, or a new sample is still scrolling into view
    // (scrollPhase<1). Once everything converges and the stream is quiet,
    // the 30 Hz tick costs bindings only — zero canvas repaints.
    if (batchSeq !== lastPaintBatch || md > 0.0009 || scrollPhase < 1.0) {
      lastPaintBatch = batchSeq
      tickSeq++
    }
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
  // Returns the largest per-element delta this pass so tick() can decide
  // whether a canvas repaint pulse is still warranted (glide in progress).
  function easeHist(d, h, k) {
    while (d.length > h.length) d.shift()
    while (d.length < h.length)
      d.push(d.length > 0 ? d[d.length - 1] : (isFinite(h[d.length]) ? h[d.length] : 0))
    var md = 0
    for (var i = 0; i < d.length; i++) {
      var tv = h[i]
      if (!isFinite(tv)) { if (isFinite(d[i])) md = 1; d[i] = NaN; continue }
      var dv = d[i]
      var nv = isFinite(dv) ? dv + (tv - dv) * k : tv
      d[i] = nv
      var dd = Math.abs(nv - (isFinite(dv) ? dv : 0))
      if (dd > md) md = dd
    }
    return md
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

  // Byte sizes for the storage device tree: "480G", "1.8T", "512M".
  function fmtBytes(b) {
    var n = num(b)
    if (n >= 1099511627776) return (n / 1099511627776).toFixed(1) + "T"
    if (n >= 1073741824)    return (n / 1073741824).toFixed(0) + "G"
    if (n >= 1048576)       return (n / 1048576).toFixed(0) + "M"
    if (n >= 1024)          return (n / 1024).toFixed(0) + "K"
    return Math.round(n) + "B"
  }

  // Compact token-count format for the ledger: 31089575 -> "31.1M".
  function fmtTok(n) {
    var v = Number(n)
    if (n === null || n === undefined || !isFinite(v)) return "—"
    if (v >= 1e9) return (v / 1e9).toFixed(2) + "B"
    if (v >= 1e6) return (v / 1e6).toFixed(1) + "M"
    if (v >= 1e3) return (v / 1e3).toFixed(1) + "k"
    return String(Math.round(v))
  }

  // Cost renders only when the ledger reports a number — null/undefined
  // stays "" so unknown cost never draws as a false $0.
  function fmtCost(c) {
    if (c === null || c === undefined) return ""
    var v = Number(c)
    if (!isFinite(v)) return ""
    if (v >= 10) return "$" + v.toFixed(1)
    if (v >= 1)  return "$" + v.toFixed(2)
    if (v > 0)   return "$" + v.toFixed(3)
    return "$0"
  }

  // One day/week/month bucket -> "31.1M↓ 7.1M↑ · $0.10". Snapshot providers
  // emit in/out:null with `total` as the real figure (never sum both);
  // a completely empty bucket reads "—".
  function tokCell(b) {
    if (b === null || b === undefined || typeof b !== "object") return "—"
    var i = b["in"], o = b["out"]
    var ii = (i === null || i === undefined) ? NaN : Number(i)
    var oo = (o === null || o === undefined) ? NaN : Number(o)
    var s
    if (isFinite(ii) || isFinite(oo)) s = fmtTok(ii) + "↓ " + fmtTok(oo) + "↑"
    else if (b.total !== undefined && b.total !== null) s = "Σ" + fmtTok(b.total)
    else s = "—"
    var c = fmtCost(b.cost)
    if (c !== "") s += " · " + c
    return s
  }

  function tokBucketTotal(b) {
    if (b === null || b === undefined || typeof b !== "object") return 0
    var i = Number(b["in"]), o = Number(b["out"]), t = Number(b.total)
    var s = (isFinite(i) ? i : 0) + (isFinite(o) ? o : 0)
    if (!(s > 0) && isFinite(t)) s = t
    return s
  }

  // Basename list of the files that fed this provider, e.g.
  // "sessions.db" or "usage_audit.jsonl, annot-luna.json +7".
  function tokProvSource(pid) {
    var s = tokData.sources
    var arr = (s && typeof s === "object" && s[pid]) ? s[pid] : []
    var names = []
    for (var i = 0; i < arr.length; i++) {
      var p = String(arr[i])
      var sl = p.lastIndexOf("/")
      names.push(sl >= 0 ? p.substr(sl + 1) : p)
    }
    if (names.length <= 3) return names.join(", ")
    return names.slice(0, 3).join(", ") + " +" + (names.length - 3)
  }

  // Provider rows for the TOKENS panel + popup: label, kind tag, alert flag
  // (meta.ready === false = unauthenticated/absent feed), status string,
  // the three window buckets and a provenance line. Sorted busiest-first.
  function tokList() {
    var a = []
    var p = tokData.providers
    if (p && typeof p === "object") {
      for (var k in p) {
        var e = p[k]
        if (!e || typeof e !== "object") continue
        var meta = (e.meta && typeof e.meta === "object") ? e.meta : {}
        a.push({
          id: k,
          label: String(e.label !== undefined ? e.label
                        : (meta.label !== undefined ? meta.label : k)),
          kind: String(e.kind !== undefined ? e.kind
                       : (meta.kind !== undefined ? meta.kind : "?")),
          ok: meta.ready !== false,
          status: meta.status !== undefined ? String(meta.status) : "",
          day:   (e.day   && typeof e.day   === "object") ? e.day   : {},
          week:  (e.week  && typeof e.week  === "object") ? e.week  : {},
          month: (e.month && typeof e.month === "object") ? e.month : {},
          src: tokProvSource(k)
        })
      }
    }
    a.sort(function(x, y) { return tokBucketTotal(y.day) - tokBucketTotal(x.day) })
    return a
  }

  readonly property int tokProviderCount:
      (tokData.providers && typeof tokData.providers === "object")
        ? Object.keys(tokData.providers).length : 0

  // "31.1M / 7.1M" for one bucket; snapshot providers (in/out null) degrade
  // to "Σ38.2M"; an entirely empty bucket reads "—".
  function tokIO(b) {
    if (b === null || b === undefined || typeof b !== "object") return "—"
    var i = b["in"], o = b["out"]
    var ii = (i === null || i === undefined) ? NaN : Number(i)
    var oo = (o === null || o === undefined) ? NaN : Number(o)
    if (isFinite(ii) || isFinite(oo)) return fmtTok(ii) + " / " + fmtTok(oo)
    if (b.total !== undefined && b.total !== null) return "Σ" + fmtTok(b.total)
    return "—"
  }

  // Display-ready provider rows for both the compact panel and the popup:
  // preformatted io strings per window, first non-null cost across the
  // windows, and a provenance line ("sources — status").
  readonly property var tokRows: {
    var list = tokList()
    var out = []
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      var cost = fmtCost(p.day.cost)
      if (cost === "") cost = fmtCost(p.week.cost)
      if (cost === "") cost = fmtCost(p.month.cost)
      var prov = p.src
      if (p.status !== "") prov += (prov !== "" ? " — " : "") + p.status
      out.push({
        label: p.label, kind: p.kind, ok: p.ok,
        dayIO: tokIO(p.day), weekIO: tokIO(p.week), monthIO: tokIO(p.month),
        cost: cost, prov: prov
      })
    }
    return out
  }

  // Decorative section glyph — the panel header renders titleText() which
  // strips leading marks, so this only survives where a title needs a bare
  // glyph (kept for header-string readability).
  function headSymbol(id) {
    var g = { system: "◈", memory: "◈", gpu: "◈", gpu2: "◈", storage: "◈",
              network: "◈", agents: "◈", matrix: "◈", sensors: "◈",
              periph: "◈", windows: "◈", repo: "◈", procs: "◈",
              launch: "◈", actions: "◈", tokens: "◈", knot: "◈" }
    return g[id] !== undefined ? g[id] : "◈"
  }

  // Eased per-core busy fraction 0..1 (sv.core is eased in tick()).
  function coreFrac(i) { return svCore(i) }
  function coreColor(i) {
    var f = coreFrac(i)
    return f > 0 ? heatColor(f, cCyan) : cMuted
  }

  // Panel titles arrive as "◈ CORE MATRIX" — the header strips the leading
  // decorative glyph and title-cases the words (digits and short telemetry
  // acronyms keep their casing, e.g. "GPU0 · Intel ARC B580").
  function titleText(t) {
    var s = String(t).replace(/^\s*[^0-9A-Za-z]+\s*/, "")
    var keep = { GPU:1, CPU:1, IO:1, RX:1, TX:1, PSI:1, CCD:1, VRAM:1,
                 NVME:1, DIMM:1, RPM:1, ZRAM:1, ACP:1, GH:1, PKG:1, PCIE:1,
                 MCTRL:1, VRM:1, ARC:1 }
    var words = s.split(" ")
    var out = []
    for (var i = 0; i < words.length; i++) {
      var w = words[i]
      if (w === "") { out.push(w); continue }
      if (/[0-9·]/.test(w) || keep[w] === 1 || w.length <= 2) out.push(w)
      else out.push(w.charAt(0).toUpperCase() + w.substr(1).toLowerCase())
    }
    return out.join(" ")
  }

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
  // `down` mirrors the series around the midline (fills toward the centre
  // instead of the floor) — the split-lane look HudR used for rx/tx.
  function paintTrace(ctx, w, h, pts, col, peak, phase, down) {
    var n = pts.length
    if (n === 0 || !(peak > 0)) return
    var step = w / 59
    var y0 = down ? Math.round(h * 0.5) + 0.5 : h - 3
    var amp = down ? h * 0.44 : h - 8

    // pixel positions, newest sample glued near the right edge and aging
    // leftward at `step` px per batch period
    var px = new Array(n)
    var py = new Array(n)
    for (var j = 0; j < n; j++) {
      px[j] = w - (n - 1 - j + phase) * step
      var v = pts[j]
      py[j] = isFinite(v)
          ? y0 + (down ? 1 : -1) * (Math.min(v, peak) / peak) * amp
          : NaN
    }

    var headX = 0, headY = 0, haveHead = false
    var grad = ctx.createLinearGradient(0, 0, 0, h)
    grad.addColorStop(0,    rgbaOf(col, 0.18))
    grad.addColorStop(0.75, rgbaOf(col, 0.05))
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

      // gradient fill under (or, mirrored, over-toward-midline) the run
      runPath()
      ctx.lineTo(px[i1], down ? y0 : h)
      ctx.lineTo(px[i0], down ? y0 : h)
      ctx.closePath()
      ctx.fillStyle = grad
      ctx.fill()

      // design-pass glow rule: ONE under-stroke at 18% alpha / 2x the core
      // width, then the 1.5 px hot core — no second glow pass, no comet
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      runPath()
      ctx.strokeStyle = rgbaOf(col, 0.18)
      ctx.lineWidth = 3.0
      ctx.stroke()
      runPath()
      ctx.strokeStyle = rgbaOf(col, 0.90)
      ctx.lineWidth = 1.5
      ctx.stroke()

      if (!haveHead && i1 === n - 1) {
        headX = px[i1]; headY = py[i1]; haveHead = true
      }
    }

    // static endpoint dot at the newest sample — no halo, no pulse
    if (haveHead) {
      ctx.fillStyle = rgbOf(col)
      ctx.beginPath()
      ctx.arc(headX, headY, 2.0, 0, Math.PI * 2)
      ctx.fill()
    }
  }

  // ------------------------------------------------------------ collapse
  readonly property var sectionIds: ["system", "memory", "gpu", "gpu2", "storage",
                                     "network", "agents", "matrix", "sensors",
                                     "periph", "windows", "repo", "procs",
                                     "launch", "actions", "tokens"]

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
    histLoad = histPush(histLoad, m.load1 !== undefined ? num(m.load1) : NaN)
    histPsiCpu = histPush(histPsiCpu, m.psi_cpu_some !== undefined ? num(m.psi_cpu_some) : NaN)
    histPsiMem = histPush(histPsiMem, m.psi_mem_some !== undefined ? num(m.psi_mem_some) : NaN)
    histPsiIo  = histPush(histPsiIo,  m.psi_io_some !== undefined ? num(m.psi_io_some) : NaN)
    histGpuW = histPush(histGpuW, m.i_pwr_w !== undefined ? num(m.i_pwr_w) : NaN)
    histRx   = histPush(histRx,   rxRate)
    histTx   = histPush(histTx,   txRate)
    histDisk = histPush(histDisk, num(m.disk_read_bps))
    dspShift(dspCpu,    histCpu)
    dspShift(dspLoad,   histLoad)
    dspShift(dspPsiCpu, histPsiCpu)
    dspShift(dspPsiMem, histPsiMem)
    dspShift(dspPsiIo,  histPsiIo)
    dspShift(dspGpuW,   histGpuW)
    dspShift(dspRx,     histRx)
    dspShift(dspTx,     histTx)
    dspShift(dspDisk,   histDisk)

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

  // -------------------------------------------------------- token ledger
  // wave-4: ../tokens/ledger.py mines the local provider feeds (omarchy
  // usage snapshots, opencode/devin sqlite, haze rollups) into tokStatePath
  // atomically. A 60 s timer pulses the ledger process; on exit the FileView
  // reloads — the same explicit-reload pattern as stateFile (watchChanges
  // stays off). A missing tokens.json just leaves tokData empty: the panel
  // shows "ledger: starting…" until the first successful run lands.
  property var tokData: ({})
  property bool tokLoaded: false
  property bool tokOpen: false        // token ledger popup — one flag, all screens

  FileView {
    id: tokFile
    path: root.tokStatePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadTokens(text())
    onLoadFailed: root.loadTokens("")
  }

  Process {
    id: ledgerProc
    command: ["python3", root.ledgerScript]
    running: false
    onExited: tokFile.reload()
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text).trim() !== "") console.warn("nexuslink.hud ledger:", String(text).trim())
    }
  }

  Timer {
    id: ledgerTimer
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!ledgerProc.running) ledgerProc.running = true
  }

  function loadTokens(raw) {
    var data = null
    try { data = JSON.parse(String(raw || "")) } catch (e) { data = null }
    if (data === null || typeof data !== "object") data = ({})
    tokData = data
    tokLoaded = true
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
  // `alert` is the boolean; `sv.alert` eases 0->1 so the frame and dial
  // ticks sweep accent->red over ~half a second instead of snapping.
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

  // ---------------- one-home cross-references (HudP staging) ----------------
  // Each metric owns exactly one panel; these one-liners are the legal
  // "see that screen" pointers rendered inside STATUS strips elsewhere.
  readonly property string storageFreeText: has("fs_root_size")
      ? Math.max(0, Math.round((num(stats.fs_root_size) - num(stats.fs_root_used)) / 1073741824)) + "G free"
      : "mounts n/a"
  readonly property int agentLiveCount: Math.max(0, num(stats.agents_procs))
  readonly property string gpuStatusText: has("i_temp_pkg")
      ? "GPU B580 " + Math.round(num(stats.i_temp_pkg)) + "°C"
      : (has("a_temp") ? "GPU iGPU " + Math.round(num(stats.a_temp)) + "°C" : "GPU B580 —")
  function batStatusText() {
    if (batCount <= 0) return "no peripherals"
    var l = batList()
    var t = batCount + " dev · " + l[0].name + " " + Math.round(l[0].pct) + "%"
    if (l[0].state !== "") t += " " + l[0].state
    return t
  }
  // PSI sparkline rows rendered on the hardware sensors sheet
  readonly property int psiRowCount: (has("psi_cpu_some") ? 1 : 0)
      + (has("psi_mem_some") ? 1 : 0) + (has("psi_io_some") ? 1 : 0)

  // AGENT USAGE ledger — omarchy agent-usage records (id / tokens / status)
  readonly property int aguseCount: Math.min(4, Math.max(0, num(stats.aguse_count)))
  function aguseList() {
    var a = []
    for (var i = 0; i < aguseCount; i++)
      a.push({
        id:     has("aguse" + i + "_id")     ? String(stats["aguse" + i + "_id"])     : "agent",
        tokens: has("aguse" + i + "_tokens") ? String(stats["aguse" + i + "_tokens"]) : "—",
        status: has("aguse" + i + "_status") ? String(stats["aguse" + i + "_status"]) : "?"
      })
    return a
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
    // One-home split: CCD thermals live in the CORE MATRIX compare bars,
    // PSI has dedicated sparkline rows below, ZRAM lives in MEMORY and
    // CLOCK lives in the matrix panel — sensorRows keeps NVMe/DIMM/media.
    var mn = Math.min(4, Math.max(0, num(stats.media_count)))
    for (i = 0; i < mn; i++)
      if (has("media" + i + "_name"))
        a.push({ label: "MEDIA" + i, value: String(stats["media" + i + "_name"]), accent: root.cMagenta })
    return a
  }

  // STORAGE — DEVICES tree (collector contract, additive):
  //   blk_count, blk{i}_{name,model,size_bytes,type,rota,temp},
  //   blk{i}p_count, blk{i}p{j}_{name,size_bytes,fstype,label,mount,
  //   used_bytes,pct}
  // blkRows() flattens the tree into a display list the panel's Repeater
  // drives directly: "dev" header rows, indented "part" rows — mounted
  // AND unmounted, the panel's job is topology — and "sep" hairlines
  // between devices. Capped at 4 devices × 6 partitions so a noisy
  // enumerator can't blow the panel out. `rh` is the row's height in ux
  // units so blkRowsH() can mirror the delegate stack exactly for the
  // panel's contentH. Absent keys degrade per-field, never per-device.
  readonly property int blkCount: Math.min(4, Math.max(0, num(stats.blk_count)))
  function blkRows() {
    var rows = []
    for (var i = 0; i < blkCount; i++) {
      var dk = "blk" + i + "_"
      var dtype = has(dk + "type") ? String(stats[dk + "type"]).toUpperCase() : ""
      if (dtype === "") dtype = num(stats[dk + "rota"]) > 0 ? "HDD" : "DISK"
      rows.push({
        kind: "dev", rh: 20,
        name:    has(dk + "name")  ? String(stats[dk + "name"])  : "disk" + i,
        model:   has(dk + "model") ? String(stats[dk + "model"]) : "",
        size:    num(stats[dk + "size_bytes"]),
        dtype:   dtype,
        hasTemp: has(dk + "temp"),
        temp:    num(stats[dk + "temp"])
      })
      var pc = Math.min(6, Math.max(0, num(stats["blk" + i + "p_count"])))
      for (var j = 0; j < pc; j++) {
        var pk     = "blk" + i + "p" + j + "_"
        var mount  = has(pk + "mount") ? String(stats[pk + "mount"]) : ""
        var size   = num(stats[pk + "size_bytes"])
        var usedOk = has(pk + "used_bytes")
        var used   = usedOk ? num(stats[pk + "used_bytes"]) : 0
        var pctOk  = has(pk + "pct")
        var pct    = pctOk ? Util.clamp(num(stats[pk + "pct"]), 0, 100) : -1
        var frac   = pctOk ? pct / 100
                   : (usedOk && size > 0 ? Util.clamp(used / size, 0, 1) : -1)
        var fst = has(pk + "fstype") ? String(stats[pk + "fstype"]) : ""
        var lab = has(pk + "label")  ? String(stats[pk + "label"])  : ""
        var fsT = fst + (fst !== "" && lab !== "" ? " · " : "") + lab
        var mounted = mount !== ""
        var val
        if (mounted) {
          val = (frac >= 0 ? Math.round(frac * 100) + "%  " : "")
              + (usedOk ? fmtBytes(used) + "/" + fmtBytes(size) : fmtBytes(size))
        } else {
          val = fmtBytes(size)
        }
        rows.push({
          kind: "part", rh: 24, last: j === pc - 1,
          name: has(pk + "name") ? String(stats[pk + "name"]) : "p" + j,
          fsText: fsT, mount: mount, mounted: mounted,
          frac: frac, val: val
        })
      }
      if (i < blkCount - 1) rows.push({ kind: "sep", rh: 10 })
    }
    return rows
  }
  // Sum of the row heights (ux units) — the panel's contentH uses this so
  // the natural height always matches the rendered delegate stack.
  function blkRowsH() {
    var r = blkRows(), h = 0
    for (var i = 0; i < r.length; i++) h += r[i].rh
    return h
  }

  // ------------------------------------------------------------ IPC
  IpcHandler {
    target: "nexuslink.hud"

    function toggleAll(): string { return root.toggleAll() }
    function refresh(): string { root.refresh(); return "ok" }
    function section(id: string): string { root.toggleSection(id); return "ok" }
    function tokens(): string { root.tokOpen = !root.tokOpen; return "ok" }
    function status(): string {
      return JSON.stringify({
        cpu: root.cpuText,
        mem: root.memText,
        gpu: root.gpuKind,
        rx: root.fmtRate(root.rxRate),
        tx: root.fmtRate(root.txRate),
        frame: root.batchSeq,
        alert: root.alert,
        tokProviders: root.tokProviderCount
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
        alert: root.alert,
        tokProviders: root.tokProviderCount
      })
    }
  }

  // -------------------------------------------------- reusable components
  // UI text is Adwaita Sans; telemetry values/numbers/timestamps and glyph
  // marks set mono:true for JetBrainsMono Nerd Font. Sizes are per use site,
  // scaled by the panel's ux where the component takes one.
  component TLabel: Text {
    property bool mono: false
    color: root.cTxt
    font.family: mono ? root.fontMono : root.fontUi
  }

  // One stat line inside a panel body: medium label at 70%, optional quiet
  // 4 px meter, right-aligned mono value at 100%. Set `fraction` 0..1 to
  // show the gauge; -1 hides it. Pass an eased fraction (root.s("...")) for
  // continuous gauge motion.
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
      color: root.cSub
      font.pixelSize: 11
      font.weight: Font.Medium
      font.letterSpacing: 0.2
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
      height: 4
      radius: 2
      color: root.cInset

      // eased fill: solid semantic colour, no gradient, no glowing cap
      Rectangle {
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: Math.max(0, track.width * Util.clamp(hrow.fraction, 0, 1))
        radius: 2
        color: hrow.accent
      }
    }

    TLabel {
      id: rval
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: hrow.value
      mono: true
      color: hrow.valueColor.a > 0 ? hrow.valueColor : root.cTxt
      font.pixelSize: 13
      font.weight: Font.Medium
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

  // Cockpit panel: a canvas-drawn bezel — rounded quiet face with a faint
  // accent sheen at the top edge, ONE hairline outline and ONE 2 px accent
  // rail marking the header (design-pass: no per-panel scanlines, no double
  // accent strokes, no corner brackets). Plus a clickable title row that
  // folds the body (animated) when `collapsible`. `shrink` false keeps the
  // panel's footprint when folded — used for the bottom strip.
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
    // optional right-aligned header readout (HudP) — used by merge panels
    // to carry a one-line cross-reference or live count in the title bar
    property string miniStat: ""
    // optional right-edge header chip (a small action button, e.g. the
    // TOKENS panel's ledger-sheet toggle); "" hides it
    property string chipGlyph: ""
    signal toggled()
    signal chipActivated()
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

    readonly property real titleH: Math.max(20, 26 * ux)
    readonly property real radius: 6 * ux

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
        var r = Math.min(cp.radius, Math.min(w, h) / 2 - 1)
        var hot = cpHeadMa.containsMouse && cp.collapsible

        // rounded silhouette — one quiet surface
        ctx.beginPath()
        ctx.moveTo(r, 0.5)
        ctx.lineTo(w - r, 0.5)
        ctx.arcTo(w - 0.5, 0.5, w - 0.5, r, r)
        ctx.lineTo(w - 0.5, h - r)
        ctx.arcTo(w - 0.5, h - 0.5, w - r, h - 0.5, r)
        ctx.lineTo(r, h - 0.5)
        ctx.arcTo(0.5, h - 0.5, 0.5, h - r, r)
        ctx.lineTo(0.5, r)
        ctx.arcTo(0.5, 0.5, r, 0.5, r)
        ctx.closePath()

        // flat fill: a whisper of accent sheen up top fading to the plate
        var g = ctx.createLinearGradient(0, 0, 0, h)
        g.addColorStop(0,    root.rgbaOf(cp.accent, cp.collapsed ? 0.03 : 0.06))
        g.addColorStop(0.30, "rgba(7,18,28,0.96)")
        g.addColorStop(1,    "rgba(4,14,22,0.97)")
        ctx.fillStyle = g
        ctx.fill()

        // top inner highlight — a lit edge under the lip, kept quiet
        ctx.save()
        ctx.clip()
        var hg = ctx.createLinearGradient(0, 0, w, 0)
        hg.addColorStop(0,    "rgba(255,255,255,0.0)")
        hg.addColorStop(0.15, root.rgbaOf(cp.accent, hot ? 0.40 : 0.22))
        hg.addColorStop(0.7,  "rgba(255,255,255,0.05)")
        hg.addColorStop(1,    "rgba(255,255,255,0.0)")
        ctx.strokeStyle = hg
        ctx.beginPath()
        ctx.moveTo(r + 1, 1.5)
        ctx.lineTo(w - 2, 1.5)
        ctx.stroke()
        ctx.restore()

        // one hairline outline — the only border a panel draws (22% neutral)
        ctx.beginPath()
        ctx.moveTo(r, 0.5)
        ctx.lineTo(w - r, 0.5)
        ctx.arcTo(w - 0.5, 0.5, w - 0.5, r, r)
        ctx.lineTo(w - 0.5, h - r)
        ctx.arcTo(w - 0.5, h - 0.5, w - r, h - 0.5, r)
        ctx.lineTo(r, h - 0.5)
        ctx.arcTo(0.5, h - 0.5, 0.5, h - r, r)
        ctx.lineTo(0.5, r)
        ctx.arcTo(0.5, 0.5, r, 0.5, r)
        ctx.closePath()
        ctx.strokeStyle = String(cp.collapsed ? root.cDiv : root.cHair)
        ctx.lineWidth = 1
        ctx.stroke()

        // the identifying accent: one 2 px rail at the header's left edge
        ctx.fillStyle = root.rgbaOf(cp.accent, cp.collapsed ? 0.35 : 0.80)
        ctx.fillRect(1.5, r + 1, 2, Math.max(6, cp.titleH - r - 2))
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
      onPressed: if (cp.host !== null) cp.host.dragPress(bodyDragMa, cp, cp.panelId, mouse.x, mouse.y)
      onPositionChanged: if (cp.host !== null) cp.host.dragMove(bodyDragMa, cp, mouse.x, mouse.y)
      onReleased: if (cp.host !== null) cp.host.dragRelease(cp)
      onCanceled: if (cp.host !== null) cp.host.dragAbort(cp)
    }

    Item {
      id: cpHead
      anchors { top: parent.top; left: parent.left; right: parent.right }
      height: cp.titleH

      // the small accent pip before the chevron — a status LED for the
      // section; together with the header rail it's the panel's only chrome
      Rectangle {
        anchors { left: parent.left; leftMargin: 5 * cp.ux; verticalCenter: parent.verticalCenter }
        width: 3 * cp.ux
        height: 3 * cp.ux
        rotation: 45
        color: cp.accent
        opacity: cp.collapsed ? 0.35 : 0.9
      }

      Row {
        id: cpHeadRow
        anchors { left: parent.left; leftMargin: 13 * cp.ux; verticalCenter: parent.verticalCenter }
        spacing: 6 * cp.ux
        TLabel {
          visible: cp.collapsible
          text: cp.collapsed ? "▸" : "▾"
          mono: true
          color: cp.accent
          font.pixelSize: 10 * cp.ux
        }
        TLabel {
          // glyph stripped + words title-cased by root.titleText
          text: root.titleText(cp.title)
          color: cpHeadMa.containsMouse ? cp.accent : root.cSub
          font.pixelSize: Math.max(11, 13 * cp.ux)
          font.weight: Font.DemiBold
          font.letterSpacing: 0.4 * cp.ux
        }
      }

      // right-aligned mini readout in the title bar (HudP feature) — collapses
      // to nothing when unset so classic panels are pixel-identical
      TLabel {
        id: cpMiniStat
        anchors { right: cpHdChip.visible ? cpHdChip.left : parent.right
                  rightMargin: 6 * cp.ux; verticalCenter: parent.verticalCenter }
        visible: cp.miniStat !== ""
        text: cp.miniStat
        mono: true
        color: cp.accent
        font.pixelSize: Math.max(9, 10 * cp.ux)
        font.letterSpacing: 0.4 * cp.ux
      }

      Rectangle {
        anchors {
          left: cpHeadRow.right
          right: cp.miniStat !== "" ? cpMiniStat.left
                : (cpHdChip.visible ? cpHdChip.left : parent.right)
          leftMargin: 9 * cp.ux; rightMargin: 9 * cp.ux
          verticalCenter: parent.verticalCenter
        }
        height: 1
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0.0; color: Util.alpha(cp.accent, 0.35) }
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
        onPressed: if (cp.host !== null && cp.panelId !== "") cp.host.dragPress(cpHeadMa, cp, cp.panelId, mouse.x, mouse.y)
        onPositionChanged: if (cp.host !== null && cp.panelId !== "") cp.host.dragMove(cpHeadMa, cp, mouse.x, mouse.y)
        onReleased: {
          var wasDrag = (cp.host !== null && cp.panelId !== "") ? cp.host.dragRelease(cp) : false
          if (!wasDrag && cp.collapsible) cp.toggled()
        }
        onCanceled: if (cp.host !== null && cp.panelId !== "") cp.host.dragAbort(cp)
        onContainsMouseChanged: bezel.requestPaint()
      }

      // optional header action chip — sits on top of the drag/toggle
      // surface so a click activates instead of starting a panel move
      Rectangle {
        id: cpHdChip
        visible: cp.chipGlyph !== ""
        anchors { right: parent.right; rightMargin: 5 * cp.ux; verticalCenter: parent.verticalCenter }
        width: 20 * cp.ux
        height: 16 * cp.ux
        radius: 3 * cp.ux
        color: hdChipMa.containsMouse ? Util.alpha(cp.accent, 0.13) : Util.alpha(cp.accent, 0.05)
        border.color: hdChipMa.containsMouse ? Util.alpha(cp.accent, 0.7) : Util.alpha(cp.accent, 0.30)
        border.width: 1
        TLabel {
          anchors.centerIn: parent
          text: cp.chipGlyph
          mono: true
          color: hdChipMa.containsMouse ? "#eafcff" : cp.accent
          font.pixelSize: 10 * cp.ux
        }
        MouseArea {
          id: hdChipMa
          anchors { fill: parent; margins: -2 * cp.ux }
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: cp.chipActivated()
        }
      }
    }

    Item {
      id: cpClip
      anchors {
        top: cpHead.bottom; left: parent.left
        right: parent.right; bottom: parent.bottom
        leftMargin: 12 * cp.ux; rightMargin: 12 * cp.ux; bottomMargin: 10 * cp.ux
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
        onPressed: if (cp.host !== null) cp.host.sizePress(gripMa, cp, cp.panelId, mouse.x, mouse.y)
        onPositionChanged: if (cp.host !== null) cp.host.sizeMove(gripMa, cp, mouse.x, mouse.y)
        onReleased: if (cp.host !== null) cp.host.sizeRelease(cp)
        onCanceled: if (cp.host !== null) cp.host.sizeAbort(cp)
      }
    }
  }

  // Small temperature readout for the GPU temp grid — hairline tile, mono
  // value; threshold colour lives on the value, not on cell chrome.
  component TempBox: Rectangle {
    property string label: ""
    property real value: NaN
    property real ux: 1
    readonly property color valueColor: isNaN(value) ? root.cMuted
        : root.tempColor(value)
    color: Util.alpha(root.cCyan, 0.04)
    radius: 4 * ux
    border.width: 1
    border.color: root.cHair
    TLabel {
      anchors { left: parent.left; leftMargin: 6 * parent.ux; top: parent.top; topMargin: 4 * parent.ux }
      text: parent.label
      color: root.cMuted
      font.pixelSize: Math.max(9, 9 * parent.ux)
      font.letterSpacing: 0.6 * parent.ux
    }
    TLabel {
      anchors { left: parent.left; leftMargin: 6 * parent.ux; bottom: parent.bottom; bottomMargin: 3 * parent.ux }
      text: isNaN(parent.value) ? "--" : Math.round(parent.value * 10) / 10 + "°C"
      mono: true
      color: parent.valueColor
      font.pixelSize: Math.max(12, 13 * parent.ux)
    }
  }

  // Sparkline canvas: hairline baseline + two guide thirds, one or two
  // smoothed series, repaints on the shared clock tick. Guarded so
  // collapsed/hidden panels cost nothing — `live` lets a collapsible host
  // panel stop repaints while folded.
  component TraceCanvas: Canvas {
    id: tc
    property var pts: []
    property var pts2: []
    property color col: root.cCyan
    property color col2: root.cMagenta
    property real vmax: 0
    // split: draw pts2 mirrored below the midline (rx-up / tx-down lanes)
    property bool split: false
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

      // quiet plot: midline baseline + two vertical guides at 8% neutral —
      // no quarter grid, no bright edges, no input-port marker
      ctx.lineWidth = 1
      ctx.strokeStyle = "rgba(215,232,237,0.08)"
      ctx.beginPath()
      for (var gx = 1; gx < 3; gx++) {
        var xg = Math.round(w * gx / 3) + 0.5
        ctx.moveTo(xg, 0); ctx.lineTo(xg, h)
      }
      var ym = Math.round(h * 0.5) + 0.5
      ctx.moveTo(0, ym); ctx.lineTo(w, ym)
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
      root.paintTrace(ctx, w, h, pts, col, peak, root.scrollPhase, false)
      if (pts2.length > 0) {
        if (tc.split) {
          // faint divider between the up/down lanes
          ctx.strokeStyle = "rgba(215,232,237,0.12)"
          ctx.lineWidth = 1
          ctx.beginPath()
          ctx.moveTo(0, Math.round(h * 0.5) + 0.5)
          ctx.lineTo(w, Math.round(h * 0.5) + 0.5)
          ctx.stroke()
        }
        root.paintTrace(ctx, w, h, pts2, col2, peak, root.scrollPhase, tc.split)
      }
    }
  }

  // Label + current value + trace, one telemetry series in a box.
  // `live` gates the inner canvas repaint — wire it to the host panel's
  // shown/collapsed state so role-hidden panels never paint.
  component SparkBox: Item {
    property string label: ""
    property string val: ""
    property var pts: []
    property color col: root.cCyan
    property real vmax: 0
    property real ux: 1
    property bool live: true
    TLabel {
      id: sbLabel
      anchors { left: parent.left; top: parent.top }
      text: parent.label
      color: root.cSub
      font.pixelSize: Math.max(9, 11 * parent.ux)
      font.weight: Font.Medium
      font.letterSpacing: 0.2 * parent.ux
    }
    TLabel {
      anchors { right: parent.right; top: parent.top }
      text: parent.val
      mono: true
      color: parent.col
      font.pixelSize: Math.max(9, 12 * parent.ux)
    }
    TraceCanvas {
      anchors { left: parent.left; right: parent.right; top: sbLabel.bottom; topMargin: 3 * parent.ux; bottom: parent.bottom }
      pts: parent.pts
      col: parent.col
      vmax: parent.vmax
      live: parent.live
    }
  }

  // Power-vs-cap dial (HudR's Meter shape, re-voiced for the GPU sheets):
  // outer 270° arc = eased value fraction, inner arc = secondary fraction,
  // centre label + value + optional second-series caption. Repaint rides
  // the shared tickSeq gate; `live` mirrors the host panel's shown state.
  component PwrDial: Item {
    id: pdial
    property string label: "PWR"
    property string value: "--"
    property real amount: -1            // eased 0..1 outer arc
    property color accent: root.cMagenta
    property real ux: 1
    property bool second: false         // draw the inner arc
    property real amount2: -1           // eased 0..1 inner arc
    property color accent2: root.cCyan
    property string secondLabel: ""
    property bool live: true

    Canvas {
      id: pdFace
      anchors.fill: parent
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      Connections {
        target: root
        function onTickSeqChanged() {
          if (pdial.live && pdFace.width > 8 && pdFace.height > 8) pdFace.requestPaint()
        }
      }
      onPaint: {
        var c = getContext("2d")
        c.reset()
        var cx = width / 2, cy = height / 2
        var r = Math.min(width, height) * 0.40
        if (r < 4) return
        // static tick ring — 21 notches, every 5th a major
        c.strokeStyle = "rgba(215,232,237,0.10)"
        c.lineWidth = 1
        c.beginPath()
        for (var i = 0; i <= 20; i++) {
          var a = -Math.PI * 0.75 + Math.PI * 1.5 * i / 20
          var rr = r * 1.16
          c.moveTo(cx + Math.cos(a) * rr, cy + Math.sin(a) * rr)
          c.lineTo(cx + Math.cos(a) * (rr + (i % 5 === 0 ? 5 * pdial.ux : 2 * pdial.ux)),
                   cy + Math.sin(a) * (rr + (i % 5 === 0 ? 5 * pdial.ux : 2 * pdial.ux)))
        }
        c.stroke()
        function arc(v, color, radius, line) {
          c.beginPath()
          c.strokeStyle = String(root.cHair)
          c.lineWidth = line
          c.arc(cx, cy, radius, -Math.PI * 0.75, Math.PI * 0.75)
          c.stroke()
          if (v >= 0) {
            var f = Math.min(1, v)
            var col = root.heatColor(f, color)
            var ae = -Math.PI * 0.75 + Math.PI * 1.5 * f
            c.beginPath()
            c.strokeStyle = root.rgbaOf(col, 0.18)
            c.lineWidth = line * 2.0
            c.arc(cx, cy, radius, -Math.PI * 0.75, ae)
            c.stroke()
            c.beginPath()
            c.strokeStyle = root.rgbOf(col)
            c.lineWidth = line
            c.arc(cx, cy, radius, -Math.PI * 0.75, ae)
            c.stroke()
          }
        }
        arc(pdial.amount,  pdial.accent,  r,        Math.max(3, width * 0.055))
        if (pdial.second) arc(pdial.amount2, pdial.accent2, r * 0.78, Math.max(2, width * 0.035))
      }
    }
    Column {
      anchors.centerIn: parent
      spacing: 2 * pdial.ux
      TLabel {
        anchors.horizontalCenter: parent.horizontalCenter
        text: pdial.label
        color: root.cMuted
        font.pixelSize: Math.max(9, 10 * pdial.ux)
        font.letterSpacing: 0.4 * pdial.ux
      }
      TLabel {
        anchors.horizontalCenter: parent.horizontalCenter
        text: pdial.value
        mono: true
        color: pdial.accent
        font.weight: Font.DemiBold
        font.pixelSize: Math.max(14, 20 * pdial.ux)
      }
      TLabel {
        visible: pdial.second && pdial.secondLabel !== ""
        anchors.horizontalCenter: parent.horizontalCenter
        text: pdial.secondLabel + " " + (pdial.amount2 >= 0 ? Math.round(pdial.amount2 * 100) + "%" : "—")
        mono: true
        color: pdial.accent2
        font.pixelSize: Math.max(9, 9 * pdial.ux)
      }
    }
  }

  // --------------------------------------- interactive chips + hit rows
  // Every interactive element owns a dormant Quickshell.Io.Process; a click
  // pulses `running` (false→true) which spawns the command detached. All of
  // these live inside CPanel bodies whose item rects are in the window mask,
  // so clicks never leak to the desktop.

  // Generic command chip — launcher / quick-action button. Idle = quiet
  // hairline; hover = 7% accent wash (one cue, no border flash).
  component CmdChip: Rectangle {
    id: cmdChip
    property string label: "APP"
    property string glyph: "▸"
    property color accent: root.cCyan
    property var argv: []
    property real ux: 1
    signal activated()

    width: chipRow.implicitWidth + 20 * ux
    height: Math.max(24, 28 * ux)
    radius: 4 * ux
    color: cmdMa.containsMouse ? Util.alpha(accent, 0.07) : Qt.rgba(1, 1, 1, 0.03)
    border.color: root.cHair
    border.width: 1
    Behavior on color { ColorAnimation { duration: 120 } }

    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: 6 * cmdChip.ux
      TLabel {
        anchors.verticalCenter: parent.verticalCenter
        text: cmdChip.glyph
        mono: true
        color: cmdChip.accent
        font.pixelSize: Math.max(10, 11 * cmdChip.ux)
      }
      TLabel {
        anchors.verticalCenter: parent.verticalCenter
        text: cmdChip.label
        color: cmdMa.containsMouse ? "#eafcff" : root.cSub
        font.pixelSize: Math.max(10, 11 * cmdChip.ux)
        font.weight: Font.Medium
        font.letterSpacing: 0.2 * cmdChip.ux
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
    height: Math.max(24, 28 * ux)
    radius: 4 * ux
    color: active ? Util.alpha(root.cGreen, 0.13)
         : wsMa.containsMouse ? Util.alpha(root.cCyan, 0.07)
         : Qt.rgba(1, 1, 1, 0.03)
    border.color: active ? root.cGreen
                : wsMa.containsMouse ? Util.alpha(root.cCyan, 0.55)
                : root.cHair
    border.width: 1
    Behavior on color { ColorAnimation { duration: 120 } }

    Row {
      id: wsChipRow
      anchors.centerIn: parent
      spacing: 5 * wsChip.ux
      TLabel {
        anchors.verticalCenter: parent.verticalCenter
        text: wsChip.wsName
        color: wsChip.active ? root.cGreen : (wsMa.containsMouse ? "#eafcff" : root.cSub)
        font.pixelSize: Math.max(9, 10 * wsChip.ux)
        font.weight: wsChip.active ? Font.DemiBold : Font.Medium
        font.letterSpacing: 0.2 * wsChip.ux
      }
      TLabel {
        anchors.verticalCenter: parent.verticalCenter
        text: "·" + wsChip.wins
        mono: true
        color: wsChip.active ? root.cGreen : root.cMuted
        font.pixelSize: Math.max(9, 9 * wsChip.ux)
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
    height: Math.max(28, 32 * ux)

    Rectangle {
      anchors.fill: parent
      radius: 4 * wrow.ux
      color: wMa.containsMouse ? Util.alpha(root.cCyan, 0.07)
           : wrow.onThisScreen ? Util.alpha(root.cCyan, 0.04)
           : "transparent"
      Behavior on color { ColorAnimation { duration: 120 } }
    }
    Rectangle {
      id: wsBadge
      anchors { left: parent.left; leftMargin: 5 * wrow.ux; verticalCenter: parent.verticalCenter }
      width: 26 * wrow.ux
      height: 19 * wrow.ux
      radius: 4 * wrow.ux
      color: wrow.activeWs ? Util.alpha(root.cGreen, 0.13) : Util.alpha(root.cCyan, 0.08)
      TLabel {
        anchors.centerIn: parent
        text: wrow.wsName
        mono: true
        color: wrow.activeWs ? root.cGreen : root.cCyan
        font.pixelSize: Math.max(9, 9 * wrow.ux)
        font.weight: Font.Medium
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
        font.pixelSize: Math.max(11, 12 * wrow.ux)
        font.weight: Font.Medium
        elide: Text.ElideRight
      }
      TLabel {
        width: parent.width
        text: wrow.wtitle
        color: root.cMuted
        font.pixelSize: Math.max(9, 11 * wrow.ux)
        elide: Text.ElideRight
      }
    }
    TLabel {
      id: monLbl
      anchors { right: parent.right; rightMargin: 6 * wrow.ux; verticalCenter: parent.verticalCenter }
      text: wrow.monName
      mono: true
      color: wrow.onThisScreen ? root.cGreen : root.cMuted
      font.pixelSize: Math.max(9, 9 * wrow.ux)
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
    radius: 4 * ux
    color: active ? Util.alpha(accent, isBuild ? 0.08 + 0.08 * root.pulse : 0.13)
                  : Qt.rgba(1, 1, 1, 0.03)
    border.color: active ? Util.alpha(accent, 0.6) : root.cHair
    border.width: 1
    Behavior on color { ColorAnimation { duration: 150 } }

    Column {
      anchors { left: parent.left; leftMargin: 8 * agChip.ux; right: parent.right; rightMargin: 6 * agChip.ux; verticalCenter: parent.verticalCenter }
      spacing: 2 * agChip.ux
      Row {
        spacing: 5 * agChip.ux
        TLabel {
          text: agChip.name.toUpperCase()
          color: agChip.active ? agChip.accent : root.cMuted
          font.pixelSize: Math.max(9, 10 * agChip.ux)
          font.weight: Font.DemiBold
          font.letterSpacing: 0.4 * agChip.ux
        }
        TLabel {
          visible: agChip.isBuild && agChip.active
          text: "ACTIVE WORK"
          color: root.cAmber
          opacity: 0.45 + 0.55 * root.pulse
          font.pixelSize: Math.max(9, 9 * agChip.ux)
          font.weight: Font.Medium
          font.letterSpacing: 0.4 * agChip.ux
        }
      }
      TLabel {
        text: agChip.active ? agChip.procs + " proc · " + Math.round(agChip.cpu) + "%" : "idle"
        mono: true
        color: agChip.active ? root.cTxt : root.cMuted
        font.pixelSize: Math.max(9, 9 * agChip.ux)
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
    height: Math.max(28, 32 * ux)

    TLabel {
      id: bGlyph
      anchors { left: parent.left; verticalCenter: parent.verticalCenter }
      text: brow.charging ? "⌁" : "▮"
      mono: true
      color: brow.stateCol
      opacity: brow.charging ? 0.45 + 0.55 * root.pulse : 0.9
      font.pixelSize: Math.max(10, 11 * brow.ux)
    }
    TLabel {
      id: bName
      anchors { left: bGlyph.right; leftMargin: 7 * brow.ux; top: parent.top; topMargin: 1 * brow.ux }
      width: parent.width * 0.55
      text: brow.devName
      color: root.cTxt
      font.pixelSize: Math.max(11, 12 * brow.ux)
      font.weight: Font.Medium
      elide: Text.ElideRight
    }
    TLabel {
      anchors { right: parent.right; top: parent.top; topMargin: 1 * brow.ux }
      text: brow.pct >= 0 ? Math.round(brow.pct) + "%" : "--"
      mono: true
      color: brow.stateCol
      font.pixelSize: Math.max(11, 12 * brow.ux)
      font.weight: Font.Medium
    }
    Rectangle {
      id: bTrack
      anchors { left: bGlyph.right; leftMargin: 7 * brow.ux; right: parent.right; bottom: parent.bottom; bottomMargin: 4 * brow.ux }
      height: Math.max(3, 4 * brow.ux)
      radius: 2
      color: root.cInset
      Rectangle {
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: Math.max(0, bTrack.width * Util.clamp(brow.pct / 100, 0, 1))
        radius: 2
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
      font.pixelSize: Math.max(9, 9 * brow.ux)
      font.letterSpacing: 0.4 * brow.ux
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
    height: Math.max(26, 30 * ux)

    Rectangle {
      anchors.fill: parent
      radius: 4 * rrow.ux
      color: rrMa.containsMouse ? Util.alpha(root.cGreen, 0.07) : "transparent"
      Behavior on color { ColorAnimation { duration: 120 } }
    }
    Rectangle {
      anchors { left: parent.left; leftMargin: 4 * rrow.ux; verticalCenter: parent.verticalCenter }
      width: 40 * rrow.ux
      height: 17 * rrow.ux
      radius: 4 * rrow.ux
      color: Util.alpha(root.cGreen, 0.10)
      TLabel {
        anchors.centerIn: parent
        width: parent.width - 2
        text: rrow.kind
        mono: true
        color: root.cGreen
        font.pixelSize: Math.max(9, 9 * rrow.ux)
        font.weight: Font.Medium
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
      }
    }
    TLabel {
      anchors { left: parent.left; leftMargin: 50 * rrow.ux; right: ageLbl.left; rightMargin: 6 * rrow.ux; verticalCenter: parent.verticalCenter }
      text: rrow.repo
      color: rrMa.containsMouse ? "#eafcff" : root.cTxt
      font.pixelSize: Math.max(11, 12 * rrow.ux)
      font.weight: Font.Medium
      elide: Text.ElideRight
    }
    TLabel {
      id: ageLbl
      anchors { right: parent.right; rightMargin: 5 * rrow.ux; verticalCenter: parent.verticalCenter }
      text: rrow.age
      mono: true
      color: root.cMuted
      font.pixelSize: Math.max(9, 11 * rrow.ux)
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
  // Process row (HudP semantics): rank + name + animated cpu-share bar +
  // right column with the raw percentage over a "cpu" unit sublabel, so the
  // header's "%CPU (1s)" promise is legible per row.
  component ProcRow: Item {
    id: prow
    property int rank: 0
    property string pname: ""
    property real pcpu: 0
    property real ux: 1

    width: parent ? parent.width : 0
    height: Math.max(28, 30 * ux)

    TLabel {
      id: prk
      anchors { left: parent.left; verticalCenter: parent.verticalCenter }
      width: 16 * prow.ux
      text: prow.rank
      mono: true
      color: root.cMuted
      font.pixelSize: Math.max(9, 9 * prow.ux)
    }
    TLabel {
      id: pnm
      anchors { left: prk.right; leftMargin: 4 * prow.ux; verticalCenter: parent.verticalCenter }
      width: parent.width * 0.40
      text: prow.pname
      color: root.cTxt
      font.pixelSize: Math.max(11, 12 * prow.ux)
      font.weight: Font.Medium
      elide: Text.ElideRight
    }
    Rectangle {
      id: ptrack
      anchors { left: pnm.right; leftMargin: 6 * prow.ux; right: pctCol.left; rightMargin: 8 * prow.ux; verticalCenter: parent.verticalCenter }
      height: Math.max(3, 4 * prow.ux)
      radius: 2
      color: root.cInset
      Rectangle {
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: Math.max(0, ptrack.width * Util.clamp(prow.pcpu / 100, 0, 1))
        radius: 2
        color: prow.pcpu >= 60 ? root.cMagenta : prow.pcpu >= 25 ? root.cAmber : root.cCyan
        Behavior on width { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }
      }
    }
    Item {
      id: pctCol
      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
      width: 42 * prow.ux
      height: parent.height
      TLabel {
        anchors { right: parent.right; top: parent.top; topMargin: 1 * prow.ux }
        text: Math.round(prow.pcpu) + "%"
        mono: true
        horizontalAlignment: Text.AlignRight
        color: prow.pcpu >= 60 ? root.cMagenta : prow.pcpu >= 25 ? root.cAmber : root.cAccent
        font.pixelSize: Math.max(11, 12 * prow.ux)
        font.weight: Font.Medium
      }
      TLabel {
        anchors { right: parent.right; bottom: parent.bottom; bottomMargin: 1 * prow.ux }
        text: "cpu"
        horizontalAlignment: Text.AlignRight
        color: root.cDim
        font.pixelSize: Math.max(9, 9 * prow.ux)
      }
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
    height: Math.max(22, 24 * ux)

    Rectangle {
      anchors.fill: parent
      radius: 4 * trow.ux
      color: tmMa.containsMouse ? Util.alpha(root.cGreen, 0.07) : "transparent"
      Behavior on color { ColorAnimation { duration: 120 } }
    }
    TLabel {
      anchors { left: parent.left; leftMargin: 5 * trow.ux; verticalCenter: parent.verticalCenter }
      text: "▸"
      mono: true
      color: trow.att ? root.cGreen : root.cMuted
      font.pixelSize: Math.max(9, 9 * trow.ux)
    }
    TLabel {
      anchors { left: parent.left; leftMargin: 18 * trow.ux; right: attBadge.left; rightMargin: 6 * trow.ux; verticalCenter: parent.verticalCenter }
      text: trow.sname + "  ·  " + trow.wins + " win"
      color: tmMa.containsMouse ? "#eafcff" : root.cSub
      font.pixelSize: Math.max(11, 11 * trow.ux)
      font.weight: Font.Medium
      elide: Text.ElideRight
    }
    Rectangle {
      id: attBadge
      visible: trow.att
      anchors { right: parent.right; rightMargin: 5 * trow.ux; verticalCenter: parent.verticalCenter }
      width: 34 * trow.ux
      height: 14 * trow.ux
      radius: 4 * trow.ux
      color: Util.alpha(root.cGreen, 0.13)
      TLabel {
        anchors.centerIn: parent
        text: "ATT"
        mono: true
        color: root.cGreen
        font.pixelSize: Math.max(9, 9 * trow.ux)
        font.weight: Font.Medium
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
    height: Math.max(20, 22 * ux)

    Rectangle {
      anchors.fill: parent
      radius: 4 * drow.ux
      color: dvMa.containsMouse ? Util.alpha(root.cMagenta, 0.07) : "transparent"
      Behavior on color { ColorAnimation { duration: 120 } }
    }
    TLabel {
      anchors { left: parent.left; leftMargin: 5 * drow.ux; verticalCenter: parent.verticalCenter }
      text: "◆"
      mono: true
      color: drow.live ? root.cMagenta : root.cMuted
      opacity: drow.live ? 0.5 + 0.5 * root.pulse : 0.6
      font.pixelSize: Math.max(9, 9 * drow.ux)
    }
    TLabel {
      anchors { left: parent.left; leftMargin: 17 * drow.ux; right: pidLbl.left; rightMargin: 6 * drow.ux; verticalCenter: parent.verticalCenter }
      text: drow.sname
      color: dvMa.containsMouse ? "#eafcff" : (drow.live ? root.cSub : root.cMuted)
      font.pixelSize: Math.max(11, 11 * drow.ux)
      font.weight: Font.Medium
      elide: Text.ElideRight
    }
    TLabel {
      id: pidLbl
      anchors { right: parent.right; rightMargin: 5 * drow.ux; verticalCenter: parent.verticalCenter }
      text: drow.live ? "pid " + drow.spid : "stale"
      mono: true
      color: drow.live ? root.cGreen : root.cMuted
      font.pixelSize: Math.max(9, 9 * drow.ux)
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
      height: Math.max(3, 4 * msl.ux)
      radius: 2
      color: root.cInset
      Rectangle {
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: Math.max(0, (parent.width) * Util.clamp(msl.value, 0, 1))
        radius: 2
        color: Util.alpha(msl.accent, 0.7)
      }
    }
    Rectangle {
      x: Math.max(0, Math.min(parent.width - width, (parent.width - width) * Util.clamp(msl.value, 0, 1)))
      anchors.verticalCenter: parent.verticalCenter
      width: 8 * msl.ux
      height: 12 * msl.ux
      radius: 2 * msl.ux
      color: msl.accent
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

    width: schipLbl.implicitWidth + 20 * ux
    height: Math.max(24, 28 * ux)
    radius: 4 * ux
    color: lit ? Util.alpha(accent, 0.13) : Qt.rgba(1, 1, 1, 0.03)
    border.color: lit ? accent : root.cHair
    border.width: 1
    TLabel {
      id: schipLbl
      anchors.centerIn: parent
      text: schip.label
      color: schip.lit ? accent : (schipMa.containsMouse ? "#eafcff" : root.cMuted)
      font.pixelSize: Math.max(9, 10 * schip.ux)
      font.weight: schip.lit ? Font.DemiBold : Font.Medium
      font.letterSpacing: 0.3 * schip.ux
    }
    MouseArea {
      id: schipMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: schip.chosen()
    }
  }

  // ---------------------------------------------------- pixel knot element
  // PixelKnot.qml inlined as a single-file component (wave-4): the Nexus
  // Link celtic-knot element rendered as pixel art. Idle cells sit dim; a
  // shuffle-bag scheduler fires one of five micro-animations every ~30-60 s
  // (scan sweep / centre pulse / draw-in trace / sparkle / hue rotation).
  // Instantiated once on the DP-2 bench inside the "knot" free-canvas zone.
  component PixelKnot: Canvas {
    id: knotCanvas

    // ---- public API --------------------------------------------------------
    property int   px: 5                 // logical pixel-cell size
    property color accent: "#00e5ff"     // knot colour (follows HUD accent)
    property int   cycleSeconds: 45      // nominal cadence; jittered 30..60 s
    property bool  running: true         // master gate (HUD tick may clear it)

    readonly property int cols: 48
    readonly property int rows: 49
    implicitWidth:  cols * px
    implicitHeight: rows * px

    function pause()  { paused = true;  cycleTimer.stop(); fxTimer.stop() }
    function resume() {
      paused = false
      if (!running) return
      if (effect >= 0) { t0 = Date.now() - elapsed; fxTimer.restart() }
      else scheduleNext()
      requestPaint()
    }
    onRunningChanged: if (running) resume(); else pause()

    // ---- baked pixel matrix ("#" = knot cell) -------------------------------
    readonly property var knotRows: [
      "......................##........................",
      ".....................####.......................",
      "....................######......................",
      "...................########.....................",
      "...................###..####....................",
      "..................####...###....................",
      ".................############...................",
      ".................###......#####.................",
      "..............######.......###.##...............",
      "............##..###........####..##.............",
      "...........#....###.........###....#............",
      ".........##....###..........###.....##..........",
      "........##.....###...........###.....##.........",
      ".......##......###...........###......##........",
      "......##.......##............###.......##.......",
      "......#.......###.............##........#.......",
      ".....#........###.............###........#......",
      "....##........###.............###........#......",
      "....#.........###.............###.........#.....",
      "....#.........###.............###.........#.....",
      "...#..........###.............###..........#....",
      "...#...........#.############.###..........#....",
      "..##...........##############.###..........#....",
      "..#..........#########....######.###........#...",
      "..#........######............###.####.......#...",
      "..#......######.##...........###.######.....#...",
      "..#.....#####...###..........###...#####....#...",
      "..#....####.....###.........###......####...#...",
      "..#...####......####........###.......####..#...",
      "..#..####........###.......###.........####.#...",
      "..#.####.........####......###..........#####...",
      "..#.###...........####....###............###....",
      "..#####............###...####.............###...",
      "...###.............####..###..............####..",
      "..###...............####.##................###..",
      "..###................#####................#####.",
      ".####.................#####...............#.###.",
      ".####..............##########............##.###.",
      ".###.#...........######..######..........#...###",
      "###...#........#######....#########.....########",
      "#######...##########........####################",
      "##################.............###############..",
      "..#############.....................###.#.......",
      ".........##.........................##..........",
      "..........##.......................##...........",
      "............##...................##.............",
      ".............###...............###..............",
      "...............####.........####................",
      "...................#########...................."
    ]

    // ---- derived geometry / animation state ---------------------------------
    property var    cells: []          // [{x,y,s}] grid coords + sparkle seed
    property var    rank: []           // cell index -> position in trace order
    property real   kcx: 0             // filled-cell bbox centre (pulse origin)
    property real   kcy: 0
    property real   maxR: 1            // farthest cell distance from centre
    property int    effect: -1         // -1 idle; 0..4 active micro-animation
    property double t0: 0              // effect start timestamp (ms)
    property double elapsed: 0         // ms into current effect
    property double effectDur: 0
    property var    bag: []            // shuffle-bag of pending effect ids
    property bool   paused: false

    readonly property real  idleA:    0.16       // idle cell alpha (~15-20%)
    readonly property color cMagenta: "#ff2bd6"  // HUD palette anchors
    readonly property color cAmber:   "#ffb300"
    property var hueStops: []          // built onCompleted: accent,magenta,amber

    Component.onCompleted: {
      buildCells()
      requestPaint()
      if (running) scheduleNext()
    }
    onAccentChanged: { buildHueStops(); requestPaint() }
    onPxChanged:     requestPaint()
    onWidthChanged:  requestPaint()
    onHeightChanged: requestPaint()

    function buildHueStops() {
      hueStops = [accent, cMagenta, cAmber, accent] // accent->magenta->amber->accent
    }

    function buildCells() {
      var list = [], mnx = 1e9, mxx = -1e9, mny = 1e9, mxy = -1e9
      for (var y = 0; y < rows; y++) {
        var row = knotRows[y] || ""
        for (var x = 0; x < cols; x++) {
          if (row.charAt(x) === "#") {
            list.push({ x: x, y: y, s: Math.random() })
            if (x < mnx) mnx = x; if (x > mxx) mxx = x
            if (y < mny) mny = y; if (y > mxy) mxy = y
          }
        }
      }
      cells = list
      kcx = (mnx + mxx) / 2; kcy = (mny + mxy) / 2
      var mr = 1
      for (var i = 0; i < list.length; i++) {
        var d = Math.sqrt((list[i].x - kcx) * (list[i].x - kcx)
                        + (list[i].y - kcy) * (list[i].y - kcy))
        if (d > mr) mr = d
      }
      maxR = mr
      buildTrace()
      buildHueStops()
    }

    // Greedy nearest-neighbour crawl from the topmost-centre cell — approximates
    // tracing the continuous knot ribbon. O(n^2) once at load (617 cells).
    function buildTrace() {
      var n = cells.length, used = [], order = [], r = new Array(n)
      for (var i = 0; i < n; i++) used.push(false)
      var cur = 0
      for (i = 1; i < n; i++)
        if (cells[i].y < cells[cur].y
         || (cells[i].y === cells[cur].y && Math.abs(cells[i].x - kcx) < Math.abs(cells[cur].x - kcx)))
          cur = i
      for (var k = 0; k < n; k++) {
        order.push(cur); used[cur] = true
        var best = -1, bd = 1e18
        for (var j = 0; j < n; j++) {
          if (used[j]) continue
          var dx = cells[j].x - cells[cur].x, dy = cells[j].y - cells[cur].y
          var dd = dx * dx + dy * dy
          if (dd < bd) { bd = dd; best = j }
        }
        cur = best
      }
      for (k = 0; k < n; k++) r[order[k]] = k
      rank = r
    }

    // ---- scheduler -----------------------------------------------------------
    function scheduleNext() {
      var c = Math.max(30, Math.min(60, cycleSeconds))
      var iv = Math.max(30, Math.min(60, c + (Math.random() * 2 - 1) * 15))
      cycleTimer.interval = Math.round(iv * 1000)   // jittered 30..60 s
      cycleTimer.restart()
    }
    function durFor(e) {                            // effect lifetime, ms
      switch (e) {
        case 0: return 1700                          // scan sweep
        case 1: return 2000                          // pulse ring
        case 2: return 5200                          // draw 2.4s + hold 2s + fade .8s
        case 3: return 3200                          // sparkle
        case 4: return 4400                          // hue rotation
      }
      return 1000
    }
    function startEffect() {
      if (bag.length === 0) {                        // shuffle-bag: all 5, random order
        bag = [0, 1, 2, 3, 4]
        for (var i = bag.length - 1; i > 0; i--) {
          var j = Math.floor(Math.random() * (i + 1))
          var t = bag[i]; bag[i] = bag[j]; bag[j] = t
        }
      }
      effect = bag.pop()
      effectDur = durFor(effect)
      t0 = Date.now(); elapsed = 0
      fxTimer.restart()
      requestPaint()
    }
    function endEffect() {
      fxTimer.stop(); effect = -1; elapsed = 0
      requestPaint()                                 // settle back to idle dim
      if (running && !paused) scheduleNext()
    }

    Timer {
      id: cycleTimer
      repeat: false
      onTriggered: {
        if (knotCanvas.running && !knotCanvas.paused) knotCanvas.startEffect()
        // paused/stopped: resume() or running:true re-arms the timer
      }
    }
    Timer {
      id: fxTimer                                    // ~30 Hz paint pump
      interval: 33; repeat: true
      onTriggered: {
        knotCanvas.elapsed = Date.now() - knotCanvas.t0
        if (knotCanvas.elapsed >= knotCanvas.effectDur) knotCanvas.endEffect()
        else knotCanvas.requestPaint()
      }
    }

    // ---- colour helpers -------------------------------------------------------
    function lerpC(a, b, t) {
      return Qt.rgba(a.r + (b.r - a.r) * t,
                     a.g + (b.g - a.g) * t,
                     a.b + (b.b - a.b) * t, 1)
    }
    function hueAt(f) {                              // f in [0,1] around stop ring
      var p = f * (hueStops.length - 1), i = Math.floor(p)
      if (i >= hueStops.length - 1) i = hueStops.length - 2
      return lerpC(hueStops[i], hueStops[i + 1], p - i)
    }
    function rgbaStr(c, a) {
      return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255)
                   + "," + Math.round(c.b * 255) + "," + a.toFixed(3) + ")"
    }

    // ---- per-cell boost functions ----------------------------------------------
    function boost(i, pr) {                          // pr = effect progress 0..1
      var c = cells[i]
      switch (effect) {
        case 0: {                                    // SCAN: column + short trail
          var pos = -3 + pr * (cols + 6), d = c.x - pos
          var b = Math.max(0, 1 - Math.abs(d) / 2.4)
          if (d < 0) b = Math.max(b, 0.45 * Math.max(0, 1 + d / 9))
          return b
        }
        case 1: {                                    // PULSE: expanding ring
          var dx = c.x - kcx, dy = c.y - kcy
          var R = pr * (maxR + 3), rr = Math.sqrt(dx * dx + dy * dy)
          return Math.max(0, 1 - Math.abs(rr - R) / 3.0)
        }
        case 2: {                                    // DRAW-IN: trace, hold, fade
          var ph = elapsed
          if (ph < 2400) {
            var lit = ph / 2400 * cells.length
            return Math.max(0, Math.min(1, (lit - rank[i]) / 5))
          }
          if (ph < 4400) return 1
          return Math.max(0, 1 - (ph - 4400) / 800)
        }
        case 3: {                                    // SPARKLE: per-cell twinkle
          var v = Math.sin(elapsed * 0.004 * (2 + c.s * 6) + c.s * 40)
          var env = Math.min(1, Math.min(elapsed, effectDur - elapsed) / 400)
          return Math.max(0, (v - 0.45) / 0.55) * env
        }
        case 4: return 0.8                           // TRACE-COLOR: flat bright
      }
      return 0
    }

    // ---- paint ------------------------------------------------------------------
    onPaint: {
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, width, height)
      var n = cells.length
      if (n === 0) return

      var cw = width / cols, ch = height / rows
      var ins = Math.max(0.5, Math.min(cw, ch) * 0.07) // pixel grout
      var pr = effectDur > 0 ? Math.min(1, elapsed / effectDur) : 0
      var isHue = (effect === 4)
      var hueF = pr                                  // one full ring over duration

      for (var i = 0; i < n; i++) {
        var b = boost(i, pr)
        var a = idleA + b * 0.84
        if (a > 1) a = 1
        var col = accent
        if (isHue)                                   // slight spatial hue drift
          col = hueAt((hueF + cells[i].x * 0.012 + cells[i].y * 0.008) % 1)
        ctx.fillStyle = rgbaStr(col, a)
        var c = cells[i]
        ctx.fillRect(c.x * cw + ins, c.y * ch + ins, cw - 2 * ins, ch - 2 * ins)
      }
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
      // The settings scrim covers the whole window while its sheet is open,
      // and the token-ledger scrim does the same while the popup is up.
      mask: Region {
        regions: [
          Region { item: titlePlate },
          Region { item: win.sheetOpen ? sheetScrim : null },
          Region { item: root.tokOpen ? tokScrim : null },
          Region { item: root.tokOpen ? tokSheet : null },
          // command cockpit — sparse cinematic set: hero system, the reactor
          // chassis (spark flanks + dial + marquee), compact agents, status
          Region { item: win.isCommand && sysPanel.masked   ? sysPanel    : null },
          Region { item: win.centerShown && !win.zoneBusy ? sparkLPanel : null },
          Region { item: win.centerShown && !win.zoneBusy ? sparkRPanel : null },
          Region { item: win.centerShown && !win.zoneBusy ? procPanel   : null },
          Region { item: win.centerShown && !win.zoneBusy ? dialBox     : null },
          Region { item: win.isCommand && agentsPanel.masked ? agentsPanel : null },
          Region { item: win.isCommand && statusPanel.masked ? statusPanel : null },
          // compact launch rail rides the command title zone only (ops has
          // the full LAUNCH panel; hardware is a read-only lab bench)
          Region { item: win.isCommand ? topRail : null },
          // hardware detail — sole home for every silicon/storage/battery
          // metric, plus the decorative pixel knot
          Region { item: win.isHardware && hwMatrixPanel.masked   ? hwMatrixPanel   : null },
          Region { item: win.isHardware && hwSensorsPanel.masked  ? hwSensorsPanel  : null },
          Region { item: win.isHardware && hwGpu0Panel.masked     ? hwGpu0Panel     : null },
          Region { item: win.isHardware && hwGpu1Panel.masked     ? hwGpu1Panel     : null },
          Region { item: win.isHardware && hwStoragePanel.masked  ? hwStoragePanel  : null },
          Region { item: win.isHardware && hwPeriphPanel.masked   ? hwPeriphPanel   : null },
          Region { item: win.isHardware && hwMemoryPanel.masked   ? hwMemoryPanel   : null },
          Region { item: knotZone.masked ? knotZone : null },
          Region { item: win.isHardware && hwStatusPanel.masked   ? hwStatusPanel   : null },
          // ops console — sole home for work surfaces + top procs + net feed
          // + the token ledger panel
          Region { item: win.isOps && navPanel.masked        ? navPanel        : null },
          Region { item: win.isOps && opsProcsPanel.masked   ? opsProcsPanel   : null },
          Region { item: win.isOps && opsAgentsPanel.masked  ? opsAgentsPanel  : null },
          Region { item: win.isOps && repoPanel.masked       ? repoPanel       : null },
          Region { item: win.isOps && launchPanel.masked     ? launchPanel     : null },
          Region { item: win.isOps && opsActionsPanel.masked ? opsActionsPanel : null },
          Region { item: win.isOps && tokPanel.masked        ? tokPanel        : null },
          Region { item: win.isOps && opsNetPanel.masked     ? opsNetPanel     : null },
          Region { item: win.isOps && opsStatusPanel.masked  ? opsStatusPanel  : null }
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
      // ONE-HOME SETS (BRIEF-PASS3-CONTENT): silicon detail lives only on
      // hardware, work/console panels only on ops, and command keeps just
      // the cinematic hero pieces — no metric is duplicated across roles.
      readonly property var rolePanelIds: ({
        command:  ["system", "center", "agents", "knot", "status"],
        hardware: ["matrix", "sensors", "gpu", "gpu2", "storage",
                   "periph", "memory", "status"],
        ops:      ["windows", "procs", "agents", "repo", "launch", "actions",
                   "tokens", "network", "status"]
      })
      readonly property var roleIds: rolePanelIds[role] !== undefined ? rolePanelIds[role] : rolePanelIds.command
      readonly property string screenName: String(modelData.name)
      readonly property bool centerShown: isCommand && !isHidden("center")
      readonly property bool zoneBusy: draggingId === "center" || sizingId === "center"

      readonly property var panelLabels: ({
        system: "SYSTEM", memory: "MEMORY", gpu: "GPU SHEET 0",
        gpu2: "GPU SHEET 1", storage: "STORAGE — DEVICES", center: "REACTOR DIAL",
        network: "NETWORK", agents: "AGENTS", status: "STATUS",
        matrix: "CORE MATRIX", sensors: "SENSORS", procs: "TOP PROCS",
        periph: "PERIPHERALS", windows: "WINDOWS / NAV", repo: "REPO ACTIVITY",
        launch: "LAUNCH", actions: "OPS ACTIONS", tokens: "TOKENS",
        knot: "PIXEL KNOT"
      })
      function panelLabel(id) {
        var t = panelLabels[id]
        return root.titleText(t !== undefined ? t : String(id).toUpperCase())
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
          case "storage": return hwStoragePanel
          case "periph":  return hwPeriphPanel
          case "memory":  return hwMemoryPanel
          case "status":  return hwStatusPanel
          }
        } else if (isOps) {
          switch (pid) {
          case "windows": return navPanel
          case "procs":   return opsProcsPanel
          case "agents":  return opsAgentsPanel
          case "repo":    return repoPanel
          case "launch":  return launchPanel
          case "actions": return opsActionsPanel
          case "tokens":  return tokPanel
          case "network": return opsNetPanel
          case "status":  return opsStatusPanel
          }
        } else {
          switch (pid) {
          case "system":  return sysPanel
          case "center":  return centerZone
          case "agents":  return agentsPanel
          case "knot":    return knotZone
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
        var dm = defaultRects()
        if (m === null) {
          layoutMap = dm
        } else {
          // backfill panels added after this map was persisted (wave-4's
          // tokens/knot) at their designed rects — existing rects untouched
          var mm = {}
          for (var mk in m) mm[mk] = m[mk]
          for (var dk in dm) if (mm[dk] === undefined) mm[dk] = dm[dk]
          layoutMap = mm
        }
        layoutReady = true
        reflowTimer.restart()          // clamp/resolve whatever we loaded
        animGate.start()               // enable slide animations after settle
      }

      function pxOf(id) { var r = layoutMap[id]; return r ? r.fx * field.width : 0 }
      function pyOf(id) { var r = layoutMap[id]; return r ? r.fy * field.height : 0 }
      function pwOf(id) { var r = layoutMap[id]; return r ? Math.max(40, r.fw * field.width) : 160 * ux }
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

      // Factory map: the merged one-home layout in field coordinates.
      // Panel heights read live `naturalH` so collapsed state can't corrupt
      // the defaults. Command is deliberately sparse — a hero column and the
      // reactor — while hardware/ops keep their three-column workbenches.
      function defaultRects() {
        var m = {}
        var W = Math.max(1, field.width), H = Math.max(1, field.height)
        var g = gap, rH = railH, sH = stripH
        if (isCommand) {
          // ---- HudFinal3b cinematic cockpit ----
          // SYSTEM is a full-height left rail; everything else lives in the
          // "open canvas" right of it. The reactor chassis is a large
          // square-ish block centred in that canvas' upper-middle band, the
          // pixel knot shrinks to a ~200 px watermark parked on the
          // reactor's vertical axis just above the strips, and AGENTS +
          // STATUS sit flush with the field floor.
          var L = leftW
          var OW = Math.max(40, W - L - g)          // open-canvas width

          // bottom strips — inside the open canvas, bottoms flush with H.
          // Heights ride live naturalH (nh() honours hidden/collapsed), so
          // the cards end exactly at the field edge instead of floating a
          // dead band above it.
          var sAg = Math.max(nh("agents"), 90 * ux)
          var sSt = Math.max(nh("status"), 90 * ux)
          var sTop = Math.max(0, H - Math.max(sAg, sSt))
          var aw = Math.max(140, OW * 0.44)
          var sw = Math.max(140, OW - g - aw)
          m["agents"]  = mkRect(L + g, Math.max(0, H - sAg), aw)
          m["status"]  = mkRect(L + g + aw + g, Math.max(0, H - sSt), sw)

          // knot watermark — a large dim celtic-knot silhouette centred on
          // the open canvas (both axes), behind every panel at z -2. It is
          // the field's backdrop, not a tile in it, so it may overlap the
          // chassis and the bottom strips.
          var kk = Math.min(Math.max(300, H * 0.30), OW * 0.62, 500)
          m["knot"]    = mkRect(L + g + Math.max(0, (OW - kk) / 2),
                                Math.max(0, (H - kk) / 2), kk, kk)

          // reactor chassis — the centrepiece: ~52 % of field width and up
          // to ~64 % of field height, centred horizontally in the open
          // canvas and vertically in the band above the strips, stacked on
          // the same axis as the knot. fh is set so the chassis honours the
          // designed height (it accepts sizeH).
          var bandH = Math.max(160, sTop - g)
          var cw = Math.min(Math.max(600 * ux, W * 0.52), OW)
          var ch = Math.min(Math.max(360 * ux, H * 0.64), bandH)
          var cx = L + g + Math.max(0, (OW - cw) * 0.5)
          var cy = Math.max(0, (bandH - ch) * 0.5)
          m["center"]  = mkRect(cx, cy, cw, ch)

          // full-height left rail — the eased LOAD1 trace fills its lower
          // half (see sysPanel body)
          m["system"]  = mkRect(0, 0, L, H)
        } else if (isHardware) {
          var hL = hwLeftW, hM = hwMidW, hR = hwRightW
          var hmx = nh("matrix"), hsn = nh("sensors")
          var hg0 = nh("gpu"), hg1 = nh("gpu2")
          var hst = nh("storage"), hpe = nh("periph")
          var hmem = nh("memory")
          m["matrix"]  = mkRect(0, 0, hL)
          m["sensors"] = mkRect(0, hmx + g, hL)
          var hcx = hL + g
          m["gpu"]     = mkRect(hcx, 0, hM)
          m["gpu2"]    = mkRect(hcx, hg0 + g, hM)
          var hrx = W - hR
          m["storage"] = mkRect(hrx, 0, hR)
          m["periph"]  = mkRect(hrx, hst + g, hR)
          m["memory"]  = mkRect(hrx, hst + hpe + 2 * g, hR)
          // status is the lone bottom-strip resident — full width, with
          // cross-references to the command/ops homes of other metrics
          m["status"]  = mkRect(0, H - sH, W)
        } else {
          var oL = opsLeftW, oM = opsMidW, oR = opsRightW
          var onv = nh("windows")
          var oag = nh("agents"), orp = nh("repo")
          var oln = nh("launch"), oac = nh("actions")
          var otk = nh("tokens")
          m["windows"] = mkRect(0, 0, oL)
          m["procs"]   = mkRect(0, onv + g, oL)
          var ocx = oL + g
          m["agents"]  = mkRect(ocx, 0, oM)
          m["repo"]    = mkRect(ocx, oag + g, oM)
          var orx = W - oR
          m["launch"]  = mkRect(orx, 0, oR)
          m["actions"] = mkRect(orx, oln + g, oR)
          // the token ledger sits under OPS ACTIONS in the right column;
          // NETWORK keeps filling whatever is left down to the strip
          m["tokens"]  = mkRect(orx, oln + oac + 2 * g, oR)
          m["network"] = mkRect(orx, oln + oac + otk + 3 * g, oR,
                                Math.max(120, rH - oln - oac - otk - 3 * g))
          m["status"]  = mkRect(0, H - sH, W)
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
      // with "" it's a tidy-up — clamp offscreen rects only. Tidy-up must
      // NOT resolve overlaps: designed overlaps (the knot watermark sitting
      // behind the proc drawer) are legal, and a 280 ms reflow triggered by
      // dynamic heights would otherwise shove a user-dropped panel back —
      // the "snap back" bug. Only a real drop/resize morphs siblings.
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
          if (anchorId !== "" && overlapsAny(r, placed)) r = nearestFree(r, placed)
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
      // One quiet 1 px outline at 35% accent alpha (lerped toward alert red
      // via alertMix) plus an alert-only breathing halo — the nested inner
      // line, corner brackets, edge index ticks and scan sweep are gone per
      // the design pass; the frame is context, not content.
      Rectangle {
        id: frameLine
        anchors { fill: parent; margins: win.pad }
        color: "transparent"
        border.color: Util.alpha(root.frameCol, 0.35)
        border.width: 1
      }
      Rectangle {
        id: frameHalo
        anchors { fill: parent; margins: win.pad - 2 * win.ux }
        color: "transparent"
        border.color: root.cAlert
        border.width: 2
        opacity: root.alertMix * (0.10 + 0.20 * root.pulse)
        visible: root.alertMix > 0.02
      }

      // ---------------------------------------------------- title plate
      // Masthead inside the top edge of the frame; clicking it
      // folds/unfolds every collapsible panel.
      Item {
        id: titlePlate
        width: plateRow.width + 34 * win.ux + gearChip.width
        height: 28 * win.ux
        anchors.horizontalCenter: parent.horizontalCenter
        // dropped below the omarchy bar / top frame line instead of
        // straddling it
        y: win.pad + 28 * win.ux
        Rectangle {
          anchors.fill: parent
          radius: 6 * win.ux
          color: root.cPlate
          border.color: root.cHair
          border.width: 1
        }
        Row {
          id: plateRow
          anchors.centerIn: parent
          spacing: 10 * win.ux
          TLabel {
            text: "NEXUS"
            color: root.cCyan
            font.pixelSize: Math.max(13, 16 * win.ux)
            font.weight: Font.DemiBold
            font.letterSpacing: 0.4 * win.ux
          }
          TLabel {
            text: "//" + (root.hostName !== "" ? root.hostName : "?")
            mono: true
            color: root.cGreen
            font.pixelSize: Math.max(11, 12 * win.ux)
          }
          TLabel {
            text: root.titleText(win.roleLabel)
            color: win.isOps ? root.cGreen : (win.isHardware ? root.cAmber : root.cMuted)
            font.pixelSize: Math.max(9, 11 * win.ux)
            font.letterSpacing: 0.4 * win.ux
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
          radius: 4 * win.ux
          color: gearMa.containsMouse ? Util.alpha(root.cCyan, 0.13) : "transparent"
          border.color: gearMa.containsMouse ? root.cCyan : root.cHair
          border.width: 1
          TLabel {
            anchors.centerIn: parent
            text: "⚙"
            mono: true
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
      // page only (ops has the full LAUNCH panel; hardware has none — the
      // one-home rule counts launchers as ops/command furniture, not lab).
      Row {
        id: topRail
        visible: win.isCommand
        anchors { right: parent.right; rightMargin: win.pad + 8 * win.ux }
        y: win.pad + 26 * win.ux
        height: 28 * win.ux
        spacing: 6 * win.ux
        TLabel {
          anchors.verticalCenter: parent.verticalCenter
          text: "⏻"
          mono: true
          color: root.cMuted
          font.pixelSize: 11 * win.ux
        }
        CmdChip { ux: win.ux; label: "Devin";   glyph: "◆"; accent: root.cMagenta; argv: ["gtk-launch", "devin-desktop"] }
        CmdChip { ux: win.ux; label: "Term";    glyph: "▸"; accent: root.cGreen;   argv: ["gtk-launch", "foot"] }
        CmdChip { ux: win.ux; label: "Files";   glyph: "▣"; accent: root.cAmber;   argv: ["gtk-launch", "org.gnome.Nautilus"] }
        CmdChip { ux: win.ux; label: "Web";     glyph: "◉"; accent: root.cCyan;    argv: ["gtk-launch", "chromium"] }
        CmdChip { ux: win.ux; label: "Lock";    glyph: "⏻"; accent: root.cAlert;   argv: ["omarchy-shell", "lock", "lock"] }
      }
      // ------------------------------------------------- free-canvas items
      // The free-canvas surface: all panels/elements live inside `field`,
      // which is inset by the frame margins + title zone — so every
      // pxOf/pyOf/pwOf/phOf fraction maps through this rect and content can
      // never bleed under the frame. Panels are painted-rectangle items —
      // exactly what the Region { item: ... } mask entries above bind to;
      // regions track each item's geometry live, and `masked` drops a
      // mid-gesture panel out of the mask so a moving bezel can't eat
      // clicks meant for the desktop.
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

      // drop preview: snapped ghost while a drag is in flight (and while the
      // reactor zone is dragged, for the whole chassis)
      Item {
        id: ghostBox
        visible: win.ghostRect !== null
        x: win.ghostRect ? win.ghostRect.x : 0
        y: win.ghostRect ? win.ghostRect.y : 0
        width: win.ghostRect ? win.ghostRect.w : 0
        height: win.ghostRect ? win.ghostRect.h : 0
        z: 70
        Rectangle {
          anchors.fill: parent
          color: Util.alpha(root.cCyan, 0.07)
          border.color: Util.alpha(root.cCyan, 0.5)
          border.width: 1
          radius: 6
        }
      }

      // ================================================= COMMAND COCKPIT
      // Left: SYSTEM — hero CPU card.
      CPanel {
        id: sysPanel
        panelId: "system"
        host: win
        title: root.headSymbol("system") + " SYSTEM"
        accent: root.cCyan
        ux: win.ux
        shown: win.isCommand && !win.isHidden("system")
        collapsed: root.isCollapsed("system")
        onToggled: root.toggleSection("system")
        contentH: 114 * win.ux
        minW: 220 * win.ux
        minH: 80 * win.ux

        Item {
          id: sysInner
          anchors.fill: parent

          Item {
            anchors { top: parent.top; topMargin: 2 * win.ux; left: parent.left; right: parent.right }
            height: 40 * win.ux
            TLabel {
              anchors.left: parent.left
              text: "CPU // " + String(root.kernelName)
              color: root.cSub
              font.pixelSize: Math.max(10, 11 * win.ux)
              font.weight: Font.Medium
              elide: Text.ElideRight
              width: parent.width
            }
            TLabel {
              anchors.right: parent.right
              text: root.has("threads") ? root.stats.threads + " thr" : ""
              mono: true
              color: root.cMuted
              font.pixelSize: Math.max(9, 9 * win.ux)
            }
          }

          Item {
            anchors { top: parent.top; topMargin: 32 * win.ux; left: parent.left; right: parent.right }
            height: 58 * win.ux
            TLabel {
              anchors { left: parent.left; baseline: heroPct.baseline }
              text: "cpu"
              color: root.cMuted
              font.pixelSize: Math.max(9, 10 * win.ux)
              font.letterSpacing: 0.4 * win.ux
            }
            TLabel {
              id: heroPct
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.cpuPct >= 0 ? Math.round(root.cpuPct) : "--"
              mono: true
              color: root.cTxt
              font.pixelSize: Math.max(30, 36 * win.ux)
              font.weight: Font.DemiBold
            }
            TLabel {
              anchors { left: heroPct.right; leftMargin: 2 * win.ux; baseline: heroPct.baseline }
              text: "%"
              mono: true
              color: root.cMuted
              font.pixelSize: Math.max(14, 18 * win.ux)
            }
            Rectangle {
              anchors { right: parent.right; rightMargin: 2 * win.ux; verticalCenter: parent.verticalCenter }
              width: 8 * win.ux; height: 8 * win.ux; rotation: 45
              color: root.cGreen
              opacity: 0.15 + 0.85 * Util.clamp(root.s("cpu", 0), 0, 1)
              visible: opacity > 0.02
            }
          }

          HudRow {
            anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 86 * win.ux }
            label: "LOAD"
            value: root.loadText
            fraction: -1
          }

          // eased LOAD1 history trace — the rail's lower half. In the 3b
          // cockpit the SYSTEM card is a full-height column (its map entry
          // carries fh = 1.0), so this fills every spare pixel between the
          // hero readout and the uptime footer; when the panel hugs its
          // natural height it simply clips to nothing.
          TLabel {
            id: sysTraceCap
            anchors { left: parent.left; top: parent.top; topMargin: 110 * win.ux }
            text: "LOAD1 · 60 S"
            color: root.cDim
            font.pixelSize: Math.max(8, 8 * win.ux)
            font.letterSpacing: 0.6 * win.ux
          }
          TraceCanvas {
            anchors { left: parent.left; right: parent.right
                      top: sysTraceCap.bottom; topMargin: 4 * win.ux
                      bottom: parent.bottom; bottomMargin: 18 * win.ux }
            pts: root.dspLoad
            col: root.cCyan
            live: sysPanel.shown && !sysPanel.collapsed
          }
          TLabel {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            text: root.uptimeText + "  ·  " + (root.has("procs") ? root.stats.procs : "—") + " procs"
            mono: true
            color: root.cMuted
            font.pixelSize: Math.max(9, 9 * win.ux)
            horizontalAlignment: Text.AlignRight
          }
        }
      }

      // Center: reactor chassis — flanked by the SYSTEM + NETWORK split-lane
      // sparkline strips (their own CPanel cards). One layout entry ("center")
      // keeps the whole cluster rigid inside the magnetic field.
      Item {
        id: centerZone
        visible: win.isCommand && !win.isHidden("center")
        // free-canvas plumbing, same contract as CPanel: host/grid bindings
        // make the whole chassis draggable, snappable and width-resizable
        property string panelId: "center"
        property var    host: win
        readonly property bool dragging: win.draggingId === "center"
        readonly property bool resizing: win.sizingId === "center"
        readonly property bool masked: visible && !dragging && !resizing
        property real minW: 560 * win.ux
        property real minH: 320 * win.ux
        property real sizeH: -1
        // 3b: the chassis is a TALL zone — the map carries fh so sizeH owns
        // the height; the natural fallback stacks bar + dial band + drawer
        // so a map without fh still composes sensibly.
        height: {
          if (sizeH > 0) return Math.max(minH, sizeH)
          var flankH = Math.max(sparkLPanel.height, sparkRPanel.height)
          var dialH = Math.max(160 * win.ux, flankH)
          return Math.max(minH,
                          (14 + 4) * win.ux + dialH + 8 * win.ux
                          + procPanel.height)
        }
        opacity: dragging ? 0.92 : 1.0
        z: dragging ? 60 : 0
        Behavior on height { enabled: win.animateLayout && !centerZone.resizing; NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Behavior on x { enabled: win.animateLayout && !centerZone.dragging; NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Behavior on y { enabled: win.animateLayout && !centerZone.dragging; NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Binding on x { when: !centerZone.dragging; value: win.pxOf("center") }
        Binding on y { when: !centerZone.dragging; value: win.pyOf("center") }
        Binding on width { when: !centerZone.resizing; value: win.pwOf("center") }
        Binding { target: centerZone; property: "sizeH"; when: !centerZone.resizing; value: win.phOf("center") }

        // header drag strip — a quiet grab rail across the chassis so the
        // cluster can be moved even when every flank card is hidden
        Item {
          id: chassisBar
          anchors { left: parent.left; right: parent.right; top: parent.top }
          height: 14 * win.ux
          Rectangle {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 1
            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop { position: 0.0; color: "transparent" }
              GradientStop { position: 0.5; color: Util.alpha(root.cCyan, 0.30) }
              GradientStop { position: 1.0; color: "transparent" }
            }
          }
          TLabel {
            anchors.centerIn: parent
            visible: chassisMa.containsMouse || centerZone.dragging
            text: "≡ move"
            mono: true
            color: root.cMuted
            font.pixelSize: Math.max(9, 9 * win.ux)
            font.letterSpacing: 0.4 * win.ux
          }
          MouseArea {
            id: chassisMa
            anchors { fill: parent; margins: -3 * win.ux }
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onPressed: win.dragPress(chassisMa, centerZone, "center", mouse.x, mouse.y)
            onPositionChanged: win.dragMove(chassisMa, centerZone, mouse.x, mouse.y)
            onReleased: win.dragRelease(centerZone)
            onCanceled: win.dragAbort(centerZone)
          }
          Item {
            anchors { right: parent.right; rightMargin: 2 * win.ux; verticalCenter: parent.verticalCenter }
            width: 14 * win.ux
            height: 14 * win.ux
            opacity: zGripMa.containsMouse || centerZone.resizing ? 1.0 : 0.35
            Rectangle { anchors { right: parent.right; bottom: parent.bottom } width: 1.5; height: 8 * win.ux; color: root.cCyan }
            Rectangle { anchors { right: parent.right; bottom: parent.bottom } width: 8 * win.ux; height: 1.5; color: root.cCyan }
            MouseArea {
              id: zGripMa
              anchors { fill: parent; margins: -4 * win.ux }
              hoverEnabled: true
              cursorShape: Qt.SizeFDiagCursor
              onPressed: win.sizePress(zGripMa, centerZone, "center", mouse.x, mouse.y)
              onPositionChanged: win.sizeMove(zGripMa, centerZone, mouse.x, mouse.y)
              onReleased: win.sizeRelease(centerZone)
              onCanceled: win.sizeAbort(centerZone)
            }
          }
        }

        // left flank: SYS TRACE — wing instrument, vertically centred on
        // the dial band so it rides the reactor's midline instead of
        // pinning to the chassis top
        CPanel {
          id: sparkLPanel
          panelId: ""
          host: null
          anchors { left: parent.left; verticalCenter: dialBox.verticalCenter }
          width: Math.max(150 * win.ux, parent.width * 0.24)
          title: "SYS"
          accent: root.cCyan
          ux: win.ux * 0.9
          shown: true
          collapsible: false
          contentH: Math.max(120 * win.ux, sysMiniRow.implicitHeight + 22 * win.ux)
          minW: 120 * win.ux
          minH: 60 * win.ux
          Item {
            anchors.fill: parent
            TLabel {
              id: sysMiniLbl
              anchors { left: parent.left; top: parent.top }
              text: "CPU " + root.cpuText
              mono: true
              color: root.cAccent
              font.pixelSize: Math.max(9, 10 * win.ux)
            }
            Row {
              id: sysMiniRow
              anchors { left: parent.left; right: parent.right; top: sysMiniLbl.bottom; topMargin: 3 * win.ux; bottom: parent.bottom }
              spacing: 4 * win.ux
              Repeater {
                model: Math.min(32, root.coreCount)
                delegate: Item {
                  width: Math.max(2, (sysMiniRow.width - sysMiniRow.spacing * (Math.min(32, root.coreCount) - 1)) / Math.max(1, Math.min(32, root.coreCount)))
                  height: sysMiniRow.height
                  readonly property real cf: root.coreFrac(index) >= 0 ? root.coreFrac(index) : 0
                  Rectangle {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: parent.height * Util.clamp(parent.cf, 0, 1)
                    color: root.coreColor(index)
                    opacity: 0.55 + 0.45 * Util.clamp(parent.cf, 0, 1)
                  }
                  Rectangle {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: 1
                    color: root.cInset
                  }
                }
              }
            }
          }
        }

        // right flank: NET TRACE — mirrored wing on the dial midline
        CPanel {
          id: sparkRPanel
          panelId: ""
          host: null
          anchors { right: parent.right; verticalCenter: dialBox.verticalCenter }
          width: Math.max(150 * win.ux, parent.width * 0.24)
          title: "NET"
          accent: root.cGreen
          ux: win.ux * 0.9
          shown: true
          collapsible: false
          contentH: Math.max(120 * win.ux, cxMarqueeRow.implicitHeight + 30 * win.ux + 10 * win.ux)
          minW: 120 * win.ux
          minH: 60 * win.ux
          Item {
            anchors.fill: parent
            Item {
              anchors { left: parent.left; right: parent.right; top: parent.top }
              height: 30 * win.ux
              TLabel {
                anchors { left: parent.left; top: parent.top }
                text: "R " + root.fmtRate(root.rxRate)
                mono: true
                color: root.cCyan
                font.pixelSize: Math.max(9, 10 * win.ux)
              }
              TLabel {
                anchors { left: parent.left; top: parent.top; topMargin: 13 * win.ux }
                text: "T " + root.fmtRate(root.txRate)
                mono: true
                color: root.cMagenta
                font.pixelSize: Math.max(9, 10 * win.ux)
              }
            }
            Row {
              id: cxMarqueeRow
              anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 30 * win.ux; bottom: parent.bottom }
              spacing: 3 * win.ux
              Repeater {
                model: 28
                delegate: Rectangle {
                  width: Math.max(2, (cxMarqueeRow.width - cxMarqueeRow.spacing * 27) / 28)
                  height: Math.max(3, cxMarqueeRow.height * (0.25 + 0.75 * Util.clamp(root.rxRate / 30000000, 0, 1)))
                  radius: 1
                  color: index < 14 ? root.cCyan : root.cMagenta
                  opacity: 0.15 + 0.75 * Util.clamp((index < 14 ? root.rxRate : root.txRate) / 30000000, 0, 1)
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }
          }
        }

        // bottom drawer: TOP PROCS folded into the reactor cluster as a
        // compact console drawer under the dial — capped at 4 rows so the
        // dial keeps the stage (the full list lives on the ops console)
        CPanel {
          id: procPanel
          panelId: ""
          host: null
          anchors { left: sparkLPanel.right; leftMargin: 6 * win.ux; right: sparkRPanel.left; rightMargin: 6 * win.ux
                    bottom: parent.bottom }
          title: root.headSymbol("procs") + " TOP PROCS"
          accent: root.cMagenta
          ux: win.ux * 0.9
          shown: true
          collapsible: false
          contentH: Math.max(90 * win.ux, Math.min(4, Math.max(1, root.num(root.stats.proc_n))) * 22 * win.ux + 24 * win.ux)
          minW: 160 * win.ux
          minH: 60 * win.ux
          Column {
            anchors.fill: parent
            spacing: 1 * win.ux
            Repeater {
              model: Math.min(4, Math.max(0, root.num(root.stats.proc_n)))
              delegate: ProcRow {
                width: parent.width
                rank: index + 1
                pname: root.has("proc" + index + "_name") ? String(root.stats["proc" + index + "_name"]) : "?"
                pcpu: root.procCpu(index)
                ux: win.ux * 0.9
              }
            }
            TLabel {
              visible: root.num(root.stats.proc_n) <= 0
              text: "collector starting…"
              color: root.cMuted
              font.pixelSize: Math.max(9, 10 * win.ux)
            }
          }
        }

        // reactor — the centrepiece: the dial owns the whole band between
        // the grab rail and the PROCS drawer, centred in the middle column
        // between the two wing cards so hiding a flank never re-centres it
        Item {
          id: dialBox
          anchors { top: chassisBar.bottom; topMargin: 4 * win.ux
                    bottom: procPanel.top; bottomMargin: 6 * win.ux }
          anchors.horizontalCenter: parent.horizontalCenter
          width: Math.max(140 * win.ux, parent.width - sparkLPanel.width - sparkRPanel.width - 16 * win.ux)
          readonly property real dSize: Math.min(width, height)

          Item {
            id: dialFace
            anchors.centerIn: parent
            width: dialBox.dSize
            height: dialBox.dSize

            Canvas {
              id: dialCanvas
              anchors.fill: parent
              onWidthChanged: requestPaint()
              onHeightChanged: requestPaint()
              Connections {
                target: root
                function onTickSeqChanged() { dialCanvas.requestPaint() }
              }
              onPaint: {
                var c = getContext("2d")
                c.reset()
                var cx = width / 2, cy = height / 2
                var r = Math.min(width, height) * 0.42
                if (r < 10) return
                var v = Math.max(0, root.s("cpu", 0))

                // static tick ring — shared 21-notch pattern, quieted
                c.strokeStyle = "rgba(215,232,237,0.10)"
                c.lineWidth = 1
                c.beginPath()
                for (var i = 0; i <= 20; i++) {
                  var a = -Math.PI * 0.75 + Math.PI * 1.5 * i / 20
                  var rr = r * 1.14
                  c.moveTo(cx + Math.cos(a) * rr, cy + Math.sin(a) * rr)
                  c.lineTo(cx + Math.cos(a) * (rr + (i % 5 === 0 ? 4.5 * win.ux : 2 * win.ux)),
                           cy + Math.sin(a) * (rr + (i % 5 === 0 ? 4.5 * win.ux : 2 * win.ux)))
                }
                c.stroke()

                // arc — cyan->amber->red by value (heat-colour mapping)
                function arc(vv, color, radius, line) {
                  c.beginPath()
                  c.strokeStyle = String(root.cHair)
                  c.lineWidth = line
                  c.arc(cx, cy, radius, -Math.PI * 0.75, Math.PI * 0.75)
                  c.stroke()
                  if (vv >= 0) {
                    var f = Math.min(1, vv)
                    var col = root.heatColor(f, root.cAccent)
                    var ae = -Math.PI * 0.75 + Math.PI * 1.5 * f
                    c.beginPath()
                    c.strokeStyle = root.rgbaOf(col, 0.18)
                    c.lineWidth = line * 2
                    c.arc(cx, cy, radius, -Math.PI * 0.75, ae)
                    c.stroke()
                    c.beginPath()
                    c.strokeStyle = root.rgbOf(col)
                    c.lineWidth = line
                    c.arc(cx, cy, radius, -Math.PI * 0.75, ae)
                    c.stroke()
                  }
                }
                arc(v, root.cAccent, r, Math.max(3, r * 0.10))
              }
            }
            Column {
              anchors.centerIn: parent
              spacing: 1 * win.ux
              TLabel {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "REACTOR"
                color: root.cMuted
                font.pixelSize: Math.max(9, 10 * win.ux)
                font.letterSpacing: 0.4 * win.ux
              }
              TLabel {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.cpuPct >= 0 ? Math.round(root.cpuPct) + "%" : "--"
                mono: true
                color: root.cAccent
                font.weight: Font.DemiBold
                font.pixelSize: Math.max(18, 22 * win.ux)
              }
              TLabel {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.has("load1") ? "load " + String(root.stats.load1) : ""
                mono: true
                color: root.cMuted
                font.pixelSize: Math.max(9, 9 * win.ux)
              }
              // 3b: thin wall-clock readout inside the dial face — the one
              // tasteful addition the cinema layout earns
              TLabel {
                anchors.horizontalCenter: parent.horizontalCenter
                text: {
                  var d = root.now
                  var p = function(n) { return (n < 10 ? "0" : "") + n }
                  return p(d.getHours()) + ":" + p(d.getMinutes())
                       + ":" + p(d.getSeconds()) + "  ·  up " + root.uptimeText
                }
                mono: true
                color: root.cDim
                font.pixelSize: Math.max(8, 9 * win.ux)
                font.letterSpacing: 0.3 * win.ux
              }
            }
          }
        }
      }

      // Bottom strip (command): compact agents + status cross-refs.
      CPanel {
        id: agentsPanel
        panelId: "agents"
        host: win
        title: root.headSymbol("agents") + " AGENTS"
        accent: root.cMagenta
        ux: win.ux * 0.9
        shown: win.isCommand && !win.isHidden("agents")
        collapsed: root.isCollapsed("agents")
        onToggled: root.toggleSection("agents")
        contentH: 78 * win.ux
        minW: 200 * win.ux
        minH: 40 * win.ux
        Flow {
          anchors.fill: parent
          spacing: 5 * win.ux
          Repeater {
            model: root.agList()
            delegate: AgChip {
              ux: win.ux * 0.9
              name: modelData.id
              procs: modelData.procs
              cpu: modelData.cpu
            }
          }
          TLabel {
            visible: root.agentLiveCount <= 0
            text: "no agent processes"
            color: root.cMuted
            font.pixelSize: Math.max(9, 10 * win.ux)
          }
        }
      }

      CPanel {
        id: statusPanel
        panelId: "status"
        host: win
        title: "STATUS"
        accent: root.cGreen
        ux: win.ux * 0.9
        shown: win.isCommand && !win.isHidden("status")
        collapsible: false
        contentH: 74 * win.ux
        minW: 200 * win.ux
        minH: 40 * win.ux
        // one-line cross-refs to the hardware/ops homes of shared metrics
        Column {
          anchors.fill: parent
          spacing: 4 * win.ux
          Repeater {
            model: [
              ["GPU",  root.gpuStatusText,    root.cAmber],
              ["MEM",  root.memText !== "n/a" ? Math.round(root.memFrac * 100) + "%" : "—", root.cCyan],
              ["DISK", root.storageFreeText,  root.cGreen],
              ["BAT",  root.batStatusText(),  root.cMagenta],
              ["NET",  root.linkOk ? root.fmtRate(root.rxRate) + " rx" : "link lost", root.cGreen]
            ]
            delegate: Row {
              spacing: 7 * win.ux
              TLabel {
                width: 44 * win.ux
                text: modelData[0]
                color: root.cMuted
                font.pixelSize: Math.max(9, 10 * win.ux)
                font.weight: Font.Medium
                font.letterSpacing: 0.2 * win.ux
              }
              TLabel {
                text: modelData[1]
                mono: true
                color: modelData[2]
                font.pixelSize: Math.max(10, 11 * win.ux)
                elide: Text.ElideRight
              }
            }
          }
        }
      }
      // ================================================= HARDWARE DETAIL
      // Core matrix: per-core busy bars + clocks (bar colour heats with load;
      // a leading p-state block when the frequency exposes one, trailing
      // CCD compare bars when the collector reports them).
      CPanel {
        id: hwMatrixPanel
        panelId: "matrix"
        host: win
        title: root.headSymbol("matrix") + " CORE MATRIX"
        accent: root.cCyan
        ux: win.ux * 0.9
        shown: win.isHardware && !win.isHidden("matrix")
        collapsed: root.isCollapsed("matrix")
        onToggled: root.toggleSection("matrix")
        contentH: {
          var rows = Math.ceil(Math.max(1, root.coreCount) / 6)
          var h = rows * 20 * win.ux + 16 * win.ux
          if (root.has("ccd0_avg")) h += 26 * win.ux
          if (root.has("clock_mhz")) h += 16 * win.ux
          return h
        }
        minW: 240 * win.ux
        minH: 60 * win.ux
        Column {
          anchors.fill: parent
          spacing: 5 * win.ux
          Grid {
            width: parent.width
            columns: 6
            columnSpacing: 4 * win.ux
            rowSpacing: 4 * win.ux
            Repeater {
              model: Math.min(48, root.coreCount)
              delegate: Item {
                width: (parent.width - 5 * 4 * win.ux) / 6
                height: 20 * win.ux
                readonly property real cf: root.coreFrac(index) >= 0 ? root.coreFrac(index) : 0
                Rectangle {
                  anchors { left: parent.left; right: parent.right; top: parent.top }
                  height: 12 * win.ux
                  radius: 2
                  color: root.cInset
                  Rectangle {
                    anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                    width: parent.width * Util.clamp(parent.cf, 0, 1)
                    radius: 2
                    color: root.coreColor(index)
                    Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                  }
                }
                TLabel {
                  anchors { left: parent.left; bottom: parent.bottom }
                  text: index
                  mono: true
                  color: root.cMuted
                  font.pixelSize: Math.max(9, 8 * win.ux)
                }
                TLabel {
                  anchors { right: parent.right; bottom: parent.bottom }
                  text: Math.round(parent.cf * 100)
                  mono: true
                  color: root.cSub
                  font.pixelSize: Math.max(9, 8 * win.ux)
                }
              }
            }
          }
          Row {
            spacing: 8 * win.ux
            TLabel {
              text: "CLOCK " + (root.has("clock_mhz") ? root.fmtRate(root.num(root.stats.clock_mhz) * 1e6).replace("/s", "Hz") : "—")
              mono: true
              color: root.cGreen
              font.pixelSize: Math.max(9, 10 * win.ux)
            }
            TLabel {
              text: root.has("ccd0_avg") ? "CCD0 " + Math.round(root.num(root.stats.ccd0_avg)) + "%" : ""
              mono: true
              color: root.cMuted
              font.pixelSize: Math.max(9, 10 * win.ux)
            }
            TLabel {
              text: root.has("ccd1_avg") ? "CCD1 " + Math.round(root.num(root.stats.ccd1_avg)) + "%" : ""
              mono: true
              color: root.cMuted
              font.pixelSize: Math.max(9, 10 * win.ux)
            }
          }
        }
      }

      // Sensors: all thermal rows — CPU pkg, GPU temps, NVMe/DIMM/media.
      CPanel {
        id: hwSensorsPanel
        panelId: "sensors"
        host: win
        title: root.headSymbol("sensors") + " SENSORS"
        accent: root.cAmber
        ux: win.ux * 0.9
        shown: win.isHardware && !win.isHidden("sensors")
        collapsed: root.isCollapsed("sensors")
        onToggled: root.toggleSection("sensors")
        contentH: 40 * win.ux + root.psiRowCount * 34 * win.ux
                  + root.sensorRows().length * 18 * win.ux
        minW: 240 * win.ux
        minH: 60 * win.ux
        Column {
          anchors.fill: parent
          spacing: 3 * win.ux
          HudRow {
            width: parent.width
            label: "CPU PKG"
            value: root.has("cpu_temp") ? Math.round(root.num(root.stats.cpu_temp)) + "°C" : "--"
            accent: root.has("cpu_temp") ? root.tempColor(root.num(root.stats.cpu_temp)) : root.cMuted
            fraction: root.has("cpu_temp") ? root.num(root.stats.cpu_temp) / 100 : -1
          }
          Repeater {
            model: [
              { key: "psi_cpu_some", lbl: "PSI CPU", pts: root.dspPsiCpu, col: root.cCyan },
              { key: "psi_mem_some", lbl: "PSI MEM", pts: root.dspPsiMem, col: root.cAmber },
              { key: "psi_io_some",  lbl: "PSI IO",  pts: root.dspPsiIo,  col: root.cMagenta }
            ]
            delegate: Item {
              visible: root.has(modelData.key)
              width: parent.width
              height: visible ? 32 * win.ux : 0
              TLabel {
                anchors { left: parent.left; top: parent.top }
                text: modelData.lbl
                color: root.cSub
                font.pixelSize: Math.max(9, 10 * win.ux)
                font.weight: Font.Medium
                font.letterSpacing: 0.2 * win.ux
              }
              TLabel {
                anchors { right: parent.right; top: parent.top }
                text: root.has(modelData.key) ? (root.num(root.stats[modelData.key]) * 100).toFixed(1) + "%" : "—"
                mono: true
                color: modelData.col
                font.pixelSize: Math.max(9, 10 * win.ux)
              }
              TraceCanvas {
                anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 12 * win.ux; bottom: parent.bottom }
                pts: modelData.pts
                col: modelData.col
                vmax: 1.0
                live: parent.visible && !hwSensorsPanel.collapsed
              }
            }
          }
          Repeater {
            model: root.sensorRows()
            delegate: Row {
              width: parent.width
              spacing: 7 * win.ux
              TLabel {
                width: 62 * win.ux
                text: modelData.label
                color: root.cMuted
                font.pixelSize: Math.max(9, 10 * win.ux)
                font.weight: Font.Medium
              }
              TLabel {
                text: modelData.value
                mono: true
                color: modelData.accent
                font.pixelSize: Math.max(10, 11 * win.ux)
                elide: Text.ElideRight
              }
            }
          }
        }
      }

      // GPU sheet 0 — the Arc B580.
      CPanel {
        id: hwGpu0Panel
        panelId: "gpu"
        host: win
        title: root.headSymbol("gpu") + " " + root.gpu0Title
        accent: root.cMagenta
        ux: win.ux * 0.9
        shown: win.isHardware && !win.isHidden("gpu") && root.gpu0Shown
        collapsed: root.isCollapsed("gpu")
        onToggled: root.toggleSection("gpu")
        miniStat: root.has("i_util") ? Math.round(root.num(root.stats.i_util)) + "% util" : ""
        contentH: 150 * win.ux + (root.has("i_pwr_w") ? 70 * win.ux : 0)
                + 4 * 18 * win.ux
        minW: 260 * win.ux
        minH: 80 * win.ux
        Column {
          anchors.fill: parent
          spacing: 6 * win.ux
          Item {
            width: parent.width
            height: 130 * win.ux
            PwrDial {
              anchors { left: parent.left; verticalCenter: parent.verticalCenter }
              width: 130 * win.ux
              height: 130 * win.ux
              ux: win.ux * 0.9
              label: "PWR"
              value: root.has("i_pwr_w") ? Math.round(root.num(root.stats.i_pwr_w)) + "W" : "--"
              amount: root.iPwrFrac >= 0 ? root.s("gpuW", 0) : -1
              accent: root.cMagenta
              second: root.iUtilFrac >= 0
              amount2: root.iUtilFrac >= 0 ? root.s("gpuU", 0) : -1
              accent2: root.cCyan
              secondLabel: "util"
              live: hwGpu0Panel.shown && !hwGpu0Panel.collapsed
            }
            Column {
              anchors { left: parent.left; leftMargin: 140 * win.ux; right: parent.right; verticalCenter: parent.verticalCenter }
              spacing: 4 * win.ux
              HudRow {
                width: parent.width
                label: "UTIL"
                value: root.has("i_util") ? Math.round(root.num(root.stats.i_util)) + "%" : "--"
                fraction: root.iUtilFrac >= 0 ? root.s("gpuU", 0) : -1
                accent: root.cCyan
              }
              HudRow {
                width: parent.width
                label: "VRAM"
                value: root.iVramFrac >= 0
                    ? Math.round(root.iVramFrac * 100) + "%  " + root.fmtBtoGiB(root.stats.i_vram_used) + "G"
                    : "--"
                fraction: root.iVramFrac >= 0 ? root.s("gpuV", 0) : -1
                accent: root.cMagenta
              }
              HudRow {
                width: parent.width
                label: "CORE"
                value: root.has("i_temp_pkg") ? Math.round(root.num(root.stats.i_temp_pkg)) + "°C" : "--"
                accent: root.has("i_temp_pkg") ? root.tempColor(root.num(root.stats.i_temp_pkg)) : root.cMuted
                fraction: root.has("i_temp_pkg") ? root.num(root.stats.i_temp_pkg) / 100 : -1
              }
              HudRow {
                width: parent.width
                label: "VRAM T"
                value: root.has("i_temp_vram") ? Math.round(root.num(root.stats.i_temp_vram)) + "°C" : "--"
                accent: root.has("i_temp_vram") ? root.tempColor(root.num(root.stats.i_temp_vram)) : root.cMuted
                fraction: root.has("i_temp_vram") ? root.num(root.stats.i_temp_vram) / 100 : -1
              }
            }
          }
          Item {
            visible: root.has("i_pwr_w")
            width: parent.width
            height: visible ? 64 * win.ux : 0
            TLabel {
              anchors { left: parent.left; top: parent.top }
              text: "POWER"
              color: root.cSub
              font.pixelSize: Math.max(9, 10 * win.ux)
              font.weight: Font.Medium
              font.letterSpacing: 0.2 * win.ux
            }
            TLabel {
              anchors { right: parent.right; top: parent.top }
              text: root.has("i_pwr_cap_w") ? "cap " + Math.round(root.num(root.stats.i_pwr_cap_w)) + "W" : ""
              mono: true
              color: root.cMuted
              font.pixelSize: Math.max(9, 9 * win.ux)
            }
            TraceCanvas {
              anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 13 * win.ux; bottom: parent.bottom }
              pts: root.dspGpuW
              col: root.cMagenta
              vmax: root.has("i_pwr_cap_w") ? root.num(root.stats.i_pwr_cap_w) : 0
              live: hwGpu0Panel.shown && !hwGpu0Panel.collapsed
            }
          }
          Grid {
            width: parent.width
            columns: 4
            columnSpacing: 4 * win.ux
            rowSpacing: 4 * win.ux
            Repeater {
              model: [
                ["PKG",    root.stats.i_temp_pkg],
                ["VRAM",   root.stats.i_temp_vram],
                ["MCTRL",  root.stats.i_temp_mctrl],
                ["PCIE",   root.stats.i_temp_pcie]
              ]
              delegate: TempBox {
                width: (parent.width - 3 * 4 * win.ux) / 4
                height: 38 * win.ux
                ux: win.ux * 0.9
                label: modelData[0]
                value: modelData[1] !== undefined ? root.num(modelData[1]) : NaN
              }
            }
          }
        }
      }

      // GPU sheet 1 — the iGPU / second card.
      CPanel {
        id: hwGpu1Panel
        panelId: "gpu2"
        host: win
        title: root.headSymbol("gpu2") + " " + root.gpu1Title
        accent: root.cAmber
        ux: win.ux * 0.9
        shown: win.isHardware && !win.isHidden("gpu2") && root.gpu1Shown
        collapsed: root.isCollapsed("gpu2")
        onToggled: root.toggleSection("gpu2")
        miniStat: root.has("a_util") ? Math.round(root.num(root.stats.a_util)) + "% util" : ""
        contentH: 96 * win.ux
        minW: 260 * win.ux
        minH: 60 * win.ux
        Column {
          anchors.fill: parent
          spacing: 4 * win.ux
          HudRow {
            width: parent.width
            label: "UTIL"
            value: root.has("a_util") ? Math.round(root.num(root.stats.a_util)) + "%" : "--"
            fraction: root.aUtilFrac >= 0 ? root.s("gpu2U", 0) : -1
            accent: root.cAmber
          }
          HudRow {
            width: parent.width
            label: "VRAM"
            value: root.aVramFrac >= 0
                ? Math.round(root.aVramFrac * 100) + "%  " + root.fmtBtoGiB(root.stats.a_vram_used) + "G"
                : "--"
            fraction: root.aVramFrac >= 0 ? root.s("gpu2V", 0) : -1
            accent: root.cAmber
          }
          HudRow {
            width: parent.width
            label: "TEMP"
            value: root.has("a_temp") ? Math.round(root.num(root.stats.a_temp)) + "°C" : "--"
            accent: root.has("a_temp") ? root.tempColor(root.num(root.stats.a_temp)) : root.cMuted
            fraction: root.has("a_temp") ? root.num(root.stats.a_temp) / 100 : -1
          }
          HudRow {
            width: parent.width
            label: "PWR"
            value: root.has("a_pwr_w") ? Math.round(root.num(root.stats.a_pwr_w)) + "W" : "--"
            fraction: -1
          }
          HudRow {
            width: parent.width
            label: "NAV"
            value: root.has("a_vram_total") ? root.fmtBtoGiB(root.stats.a_vram_total) + "G total" : "--"
            fraction: -1
          }
        }
      }

      // Storage — DEVICES: a block-device tree. One row per blk{i} whole
      // disk (name / model / total size / temp when reported / type tag),
      // then its blk{i}p{j} partitions indented under it on a connector
      // tick — fstype·label, mount point, and a heat-coloured usage bar
      // with % + used/total for mounted parts. Unmounted partitions stay
      // visible, dimmed and tagged — the panel's job is topology, not
      // just active mounts. Stale collectors (no blk_count) degrade to
      // the old fs_root/fs_home mount rows. The disk R/W trace still
      // anchors the panel bottom.
      CPanel {
        id: hwStoragePanel
        panelId: "storage"
        host: win
        title: root.headSymbol("storage") + " STORAGE — DEVICES"
        accent: root.cGreen
        ux: win.ux * 0.9
        shown: win.isHardware && !win.isHidden("storage")
        collapsed: root.isCollapsed("storage")
        onToggled: root.toggleSection("storage")
        miniStat: root.blkCount > 0 ? root.blkCount + " dev" : root.storageFreeText
        contentH: {
          // device rows + part rows + separators, or the two legacy mount
          // rows — then the shared I/O row and the R/W trace
          var body = root.blkCount > 0 ? root.blkRowsH() : (2 * 18 + 5)
          return (body + 2 * 5 + 18 + 30) * win.ux
        }
        minW: 240 * win.ux
        minH: 60 * win.ux
        Column {
          anchors.fill: parent
          spacing: 5 * win.ux

          // ---- device tree — model rows from root.blkRows() ----------
          // (positioners skip invisible children, so this column costs
          // nothing while the fallback below owns the body)
          Column {
            id: blkTreeCol
            width: parent.width
            visible: root.blkCount > 0
            spacing: 0
            Repeater {
              model: root.blkRows()
              delegate: Item {
                id: blkRow
                width: parent.width
                height: modelData.rh * win.ux

                // ---- whole-disk device row ---------------------------
                Item {
                  anchors.fill: parent
                  visible: modelData.kind === "dev"
                  TLabel {
                    id: dName
                    anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                    text: modelData.name !== undefined ? modelData.name : ""
                    mono: true
                    color: root.cTxt
                    font.pixelSize: Math.max(11, 12 * win.ux)
                    font.weight: Font.DemiBold
                  }
                  TLabel {
                    anchors { left: dName.right; leftMargin: 8 * win.ux
                              right: dTrail.left; rightMargin: 6 * win.ux
                              verticalCenter: parent.verticalCenter }
                    text: modelData.model !== undefined ? modelData.model : ""
                    color: root.cMuted
                    font.pixelSize: Math.max(9, 10 * win.ux)
                    elide: Text.ElideRight
                  }
                  Row {
                    id: dTrail
                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                    spacing: 8 * win.ux
                    TLabel {
                      visible: modelData.hasTemp === true
                      text: Math.round(modelData.temp) + "°C"
                      mono: true
                      color: root.tempColor(modelData.temp)
                      font.pixelSize: Math.max(9, 10 * win.ux)
                    }
                    TLabel {
                      text: root.fmtBytes(modelData.size)
                      mono: true
                      color: root.cTxt
                      font.pixelSize: Math.max(10, 11 * win.ux)
                      font.weight: Font.Medium
                    }
                    Rectangle {
                      width: dTagLbl.implicitWidth + 9 * win.ux
                      height: 14 * win.ux
                      radius: 3 * win.ux
                      color: Util.alpha(hwStoragePanel.accent, 0.08)
                      border.color: Util.alpha(hwStoragePanel.accent, 0.35)
                      border.width: 1
                      TLabel {
                        id: dTagLbl
                        anchors.centerIn: parent
                        text: modelData.dtype !== undefined ? modelData.dtype : "DISK"
                        mono: true
                        color: hwStoragePanel.accent
                        font.pixelSize: Math.max(8, 9 * win.ux)
                        font.weight: Font.Medium
                        font.letterSpacing: 0.4 * win.ux
                      }
                    }
                  }
                }

                // ---- partition row (indent + connector tick) ---------
                Item {
                  anchors.fill: parent
                  visible: modelData.kind === "part"
                  TLabel {
                    id: pTick
                    anchors { left: parent.left; leftMargin: 2 * win.ux
                              top: parent.top; topMargin: 1 * win.ux }
                    text: modelData.last ? "└" : "├"
                    mono: true
                    color: root.cDim
                    font.pixelSize: Math.max(9, 10 * win.ux)
                  }
                  TLabel {
                    id: pName
                    anchors { left: parent.left; leftMargin: 14 * win.ux
                              top: parent.top; topMargin: 1 * win.ux }
                    width: Math.min(implicitWidth, parent.width * 0.55)
                    text: modelData.name !== undefined ? modelData.name : ""
                    mono: true
                    color: modelData.mounted === true ? root.cTxt : root.cMuted
                    font.pixelSize: Math.max(10, 11 * win.ux)
                    font.weight: Font.Medium
                    elide: Text.ElideRight
                  }
                  TLabel {
                    id: pMount
                    visible: modelData.mounted === true
                    anchors { right: parent.right; top: parent.top
                              topMargin: 2 * win.ux }
                    width: Math.min(implicitWidth, parent.width * 0.40)
                    text: modelData.mount !== undefined ? modelData.mount : ""
                    mono: true
                    color: root.cSub
                    font.pixelSize: Math.max(9, 10 * win.ux)
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideMiddle
                  }
                  Rectangle {
                    id: pUnm
                    visible: modelData.kind === "part" && modelData.mounted !== true
                    anchors { right: parent.right; top: parent.top
                              topMargin: 2 * win.ux }
                    width: unmLbl.implicitWidth + 8 * win.ux
                    height: 13 * win.ux
                    radius: 3 * win.ux
                    color: Util.alpha(root.cMuted, 0.08)
                    border.color: root.cDiv
                    border.width: 1
                    TLabel {
                      id: unmLbl
                      anchors.centerIn: parent
                      text: "unmounted"
                      mono: true
                      color: root.cDim
                      font.pixelSize: Math.max(8, 8 * win.ux)
                      font.letterSpacing: 0.3 * win.ux
                    }
                  }
                  TLabel {
                    id: pFs
                    anchors { left: parent.left; leftMargin: 14 * win.ux
                              bottom: parent.bottom; bottomMargin: 4 * win.ux }
                    width: Math.min(implicitWidth, 92 * win.ux)
                    text: modelData.fsText !== undefined && modelData.fsText !== ""
                          ? modelData.fsText : "raw"
                    color: modelData.mounted === true ? root.cMuted : root.cDim
                    font.pixelSize: Math.max(9, 9 * win.ux)
                    elide: Text.ElideRight
                  }
                  Rectangle {
                    id: pBar
                    visible: modelData.mounted === true && modelData.frac >= 0
                    anchors { left: pFs.right; leftMargin: 8 * win.ux
                              right: pVal.left; rightMargin: 8 * win.ux
                              bottom: parent.bottom; bottomMargin: 6 * win.ux }
                    height: Math.max(3, 4 * win.ux)
                    radius: 2
                    color: root.cInset
                    Rectangle {
                      anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                      width: Math.max(0, pBar.width * Util.clamp(modelData.frac >= 0 ? modelData.frac : 0, 0, 1))
                      radius: 2
                      color: root.heatColor(modelData.frac, hwStoragePanel.accent)
                      Behavior on width { NumberAnimation { duration: 350; easing.type: Easing.OutCubic } }
                    }
                  }
                  TLabel {
                    id: pVal
                    anchors { right: parent.right; bottom: parent.bottom
                              bottomMargin: 4 * win.ux }
                    text: modelData.val !== undefined ? modelData.val : ""
                    mono: true
                    color: modelData.mounted === true && modelData.frac >= 0
                           ? root.heatColor(modelData.frac, hwStoragePanel.accent)
                           : root.cDim
                    font.pixelSize: Math.max(9, 9 * win.ux)
                    font.weight: Font.Medium
                  }
                }

                // ---- per-device separator hairline -------------------
                Rectangle {
                  visible: modelData.kind === "sep"
                  anchors { left: parent.left; right: parent.right
                            verticalCenter: parent.verticalCenter }
                  height: 1
                  color: root.cDiv
                }
              }
            }
          }

          // ---- graceful degrade: pre-tree collectors only emit fs_* --
          Column {
            width: parent.width
            visible: root.blkCount <= 0
            spacing: 5 * win.ux
            HudRow {
              width: parent.width
              label: root.fsLabel("root")
              value: root.fsText("root")
              fraction: root.fsFrac("root") >= 0 ? root.s("fs0", 0) : -1
              accent: root.fsFrac("root") > 0.85 ? root.cAlert : root.cGreen
            }
            HudRow {
              width: parent.width
              label: root.fsLabel("home")
              value: root.fsText("home")
              fraction: root.fsFrac("home") >= 0 ? root.s("fs1", 0) : -1
              accent: root.fsFrac("home") > 0.85 ? root.cAlert : root.cGreen
            }
          }

          // ---- disk R/W rate + trace (unchanged panel footer) --------
          HudRow {
            width: parent.width
            label: "I/O"
            value: "R " + root.fmtRate(root.num(root.stats.disk_read_bps)) + "  W " + root.fmtRate(root.num(root.stats.disk_write_bps))
            fraction: -1
          }
          TraceCanvas {
            width: parent.width
            height: 30 * win.ux
            pts: root.dspDisk
            col: root.cGreen
            live: hwStoragePanel.shown && !hwStoragePanel.collapsed
          }
        }
      }

      // Peripherals: wireless batteries with live charge states.
      CPanel {
        id: hwPeriphPanel
        panelId: "periph"
        host: win
        title: root.headSymbol("periph") + " PERIPHERALS"
        accent: root.cMagenta
        ux: win.ux * 0.9
        shown: win.isHardware && !win.isHidden("periph")
        collapsed: root.isCollapsed("periph")
        onToggled: root.toggleSection("periph")
        miniStat: root.batCount > 0 ? root.batCount + " dev" : ""
        contentH: Math.max(30 * win.ux, root.batCount * 34 * win.ux + 8 * win.ux)
        minW: 220 * win.ux
        minH: 40 * win.ux
        Column {
          anchors.fill: parent
          spacing: 3 * win.ux
          Repeater {
            model: root.batList()
            delegate: BatRow {
              width: parent.width
              devName: modelData.name
              pct: modelData.pct
              bstate: modelData.state
              ux: win.ux * 0.9
            }
          }
          TLabel {
            visible: root.batCount <= 0
            text: "no wireless peripherals"
            color: root.cMuted
            font.pixelSize: Math.max(9, 10 * win.ux)
          }
        }
      }

      // Memory: swap lives here too — one home for all volatile state.
      CPanel {
        id: hwMemoryPanel
        panelId: "memory"
        host: win
        title: root.headSymbol("memory") + " MEMORY"
        accent: root.cCyan
        ux: win.ux * 0.9
        shown: win.isHardware && !win.isHidden("memory")
        collapsed: root.isCollapsed("memory")
        onToggled: root.toggleSection("memory")
        miniStat: root.memFrac >= 0 ? Math.round(root.memFrac * 100) + "%" : ""
        contentH: 80 * win.ux
        minW: 220 * win.ux
        minH: 50 * win.ux
        Column {
          anchors.fill: parent
          spacing: 5 * win.ux
          HudRow {
            width: parent.width
            label: "RAM"
            value: root.memText
            fraction: root.memFrac >= 0 ? root.s("mem", 0) : -1
            accent: root.memFrac > 0.9 ? root.cAlert : root.cCyan
          }
          HudRow {
            width: parent.width
            label: "SWAP"
            value: root.swapText
            fraction: root.swapFrac >= 0 ? root.s("swap", 0) : -1
            accent: root.swapFrac > 0.8 ? root.cAmber : root.cCyan
          }
          HudRow {
            width: parent.width
            label: "ZRAM"
            value: root.has("zram_data") ? root.fmtBtoGiB(root.num(root.stats.zram_data)) + "G data" : "--"
            fraction: -1
          }
        }
      }

      // Pixel knot — 3b: reduced to a watermark. It parks at the bottom
      // centre of the open canvas on the reactor's vertical axis, painted
      // UNDER the panels (z −2) and idling at less than half opacity; it
      // flares back toward full only while one of its micro-animations is
      // running. Same free-canvas plumbing (drag/snap/resize/persist) as
      // CPanel; the canvas pauses its scheduler while hidden.
      Item {
        id: knotZone
        property string panelId: "knot"
        property var host: win
        visible: win.isCommand && !win.isHidden("knot")
        readonly property bool dragging: win.draggingId === "knot"
        readonly property bool resizing: win.sizingId === "knot"
        // a background watermark must not claim pointer area — masked:false
        // keeps it out of the window mask so clicks pass through to the
        // desktop (its drag surface stays inert; the v3 lane makes it a
        // fixed element properly)
        readonly property bool masked: false
        readonly property real naturalH: width
        property real minW: 120 * win.ux
        property real minH: 120 * win.ux
        property real sizeH: -1
        height: sizeH > 0 ? sizeH : width
        opacity: dragging ? 0.92 : (knotArt.effect >= 0 ? 0.85 : 0.45)
        z: dragging ? 60 : -2
        Behavior on opacity { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
        Behavior on x { enabled: win.animateLayout && !knotZone.dragging; NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Behavior on y { enabled: win.animateLayout && !knotZone.dragging; NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Binding on x { when: !knotZone.dragging; value: win.pxOf("knot") }
        Binding on y { when: !knotZone.dragging; value: win.pyOf("knot") }
        Binding on width { when: !knotZone.resizing; value: win.pwOf("knot") }
        Binding { target: knotZone; property: "sizeH"; when: !knotZone.resizing; value: win.phOf("knot") }

        PixelKnot {
          id: knotArt
          anchors.centerIn: parent
          px: Math.max(2, Math.floor(Math.min(knotZone.width, knotZone.height) / 49))
          width: knotArt.px * knotArt.cols
          height: knotArt.px * knotArt.rows
          accent: root.cAccent
          running: knotZone.visible
        }

        // drag surface over the canvas — the knot itself isn't a CPanel so
        // it gets the same hover-drag plumbing the chassis bar uses
        MouseArea {
          id: knotMa
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onPressed: win.dragPress(knotMa, knotZone, "knot", mouse.x, mouse.y)
          onPositionChanged: win.dragMove(knotMa, knotZone, mouse.x, mouse.y)
          onReleased: win.dragRelease(knotZone)
          onCanceled: win.dragAbort(knotZone)
        }
        Item {
          anchors { right: parent.right; bottom: parent.bottom; margins: 2 }
          width: 14 * win.ux
          height: 14 * win.ux
          visible: knotZone.visible
          opacity: knotGripMa.containsMouse || knotZone.resizing ? 1.0 : 0.35
          Rectangle { anchors { right: parent.right; bottom: parent.bottom } width: 1.5; height: 9 * win.ux; color: root.cCyan }
          Rectangle { anchors { right: parent.right; bottom: parent.bottom } width: 9 * win.ux; height: 1.5; color: root.cCyan }
          MouseArea {
            id: knotGripMa
            anchors { fill: parent; margins: -4 * win.ux }
            hoverEnabled: true
            cursorShape: Qt.SizeFDiagCursor
            onPressed: win.sizePress(knotGripMa, knotZone, "knot", mouse.x, mouse.y)
            onPositionChanged: win.sizeMove(knotGripMa, knotZone, mouse.x, mouse.y)
            onReleased: win.sizeRelease(knotZone)
            onCanceled: win.sizeAbort(knotZone)
          }
        }
      }

      // Status cross-refs: pointers to homes on other screens + link health.
      CPanel {
        id: hwStatusPanel
        panelId: "status"
        host: win
        title: "STATUS"
        accent: root.cGreen
        ux: win.ux * 0.9
        shown: win.isHardware && !win.isHidden("status")
        collapsible: false
        contentH: 44 * win.ux
        minW: 260 * win.ux
        minH: 30 * win.ux
        Row {
          anchors.fill: parent
          spacing: 18 * win.ux
          Repeater {
            model: [
              ["LINK", root.linkOk ? "live · f" + root.batchSeq : "lost", root.linkOk ? root.cGreen : root.cAlert],
              ["NET",  root.fmtRate(root.rxRate) + " rx", root.cCyan],
              ["WIN",  root.winCount + " on " + root.wsCount + " ws", root.cMagenta],
              ["OPS",  root.tokProviderCount > 0 ? root.tokProviderCount + " token feeds" : "ledger pending", root.cGreen]
            ]
            delegate: Row {
              spacing: 6 * win.ux
              TLabel {
                text: modelData[0]
                color: root.cMuted
                font.pixelSize: Math.max(9, 10 * win.ux)
                font.weight: Font.Medium
                font.letterSpacing: 0.2 * win.ux
              }
              TLabel {
                text: modelData[1]
                mono: true
                color: modelData[2]
                font.pixelSize: Math.max(10, 11 * win.ux)
              }
            }
          }
        }
      }
      // ================================================= OPS / DEV CONSOLE
      // Windows/nav: workspace chips + focused window rows for this monitor.
      CPanel {
        id: navPanel
        panelId: "windows"
        host: win
        title: root.headSymbol("windows") + " WINDOWS / NAV"
        accent: root.cGreen
        ux: win.ux * 0.9
        shown: win.isOps && !win.isHidden("windows")
        collapsed: root.isCollapsed("windows")
        onToggled: root.toggleSection("windows")
        miniStat: root.winCount + " win · " + root.wsCount + " ws"
        contentH: Math.max(80 * win.ux,
                           Math.ceil(root.wsCount / 5) * 30 * win.ux
                           + Math.min(6, root.winCount) * 32 * win.ux + 26 * win.ux)
        minW: 280 * win.ux
        minH: 60 * win.ux
        Column {
          anchors.fill: parent
          spacing: 4 * win.ux
          Flow {
            width: parent.width
            spacing: 4 * win.ux
            Repeater {
              model: root.wsList()
              delegate: WsChip {
                ux: win.ux * 0.9
                wsId: String(modelData.id)
                wsName: modelData.name
                wins: modelData.wins
                active: modelData.id === win.activeWsId
                onThisMon: modelData.mon === win.screenName
              }
            }
          }
          Rectangle {
            width: parent.width; height: 1; color: root.cDiv
          }
          Repeater {
            model: root.winList(win.screenName)
            delegate: WinRow {
              width: parent.width
              addr: modelData.addr
              cls: modelData.cls
              wtitle: modelData.title
              wsName: modelData.ws
              monName: modelData.mon
              onThisScreen: modelData.mon === win.screenName
              activeWs: modelData.wsid === win.activeWsId
              ux: win.ux * 0.9
            }
          }
          TLabel {
            visible: root.winCount <= 0
            text: "no clients — hyprland idle"
            color: root.cMuted
            font.pixelSize: Math.max(9, 10 * win.ux)
          }
        }
      }

      // Top procs: full-height list, the ops workhorse.
      CPanel {
        id: opsProcsPanel
        panelId: "procs"
        host: win
        title: root.headSymbol("procs") + " TOP PROCS"
        accent: root.cMagenta
        ux: win.ux * 0.9
        shown: win.isOps && !win.isHidden("procs")
        collapsed: root.isCollapsed("procs")
        onToggled: root.toggleSection("procs")
        miniStat: root.has("procs") ? root.stats.procs + " total" : ""
        contentH: Math.max(90 * win.ux, Math.min(10, Math.max(1, root.num(root.stats.proc_n))) * 26 * win.ux + 24 * win.ux)
        minW: 260 * win.ux
        minH: 60 * win.ux
        Column {
          anchors.fill: parent
          spacing: 1 * win.ux
          Repeater {
            model: Math.min(10, Math.max(0, root.num(root.stats.proc_n)))
            delegate: ProcRow {
              width: parent.width
              rank: index + 1
              pname: root.has("proc" + index + "_name") ? String(root.stats["proc" + index + "_name"]) : "?"
              pcpu: root.procCpu(index)
              ux: win.ux * 0.9
            }
          }
          TLabel {
            visible: root.num(root.stats.proc_n) <= 0
            text: "collector starting…"
            color: root.cMuted
            font.pixelSize: Math.max(9, 10 * win.ux)
          }
        }
      }

      // Agents: harness chips + devin session locks + tmux attach rows.
      CPanel {
        id: opsAgentsPanel
        panelId: "agents"
        host: win
        title: root.headSymbol("agents") + " AGENTS"
        accent: root.cMagenta
        ux: win.ux * 0.9
        shown: win.isOps && !win.isHidden("agents")
        collapsed: root.isCollapsed("agents")
        onToggled: root.toggleSection("agents")
        miniStat: root.agentLiveCount > 0 ? root.agentLiveCount + " proc" : ""
        contentH: {
          var h = Math.ceil(root.harnessIds.length / 2) * 46 * win.ux + 10 * win.ux
          if (root.devsessCount > 0) h += 16 * win.ux + root.devsessCount * 20 * win.ux
          if (root.tmuxCount > 0)    h += 16 * win.ux + root.tmuxCount * 24 * win.ux
          if (root.aguseCount > 0)   h += 16 * win.ux + root.aguseCount * 18 * win.ux
          return h
        }
        minW: 280 * win.ux
        minH: 60 * win.ux
        Column {
          anchors.fill: parent
          spacing: 5 * win.ux
          Grid {
            width: parent.width
            columns: 2
            columnSpacing: 5 * win.ux
            rowSpacing: 5 * win.ux
            Repeater {
              model: root.agList()
              delegate: AgChip {
                width: (parent.width - 5 * win.ux) / 2
                ux: win.ux * 0.9
                name: modelData.id
                procs: modelData.procs
                cpu: modelData.cpu
              }
            }
          }
          Column {
            visible: root.devsessCount > 0
            width: parent.width
            spacing: 1 * win.ux
            TLabel {
              text: "DEVIN LOCKS"
              color: root.cMuted
              font.pixelSize: Math.max(9, 9 * win.ux)
              font.weight: Font.Medium
              font.letterSpacing: 0.4 * win.ux
            }
            Repeater {
              model: root.devsessList()
              delegate: DevRow {
                width: parent.width
                sname: modelData.name
                spid: modelData.pid
                live: modelData.live
                ux: win.ux * 0.9
              }
            }
          }
          Column {
            visible: root.tmuxCount > 0
            width: parent.width
            spacing: 1 * win.ux
            TLabel {
              text: "TMUX — click to attach"
              color: root.cMuted
              font.pixelSize: Math.max(9, 9 * win.ux)
              font.weight: Font.Medium
              font.letterSpacing: 0.4 * win.ux
            }
            Repeater {
              model: root.tmuxList()
              delegate: TmuxRow {
                width: parent.width
                sname: modelData.name
                wins: modelData.win
                att: modelData.att
                ux: win.ux * 0.9
              }
            }
          }
          Column {
            visible: root.aguseCount > 0
            width: parent.width
            spacing: 1 * win.ux
            TLabel {
              text: "AGENT LEDGER"
              color: root.cMuted
              font.pixelSize: Math.max(9, 9 * win.ux)
              font.weight: Font.Medium
              font.letterSpacing: 0.4 * win.ux
            }
            Repeater {
              model: root.aguseList()
              delegate: Row {
                width: parent.width
                spacing: 7 * win.ux
                TLabel {
                  width: parent.width * 0.5
                  text: modelData.id
                  color: root.cSub
                  font.pixelSize: Math.max(9, 10 * win.ux)
                  elide: Text.ElideRight
                }
                TLabel {
                  text: modelData.tokens
                  mono: true
                  color: root.cCyan
                  font.pixelSize: Math.max(9, 10 * win.ux)
                }
                TLabel {
                  anchors.right: undefined
                  text: modelData.status
                  mono: true
                  color: modelData.status === "ok" ? root.cGreen : root.cAmber
                  font.pixelSize: Math.max(9, 9 * win.ux)
                }
              }
            }
          }
        }
      }

      // Repo activity: github event feed + notification count.
      CPanel {
        id: repoPanel
        panelId: "repo"
        host: win
        title: root.headSymbol("repo") + " REPO ACTIVITY"
        accent: root.cGreen
        ux: win.ux * 0.9
        shown: win.isOps && !win.isHidden("repo")
        collapsed: root.isCollapsed("repo")
        onToggled: root.toggleSection("repo")
        miniStat: root.ghOk ? (root.ghUnread > 0 ? root.ghUnread + " unread" : "clear") : "offline"
        contentH: Math.max(60 * win.ux, root.ghEvCount * 30 * win.ux + 22 * win.ux)
        minW: 280 * win.ux
        minH: 60 * win.ux
        Column {
          anchors.fill: parent
          spacing: 1 * win.ux
          Row {
            spacing: 6 * win.ux
            TLabel {
              text: root.ghOk ? "github" : "github offline"
              color: root.ghOk ? root.cGreen : root.cMuted
              font.pixelSize: Math.max(9, 10 * win.ux)
              font.weight: Font.Medium
            }
            TLabel {
              visible: root.ghUnread > 0
              text: root.ghUnread + " unread"
              mono: true
              color: root.cAmber
              font.pixelSize: Math.max(9, 10 * win.ux)
            }
          }
          Repeater {
            model: root.ghevList()
            delegate: RepoRow {
              width: parent.width
              kind: modelData.type
              repo: modelData.repo
              age: modelData.age
              url: modelData.url
              ux: win.ux * 0.9
            }
          }
          TLabel {
            visible: root.ghEvCount <= 0
            text: root.ghOk ? "quiet — no events" : "waiting for feed"
            color: root.cMuted
            font.pixelSize: Math.max(9, 10 * win.ux)
          }
        }
      }

      // Launch: the full app rail for the ops console.
      CPanel {
        id: launchPanel
        panelId: "launch"
        host: win
        title: root.headSymbol("launch") + " LAUNCH"
        accent: root.cCyan
        ux: win.ux * 0.9
        shown: win.isOps && !win.isHidden("launch")
        collapsed: root.isCollapsed("launch")
        onToggled: root.toggleSection("launch")
        contentH: 78 * win.ux
        minW: 260 * win.ux
        minH: 50 * win.ux
        Flow {
          anchors.fill: parent
          spacing: 6 * win.ux
          CmdChip { ux: win.ux * 0.9; label: "Devin";   glyph: "◆"; accent: root.cMagenta; argv: ["gtk-launch", "devin-desktop"] }
          CmdChip { ux: win.ux * 0.9; label: "Term";    glyph: "▸"; accent: root.cGreen;   argv: ["gtk-launch", "foot"] }
          CmdChip { ux: win.ux * 0.9; label: "Files";   glyph: "▣"; accent: root.cAmber;   argv: ["gtk-launch", "org.gnome.Nautilus"] }
          CmdChip { ux: win.ux * 0.9; label: "Web";     glyph: "◉"; accent: root.cCyan;    argv: ["gtk-launch", "chromium"] }
          CmdChip { ux: win.ux * 0.9; label: "Slack";   glyph: "✳"; accent: root.cMagenta; argv: ["gtk-launch", "slack"] }
          CmdChip { ux: win.ux * 0.9; label: "Monitor"; glyph: "◔"; accent: root.cAmber;   argv: ["foot", "btop"] }
          CmdChip { ux: win.ux * 0.9; label: "Settings";glyph: "⚙"; accent: root.cCyan;    argv: ["gtk-launch", "gnome-control-center"] }
        }
      }

      // Quick actions: lock / suspend / reboot / poweroff pulse-buttons.
      CPanel {
        id: opsActionsPanel
        panelId: "actions"
        host: win
        title: root.headSymbol("actions") + " OPS ACTIONS"
        accent: root.cAlert
        ux: win.ux * 0.9
        shown: win.isOps && !win.isHidden("actions")
        collapsed: root.isCollapsed("actions")
        onToggled: root.toggleSection("actions")
        contentH: 50 * win.ux
        minW: 260 * win.ux
        minH: 40 * win.ux
        Row {
          anchors.fill: parent
          spacing: 6 * win.ux
          CmdChip { ux: win.ux * 0.9; label: "Lock";     glyph: "⏻"; accent: root.cCyan;  argv: ["omarchy-shell", "lock", "lock"] }
          CmdChip { ux: win.ux * 0.9; label: "Suspend";  glyph: "◔"; accent: root.cAmber; argv: ["systemctl", "suspend"] }
          CmdChip { ux: win.ux * 0.9; label: "Reboot";   glyph: "↻"; accent: root.cAmber; argv: ["systemctl", "reboot"] }
          CmdChip { ux: win.ux * 0.9; label: "Poweroff"; glyph: "⏻"; accent: root.cAlert; argv: ["systemctl", "poweroff"] }
        }
      }

      // TOKENS — the provider ledger panel (wave-4). Compact per-provider
      // rows: label · kind tag · day in/out · cost; alert tint when a
      // provider's meta says its feed is absent or unauthenticated. The ⧉
      // header chip (and the `tokens` IPC target) opens the ledger sheet.
      CPanel {
        id: tokPanel
        panelId: "tokens"
        host: win
        title: root.headSymbol("tokens") + " TOKENS"
        accent: root.cGreen
        ux: win.ux * 0.9
        shown: win.isOps && !win.isHidden("tokens")
        collapsed: root.isCollapsed("tokens")
        onToggled: root.toggleSection("tokens")
        chipGlyph: "⧉"
        onChipActivated: root.tokOpen = !root.tokOpen
        miniStat: root.tokProviderCount > 0 ? root.tokProviderCount + " feeds" : "starting…"
        contentH: Math.max(30 * win.ux, root.tokRows.length * 30 * win.ux + 20 * win.ux)
        minW: 260 * win.ux
        minH: 44 * win.ux
        Column {
          anchors.fill: parent
          spacing: 2 * win.ux
          Repeater {
            model: root.tokRows
            delegate: Item {
              width: parent.width
              height: Math.max(26, 28 * win.ux)
              Rectangle {
                anchors.fill: parent
                radius: 4 * win.ux
                color: "transparent"
                visible: false
              }
              TLabel {
                anchors { left: parent.left; leftMargin: 2 * win.ux; verticalCenter: parent.verticalCenter }
                width: parent.width * 0.34
                text: modelData.label
                color: modelData.ok ? root.cTxt : root.cAlert
                font.pixelSize: Math.max(10, 11 * win.ux)
                font.weight: Font.Medium
                elide: Text.ElideRight
              }
              Rectangle {
                id: tokKind
                anchors { left: parent.left; leftMargin: parent.width * 0.36; verticalCenter: parent.verticalCenter }
                width: Math.max(26, tokKindLbl.implicitWidth + 8 * win.ux)
                height: 14 * win.ux
                radius: 3 * win.ux
                color: Util.alpha(modelData.ok ? root.cGreen : root.cAlert, 0.10)
                TLabel {
                  id: tokKindLbl
                  anchors.centerIn: parent
                  text: modelData.kind
                  mono: true
                  color: modelData.ok ? root.cGreen : root.cAlert
                  font.pixelSize: Math.max(9, 8 * win.ux)
                  font.weight: Font.Medium
                }
              }
              TLabel {
                anchors { right: tokCost.left; rightMargin: 8 * win.ux; verticalCenter: parent.verticalCenter }
                text: modelData.dayIO
                mono: true
                color: modelData.ok ? root.cSub : root.cAlert
                font.pixelSize: Math.max(10, 11 * win.ux)
              }
              TLabel {
                id: tokCost
                anchors { right: parent.right; rightMargin: 2 * win.ux; verticalCenter: parent.verticalCenter }
                text: modelData.cost !== "" ? modelData.cost : "—"
                mono: true
                color: modelData.cost !== "" ? root.cGreen : root.cMuted
                font.pixelSize: Math.max(10, 11 * win.ux)
                font.weight: Font.Medium
              }
            }
          }
          TLabel {
            visible: root.tokRows.length === 0
            text: "ledger: starting…"
            mono: true
            color: root.cMuted
            font.pixelSize: Math.max(9, 10 * win.ux)
          }
          TLabel {
            visible: root.tokData.updated !== undefined
            text: "updated " + String(root.tokData.updated)
            mono: true
            color: root.cDim
            font.pixelSize: Math.max(9, 9 * win.ux)
          }
        }
      }

      // Network feed: rates + split-lane trace + iface/addr rows.
      CPanel {
        id: opsNetPanel
        panelId: "network"
        host: win
        title: root.headSymbol("network") + " NETWORK"
        accent: root.cCyan
        ux: win.ux * 0.9
        shown: win.isOps && !win.isHidden("network")
        collapsed: root.isCollapsed("network")
        onToggled: root.toggleSection("network")
        miniStat: root.linkOk ? root.fmtRate(root.rxRate) + " rx" : "offline"
        contentH: 120 * win.ux
        minW: 260 * win.ux
        minH: 60 * win.ux
        Column {
          anchors.fill: parent
          spacing: 5 * win.ux
          Item {
            width: parent.width
            height: 56 * win.ux
            TLabel {
              anchors { left: parent.left; top: parent.top }
              text: "RX " + root.fmtRate(root.rxRate)
              mono: true
              color: root.cCyan
              font.pixelSize: Math.max(10, 11 * win.ux)
            }
            TLabel {
              anchors { right: parent.right; top: parent.top }
              text: "TX " + root.fmtRate(root.txRate)
              mono: true
              color: root.cMagenta
              font.pixelSize: Math.max(10, 11 * win.ux)
            }
            TraceCanvas {
              anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 14 * win.ux; bottom: parent.bottom }
              pts: root.dspRx
              pts2: root.dspTx
              col: root.cCyan
              col2: root.cMagenta
              split: true
              live: opsNetPanel.shown && !opsNetPanel.collapsed
            }
          }
          HudRow {
            width: parent.width
            label: "IFACE"
            value: root.has("net_if") ? String(root.stats.net_if) : "--"
            fraction: -1
          }
          HudRow {
            width: parent.width
            label: "ADDR"
            value: root.has("net_addr") ? String(root.stats.net_addr) : "--"
            fraction: -1
          }
          HudRow {
            width: parent.width
            label: "LINK"
            value: root.linkOk ? "live · batch " + root.batchSeq : "lost"
            valueColor: root.linkOk ? root.cGreen : root.cAlert
            fraction: -1
          }
        }
      }

      // Ops status strip: cross-refs back to command/hardware homes.
      CPanel {
        id: opsStatusPanel
        panelId: "status"
        host: win
        title: "STATUS"
        accent: root.cGreen
        ux: win.ux * 0.9
        shown: win.isOps && !win.isHidden("status")
        collapsible: false
        contentH: 44 * win.ux
        minW: 260 * win.ux
        minH: 30 * win.ux
        Row {
          anchors.fill: parent
          spacing: 18 * win.ux
          Repeater {
            model: [
              ["CPU",  root.cpuText,          root.cCyan],
              ["MEM",  root.memFrac >= 0 ? Math.round(root.memFrac * 100) + "%" : "—", root.cCyan],
              ["GPU",  root.gpuStatusText,    root.cAmber],
              ["DISK", root.storageFreeText,  root.cGreen],
              ["BAT",  root.batStatusText(),  root.cMagenta]
            ]
            delegate: Row {
              spacing: 6 * win.ux
              TLabel {
                text: modelData[0]
                color: root.cMuted
                font.pixelSize: Math.max(9, 10 * win.ux)
                font.weight: Font.Medium
                font.letterSpacing: 0.2 * win.ux
              }
              TLabel {
                text: modelData[1]
                mono: true
                color: modelData[2]
                font.pixelSize: Math.max(10, 11 * win.ux)
                elide: Text.ElideRight
              }
            }
          }
        }
      }

      }  // —— field (free-canvas surface) ends; scrims/sheets live on win

      // --------------------------------------------------- settings sheet
      // Gear click -> dim scrim over this screen + a right-anchored sheet.
      // The scrim Rectangle goes into the window mask so clicks land on it
      // (blocking the desktop beneath) and dismiss the sheet.
      Rectangle {
        id: sheetScrim
        anchors.fill: parent
        visible: win.sheetOpen
        color: Qt.rgba(0.004, 0.027, 0.047, 0.68)
        opacity: win.sheetOpen ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        MouseArea {
          anchors.fill: parent
          onClicked: win.sheetOpen = false
        }
      }

      Rectangle {
        id: sheet
        visible: win.sheetOpen
        anchors { top: parent.top; bottom: parent.bottom; right: parent.right; margins: win.pad + 6 * win.ux }
        width: Math.min(parent.width * 0.32, 340 * win.ux)
        radius: 8 * win.ux
        color: root.cPlate
        border.color: root.cHair
        border.width: 1
        clip: true

        Flickable {
          id: sheetFlick
          anchors { fill: parent; margins: 14 * win.ux }
          contentWidth: width
          contentHeight: sheetCol.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: sheetCol
            width: sheetFlick.width
            spacing: 10 * win.ux

            TLabel {
              text: "Settings"
              color: root.cTxt
              font.pixelSize: Math.max(13, 16 * win.ux)
              font.weight: Font.DemiBold
            }
            TLabel {
              text: win.roleLabel + "  ·  " + win.screenName
              mono: true
              color: root.cMuted
              font.pixelSize: Math.max(9, 9 * win.ux)
            }
            Rectangle { width: parent.width; height: 1; color: root.cDiv }

            // accent presets
            TLabel {
              text: "ACCENT"
              color: root.cMuted
              font.pixelSize: Math.max(9, 11 * win.ux)
              font.weight: Font.Medium
              font.letterSpacing: 0.4 * win.ux
            }
            Flow {
              width: parent.width
              spacing: 6 * win.ux
              Repeater {
                model: ["cyan", "green", "magenta", "amber"]
                delegate: SetChip {
                  ux: win.ux * 0.9
                  label: modelData
                  accent: root.accentPresets[modelData].main
                  lit: root.accentName === modelData
                  onChosen: { root.accentName = modelData; root.scheduleSave() }
                }
              }
            }

            // ambient shader
            TLabel {
              text: "AMBIENT FIELD"
              color: root.cMuted
              font.pixelSize: Math.max(9, 11 * win.ux)
              font.weight: Font.Medium
              font.letterSpacing: 0.4 * win.ux
            }
            Row {
              spacing: 6 * win.ux
              SetChip {
                ux: win.ux * 0.9
                label: root.shaderOn ? "On" : "Off"
                accent: root.cCyan
                lit: root.shaderOn
                onChosen: { root.shaderOn = !root.shaderOn; root.scheduleSave() }
              }
              MiniSlider {
                width: 120 * win.ux
                ux: win.ux * 0.9
                accent: root.cCyan
                value: root.shaderIntensity
                onMoved: function(v) { root.shaderIntensity = v; root.scheduleSave() }
              }
            }

            // animation clock rate — persisted (tickHz drives animClock's
            // interval); 15 saves battery, 60 is smoother, 30 default
            TLabel {
              text: "TICK RATE"
              color: root.cMuted
              font.pixelSize: Math.max(9, 11 * win.ux)
              font.weight: Font.Medium
              font.letterSpacing: 0.4 * win.ux
            }
            Row {
              spacing: 6 * win.ux
              Repeater {
                model: [15, 30, 60]
                delegate: SetChip {
                  ux: win.ux * 0.9
                  label: modelData + " Hz"
                  accent: root.cCyan
                  lit: root.tickHz === modelData
                  onChosen: { root.tickHz = modelData; root.scheduleSave() }
                }
              }
            }

            // panel visibility toggles — one chip per registry entry on
            // this role, including the wave-4 tokens + knot additions
            TLabel {
              text: "PANELS"
              color: root.cMuted
              font.pixelSize: Math.max(9, 11 * win.ux)
              font.weight: Font.Medium
              font.letterSpacing: 0.4 * win.ux
            }
            Flow {
              width: parent.width
              spacing: 5 * win.ux
              Repeater {
                model: win.roleIds
                delegate: SetChip {
                  ux: win.ux * 0.9
                  label: win.panelLabel(modelData)
                  accent: root.cSub
                  lit: !win.isHidden(modelData)
                  onChosen: win.toggleHidden(modelData)
                }
              }
            }

            Rectangle { width: parent.width; height: 1; color: root.cDiv }
            Row {
              spacing: 6 * win.ux
              SetChip {
                ux: win.ux * 0.9
                label: "Reset layout"
                accent: root.cAmber
                lit: false
                onChosen: win.resetLayout()
              }
              SetChip {
                ux: win.ux * 0.9
                label: root.tokOpen ? "Token sheet…" : "Token sheet"
                accent: root.cGreen
                lit: root.tokOpen
                onChosen: root.tokOpen = !root.tokOpen
              }
            }
          }
        }
      }

      // ----------------------------------------------- token ledger sheet
      // wave-4: the ⧉ chip in the TOKENS header (or `quickshell ipc
      // nexuslink.hud tokens`) flips root.tokOpen. Same mechanics as the
      // settings sheet: dim scrim blocks the desktop and dismisses on click,
      // a sheet shows day/week/month buckets per provider plus provenance.
      Rectangle {
        id: tokScrim
        anchors.fill: parent
        visible: root.tokOpen
        color: Qt.rgba(0.004, 0.027, 0.047, 0.68)
        opacity: root.tokOpen ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        MouseArea {
          anchors.fill: parent
          onClicked: root.tokOpen = false
        }
      }

      Rectangle {
        id: tokSheet
        visible: root.tokOpen
        anchors.centerIn: parent
        width: Math.min(parent.width * 0.72, 640 * win.ux)
        height: Math.min(parent.height * 0.72, 480 * win.ux)
        radius: 8 * win.ux
        color: root.cPlate
        border.color: root.cHair
        border.width: 1
        clip: true

        Column {
          id: tokSheetCol
          anchors { fill: parent; margins: 16 * win.ux }
          spacing: 8 * win.ux

          Row {
            width: parent.width
            TLabel {
              text: "Token Ledger"
              color: root.cTxt
              font.pixelSize: Math.max(13, 16 * win.ux)
              font.weight: Font.DemiBold
            }
            TLabel {
              anchors.verticalCenter: parent.verticalCenter
              text: "   " + win.screenName + "  ·  shared across screens"
              mono: true
              color: root.cMuted
              font.pixelSize: Math.max(9, 9 * win.ux)
            }
          }
          Rectangle { width: parent.width; height: 1; color: root.cDiv }

          // column header
          Row {
            width: parent.width
            spacing: 0
            TLabel { width: parent.width * 0.30; text: "PROVIDER"; color: root.cMuted; font.pixelSize: Math.max(9, 9 * win.ux); font.weight: Font.Medium; font.letterSpacing: 0.4 * win.ux }
            TLabel { width: parent.width * 0.17; text: "DAY";   mono: true; color: root.cMuted; font.pixelSize: Math.max(9, 9 * win.ux); font.letterSpacing: 0.4 * win.ux }
            TLabel { width: parent.width * 0.17; text: "WEEK";  mono: true; color: root.cMuted; font.pixelSize: Math.max(9, 9 * win.ux); font.letterSpacing: 0.4 * win.ux }
            TLabel { width: parent.width * 0.17; text: "MONTH"; mono: true; color: root.cMuted; font.pixelSize: Math.max(9, 9 * win.ux); font.letterSpacing: 0.4 * win.ux }
            TLabel { width: parent.width * 0.19; text: "COST";  mono: true; color: root.cMuted; font.pixelSize: Math.max(9, 9 * win.ux); font.letterSpacing: 0.4 * win.ux; horizontalAlignment: Text.AlignRight }
          }

          Flickable {
            width: parent.width
            height: parent.height - y - 30 * win.ux
            contentWidth: width
            contentHeight: tokGridCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            Column {
              id: tokGridCol
              width: parent.width
              spacing: 3 * win.ux
              Repeater {
                model: root.tokRows
                delegate: Column {
                  width: parent.width
                  spacing: 1 * win.ux
                  Row {
                    width: parent.width
                    spacing: 0
                    TLabel {
                      width: parent.width * 0.30
                      text: modelData.label + "  ·  " + modelData.kind
                      color: modelData.ok ? root.cTxt : root.cAlert
                      font.pixelSize: Math.max(11, 12 * win.ux)
                      font.weight: Font.Medium
                      elide: Text.ElideRight
                    }
                    TLabel {
                      width: parent.width * 0.17
                      text: modelData.dayIO
                      mono: true
                      color: modelData.ok ? root.cSub : root.cAlert
                      font.pixelSize: Math.max(10, 11 * win.ux)
                    }
                    TLabel {
                      width: parent.width * 0.17
                      text: modelData.weekIO
                      mono: true
                      color: root.cSub
                      font.pixelSize: Math.max(10, 11 * win.ux)
                    }
                    TLabel {
                      width: parent.width * 0.17
                      text: modelData.monthIO
                      mono: true
                      color: root.cSub
                      font.pixelSize: Math.max(10, 11 * win.ux)
                    }
                    TLabel {
                      width: parent.width * 0.19
                      text: modelData.cost !== "" ? modelData.cost : "—"
                      mono: true
                      color: modelData.cost !== "" ? root.cGreen : root.cMuted
                      font.pixelSize: Math.max(10, 11 * win.ux)
                      font.weight: Font.Medium
                      horizontalAlignment: Text.AlignRight
                    }
                  }
                  TLabel {
                    visible: modelData.prov !== ""
                    text: modelData.prov
                    mono: true
                    color: root.cDim
                    font.pixelSize: Math.max(9, 9 * win.ux)
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }
              }
              TLabel {
                visible: root.tokRows.length === 0
                text: "ledger: starting… — mining local provider feeds"
                mono: true
                color: root.cMuted
                font.pixelSize: Math.max(10, 11 * win.ux)
              }
            }
          }

          Rectangle { width: parent.width; height: 1; color: root.cDiv }
          TLabel {
            text: "ledger: " + (root.tokLoaded && root.tokProviderCount > 0
                              ? root.tokStatePath : "starting…")
            mono: true
            color: root.cMuted
            font.pixelSize: Math.max(9, 9 * win.ux)
            elide: Text.ElideRight
            width: parent.width
          }
        }
      }

      // -------------------------------------------- scanlines + vignette
      // Painted once per resize — a static texture, not an animation. The
      // faint hairline grid keeps the black between panels reading as graph
      // paper rather than void; kept off the input path entirely (no mask
      // entry, no MouseArea).
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
