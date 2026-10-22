import QtQuick
import NexusHud.V5 1.0

// IdleDrift.qml - the deck's ambient drift helper. Nothing on the deck is ever
// fully still: this applies a slow two-term sine wander to one item.
//
// Contract (W7): IdleDrift { target: Item; amplitude: real; period: real }.
// `amplitude` is in pixels (default Motion.driftAmpMax, 2 px), `period` is the
// primary term in seconds (default Motion.driftPeriodMax, 13 s). The second
// term runs at `period * Tokens.phi`, so the ratio of the two frequencies is
// the golden ratio - irrational - and the path never visibly repeats.
//
// The wander is applied as a Translate appended to `target.transform`, not to
// `target.x` / `target.y`: those may be bound or anchored, and a helper must
// never break the layout of the item it decorates. Transforms already on the
// target are preserved verbatim; at rest they are restored.
//
// Stopping: `enabled: false` fades the gain to zero on the Motion.return
// spring, then stops both phase animations, parks the phases at zero and
// restores the target's transform. There is no residue and no jump. No Timer
// and no per-frame JS: two looping NumberAnimations over phase, which is the
// ceiling the brief allows.
//
// `phase` (0..1, cycles) and `phaseSecondary` are readable so a future streaming
// layer (knot points travelling to a widget) can align to the same rhythm.
// `previewTime` >= 0 pins the phases to a given second for stills and traces.
Item {
    id: root

    // ---- contract --------------------------------------------------------
    property Item target: null
    property real amplitude: Motion.driftAmpMax
    property real period: Motion.driftPeriodMax
    // `enabled` is Item's own property: the contract's stop switch is the one
    // every Qt item already has, so there is no shadowing property here.

    // ---- rhythm ----------------------------------------------------------
    // cycles 0..1 added to both terms, so several ambient layers can be offset
    // without drifting in lockstep.
    property real phaseOffset: 0

    // ---- still/test hook -------------------------------------------------
    property real previewTime: -1

    // ---- state -----------------------------------------------------------
    property real _gain: 0
    property real _phaseA: 0
    property real _phaseB: 0
    property Item _attachedTarget: null
    property var _priorTransforms: []

    readonly property real secondaryPeriod: period * Tokens.phi
    readonly property real phase: previewTime >= 0
                                    ? wrapCycles(previewTime / period + phaseOffset)
                                    : wrapCycles(_phaseA / (2 * Math.PI) + phaseOffset)
    readonly property real phaseSecondary: previewTime >= 0
                                    ? wrapCycles(previewTime / secondaryPeriod + phaseOffset * Tokens.phi)
                                    : wrapCycles(_phaseB / (2 * Math.PI) + phaseOffset * Tokens.phi)
    readonly property real phaseRadians: phase * 2 * Math.PI

    // 0.62 / 0.38: the golden section split of the amplitude, so the two terms
    // carry unequal weight and the path is a Lissajous curve, not a circle.
    readonly property real primaryWeight: 0.62
    readonly property real secondaryWeight: 0.38

    readonly property real _phaseARad: previewTime >= 0
                                    ? previewTime / period * 2 * Math.PI : _phaseA
    readonly property real _phaseBRad: previewTime >= 0
                                    ? previewTime / secondaryPeriod * 2 * Math.PI : _phaseB
    readonly property real _gainNow: previewTime >= 0 ? (enabled ? 1 : 0) : _gain

    readonly property real dx: _gainNow <= 0 ? 0
        : amplitude * _gainNow
          * (primaryWeight * Math.sin(_phaseARad) + secondaryWeight * Math.sin(_phaseBRad))
    readonly property real dy: _gainNow <= 0 ? 0
        : amplitude * _gainNow
          * (primaryWeight * Math.sin(_phaseARad + 1.13) + secondaryWeight * Math.sin(_phaseBRad + 2.31))

    visible: false
    width: 0
    height: 0

    function wrapCycles(v) {
        return v - Math.floor(v)
    }

    // ---- the transform handed to the target ------------------------------
    Translate {
        id: drift
        x: root.dx
        y: root.dy
    }

    function attach() {
        if (!target || _attachedTarget === target)
            return
        detach()
        var prior = target.transform ? Array.prototype.slice.call(target.transform) : []
        _priorTransforms = prior
        var list = prior.slice()
        list.push(drift)
        target.transform = list
        _attachedTarget = target
    }

    function detach() {
        if (!_attachedTarget)
            return
        var list = _priorTransforms ? _priorTransforms.slice() : []
        _attachedTarget.transform = list
        _attachedTarget = null
        _priorTransforms = []
    }

    onTargetChanged: {
        detach()
        if (target && enabled)
            attach()
    }

    onEnabledChanged: {
        if (enabled) {
            attach()
            fadeOut.stop()
            fadeIn.start()
        } else {
            fadeIn.stop()
            fadeOut.start()
        }
    }

    Component.onCompleted: {
        if (target && enabled) {
            attach()
            _gain = 1
        }
    }

    Component.onDestruction: detach()

    // ---- phase animation (two terms, irrational ratio) -------------------
    NumberAnimation {
        id: phaseA
        target: root
        property: "_phaseA"
        from: 0
        to: 2 * Math.PI
        duration: root.period * 1000
        loops: Animation.Infinite
        running: root.enabled && root.previewTime < 0 && root._gain > 0.0001
    }

    NumberAnimation {
        id: phaseB
        target: root
        property: "_phaseB"
        from: 0
        to: 2 * Math.PI
        duration: root.secondaryPeriod * 1000
        loops: Animation.Infinite
        running: root.enabled && root.previewTime < 0 && root._gain > 0.0001
    }

    // ---- gain ------------------------------------------------------------
    NumberAnimation {
        id: fadeIn
        target: root
        property: "_gain"
        to: 1
        duration: Motion.expandMillis
        easing.type: Easing.OutBack
        easing.overshoot: 1.17
    }

    NumberAnimation {
        id: fadeOut
        target: root
        property: "_gain"
        to: 0
        duration: Motion.returnMillis
        easing.type: Easing.BezierSpline
        easing.bezierCurve: Motion.curveSoftOut
        onFinished: {
            if (root.enabled)
                return
            // Clean stop: no phase motion, no residual offset, target's own
            // transforms restored.
            root._phaseA = 0
            root._phaseB = 0
            root.detach()
        }
    }
}
