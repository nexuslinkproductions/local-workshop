import QtQuick
import "../../kit"

// I1 expand trace: the deck's expand/return curve, measured three ways so the
// peak does not depend on the offscreen frame clock.
//
//   QT_QPA_PLATFORM=offscreen qml -I <imports> nexuslink.hud/v5/tests/i1/CrewExpandTrace.qml
//   TRACE {...}
//
// Why not one way:
//   * frame    the real CrewOrb at the deck's size (224) and tokens, sampled on
//              the probe's 4 ms timer. Honest evidence that the deck's own
//              transition runs, but the offscreen animation frame clock here is
//              25 to 100 ms (measured: spacing of consecutive distinct `growth`
//              values), and one 347 ms curve's vertex is a ~10 ms feature. A
//              frame sample lands anywhere from 0 to half a tick from the
//              vertex and therefore under-reads by 0 to 3 pp: that is the
//              sampling artefact the V3 pass found (raw peaks 1.2 to 4.9
//              percent on the same curve), not motion.
//   * stretch  the SAME easing, read off the live object that moves the orb
//              (transitions[0].animations[0], instantiated by Qt on the first
//              state change) and re-run on the probe's own property over
//              `stretch` x the duration. An easing curve's peak VALUE does not
//              depend on its duration: stretching multiplies every sample time
//              and leaves every value alone, so a ~45 ms frame becomes 4.5 ms
//              on the deck's own 347 ms timeline.
//   * analytic the same easing parameters evaluated in 0.05 ms steps, i.e. the
//              closed form of the curve Qt runs, with no clock in it at all.
// tools/deck-trace.py reports the stretch and analytic numbers per run and uses
// the frame samples as a bound in both directions (nothing measured on the deck
// may sit above the curve's own maximum).
//
// The deck's numbers, unchanged: size 224 (DeckSurface.crewSize), three sessions
// from v5/fixtures/sessions.json, animate on.
Item {
    id: probe

    width: 400
    height: 400

    // ---- timeline, ms from the probe's first sample ----------------------
    readonly property int expandAt: 200
    readonly property int stretchAt: 700      // after Qt has built the transition
    readonly property int returnAt: 1000
    readonly property int stopAt: 4600        // stretch run ends at 700 + 3470

    // Peak value is duration-invariant, so 10x is a pure time reparametrisation.
    readonly property int stretch: 10

    property double t0: 0
    property bool expanded: false
    property bool returned: false
    property bool stretched: false
    property real restGrowth: 1.0
    property var samples: []

    // ---- the deck's own transition, read off the running component --------
    // Qt instantiates a Transition's animations on the first state change, so
    // from then on transitions[0].animations[0] is the object that moves
    // `growth`. Duration, easing type and the OutBack parameter come from
    // there, not from a copy in this file.
    property var liveAnimation: null
    property int liveDuration: 0
    property int liveEasingType: -1
    property real liveOvershoot: 0
    property string liveError: ""
    property var stretchSetup: ({})

    property real slowGrowth: 1.0

    CrewOrb {
        id: orb

        size: 224
        x: (probe.width - size) / 2
        y: 40
        sessions: [
            { "id": "a01748", "model": "sonnet-5-5", "idle_s": 32, "title": "Draft vari8-beta issues for the crew" },
            { "id": "a1d052", "model": "sonnet-5-5", "idle_s": 20, "title": "Enable operator-mode" },
            { "id": "683c2c", "parent": "a1d052", "model": "sonnet-5-5", "idle_s": 17,
              "title": "Composition study s1: widget-and-icon-first HUD" }
        ]
        animate: true
    }

    // The stretched copy. Every parameter that matters is written from the live
    // transition in startStretch(), and stretchSetup below records whether the
    // copy really carries them, so a drift between this animation and the
    // deck's shows up in the trace instead of hiding in it.
    NumberAnimation {
        id: slowGrow

        target: probe
        property: "slowGrowth"
        duration: 3470
        easing.type: Easing.OutBack
        easing.overshoot: 1.15
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
            probe.restGrowth = orb.growth
            return
        }
        var t = now - probe.t0
        if (t > probe.stopAt) {
            probe.dump()
            Qt.exit(0)
            return
        }
        probe.samples.push({ "t": t, "g": orb.growth, "s": probe.slowGrowth })

        if (!probe.expanded && t >= probe.expandAt) {
            probe.expanded = true
            orb.expanded = true
        }
        if (!probe.stretched && t >= probe.stretchAt) {
            probe.stretched = true
            probe.startStretch()
        }
        if (!probe.returned && t >= probe.returnAt) {
            probe.returned = true
            orb.expanded = false
        }
    }

    function startStretch() {
        var an = null
        var setup = { "ok": false }
        try {
            an = orb.transitions[0].animations[0]
            probe.liveAnimation = an
            probe.liveDuration = an.duration
            probe.liveEasingType = an.easing.type
            probe.liveOvershoot = an.easing.overshoot
        } catch (e) {
            probe.liveError = String(e)
            probe.stretchSetup = setup
            return
        }
        slowGrow.from = probe.restGrowth
        slowGrow.to = orb.expandScale
        slowGrow.duration = probe.liveDuration * probe.stretch
        slowGrow.easing.type = an.easing.type
        slowGrow.easing.overshoot = an.easing.overshoot
        slowGrow.start()
        setup = {
            "ok": slowGrow.duration === probe.liveDuration * probe.stretch
                  && slowGrow.easing.type === an.easing.type
                  && Math.abs(slowGrow.easing.overshoot - an.easing.overshoot) < 1e-9
                  && Math.abs(slowGrow.from - probe.restGrowth) < 1e-9
                  && Math.abs(slowGrow.to - orb.expandScale) < 1e-9,
            "from": slowGrow.from,
            "to": slowGrow.to,
            "duration": slowGrow.duration,
            "easingType": slowGrow.easing.type,
            "overshoot": slowGrow.easing.overshoot
        }
        probe.stretchSetup = setup
    }

    // Qt's OutBack: value(t) = 1 + (c + 1)(t - 1)^3 + c(t - 1)^2 for t in 0..1,
    // with c = easing.overshoot. Peak of the curve, in fraction-of-travel terms.
    function outBack(t, c) {
        var u = t - 1.0
        return 1.0 + (c + 1.0) * u * u * u + c * u * u
    }

    function easeName(type) {
        if (type === Easing.OutBack)
            return "OutBack"
        if (type === Easing.OutCubic)
            return "OutCubic"
        return String(type)
    }

    // The curve evaluated on its own timeline, no frame clock involved.
    function analyse() {
        if (probe.liveDuration <= 0 || probe.liveEasingType !== Easing.OutBack) {
            return { "error": "live easing is not OutBack (type " + probe.liveEasingType
                              + "), no closed form in this probe" }
        }
        var c = probe.liveOvershoot
        var step = 0.05
        var peak = -1e9
        var peakAt = 0
        for (var ms = 0; ms <= probe.liveDuration + 1e-9; ms += step) {
            var v = probe.outBack(ms / probe.liveDuration, c)
            if (v > peak) {
                peak = v
                peakAt = ms
            }
        }
        return {
            "stepMs": step,
            "easingType": probe.liveEasingType,
            "easingName": probe.easeName(probe.liveEasingType),
            "overshoot": c,
            "endValue": probe.outBack(1.0, c),
            "peakFraction": peak,
            "peakAtMs": peakAt,
            "peakGrowth": probe.restGrowth + (orb.expandScale - probe.restGrowth) * peak,
            "overshootPct": (peak - 1.0) * 100.0
        }
    }

    function dump() {
        console.log("TRACE " + JSON.stringify({
            "label": "crew-expand",
            "expandMillisToken": Motion.expandMillis,
            "returnMillisToken": Motion.returnMillis,
            "expandOvershootToken": Motion.expandOvershoot,
            "expandScale": orb.expandScale,
            "restGrowth": probe.restGrowth,
            "returnAtMs": probe.returnAt,
            "stretchAtMs": probe.stretchAt,
            "stretchFactor": probe.stretch,
            "animation": {
                "source": "CrewOrb.transitions[0].animations[0]",
                "duration": probe.liveDuration,
                "easingType": probe.liveEasingType,
                "easingName": probe.easeName(probe.liveEasingType),
                "overshoot": probe.liveOvershoot,
                "property": probe.liveAnimation ? probe.liveAnimation.property : "",
                "error": probe.liveError
            },
            "stretchSetup": probe.stretchSetup,
            "slowEnd": probe.slowGrowth,
            "analytic": probe.analyse(),
            "samples": probe.samples
        }))
    }
}
