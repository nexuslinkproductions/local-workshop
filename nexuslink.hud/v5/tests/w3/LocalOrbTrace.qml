import QtQuick
import "../../kit"

// W3 trace harness: LocalOrb's sphere-field scale, sampled offscreen.
//
// Run one of the four thin entry points next to this file, which set the two
// properties below (they exist because `qml` loads every positional argument as
// a file, so a --mode=... flag would be an error, not a parameter):
//
//   tests/w3/trace-expand.qml          activity 0 -> 1, the deck's 8 percent lift
//   tests/w3/trace-expand-stall150.qml the same, with a 150 ms blocked frame
//   tests/w3/trace-return.qml          activity 1 -> 0, back to rest
//   tests/w3/trace-focus.qml           focusLevel 0 -> 1, the 4 percent lift
//
//   QT_QPA_PLATFORM=offscreen QML_IMPORT_PATH=<imports> qml -I <imports> \
//       nexuslink.hud/v5/tests/w3/trace-expand.qml
//   (tools/w3-localorb-trace.py does this for all four and judges the bands)
//
// Prints one `TRACE {...}` line with (t_ms, fieldScale) pairs and the
// component's own motion parameters, the same shape tests/i1/CrewExpandTrace.qml
// uses and tools/deck-trace.py parses. The values come from LocalOrb.fieldScale,
// so the trace is of the shipped component at the deck's own size
// (DeckSurface.localDeep composes it at 200 px), not a copy of it.
//
// Component-level on purpose: DeckSurface's scene starves a sampler to a ~100 ms
// grid during a state change (measured by I1), and the expand peak is one
// instant of a 347 ms curve, so a deck-level capture misses it.
Item {
    id: probe

    // "expand", "return" or "focus".
    property string mode: "expand"
    // Milliseconds the event loop is blocked right after the trigger: a frame
    // that arrives late, the case the old SpringAnimation diverged on.
    property int stallMs: 0

    // A return has to start from the lifted value with the animation already
    // settled, so it ramps up first and comes back down at `triggerAtMs`.
    readonly property int triggerAtMs: mode === "return" ? 700 : 200
    readonly property int rampAtMs: 100
    readonly property int stopAtMs: mode === "return" ? 1800 : 1400

    width: 400
    height: 400

    property double t0: 0
    property bool started: false
    property bool triggered: false
    property var samples: []
    property int stalledAtMs: -1

    LocalOrb {
        id: orb

        x: (probe.width - width) / 2
        y: (probe.height - height) / 2

        // The deck's local deep view: 200 px, fixtures/modelGb 0.33.
        size: 200
        sizeGb: 0.33
        accent: Tokens.acid
        activity: probe.mode === "return"
                  ? (probe.triggered ? 0 : (probe.started ? 1 : 0))
                  : (probe.mode === "expand" && probe.triggered ? 1 : 0)
        focusLevel: probe.mode === "focus" ? (probe.triggered ? 1 : 0) : 0
    }

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
        probe.samples.push({ "t": t, "v": orb.fieldScale })

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
        // The component publishes its own motion parameters, so the closed-form
        // column in tools/w3-localorb-trace.py is computed from the QML that
        // actually ran, not from a number copied into the tool.
        console.log("TRACE " + JSON.stringify({
            "label": "w3-localorb-" + probe.mode + (probe.stallMs > 0 ? "-stall" + probe.stallMs : ""),
            "mode": probe.mode,
            "stallMs": probe.stallMs,
            "rampAtMs": probe.rampAtMs,
            "triggerAtMs": probe.triggerAtMs,
            "stalledAtMs": probe.stalledAtMs,
            "sizePx": orb.size,
            "sizeGb": orb.sizeGb,
            "activityLift": orb.activityLift,
            "focusLift": orb.focusLift,
            "expandOvershoot": orb.expandOvershoot,
            "expandMillis": Motion.expandMillis,
            "returnMillis": Motion.returnMillis,
            "samples": probe.samples
        }))
    }
}
