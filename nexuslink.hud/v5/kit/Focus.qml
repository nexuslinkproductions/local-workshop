import QtQuick
import QtQuick.Effects
import NexusHud.V5 1.0

// Focus.qml - the deck's focus environment. While `active`, everything inside
// the component that is not the `targetRect` is dimmed, scrimmed and softly
// blurred; the target rect itself stays crisp. When the focus ends it springs
// back. Numbers come from Tokens (dim 0.26 in the 0.18 to 0.3 band, scrim 0.35,
// blur 10 px in the 8 to 12 band) and durations from Motion.
//
// Contract (W7): Focus { active: bool; targetRect: rect; content: Item }.
// `targetRect` is in this item's coordinates and may be any size: a 112 px
// hero widget or a large expanded card near the centre. The API does not care.
//
// How it dims, and what it never touches:
//   The content is captured once into `snap` (ShaderEffectSource,
//   hideSource). One MultiEffect copy is blurred and drawn at Tokens.focusDim
//   opacity with a Tokens.focusScrim black colorization, so only the pixels the
//   HUD content actually covers get dimmed - the desktop visible through the
//   panel is untouched, because the effect's alpha is the content's alpha. A
//   second ShaderEffectSource crops the same snapshot to `targetRect` and draws
//   it at full opacity on top, which is the crisp focal area.
//
// Why no mask: Qt 6.12's MultiEffect maskInverted is meant to punch exactly this
// hole, but it is not honoured on the offscreen RHI path this project renders
// with (measured: maskInverted true produces the full effect everywhere, see
// docs/w7-motion.md). The crisp crop on top is the measurable equivalent and
// needs no shader regeneration. Inside the focal rect, transparent parts of the
// content show the dimmed blurred copy underneath, which reads as depth of
// field (as in s2-crew-focus.png), not as a box.
//
// `previewProgress` is a still-render hook: -1 lets the animation drive the
// transition, 0..1 pins it for an offscreen still. The integrator does not set
// it.
Item {
    id: root

    // ---- contract --------------------------------------------------------
    property bool active: false
    property rect targetRect: Qt.rect(0, 0, 0, 0)
    property Item content: null

    // ---- still/test hook -------------------------------------------------
    property real previewProgress: -1

    // ---- state -----------------------------------------------------------
    property real _step: 0
    readonly property real progress: previewProgress >= 0
                                      ? Math.max(0, Math.min(1, previewProgress))
                                      : Math.max(0, Math.min(1, _step))
    readonly property real springProgress: previewProgress >= 0 ? previewProgress : _step
    readonly property bool effectsVisible: progress > 0.0001

    // ---- effect numbers (all from Tokens) --------------------------------
    readonly property real dimAmount: Tokens.focusDim            // 0.26, band .18-.30
    readonly property real scrimAmount: Tokens.focusScrim        // 0.35
    readonly property real blurPixels: Tokens.focusBlur          // 10, band 8-12
    readonly property int blurMaxPixels: 32
    readonly property real blurAmount: Math.min(1.0, blurPixels / blurMaxPixels) * progress

    implicitWidth: 0
    implicitHeight: 0

    // ---- content stage ---------------------------------------------------
    Item {
        id: stage
        anchors.fill: parent
    }

    // One capture of the HUD content, shared by the dim copy and the crop.
    ShaderEffectSource {
        id: snap
        sourceItem: stage
        hideSource: root.effectsVisible
        live: true
        visible: false
        width: stage.width
        height: stage.height
    }

    // Blurred, dimmed and scrimmed copy of the whole content.
    MultiEffect {
        id: dimLayer
        anchors.fill: parent
        source: snap
        visible: root.effectsVisible
        opacity: root.dimAmount * root.progress
        colorization: root.scrimAmount * root.progress
        colorizationColor: "#000000"
        blurEnabled: true
        blurMax: root.blurMaxPixels
        blur: root.blurAmount
        autoPaddingEnabled: false
    }

    // The focal area, crisp, cropped straight out of the same snapshot.
    ShaderEffectSource {
        id: focal
        sourceItem: snap
        live: true
        visible: root.effectsVisible && root.targetRect.width > 0 && root.targetRect.height > 0
        x: root.targetRect.x
        y: root.targetRect.y
        width: Math.max(1, root.targetRect.width)
        height: Math.max(1, root.targetRect.height)
        sourceRect: {
            var x = Math.max(0, Math.min(root.targetRect.x, stage.width - 1))
            var y = Math.max(0, Math.min(root.targetRect.y, stage.height - 1))
            var w = Math.max(1, Math.min(root.targetRect.width, stage.width - x))
            var h = Math.max(1, Math.min(root.targetRect.height, stage.height - y))
            return Qt.rect(x, y, w, h)
        }
    }

    // ---- transitions -----------------------------------------------------
    // Springs in and out, never a linear fade. Qt 6.12's SpringAnimation is
    // numerically stable only well below the stiffness Motion specifies for a
    // 347 ms settle (measured: k = omega^2 = 279 diverges), so the expand is
    // run as the closed-form equivalent: Motion.expandMillis with a 5 percent
    // OutBack overshoot. The return keeps Motion.returnMillis and the
    // Motion.curveSoftOut bezier, which is monotone and slower.
    NumberAnimation {
        id: focusIn
        target: root
        property: "_step"
        to: 1
        duration: Motion.expandMillis
        easing.type: Easing.OutBack
        easing.overshoot: 1.17          // peak = 1 + 0.05, per Motion.expandOvershoot
    }

    NumberAnimation {
        id: focusOut
        target: root
        property: "_step"
        to: 0
        duration: Motion.returnMillis
        easing.type: Easing.BezierSpline
        easing.bezierCurve: Motion.curveSoftOut
    }

    onActiveChanged: {
        if (previewProgress >= 0)
            return
        if (active) {
            focusOut.stop()
            focusIn.start()
        } else {
            focusIn.stop()
            focusOut.start()
        }
    }

    // ---- content adoption ------------------------------------------------
    // The item assigned to `content` was created as a child of Focus; move it
    // under `stage` so the capture sees exactly the HUD content and nothing
    // else. Geometry is left alone: stage fills Focus, so anchors resolve the
    // same way.
    function adoptContent() {
        if (content && content.parent !== stage)
            content.parent = stage
    }

    onContentChanged: adoptContent()
    Component.onCompleted: adoptContent()
}
