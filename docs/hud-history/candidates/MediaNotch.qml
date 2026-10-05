import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Commons

// NEXUS Media Notch v2 — an always-glanceable "dynamic island" on the wlr
// top layer, one surface per target output (default: the Samsung DP-1).
//
//   - ALWAYS EXPANDED: title + artist + progress + transport visible with no
//     click; a small chip folds it into a slim pill (collapse is persisted).
//   - DRAG ANYWHERE: press-and-drag on any pixel of the body (buttons and
//     chips included — a <6px press still acts like a click). On release the
//     notch magnetically snaps to the nearest anchor: top-center / top-left /
//     top-right / mid-left / mid-right, animated 300ms OutCubic. A ghost
//     preview shows the candidate anchor while dragging.
//   - MICRO-ANIMATION: album-art-less equalizer bars bounce with playback,
//     a two-layer halo breathes on `pulse` and flares on track change, the
//     title block fades+slides on track change, the progress fill is eased,
//     transport buttons press-scale + hover-lift.
//   - PERSISTENCE: anchor + collapsed flag live in
//     ~/.config/omarchy/nexuslink/notch-state.json via FileView atomicWrites
//     (same pattern as nexuslink.hud).
//   - INPUT: only the body rect is in `mask:` — everything outside passes
//     clicks through; the region tracks the body while it is dragged.
//   - CLOCK: ~30Hz while playing or dragging, slow heartbeat when idle.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // Which output the notch lives on. Match by connector name first
  // ("DP-1"), falling back to the Samsung model string.
  property string targetOutput: "DP-1"
  property string targetModel: "LC27G7"

  // ------------------------------------------------------------ palette
  // HUD-coherent: cyan accent on the deep plate, ice text, steel-dim muted.
  readonly property color cCyan:    "#00e5ff"
  readonly property color cGreen:   "#39ff14"
  readonly property color cMagenta: "#ff2bd6"
  readonly property color cTxt:     "#c9f2fb"
  readonly property color cMuted:   "#5e93a6"
  readonly property color cLine:    "#0d4a61"
  readonly property color cPlate:   "#040e16"
  readonly property color cPanel:   Util.alpha(cPlate, 0.93)
  readonly property color cBorder:  Util.alpha(cCyan, 0.45)

  readonly property string fMain: "JetBrainsMono Nerd Font"

  // ------------------------------------------------------------ MPRIS
  readonly property var players: Mpris.players ? Mpris.players.values : []

  function hasMeta(p) { return p && (p.trackTitle || p.trackArtist) }

  readonly property var activePlayer: {
    var fallback = null
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!hasMeta(p)) continue
      if (p.isPlaying) return p
      if (!fallback) fallback = p
    }
    return fallback
  }

  readonly property bool hasMedia: activePlayer !== null
  readonly property bool playing:  activePlayer && activePlayer.isPlaying
  readonly property string title:  activePlayer ? (activePlayer.trackTitle  || "") : ""
  readonly property string artist: activePlayer ? (activePlayer.trackArtist || "") : ""
  readonly property string album:  activePlayer ? (activePlayer.trackAlbum  || "") : ""
  readonly property string artUrl: activePlayer ? (activePlayer.trackArtUrl || "") : ""
  readonly property real   lenSec: activePlayer ? Math.max(0, Number(activePlayer.length) || 0) : 0

  // Position reported by the player; a local clock interpolates between
  // reports inside tick() so the bar glides at the anim rate instead of
  // stepping once per MPRIS update.
  readonly property real mprisPos: activePlayer ? Math.max(0, Number(activePlayer.position) || 0) : 0
  property real posSec: 0
  onMprisPosChanged: posSec = mprisPos
  onLenSecChanged:   if (lenSec > 0 && posSec > lenSec) posSec = lenSec

  property real progDisp: 0   // eased 0..1 progress fill
  property real eqEnv: 0      // eased 0..1 "playback energy" feeding eq/halo

  // ----------------------------------------------------- ui state + persist
  property bool   collapsed: false            // default-open per design
  property string anchor: "top-center"
  property bool   dragActive: false           // any delegate mid-drag
  property int    trackSeq: 0                 // bumped on track change
  property string lastTrack: ""
  property double flashT: -10                 // animT stamp of last track flash

  onTitleChanged: {
    if (title !== "" && title !== lastTrack) {
      lastTrack = title
      trackSeq++
      flashT = animT
      posSec = mprisPos
      progDisp = lenSec > 0 ? Util.clamp(posSec / lenSec, 0, 1) : 0
    }
  }

  // Anchor set for the magnetic snap. Order doubles as cycleAnchor() order.
  readonly property var anchorNames: ["top-center", "top-left", "top-right", "mid-left", "mid-right"]

  readonly property string stateDir:  Quickshell.env("HOME") + "/.config/omarchy/nexuslink/"
  readonly property string statePath: stateDir + "notch-state.json"
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

  // Writes are debounced so a drag session produces one write at the end.
  Timer {
    id: saveTimer
    interval: 400
    repeat: false
    onTriggered: stateFile.setText(JSON.stringify(root.buildState(), null, 2) + "\n")
  }

  function loadState(raw) {
    // FileView may fire onLoaded more than once at startup — hydrate once.
    if (persistLoaded) return
    persistLoaded = true
    var data = null
    try { data = JSON.parse(String(raw || "")) } catch (e) { data = null }
    if (data === null || typeof data !== "object") return
    if (anchorNames.indexOf(String(data.anchor)) >= 0) anchor = String(data.anchor)
    if (typeof data.collapsed === "boolean") collapsed = data.collapsed
  }

  function buildState() {
    return { version: 1, anchor: anchor, collapsed: collapsed }
  }

  function scheduleSave() { if (persistLoaded) saveTimer.restart() }
  onAnchorChanged:    scheduleSave()
  onCollapsedChanged: scheduleSave()

  // If FileView never signals, treat state as empty rather than wait forever.
  Timer {
    id: persistWatchdog
    interval: 1200
    repeat: false
    running: true
    onTriggered: if (!root.persistLoaded) root.persistLoaded = true
  }

  Component.onCompleted: {
    stateMkdirProc.running = true
    Qt.callLater(function() { stateFile.reload() })
  }

  // ------------------------------------------------------- animation clock
  // One clock for the whole plugin (Timer, not FrameAnimation — the root
  // Item lives outside any QQuickWindow). ~30Hz while media plays or a drag
  // is active; a slow heartbeat keeps the halo breathing when idle.
  property double animT: 0.0
  property double lastTickMs: 0

  // Smooth 0..1 pulse — glows breathe on this.
  readonly property real pulse: 0.5 + 0.5 * Math.sin(animT * 2.4)
  // 1->0 decay after a track change; adds a short flare to the halo.
  readonly property real flash: Math.max(0, 1 - (animT - flashT) / 1.4)

  Timer {
    id: animClock
    interval: (root.playing || root.dragActive || root.flash > 0) ? 33 : 420
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

    var k = Math.min(1, dt * 6.0)
    eqEnv += ((playing ? 1 : 0) - eqEnv) * k

    // local position interpolation — resynced by onMprisPosChanged
    if (playing && lenSec > 0) posSec = Math.min(lenSec, posSec + dt)

    var tgt = lenSec > 0 ? Util.clamp(posSec / lenSec, 0, 1) : 0
    progDisp += (tgt - progDisp) * Math.min(1, dt * 9)
    if (Math.abs(progDisp - tgt) < 0.0004) progDisp = tgt
  }

  // Per-bar oscillator tuning for the equalizer.
  readonly property var eqSpd: [4.6, 6.4, 5.2, 7.4, 5.8]
  readonly property var eqPh:  [0.0, 1.1, 2.3, 0.6, 1.8]

  function fmtTime(sec) {
    sec = Math.max(0, Math.floor(sec))
    var m = Math.floor(sec / 60), s = sec % 60
    return m + ":" + (s < 10 ? "0" : "") + s
  }

  // Transport capability lookup — kept OUT of the Repeater's model so the
  // delegate items aren't rebuilt when capabilities/playback flip mid-press
  // (a destroyed MouseArea would orphan the shared drag state).
  function canDo(a) {
    var p = activePlayer
    if (!p) return false
    if (a === "prev") return !!p.canGoPrevious
    if (a === "next") return !!p.canGoNext
    return !!(p.canTogglePlaying || p.canPlay || p.canPause)
  }

  // ------------------------------------------------------------ screens
  // Binding re-evaluates when Quickshell.screens changes (monitor hotplug).
  readonly property var targetScreens: {
    var out = []
    var all = Quickshell.screens || []
    for (var i = 0; i < all.length; i++) {
      var s = all[i]
      if (!s) continue
      var model = ""
      try { model = String(s.model || "") } catch (e) {}
      if (String(s.name) === root.targetOutput || model.indexOf(root.targetModel) >= 0)
        out.push(s)
    }
    return out
  }

  // ------------------------------------------------------------ IPC
  IpcHandler {
    target: "nexuslink.medianotch"

    function toggle(): string { root.collapsed = !root.collapsed; return root.collapsed ? "collapsed" : "expanded" }
    function dock(name: string): string {
      if (root.anchorNames.indexOf(String(name)) < 0) return "bad-anchor"
      root.anchor = String(name)
      return "ok"
    }
    function cycleAnchor(): string {
      var i = root.anchorNames.indexOf(root.anchor)
      root.anchor = root.anchorNames[(i + 1) % root.anchorNames.length]
      return root.anchor
    }
    function status(): string {
      return JSON.stringify({
        hasMedia: root.hasMedia,
        playing: root.playing,
        title: root.title,
        artist: root.artist,
        anchor: root.anchor,
        collapsed: root.collapsed,
        screens: root.targetScreens.length
      })
    }
    function setOutput(name: string): string { root.targetOutput = name; return "ok" }
  }

  // ------------------------------------------------------------ window
  Variants {
    model: root.targetScreens

    PanelWindow {
      id: win
      required property var modelData

      screen: modelData
      visible: root.hasMedia
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore
      color: "transparent"
      WlrLayershell.namespace: "omarchy-medianotch"
      WlrLayershell.layer: WlrLayer.Top
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      // Only the notch body accepts input; every other pixel of this
      // screen-sized surface passes clicks through. The region tracks the
      // body's rect, so the mask follows it through a drag.
      mask: Region { item: body }

      readonly property real topGap:  Style.space(44)   // float below the bar
      readonly property real edgeGap: 20
      property string liveAnchor: root.anchor            // snap candidate while dragging

      // --------------------------- drag plumbing (shared by every MouseArea)
      property var   dragSrc: null
      property bool  dragging: false
      property real  pressX: 0
      property real  pressY: 0
      property real  grabDX: 0
      property real  grabDY: 0

      function anchorPos(name) {
        var W = Math.max(1, field.width), H = Math.max(1, field.height)
        var w = body.width, h = body.height
        var m = edgeGap, t = topGap
        if (name === "top-left")  return Qt.point(m, t)
        if (name === "top-right") return Qt.point(Math.max(m, W - w - m), t)
        if (name === "mid-left")  return Qt.point(m, Math.max(10, (H - h) / 2))
        if (name === "mid-right") return Qt.point(Math.max(m, W - w - m), Math.max(10, (H - h) / 2))
        return Qt.point(Math.max(m, (W - w) / 2), t)   // "top-center" + fallback
      }

      function nearestAnchor(cx, cy) {
        var best = "top-center", bd = 1e18
        for (var i = 0; i < root.anchorNames.length; i++) {
          var n = root.anchorNames[i]
          var p = anchorPos(n)
          var dx = (p.x + body.width  / 2) - cx
          var dy = (p.y + body.height / 2) - cy
          var d = dx * dx + dy * dy
          if (d < bd) { bd = d; best = n }
        }
        return best
      }

      function dragPress(src, mx, my) {
        if (dragSrc !== null) return
        dragSrc = src
        var fp = src.mapToItem(field, mx, my)
        pressX = fp.x; pressY = fp.y
        grabDX = fp.x - body.x; grabDY = fp.y - body.y
      }
      function dragMove(src, mx, my) {
        if (src !== dragSrc) return
        var fp = src.mapToItem(field, mx, my)
        if (!dragging) {
          // >6px press-and-drag starts a move; under it stays a click
          if (Math.abs(fp.x - pressX) > 6 || Math.abs(fp.y - pressY) > 6) {
            dragging = true
            root.dragActive = true
          } else return
        }
        body.x = Util.clamp(fp.x - grabDX, 6, Math.max(6, field.width  - body.width  - 6))
        body.y = Util.clamp(fp.y - grabDY, 6, Math.max(6, field.height - body.height - 6))
        liveAnchor = nearestAnchor(body.x + body.width / 2, body.y + body.height / 2)
      }
      // returns true when the gesture was a drag — callers use it to
      // suppress their click action
      function dragRelease(src) {
        if (src !== dragSrc) return false
        var did = dragging
        if (did) {
          root.anchor = liveAnchor      // commit FIRST so the re-engaged
          root.scheduleSave()           // binding aims at the new anchor
        }
        dragging = false
        dragSrc = null
        root.dragActive = false
        return did
      }
      function dragAbort(src) {
        if (src !== dragSrc) return
        dragging = false
        dragSrc = null
        root.dragActive = false
        // bindings re-engage -> the body glides back to its committed anchor
      }

      // ---------------------------------------------------- scene
      Item {
        id: field
        anchors.fill: parent

        // two-layer breathing halo behind the card — a sibling (not a child)
        // so it sits UNDER the card's fill, and bound to body geometry so it
        // trails the body through drags and snap animations.
        Rectangle {
          width:  body.width  + 22
          height: body.height + 22
          x: body.x - 11
          y: body.y - 11
          radius: body.radius + 11
          color: Util.alpha(root.cCyan,
                            0.04 + 0.05 * root.eqEnv * root.pulse + 0.06 * root.flash)
        }
        Rectangle {
          width:  body.width  + 10
          height: body.height + 10
          x: body.x - 5
          y: body.y - 5
          radius: body.radius + 5
          color: Util.alpha(root.cCyan,
                            0.06 + 0.10 * root.eqEnv * root.pulse + 0.10 * root.flash)
        }

        // magnetic-snap preview: shows the anchor the body will fly to on
        // release. Sits above the halo but below the body, so as the body
        // nears the target the ghost is covered and reads as "locked on".
        Rectangle {
          id: snapGhost
          visible: opacity > 0.01
          opacity: win.dragging ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 140 } }
          x: win.anchorPos(win.liveAnchor).x
          y: win.anchorPos(win.liveAnchor).y
          width:  body.width
          height: body.height
          radius: body.radius
          color: Util.alpha(root.cCyan, 0.05)
          border.color: Util.alpha(root.cCyan, 0.35 + 0.30 * root.pulse)
          border.width: 1

          Text {
            anchors.centerIn: parent
            text: String(win.liveAnchor).toUpperCase().replace("-", " ")
            color: root.cMuted
            font.family: root.fMain
            font.pointSize: 8
          }
        }

        // ------------------------------------------------------ the notch
        Rectangle {
          id: body
          width:  root.collapsed ? pillRow.implicitWidth + 30 : 348
          height: root.collapsed ? 36 : 116
          radius: root.collapsed ? height / 2 : 15
          color: root.cPanel
          border.width: 1
          border.color: root.playing
                        ? Util.alpha(root.cCyan, 0.45 + 0.35 * root.pulse)
                        : Util.alpha(root.cCyan, 0.28 + 0.12 * root.pulse)
          clip: true

          // position rides the committed anchor except while the pointer
          // owns it; re-engaging the Binding is what produces the 300ms snap
          Binding on x { when: !win.dragging; value: win.anchorPos(root.anchor).x }
          Binding on y { when: !win.dragging; value: win.anchorPos(root.anchor).y }

          Behavior on x { enabled: !win.dragging; NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
          Behavior on y { enabled: !win.dragging; NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
          Behavior on width  { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
          Behavior on height { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
          Behavior on radius { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

          // pop-in when media appears; subtle lift while dragging
          scale: win.dragging ? 1.03 : (root.hasMedia ? 1.0 : 0.85)
          opacity: root.hasMedia ? (win.dragging ? 0.96 : 1.0) : 0
          Behavior on scale   { NumberAnimation { duration: 220; easing.type: Easing.OutBack; easing.overshoot: 1.4 } }
          Behavior on opacity { NumberAnimation { duration: 160 } }

          // left accent strip matching the HUD
          Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 2
            opacity: 0.85
            gradient: Gradient {
              GradientStop { position: 0.0; color: root.cCyan }
              GradientStop { position: 0.5; color: root.cGreen }
              GradientStop { position: 1.0; color: root.cMagenta }
            }
          }

          // body-wide drag surface — sits below the interactive children so
          // buttons/chips get their presses, every other pixel starts a move
          MouseArea {
            id: bodyMA
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: win.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
            onPressed: function(mouse) {
              if (mouse.button === Qt.LeftButton) win.dragPress(bodyMA, mouse.x, mouse.y)
            }
            onPositionChanged: function(mouse) { win.dragMove(bodyMA, mouse.x, mouse.y) }
            onReleased: function(mouse) {
              var wasDrag = win.dragRelease(bodyMA)
              if (!wasDrag && mouse.button === Qt.MiddleButton
                  && root.activePlayer && root.activePlayer.canGoNext)
                root.activePlayer.next()
            }
            onCanceled: win.dragAbort(bodyMA)
            onWheel: function(w) {
              if (!root.activePlayer) return
              if (w.angleDelta.y > 0 && root.activePlayer.canGoPrevious) root.activePlayer.previous()
              else if (w.angleDelta.y < 0 && root.activePlayer.canGoNext) root.activePlayer.next()
            }
          }

          // ------------------------------------------- expanded card layer
          Item {
            id: expandedWrap
            anchors.fill: parent
            enabled: !root.collapsed
            opacity: root.collapsed ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 160 } }

            // ---- equalizer plate (album-art-less; art fades behind if any)
            Rectangle {
              id: eqPlate
              x: 12; y: 12
              width: 54; height: 54
              radius: 8
              color: Util.alpha(root.cCyan, 0.05)
              border.width: 1
              border.color: Util.alpha(root.cCyan, 0.20 + 0.30 * root.eqEnv * root.pulse)
              clip: true

              Image {
                anchors.fill: parent
                anchors.margins: 1
                source: root.artUrl
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                opacity: 0.28
                visible: root.artUrl !== ""
              }

              Repeater {
                model: 5
                delegate: Rectangle {
                  required property int index
                  x: 11 + index * 7
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: 7
                  width: 4
                  radius: 2
                  // dormant stub when paused; full bounce while playing
                  height: 5 + 33 * root.eqEnv *
                          (0.40 + 0.60 * (0.5 + 0.5 * Math.sin(root.animT * root.eqSpd[index] + root.eqPh[index])))
                  color: index === 2 ? root.cGreen : root.cCyan
                  opacity: 0.45 + 0.55 * root.eqEnv
                }
              }
            }

            // ---- title/artist block — fades+slides on every track change
            Item {
              id: textCol
              x: 76; y: 11
              width: body.width - 76 - 42
              height: 40
              transform: Translate { id: textSlide }

              Connections {
                target: root
                function onTrackSeqChanged() { textSlideIn.restart() }
              }
              ParallelAnimation {
                id: textSlideIn
                NumberAnimation { target: textSlide; property: "x"; from: 16; to: 0; duration: 320; easing.type: Easing.OutCubic }
                NumberAnimation { target: textCol; property: "opacity"; from: 0; to: 1; duration: 240; easing.type: Easing.OutCubic }
              }

              Text {
                id: titleT
                width: parent.width
                textFormat: Text.PlainText
                text: root.title
                color: root.cCyan
                font.family: root.fMain
                font.pointSize: 11
                font.weight: Font.DemiBold
                elide: Text.ElideRight
              }
              Text {
                y: 21
                width: parent.width
                textFormat: Text.PlainText
                text: root.artist + (root.album !== "" ? "  ·  " + root.album : "")
                color: root.cMuted
                font.family: root.fMain
                font.pointSize: 9
                elide: Text.ElideRight
                visible: text !== ""
              }
            }

            // ---- collapse chip
            Rectangle {
              id: collapseChip
              x: body.width - 30
              y: 8
              width: 20; height: 20
              radius: 6
              color: chipMA.containsMouse ? Util.alpha(root.cCyan, 0.18) : Util.alpha(root.cCyan, 0.06)
              border.color: Util.alpha(root.cCyan, chipMA.containsMouse ? 0.7 : 0.3)
              border.width: 1
              scale: chipMA.pressed && !win.dragging ? 0.85 : (chipMA.containsMouse ? 1.10 : 1.0)
              Behavior on scale { NumberAnimation { duration: 130; easing.type: Easing.OutBack } }

              Text {
                anchors.centerIn: parent
                text: "󰅝"   // chevron-up: fold into pill
                color: chipMA.containsMouse ? root.cCyan : root.cMuted
                font.family: root.fMain
                font.pixelSize: 11
              }
              MouseArea {
                id: chipMA
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPressed: function(mouse) { win.dragPress(chipMA, mouse.x, mouse.y) }
                onPositionChanged: function(mouse) { win.dragMove(chipMA, mouse.x, mouse.y) }
                onReleased: function() {
                  if (!win.dragRelease(chipMA) && chipMA.containsMouse) root.collapsed = true
                }
                onCanceled: win.dragAbort(chipMA)
              }
            }

            // ---- progress bar (click-to-seek) + time readout
            Item {
              id: progressRow
              x: 76; y: 56
              width: textCol.width + 22
              height: 12

              Rectangle {
                id: barTrack
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 78
                height: 4
                radius: 2
                color: Util.alpha(root.cCyan, 0.12)

                Rectangle {
                  id: barFill
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  width: parent.width * root.progDisp
                  radius: 2
                  gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: Util.alpha(root.cCyan, 0.75) }
                    GradientStop { position: 1.0; color: root.cCyan }
                  }

                  // glowing tip riding the fill edge
                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    anchors.rightMargin: -3
                    width: 7; height: 7; radius: 3.5
                    color: root.cCyan
                    opacity: (0.35 + 0.65 * root.pulse) * (0.25 + 0.75 * root.eqEnv)
                  }
                }

                MouseArea {
                  id: progMA
                  x: 0; y: -5
                  width: parent.width
                  height: parent.height + 10
                  hoverEnabled: true
                  cursorShape: root.activePlayer && root.activePlayer.canSeek
                               ? Qt.PointingHandCursor : Qt.OpenHandCursor
                  onPressed: function(mouse) { win.dragPress(progMA, mouse.x, mouse.y) }
                  onPositionChanged: function(mouse) { win.dragMove(progMA, mouse.x, mouse.y) }
                  onReleased: function(mouse) {
                    var wasDrag = win.dragRelease(progMA)
                    var p = root.activePlayer
                    if (wasDrag || !p || !p.canSeek || root.lenSec <= 0) return
                    var frac = Util.clamp(mouse.x / Math.max(1, barTrack.width), 0, 1)
                    p.seek(frac * root.lenSec - root.posSec)   // relative offset seek
                  }
                  onCanceled: win.dragAbort(progMA)
                }
              }

              Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: 70
                horizontalAlignment: Text.AlignRight
                text: root.lenSec > 0 ? root.fmtTime(root.posSec) + " / " + root.fmtTime(root.lenSec) : "--:--"
                color: root.cMuted
                font.family: root.fMain
                font.pointSize: 8
              }
            }

            // ---- transport row
            Item {
              id: transportRow
              x: 76; y: 76
              width: textCol.width + 22
              height: 30

              Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                Repeater {
                  // static model — glyph/capability are resolved per-delegate
                  model: [
                    { action: "prev", w: 32 },
                    { action: "pp",   w: 40 },
                    { action: "next", w: 32 }
                  ]

                  Rectangle {
                    required property var modelData
                    readonly property bool canDoIt: root.canDo(modelData.action)
                    width: modelData.w
                    height: 28
                    radius: 6
                    opacity: canDoIt ? 1.0 : 0.35
                    color: tma.containsMouse ? Util.alpha(root.cCyan, 0.20) : Util.alpha(root.cCyan, 0.07)
                    border.width: 1
                    border.color: Util.alpha(root.cCyan, tma.containsMouse ? 0.7 : 0.3)

                    // press-scale + hover-lift (press visual releases if the
                    // gesture turns into a notch drag)
                    scale: tma.pressed && !win.dragging ? 0.84 : (tma.containsMouse ? 1.10 : 1.0)
                    transform: Translate {
                      id: liftT
                      y: tma.containsMouse && !tma.pressed ? -1.5 : 0
                      Behavior on y { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
                    }
                    Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutBack; easing.overshoot: 1.8 } }

                    Text {
                      anchors.centerIn: parent
                      text: modelData.action === "pp" ? (root.playing ? "󰏤" : "󰐊")
                          : modelData.action === "prev" ? "󰒮" : "󰒭"
                      color: canDoIt ? (tma.containsMouse ? root.cCyan : root.cTxt) : root.cMuted
                      font.family: root.fMain
                      font.pixelSize: modelData.action === "pp" ? 17 : 14
                    }

                    MouseArea {
                      id: tma
                      anchors.fill: parent
                      hoverEnabled: true
                      enabled: canDoIt
                      cursorShape: Qt.PointingHandCursor
                      onPressed: function(mouse) { win.dragPress(tma, mouse.x, mouse.y) }
                      onPositionChanged: function(mouse) { win.dragMove(tma, mouse.x, mouse.y) }
                      onReleased: function() {
                        var wasDrag = win.dragRelease(tma)
                        if (wasDrag || !tma.containsMouse) return
                        var p = root.activePlayer
                        if (!p) return
                        if (modelData.action === "prev" && p.canGoPrevious) p.previous()
                        else if (modelData.action === "next" && p.canGoNext) p.next()
                        else if (modelData.action === "pp") {
                          if (p.isPlaying && p.canPause) p.pause()
                          else if (!p.isPlaying && p.canPlay) p.play()
                          else if (p.canTogglePlaying) p.togglePlaying()
                        }
                      }
                      onCanceled: win.dragAbort(tma)
                    }
                  }
                }
              }

              Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: String(root.activePlayer && root.activePlayer.identity
                             ? root.activePlayer.identity : "MPRIS").toUpperCase()
                color: Util.alpha(root.cMuted, 0.8)
                font.family: root.fMain
                font.pointSize: 7
              }
            }
          }

          // ------------------------------------------- collapsed pill layer
          Item {
            id: pillWrap
            anchors.fill: parent
            enabled: root.collapsed
            opacity: root.collapsed ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 160 } }

            Row {
              id: pillRow
              anchors.centerIn: parent
              spacing: 9

              Text {
                text: root.playing ? "󰏤" : "󰐊"
                color: root.playing ? root.cGreen : root.cMuted
                font.family: root.fMain
                font.pixelSize: 11
                anchors.verticalCenter: parent.verticalCenter
              }

              Item {
                id: pillEq
                width: 14; height: 16
                implicitWidth: 14
                anchors.verticalCenter: parent.verticalCenter
                Repeater {
                  model: 3
                  delegate: Rectangle {
                    required property int index
                    x: index * 5
                    anchors.bottom: parent.bottom
                    width: 3; radius: 1.5
                    height: 3 + 11 * root.eqEnv *
                            (0.40 + 0.60 * (0.5 + 0.5 * Math.sin(root.animT * root.eqSpd[index] + root.eqPh[index])))
                    color: root.cCyan
                    opacity: 0.45 + 0.55 * root.eqEnv
                  }
                }
              }

              Item {
                id: pillClip
                width: Math.min(pillLabel.implicitWidth, 150)
                implicitWidth: width
                height: 14
                clip: true
                anchors.verticalCenter: parent.verticalCenter
                transform: Translate { id: pillSlide }

                Connections {
                  target: root
                  function onTrackSeqChanged() { pillSlideIn.restart() }
                }
                ParallelAnimation {
                  id: pillSlideIn
                  NumberAnimation { target: pillSlide; property: "x"; from: 12; to: 0; duration: 300; easing.type: Easing.OutCubic }
                  NumberAnimation { target: pillClip; property: "opacity"; from: 0; to: 1; duration: 220; easing.type: Easing.OutCubic }
                }

                Text {
                  id: pillLabel
                  textFormat: Text.PlainText
                  text: root.title + (root.artist !== "" ? "  ·  " + root.artist : "")
                  color: root.cTxt
                  font.family: root.fMain
                  font.pointSize: 9

                  property bool needsScroll: implicitWidth > pillClip.width
                  // a stopped marquee leaves x wherever it halted — reset it
                  onNeedsScrollChanged: if (!needsScroll) x = 0
                  Connections {
                    target: root
                    function onCollapsedChanged() { if (!root.collapsed) pillLabel.x = 0 }
                  }
                  NumberAnimation on x {
                    running: pillLabel.needsScroll && root.collapsed
                    loops: Animation.Infinite
                    duration: Math.max(5000, pillLabel.implicitWidth * 22)
                    from: pillClip.width
                    to: -pillLabel.implicitWidth
                    easing.type: Easing.Linear
                  }
                }
              }

              Rectangle {
                id: expandChip
                width: 18; height: 18
                implicitWidth: 18
                radius: 5
                anchors.verticalCenter: parent.verticalCenter
                color: expMA.containsMouse ? Util.alpha(root.cCyan, 0.20) : Util.alpha(root.cCyan, 0.07)
                border.color: Util.alpha(root.cCyan, expMA.containsMouse ? 0.7 : 0.3)
                border.width: 1
                scale: expMA.pressed && !win.dragging ? 0.85 : (expMA.containsMouse ? 1.12 : 1.0)
                Behavior on scale { NumberAnimation { duration: 130; easing.type: Easing.OutBack } }

                Text {
                  anchors.centerIn: parent
                  text: "󰅞"   // chevron-down: unfold into card
                  color: expMA.containsMouse ? root.cCyan : root.cMuted
                  font.family: root.fMain
                  font.pixelSize: 10
                }
                MouseArea {
                  id: expMA
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onPressed: function(mouse) { win.dragPress(expMA, mouse.x, mouse.y) }
                  onPositionChanged: function(mouse) { win.dragMove(expMA, mouse.x, mouse.y) }
                  onReleased: function() {
                    if (!win.dragRelease(expMA) && expMA.containsMouse) root.collapsed = false
                  }
                  onCanceled: win.dragAbort(expMA)
                }
              }
            }
          }
        }
      }
    }
  }
}
