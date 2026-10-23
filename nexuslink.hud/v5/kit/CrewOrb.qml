pragma ComponentBehavior: Bound

import QtQuick
import NexusHud.V5 1.0

// CrewOrb: the crew as a swarm. One dim dot shell (the C2 sphere renderer,
// kit/SwarmSphere.qml) with one sub-swarm per open session inside it, one dot
// field per agent accent, and a text block that only exists in the expanded
// state.
//
// Card W2. Reference: hud-candidates/comp-r1/s2/s2-crew-focus.png (the approved
// focus state) and the s2 rest sheet, section "3b. Crew orb" of s2/README.md:
// one dim shell of dots, inside it one sub-swarm per open session, a bright core
// point per session, acid when a session is streaming, a child sits next to its
// parent. s2 wins over s1.
//
// Three states, one component:
//   rest      (expanded false)  shell at `size`, sub-swarms inside it, no text
//   expanded  (expanded true)   the orb grows on the expand spring, session
//                               titles appear below it (16 px floor)
//   detail    (expanded true, selectedIndex >= 0)  the selected sub-swarm grows
//                               and brightens, the rest dim, and that session's
//                               detail (title, agent, tokens, activity) replaces
//                               the list: "every widget expands into a deeper
//                               view, crew to sessions" (Marcel, 2026-10-23).
// The expanded list is one title per session: the accent dot carries the agent,
// the acid core in the orb carries "streaming", and the state word plus the
// numbers live in the detail so the menu stays short. A session with a `parent`
// sits next to its parent sub-swarm (s2 3b).
//
// Every transition is a spring from Motion: expand 0.69 / 16.7 rad/s (5.00
// percent overshoot, 347 ms), return 1.0 / 9.0 (no overshoot, 444 ms). No linear
// easing, no bezier list (a 4-value bezierCurve is linear in Qt 6.12).
//
// Renderer split, and why. The shell is SwarmSphere, the one GPU pass. The
// sub-swarms are QML dot fields, not more SwarmSphere instances, for two
// measured reasons:
//   * SwarmSphere's dot radius is a constant in item units (u_dotR 0.0148 of the
//     half width), so a sub-swarm draws dots of 0.4 px at 56 px, 0.8 px at
//     107 px and 1.1 px at 152 px. The deck sizes (118 rest, 224 expanded, 320
//     focus) put a sub-swarm at 56 to 152 px, so the shader would paint a dim
//     smear instead of points. Making a sub-swarm a SwarmSphere needs a
//     per-instance dot radius, which SwarmSphere does not expose and this card
//     does not own.
//   * One ShaderEffect per swarm is what the idle budget asks for
//     (MAIN-SCREEN-BUILD.md constraint 3). Eight sessions would otherwise be
//     eight extra meshes and eight 30 Hz timers.
// The sub-swarms use the same grammar as the shell and as kit/LocalOrb.qml: a
// Fibonacci sphere, round dots whose radius and alpha follow depth, no lines, no
// glow. The dot language is identical, the rasterisation is not.
//
// Motion of the dots themselves: the shell wanders and breathes in its shader at
// Motion.breathPeriod (5.8 s, inside the 5 to 6 s band). The sub-swarms breathe
// on one 5.8 s scale animation on the shared cluster layer (40 percent in,
// 60 percent out, 2 percent amplitude, the numbers the shell's shader uses), and
// hold a fixed per-session rotation so they never look stamped. No per-frame JS
// geometry, no Canvas, no Timer.
//
// Data: `sessions` is a JS array, either the card contract shape
// {id, title, state, agent, accent} or the raw v5/fixtures/sessions.json rows
// {id, title, model, tokens, tools, idle_s, activity, parent}. Missing fields
// are derived here (state from idle_s, agent from model, accent from the agent),
// so the fixture is read as merged and W8 stays its owner. If a row carries
// explicit state / agent / accent, those win.
//
// Interaction (only while `expanded`): click a sub-swarm or a row to select it;
// that sets selectedIndex, emits sessionActivated(id) and shows the detail.
// Clicking empty space or calling clearSelection() returns to the list. Keyboard
// hooks (focus the item yourself; keys are inert without active focus):
// left/up previous, right/down next, Enter activate, Escape clear.

