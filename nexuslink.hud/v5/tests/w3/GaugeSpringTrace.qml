import QtQuick
import "../../kit"

// qmllint disable unqualified missing-property
// The subject component is chosen at runtime from Qt.application.arguments, so
// `probe` is read from inside Component scopes and the animated value comes back
// from a JS-selected object: both are correct at runtime and outside what
// qmllint can type. This is a probe, not shipped UI; every other new file in
// this branch is warning-free, so tools/qml-lint.sh stays at its base count.

// W3 gauge motion probe: the value PulseRing, DotArc, DotBar and IconTile
// animate on a focus / selection change, sampled offscreen.
//
// Why this exists: all four handed Qt 6.12's SpringAnimation the analytic pair
// (spring = expandOmega^2 = 278.89, damping = 2 * expandZeta * omega = 23.05).
// Qt 6.12 clamps `damping` to [0, 1] and applies the spring term without a dt
// factor, so 23.05 becomes 1.0 and the response is a barely damped explicit
// Euler spring that diverges on the first change of the input. Numbers, closed
// form and the stalled frame: docs/w3-gauges-spring.md, tool:
// tools/w3-gauge-spring-trace.py.
//
// Run one probe:
//
//   QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH=<NexusHud/V5 symlink> \
//       qml -I <imports> tests/w3/GaugeSpringTrace.qml \
//       -- --component=pulsering --channel=scale --mode=expand --stall=0
//
// Flags reach QML through Qt.application.arguments: the `--` separator is what
// keeps them out of the file list (without it the runtime tries to load
// `--mode=expand` as a second QML file). tools/w3-gauge-spring-trace.py runs
// every combination and judges the bands.
//
// The number under the probe is the shipped component's own: the first child
// item's `scale` for the three gauges (the item the old SpringAnimation sat on)
// and the tile's own `scale` / `opacity`. That is why this probe also runs
// against the pre-repair components, which published no property at all.
Item {
    id: probe

    readonly property var argv: Qt.application.arguments

    function arg(name, fallback) {
        var prefix = "--" + name + "="
        for (var i = 0; i < probe.argv.length; i++)
            if (probe.argv[i].indexOf(prefix) === 0)
                return probe.argv[i].substring(prefix.length)
        return fallback
    }

    // pulsering | dotarc | dotbar | icontile
    readonly property string component: probe.arg("component", "pulsering")
    // scale | dim. Only IconTile has two channels: `selected` scales the tile,
    // `focusLevel` fades it. The three gauges only have the focus lift.
    readonly property string channel: probe.arg("channel", "scale")
    // expand (rest -> lifted) | return (lifted -> rest)
    readonly property string mode: probe.arg("mode", "expand")
    // Milliseconds the event loop is blocked right at the trigger: the late
    // frame the old spring diverged on with no late frame needed at all.
    readonly property int stallMs: parseInt(probe.arg("stall", "0"), 10)

    // A return has to start from the lifted value with the animation already
    // settled, so it ramps up first and comes back down at triggerAtMs.
    readonly property int triggerAtMs: probe.mode === "return" ? 700 : 200
    readonly property int rampAtMs: 100
    readonly property int stopAtMs: probe.mode === "return" ? 1800 : 1400

    width: 600
    height: 600

    property double t0: 0
    property bool started: false
    property bool triggered: false
    property bool stalled: false
    property var samples: []
    property int stalledAtMs: -1

    readonly property bool wantsLifted: probe.mode === "return"
                                           ? (probe.started && !probe.triggered)
                                           : probe.triggered

    // ---- the four subjects ------------------------------------------------
    // Sizes are the deck's own: mac size 156 px (PulseRing), deep-view arcs at
    // 144 to 216 px, the storage bar at 360 px of 12 segments, the tile at 96.
    Loader {
        id: subject

        anchors.centerIn: parent
        sourceComponent: probe.component === "pulsering" ? pulseRing
                       : probe.component === "dotarc" ? dotArc
                       : probe.component === "dotbar" ? dotBar
                       : iconTile
    }

    Component {
        id: pulseRing

        PulseRing {
            size: Tokens.pulseRingSize
            value: 7.5                 // v5/fixtures/link.json rtt.median
            accent: Tokens.ice
            focusLevel: probe.wantsLifted ? 1 : 0
        }
    }

    Component {
        id: dotArc

        DotArc {
            size: Tokens.dotArcSize
            level: 1.0                 // link.json mac.batt
            accent: Tokens.acid
            focusLevel: probe.wantsLifted ? 1 : 0
        }
    }

    Component {
        id: dotBar

        DotBar {
            size: Tokens.dotBarSize
            segments: Tokens.dotBarSegments
            level: 0.76                // metrics.json host.load1_frac
            accent: Tokens.azure
            focusLevel: probe.wantsLifted ? 1 : 0
        }
    }

    Component {
        id: iconTile

        IconTile {
            size: 96                    // the deck's tile size in the W4 sheet
            glyph: "hermes"
            label: "Hermes"
            launchCount: 3
            selected: probe.channel === "scale" && probe.wantsLifted
            focusLevel: probe.channel === "dim" && probe.wantsLifted ? 1 : 0
        }
    }

    // ---- the measured value ----------------------------------------------
    // The gauges animate their first child item (art / bar); IconTile animates
    // its own scale and opacity.
    function value() {
        var s = subject.item
        if (!s)
            return NaN
        if (probe.component === "icontile")
            return probe.channel === "dim" ? s.opacity : s.scale
        return s.children[0].scale
    }

    // The two endpoints the run animates between, from the component's own
    // parameters, so the tool never scores against a copied number.
    readonly property real restValue: 1.0
    readonly property real liftedValue: {
        var s = subject.item
        if (!s)
            return 1.0
        if (probe.component === "icontile")
            return probe.channel === "dim" ? Tokens.focusDimMax : s.selectedScale
        return 1 + s.focusLift
    }
    readonly property real fromValue: probe.mode === "return" ? probe.liftedValue : probe.restValue
    readonly property real toValue: probe.mode === "return" ? probe.restValue : probe.liftedValue

    Timer {
        interval: 4
        repeat: true
        running: true

        onTriggered: probe.sample()
    }

    function sample() {
        var now = Date.now()
        if (probe.t0 === 0) {
            probe.t0 = now
            return
        }
        var t = now - probe.t0
        probe.samples.push({ "t": t, "v": probe.value() })

        if (!probe.started && t >= probe.rampAtMs)
            probe.started = true

        if (!probe.triggered && t >= probe.triggerAtMs) {
            probe.triggered = true
            probe.stalledAtMs = t
            if (probe.stallMs > 0) {
                // A late frame: the event loop is blocked, so the animation
                // driver jumps its clock by the whole stall on the next tick.
                var until = Date.now() + probe.stallMs
                while (Date.now() < until) { /* deliberate stall */ }
            }
        }
        if (t > probe.stopAtMs) {
            probe.dump()
            Qt.exit(0)
        }
    }

    function dump() {
        var s = subject.item
        console.log("TRACE " + JSON.stringify({
            "label": "w3-" + probe.component + "-" + probe.channel + "-" + probe.mode
                     + (probe.stallMs > 0 ? "-stall" + probe.stallMs : ""),
            "component": probe.component,
            "channel": probe.channel,
            "mode": probe.mode,
            "stallMs": probe.stallMs,
            "rampAtMs": probe.rampAtMs,
            "triggerAtMs": probe.triggerAtMs,
            "stalledAtMs": probe.stalledAtMs,
            "sizePx": s ? s.size : 0,
            "focusLift": s && s.focusLift !== undefined ? s.focusLift : 0,
            "selectedScale": s && s.selectedScale !== undefined ? s.selectedScale : 0,
            "focusDimMax": Tokens.focusDimMax,
            "expandBackOvershoot": s && s.expandBackOvershoot !== undefined
                                   ? s.expandBackOvershoot : 0,
            "expandMillis": Motion.expandMillis,
            "returnMillis": Motion.returnMillis,
            "fromValue": probe.fromValue,
            "toValue": probe.toValue,
            "samples": probe.samples
        }))
    }
}
