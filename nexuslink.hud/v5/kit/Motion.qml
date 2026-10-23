pragma Singleton

import QtQuick

// Motion.qml - v5 deck motion tokens. Numbers only: no Animation, no Behavior,
// no Timer, no JS. A component builds the animation and reads its numbers here.
//
// Source: hud-candidates/motion-r1/motion.json (the analysed motion study) plus
// the spring constants the plan approves: expand with 4 to 6 percent overshoot,
// a slower return with none, stagger 30 to 60 ms, breath 5 to 6 s at 40/60.
// Every value below is traceable to that file unless a comment says otherwise.
QtObject {
    id: motion

    // ---- springs ---------------------------------------------------------
    // Second order: zeta = damping ratio, omega = natural frequency (rad/s).
    // A deck component turns these into its own spring, e.g.
    //   zeta: Motion.expandZeta, omega: Motion.expandOmega
    readonly property real expandZeta: 0.69
    readonly property real expandOmega: 16.7
    // Overshoot = exp(-zeta * pi / sqrt(1 - zeta^2)) = 0.0500, so 5.00 percent.
    readonly property real expandOvershoot: 0.05
    // 4 / (zeta * omega) = 347 ms to settle inside 2 percent.
    readonly property int expandMillis: 347

    readonly property real returnZeta: 1.0
    readonly property real returnOmega: 9.0
    readonly property real returnOvershoot: 0.0
    // 4 / (zeta * omega) = 444 ms. Slower than expand, no overshoot.
    readonly property int returnMillis: 444

    // ---- stagger ---------------------------------------------------------
    // motion.json staggers 22 to 45 ms. 22 is under the approved band, so the
    // deck's tight step is clamped to 30. Use 30 to 60 only.
    readonly property int staggerMin: 30
    readonly property int staggerMax: 60
    readonly property int stagger: 45
    readonly property int staggerTight: 30

    // ---- breath (knot and crew orb) -------------------------------------
    // One slow cycle, 40 percent inhale and 60 percent exhale.
    readonly property real breathPeriod: 5.8
    readonly property real breathInhale: 0.4
    readonly property real breathExhale: 0.6
    readonly property real breathScale: 0.02
    readonly property real breathBright: 0.14
    readonly property real breathDensity: 0.25
    readonly property real breathLobePhase: 0.12
    // Focused stage breathes slower and shallower.
    readonly property real focusBreathPeriod: 8.5
    readonly property real focusBreathAmp: 0.6

    // ---- idle drift ------------------------------------------------------
    // Nothing on the deck is ever fully still.
    readonly property real driftAmpMin: 1.0
    readonly property real driftAmpMax: 2.0
    readonly property real driftPeriodMin: 7.0
    readonly property real driftPeriodMax: 13.0
    readonly property real driftHeldScale: 0.5
    readonly property real glowDepth: 0.025
    readonly property real glowPeriodMin: 6.0
    readonly property real glowPeriodMax: 10.0

    // ---- named roles -----------------------------------------------------
    // Durations in ms, delays in ms, slip in px. Read by the component that
    // owns the role; the singleton stays data.
    readonly property int yieldMillis: 420
    readonly property int yieldStagger: 45
    readonly property int yieldReturnMillis: 640
    readonly property int yieldReturnStagger: 45
    readonly property int bodyInMillis: 460
    readonly property int bodyInDelay: 140
    readonly property int bodyInStagger: 45
    readonly property int bodyInSlip: 12
    readonly property int bodyOutMillis: 200
    readonly property int bodyOutStagger: 40
    readonly property int bodyOutSlip: -12
    readonly property int textInMillis: 340
    readonly property int textInDelay: 120
    readonly property int textInStagger: 35
    readonly property int textOutMillis: 140
    readonly property int focusInMillis: 420
    readonly property int focusOutMillis: 600
    readonly property int focusReturnDelay: 120
    readonly property int scrimMillis: 350
    readonly property int scrimStagger: 0
    readonly property int stageInMillis: 550
    readonly property int stageOutMillis: 340
    readonly property int knotRecedeMillis: 900
    readonly property real knotRecedeScale: 0.94
    readonly property real knotRecedeOpacity: 0.45
    readonly property real focusScale: 0.965

    // ---- curves ----------------------------------------------------------
    // Cubic bezier control points [x1, y1, x2, y2], for consumers that cannot
    // take a spring (CSS-like easing, shader time remap).
    readonly property var curveInOut: [0.65, 0.0, 0.35, 1.0]
    readonly property var curveSoftOut: [0.3, 0.05, 0.15, 1.0]
    readonly property var curveDepth: [0.16, 1.0, 0.3, 1.0]
    readonly property var curvePanel: [0.22, 0.61, 0.36, 1.0]
    readonly property var curveAccel: [0.4, 0.0, 0.7, 0.2]
    readonly property var curves: ({
        "inOut": [0.65, 0.0, 0.35, 1.0],
        "softOut": [0.3, 0.05, 0.15, 1.0],
        "depth": [0.16, 1.0, 0.3, 1.0],
        "panel": [0.22, 0.61, 0.36, 1.0],
        "accel": [0.4, 0.0, 0.7, 0.2]
    })

    // ---- perspective -----------------------------------------------------
    // stageIn entry box from motion.json: the stage arrives from the lower left
    // and slightly back, then settles.
    readonly property int perspective: 1200
    readonly property real stageFromX: -35
    readonly property real stageFromY: 18
    readonly property real stageFromZ: -130
    readonly property real stageFromRotateY: -7
    readonly property real stageFromScale: 0.94
    readonly property real stageScale: 1.1
    readonly property real stageShiftX: -40
    readonly property real stageShiftY: -48

    // ---- proximity field (round 2, P1) -----------------------------------
    // Pointer-driven growth around the widgets, independent of hover.
    // d is the pointer distance to a widget centre, R = 0.5 * hypot(w, h).
    // proximity is 0 at proximityNearRadius * R and 1 at proximityFarRadius * R.
    readonly property real proximityNearRadius: 1.2
    readonly property real proximityFarRadius: 0.4
    // Neighbour push: 24 px at a fully grown neighbour, gaussian falloff.
    readonly property real proximityPushMax: 24.0
    readonly property real proximityPushSigma: 380.0

    // Grow spring. Qt's SpringAnimation normalises its constants, so these are
    // Qt units calibrated by measurement (work2/P1/cal.txt), not omega^2:
    //   spring 3.0 / damping 0.24 measured 10.48 pct overshoot, 392 ms settle.
    //   damping 0.271 is scaled for zeta 0.69 -> 5 pct, about 350 ms.
    readonly property real growSpring: 3.86
    readonly property real growDamping: 0.321
    // Return: zeta 1.0 at the same 9 / 16.7 frequency ratio as before, no
    // overshoot and about 444 ms.
    readonly property real growReturnSpring: 2.18
    readonly property real growReturnDamping: 0.349
    // Spring rest threshold. 8e-4 of a 0 to 1 move is under 0.1 px of scale.
    readonly property real growEpsilon: 0.0008
    // Push offsets use a damped spring (zeta about 1.3) so an offset never wobbles.
    readonly property real pushSpring: 3.86
    readonly property real pushDamping: 0.42
}