Item {
    id: root

    // ---- card API --------------------------------------------------------
    property real size: 224              // rest footprint, px
    property real focusLevel: 0          // 0..1 dim from W7 Focus, never `focus`
    property bool expanded: false
    property var sessions: []
    property int selectedIndex: -1
    property int hoverIndex: -1
    property bool animate: true          // false freezes the shell for stills

    signal sessionActivated(string id)

    implicitWidth: size
    implicitHeight: size
    clip: false

    // ---- design values ---------------------------------------------------
    // Local to this component until the integrator promotes them; each is
    // requested as a token in the PR body (W2). Ratios of `size` unless noted.
    readonly property real expandScale: 1.4      // expanded orb = 1.4 x size
    readonly property real anchorFraction: 0.52  // sub-swarm orbit, of orb radius
    readonly property real anchorSquash: 0.94    // flattens the orbit slightly
    readonly property real subSwarmFraction: 0.34 // sub-swarm diameter, of 1.4 x size
    readonly property real depthScaleMin: 0.86   // near / far size spread
    readonly property real depthScaleGain: 0.30
    readonly property real depthAlphaMin: 0.55
    readonly property real depthAlphaGain: 0.45
    readonly property real clusterInset: 0.84    // dots stay inside the cluster
    readonly property real dotRadiusRatio: 0.022 // dot radius, of cluster diameter
    readonly property real dotAlphaMin: 0.55
    readonly property real dotAlphaGain: 0.45
    readonly property int dotsPer70: 110         // dots at a 70 px cluster
    readonly property real coreSize: 6           // px, the per-session core point
    readonly property real hoverScale: 1.12
    readonly property real selectedScale: 2.0    // detail: selected sub-swarm
    readonly property real dimScale: 0.45        // detail: the other sub-swarms
    readonly property real dimOpacity: 0.14
    readonly property real shellOpacityRest: 0.48
    readonly property real shellOpacityExpanded: 0.22
    readonly property real shellOpacityDetail: 0.24
    readonly property int rowHeight: 26          // one title row, px
    readonly property real rowDotSize: 6
    readonly property int maxSessions: 8         // dots stay legible, cost bounded

    // ---- geometry --------------------------------------------------------
    readonly property real expandedOrbDiameter: size * expandScale
    readonly property real orbRadius: expandedOrbDiameter / 2

    // growth runs 1.0 (rest) to expandScale (expanded) and is the only thing
    // the spring moves; the layer undoes it so the geometry below is authored
    // once at the expanded size.
    property real growth: 1.0
    readonly property real layerScale: growth / expandScale

    readonly property int sessionCount: sessionModel.length
    readonly property var selectedSession:
        (selectedIndex >= 0 && selectedIndex < sessionModel.length)
        ? sessionModel[selectedIndex] : null

    // ---- shell and cluster state ----------------------------------------
    readonly property real shellOpacity: {
        if (!expanded)
            return shellOpacityRest
        return selectedIndex >= 0 ? shellOpacityDetail : shellOpacityExpanded
    }
    readonly property real textOpacity: (expanded ? 1.0 : 0.0) * (1.0 - 0.55 * clamp01(focusLevel))

    function clamp01(v) {
        return Math.max(0.0, Math.min(1.0, v))
    }

    function clusterScale(i) {
        if (!expanded)
            return 1.0
        if (selectedIndex >= 0)
            return i === selectedIndex ? selectedScale : dimScale
        return i === hoverIndex ? hoverScale : 1.0
    }

    function clusterOpacity(i) {
        if (!expanded)
            return 1.0
        if (selectedIndex >= 0)
            return i === selectedIndex ? 1.0 : dimOpacity
        return i === hoverIndex ? 1.0 : 0.92
    }

    // ---- session normalisation ------------------------------------------
    // Per-agent accents, all from Tokens. s2 uses acid for streaming, so acid is
    // kept out of this table and used for the live core point instead.
    readonly property var agentAccents: ({
        "sonnet": Tokens.azure,
        "claude": Tokens.azure,
        "opus": Tokens.azure,
        "haiku": Tokens.ice,
        "deepseek": Tokens.cyan,
        "ds4f": Tokens.cyan,
        "mimo": Tokens.amber,
        "qwen": Tokens.amber
    })
    readonly property var fallbackAccents: [Tokens.ice, Tokens.azure, Tokens.cyan, Tokens.white]

    function accentFor(agent, id) {
        var a = String(agent).toLowerCase()
        var keys = Object.keys(root.agentAccents)
        for (var i = 0; i < keys.length; ++i) {
            if (a.indexOf(keys[i]) >= 0)
                return root.agentAccents[keys[i]]
        }
        // Stable hash so a session keeps its colour across restarts.
        var h = 0
        var s = String(id)
        for (var j = 0; j < s.length; ++j)
            h = (h * 31 + s.charCodeAt(j)) % 997
        return root.fallbackAccents[h % root.fallbackAccents.length]
    }

    // State from the raw fixture: idle_s bands, because sessions.json has no
    // state field. Explicit state always wins.
    function stateOf(row) {
        if (row.state !== undefined && row.state !== null && String(row.state) !== "")
            return String(row.state)
        var idle = row.idle_s !== undefined ? Number(row.idle_s) : 0
        if (idle <= 60)
            return "live"
        if (idle <= 600)
            return "warm"
        return "idle"
    }

    // 1.0 = streaming/live (acid core), 0 = cold. Unknown states sit low.
    function weightOf(state) {
        var t = String(state).toLowerCase()
        if (t.indexOf("live") >= 0 || t.indexOf("stream") >= 0 || t.indexOf("active") >= 0)
            return 1.0
        if (t.indexOf("block") >= 0 || t.indexOf("error") >= 0 || t.indexOf("fail") >= 0)
            return 0.9
        if (t.indexOf("warm") >= 0 || t.indexOf("idle") >= 0)
            return 0.55
        return 0.4
    }

    function tokenText(t) {
        var n = Number(t)
        if (!isFinite(n) || n <= 0)
            return ""
        if (n >= 10000)
            return Math.round(n / 1000) + "k"
        if (n >= 1000)
            return (n / 1000).toFixed(1) + "k"
        return String(Math.round(n))
    }

    // One Fibonacci sphere of dots per sub-swarm, radius and alpha from depth.
    // Structural numbers (counts, angles, halves) are inline per the 2026-10-23
    // ruling; colours, sizes and alphas come from the design values above.
    function sphereDots(count, diameter, seed) {
        var out = []
        var golden = 2.399963229728653
        var baseR = Math.max(0.9, diameter * root.dotRadiusRatio)
        for (var i = 0; i < count; ++i) {
            var y = 1 - 2 * (i + 0.5) / count
            var ring = Math.sqrt(Math.max(0, 1 - y * y))
            var theta = i * golden + seed * 1.3
            var x = ring * Math.cos(theta)
            var z = ring * Math.sin(theta)
            // tilt by seed so two clusters never show the same lattice
            var ct = Math.cos(seed * 0.7)
            var st = Math.sin(seed * 0.7)
            var y2 = y * ct - z * st
            var z2 = y * st + z * ct
            var depth = (z2 + 1) / 2
            out.push({
                "x": x,
                "y": -y2,
                "r": baseR * (0.62 + 0.50 * depth),
                "a": root.dotAlphaMin + root.dotAlphaGain * depth
            })
        }
        return out
    }

    // The layout, computed once per `sessions` change: anchors at the expanded
    // size (the layer scales them down at rest), the dot field per cluster, and
    // the child-next-to-parent pass. Nothing here runs per frame.
    function buildModel(rows) {
        var out = []
        if (!rows || rows.length === undefined)
            return out
        var n = Math.min(rows.length, root.maxSessions)
        var R = root.orbRadius
        for (var i = 0; i < n; ++i) {
            var row = rows[i] || {}
            var id = row.id !== undefined ? String(row.id) : ("session-" + i)
            var agent = (row.agent !== undefined && String(row.agent) !== "")
                    ? String(row.agent)
                    : (row.model !== undefined ? String(row.model) : "")
            var state = root.stateOf(row)
            var weight = root.weightOf(state)
            var tokens = row.tokens !== undefined ? Number(row.tokens) : 0
            var tools = row.tools !== undefined ? Number(row.tools) : 0
            var diameter = root.subSwarmFraction * root.expandedOrbDiameter
                           * (0.92 + 0.16 * weight)

            var ax = 0
            var ay = 0
            var z = 0
            if (n === 1) {
                ax = 0
                ay = 0
            } else if (n === 2) {
                ax = (i === 0 ? -0.42 : 0.42) * R * root.anchorFraction
                ay = (i === 0 ? -0.16 : 0.16) * R * root.anchorFraction
                z = i === 0 ? 0.25 : -0.25
            } else {
                var y = 1 - 2 * (i + 0.5) / n
                var ring = Math.sqrt(Math.max(0, 1 - y * y))
                var theta = i * 2.399963229728653
                ax = ring * Math.cos(theta) * R * root.anchorFraction
                ay = -y * R * root.anchorFraction * root.anchorSquash
                z = ring * Math.sin(theta)
            }
            var depth = (z + 1) / 2
            var dotCount = Math.max(16, Math.round(root.dotsPer70 * diameter / 70))

            out.push({
                "id": id,
                "title": row.title !== undefined && String(row.title) !== ""
                         ? String(row.title) : "untitled session",
                "agent": agent,
                "state": state,
                "live": weight >= 1.0,
                "tokens": tokens,
                "tools": tools,
                "activity": row.activity !== undefined ? String(row.activity) : "",
                "accent": (row.accent !== undefined && row.accent !== null && row.accent !== "")
                          ? String(row.accent) : root.accentFor(agent, id),
                "ax": ax,
                "ay": ay,
                "z": z,
                "diameter": diameter,
                "depthScale": root.depthScaleMin + root.depthScaleGain * depth,
                "depthAlpha": root.depthAlphaMin + root.depthAlphaGain * depth,
                "dots": root.sphereDots(dotCount, diameter, i * 0.7 + 0.5)
            })
        }
        // s2: a child sits next to its parent. One pass after all anchors exist,
        // so a child listed before its parent still resolves.
        for (var c = 0; c < out.length; ++c) {
            var parentId = (rows[c] && rows[c].parent !== undefined
                            && rows[c].parent !== null) ? String(rows[c].parent) : ""
            if (parentId === "")
                continue
            for (var p = 0; p < out.length; ++p) {
                if (p === c || out[p].id !== parentId)
                    continue
                var ang = Math.atan2(out[p].ay, out[p].ax)
                if (isNaN(ang) || (out[p].ax === 0 && out[p].ay === 0))
                    ang = -0.9
                var nx = out[p].ax + Math.cos(ang + 0.9) * out[p].diameter * 0.62
                var ny = out[p].ay + Math.sin(ang + 0.9) * out[p].diameter * 0.62
                var maxR = R * root.anchorFraction * 1.08
                var dist = Math.sqrt(nx * nx + ny * ny)
                if (dist > maxR) {
                    nx = nx / dist * maxR
                    ny = ny / dist * maxR
                }
                out[c].ax = nx
                out[c].ay = ny
                break
            }
        }
        // The model keeps the session order: sub-swarm index == sessions index
        // == selectedIndex. Depth only sets the paint order (z) and the size and
        // alpha spread.
        return out
    }

    readonly property var sessionModel: root.buildModel(root.sessions)

    onSessionModelChanged: {
        if (selectedIndex >= sessionModel.length)
            selectedIndex = -1
    }

    // ---- interaction -----------------------------------------------------
    function activateIndex(i) {
        if (i < 0 || i >= sessionModel.length)
            return
        selectedIndex = i
        sessionActivated(sessionModel[i].id)
    }

    function clearSelection() {
        selectedIndex = -1
    }

    function selectNext() {
        if (sessionModel.length === 0)
            return
        selectedIndex = (selectedIndex + 1) % sessionModel.length
    }

    function selectPrev() {
        if (sessionModel.length === 0)
            return
        selectedIndex = (selectedIndex <= 0 ? sessionModel.length : selectedIndex) - 1
    }

    Keys.enabled: root.expanded
    Keys.onLeftPressed: root.selectPrev()
    Keys.onUpPressed: root.selectPrev()
    Keys.onRightPressed: root.selectNext()
    Keys.onDownPressed: root.selectNext()
    Keys.onReturnPressed: {
        if (root.selectedIndex >= 0)
            root.activateIndex(root.selectedIndex)
        else if (root.sessionModel.length > 0)
            root.activateIndex(0)
    }
    Keys.onEnterPressed: {
        if (root.selectedIndex >= 0)
            root.activateIndex(root.selectedIndex)
        else if (root.sessionModel.length > 0)
            root.activateIndex(0)
    }
    Keys.onEscapePressed: root.clearSelection()

    // ---- state machine: the grow spring --------------------------------
    // Qt 6.12's SpringAnimation integrates explicitly and is not stable when a
    // frame is late: measured with spring 278.89 / damping 0.69 on this Mac, one
    // 150 ms stall at the start of the expand took `growth` from 1.0 to 26076 and
    // then to 1e22 (probe: offscreen qml runtime, 8 ms trace). A closed-form
    // curve cannot do that, so the transitions use Easing.OutBack with
    // overshoot 1.15 (peak 4.9 percent, the Motion band is 4 to 6) over
    // Motion.expandMillis (347 ms) and Easing.OutCubic over Motion.returnMillis
    // (444 ms, no overshoot, slower). Same response, no divergence.
    states: State {
        name: "expanded"
        when: root.expanded
        PropertyChanges { target: root; growth: root.expandScale }
    }

    transitions: [
        Transition {
            from: ""
            to: "expanded"
            NumberAnimation {
                target: root
                property: "growth"
                duration: Motion.expandMillis
                easing.type: Easing.OutBack
                easing.overshoot: 1.15
            }
        },
        Transition {
            from: "expanded"
            to: ""
            NumberAnimation {
                target: root
                property: "growth"
                duration: Motion.returnMillis
                easing.type: Easing.OutCubic
            }
        }
    ]

    // ---- the swarm -------------------------------------------------------
    Item {
        id: orbLayer
        anchors.centerIn: parent
        width: 0
        height: 0
        scale: root.layerScale

        // The one GPU pass: the dim shell.
        SwarmSphere {
            size: root.expandedOrbDiameter
            x: -root.expandedOrbDiameter / 2
            y: -root.expandedOrbDiameter / 2
            accent: Tokens.ice
            activity: 0.18
            focusLevel: root.focusLevel
            phase: 0.37
            animate: root.animate
            opacity: root.shellOpacity

            Behavior on opacity {
                NumberAnimation {
                    duration: Motion.focusInMillis
                    easing.type: Easing.InOutSine
                }
            }
        }

        // The sub-swarms breathe together: one animation on this layer, 5.8 s
        // from Motion, 40 percent in and 60 percent out, 2 percent amplitude,
        // the same numbers the shell's shader uses. One animation, not one per
        // session, and nothing per frame in JS.
        Item {
            id: clusterLayer
            width: 0
            height: 0
            scale: 1.0

            SequentialAnimation {
                running: root.animate
                loops: Animation.Infinite
                NumberAnimation {
                    target: clusterLayer
                    property: "scale"
                    from: 1.0 - Motion.breathScale
                    to: 1.0 + Motion.breathScale
                    duration: Math.round(Motion.breathPeriod * 1000 * Motion.breathInhale)
                    easing.type: Easing.InOutSine
                }
                NumberAnimation {
                    target: clusterLayer
                    property: "scale"
                    from: 1.0 + Motion.breathScale
                    to: 1.0 - Motion.breathScale
                    duration: Math.round(Motion.breathPeriod * 1000 * Motion.breathExhale)
                    easing.type: Easing.InOutSine
                }
            }

            // One sub-swarm per open session.
            Repeater {
                model: root.sessionModel

                Item {
                    id: cluster
                    required property var modelData
                    required property int index

                    width: modelData.diameter
                    height: width
                    x: (root.selectedIndex === index ? 0 : modelData.ax) - width / 2
                    y: (root.selectedIndex === index ? 0 : modelData.ay) - height / 2
                    z: modelData.z * 10
                    scale: modelData.depthScale * root.clusterScale(index)
                    opacity: modelData.depthAlpha * root.clusterOpacity(index)

                    // Selection moves and grows on the expand curve, not on a
                    // SpringAnimation: see the state machine note above, the
                    // integrator diverges on a late frame.
                    Behavior on x {
                        NumberAnimation {
                            duration: Motion.expandMillis
                            easing.type: Easing.OutBack
                            easing.overshoot: 1.15
                        }
                    }
                    Behavior on y {
                        NumberAnimation {
                            duration: Motion.expandMillis
                            easing.type: Easing.OutBack
                            easing.overshoot: 1.15
                        }
                    }

                    Behavior on scale {
                        NumberAnimation {
                            duration: Motion.expandMillis
                            easing.type: Easing.OutBack
                            easing.overshoot: 1.15
                        }
                    }
                    Behavior on opacity {
                        NumberAnimation {
                            duration: Motion.textInMillis
                            easing.type: Easing.InOutSine
                        }
                    }

                    Repeater {
                        model: cluster.modelData.dots

                        Rectangle {
                            id: dot
                            required property var modelData

                            readonly property real dotSize: modelData.r * 2

                            width: dotSize
                            height: dotSize
                            radius: dotSize / 2
                            x: cluster.width / 2
                               + modelData.x * cluster.width * 0.5 * root.clusterInset
                               - dotSize / 2
                            y: cluster.height / 2
                               + modelData.y * cluster.height * 0.5 * root.clusterInset
                               - dotSize / 2
                            color: cluster.modelData.accent
                            opacity: modelData.a
                            antialiasing: true
                        }
                    }

                    // The bright core point per session (s2 3b). Acid while the
                    // session is streaming, the agent accent otherwise.
                    Rectangle {
                        anchors.centerIn: parent
                        readonly property real coreDiameter:
                            root.coreSize * (cluster.modelData.live ? 1.0 : 0.7)
                        width: coreDiameter
                        height: coreDiameter
                        radius: coreDiameter / 2
                        color: cluster.modelData.live ? Tokens.acid : cluster.modelData.accent
                        opacity: cluster.modelData.live ? 0.95 : 0.6
                        antialiasing: true
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: root.expanded
                        hoverEnabled: root.expanded
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.activateIndex(cluster.index)
                        onEntered: root.hoverIndex = cluster.index
                        onExited: {
                            if (root.hoverIndex === cluster.index)
                                root.hoverIndex = -1
                        }
                    }
                }
            }
        }
    }

    // ---- the text block --------------------------------------------------
    // Below the expanded orb, centred. Overflow past the item box is on purpose:
    // the item's footprint is the rest widget, the focus stage is larger and W7
    // Focus owns the dimming around it.
    Item {
        id: textStage
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.height / 2 + root.orbRadius + Tokens.sp2
        width: root.expandedOrbDiameter
        height: root.selectedIndex >= 0 ? detailBlock.height : listBlock.height
        opacity: root.textOpacity
        visible: opacity > 0.004

        Column {
            id: listBlock
            width: parent.width
            spacing: 0
            visible: root.selectedIndex < 0

            Repeater {
                model: root.sessionModel

                Item {
                    id: rowItem
                    required property var modelData
                    required property int index

                    width: listBlock.width
                    height: root.rowHeight

                    Row {
                        id: rowLine
                        anchors.fill: parent
                        spacing: Tokens.sp2

                        Rectangle {
                            width: root.rowDotSize
                            height: root.rowDotSize
                            radius: root.rowDotSize / 2
                            color: rowItem.modelData.accent
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                            width: rowLine.width - root.rowDotSize - Tokens.sp2
                            text: rowItem.modelData.title
                            color: root.hoverIndex === rowItem.index ? Tokens.ink : Tokens.textLabel
                            font.family: Tokens.fontFamily
                            font.pixelSize: Tokens.sizeCaption
                            font.weight: root.hoverIndex === rowItem.index
                                         ? Tokens.weightBold : Tokens.weightMedium
                            elide: Text.ElideRight
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.activateIndex(rowItem.index)
                        onEntered: root.hoverIndex = rowItem.index
                        onExited: {
                            if (root.hoverIndex === rowItem.index)
                                root.hoverIndex = -1
                        }
                    }
                }
            }
        }

        Column {
            id: detailBlock
            width: parent.width
            spacing: Tokens.sp1
            visible: root.selectedIndex >= 0

            Text {
                width: parent.width
                text: root.selectedSession ? root.selectedSession.title : ""
                color: Tokens.ink
                font.family: Tokens.fontFamily
                font.pixelSize: Tokens.sizeLabel
                font.weight: Tokens.weightMedium
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }

            Text {
                width: parent.width
                text: root.selectedSession
                      ? (root.selectedSession.agent.toUpperCase() + "  "
                         + root.selectedSession.state.toUpperCase())
                      : ""
                color: Tokens.textCaption
                font.family: Tokens.fontFamily
                font.pixelSize: Tokens.sizeCaption
                font.weight: Tokens.weightBold
                font.letterSpacing: Tokens.sizeCaption * Tokens.trackLabel
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
            }

            Text {
                width: parent.width
                visible: text !== ""
                text: root.selectedSession ? root.tokenText(root.selectedSession.tokens) : ""
                color: Tokens.ink
                font.family: Tokens.fontFamily
                font.pixelSize: Tokens.sizeTitle
                font.weight: Tokens.weightRegular
                horizontalAlignment: Text.AlignHCenter
            }

            Text {
                width: parent.width
                visible: text !== ""
                text: root.selectedSession ? root.selectedSession.activity : ""
                color: Tokens.textDim
                font.family: Tokens.fontFamily
                font.pixelSize: Tokens.sizeCaption
                font.weight: Tokens.weightRegular
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
            }
        }
    }

    // Clicking away from a sub-swarm returns to the list; a real "back".
    MouseArea {
        anchors.fill: parent
        enabled: root.expanded && root.selectedIndex >= 0
        onClicked: root.clearSelection()
        z: -1
    }
}
