import QtQuick
import QtQuick.Effects
import "../kit"

// FocusDim.qml - dim, soften and pull back HUD content while a focus view opens.
//
// WHAT IT IS
// Wrap the deck's HUD content in FocusDim and put the expanded Crew or Storage
// panel (or the Find results) OUTSIDE it. While active the wrapped content dims
// to Tokens.focusDim, gains a Tokens.focusBlur px MultiEffect blur, scales to
// Motion.focusScale and sits under a Tokens.focusScrim black scrim. The deck
// keeps Tokens.field and the panel outside, so neither is dimmed or blurred.
// MOTION
// In: Motion.focusInMillis with an out curve. Scrim: Motion.scrimMillis.
// Out: Motion.focusOutMillis with InOutQuad, no overshoot.
// COST
// At rest (and once the return animation has settled) there is no layer, no
// MultiEffect and no scrim: a single visible Item. Nothing runs while idle.
// The blur is GPU only. Software offscreen renders show dim, scale and scrim
// but not the MultiEffect blur; grade the blur with tools/linux/v5-shot.sh.
// ASCII only. Pure QtQuick plus the kit singletons.
Item {
    id: root

    // ---- inputs ----------------------------------------------------------
    property bool active: false

    // ---- content ---------------------------------------------------------
    // Children declared inside FocusDim are the HUD content that dims.
    default property alias content: holder.data

    // 0 at rest, 1 fully focused. Animated, never set from outside.
    property real dimAmount: active ? 1 : 0

    // True while the layer and the MultiEffect have to exist: active, or
    // still returning. Outside this window both are off (zero cost).
    readonly property bool liveLayer: root.active || root.dimAmount > 0.0005

    // The software scene graph cannot run MultiEffect; there the dim, scale
    // and scrim still land and the content stays visible (used for stills).
    readonly property bool shaderBackend: GraphicsInfo.api !== GraphicsInfo.Software

    // The scrim follows the same clock family but has its own duration.
    property real scrim: active ? 1 : 0

    Behavior on dimAmount {
        NumberAnimation {
            duration: root.active ? Motion.focusInMillis : Motion.focusOutMillis
            easing.type: root.active ? Easing.OutCubic : Easing.InOutQuad
            easing.overshoot: 1.0
        }
    }

    Behavior on scrim {
        NumberAnimation {
            duration: root.active ? Motion.scrimMillis : Motion.focusOutMillis
            easing.type: root.active ? Easing.OutCubic : Easing.InOutQuad
            easing.overshoot: 1.0
        }
    }

    // ---- the content, pulled back and dimmed -----------------------------
    Item {
        id: stage
        objectName: "focusStage"
        anchors.fill: parent
        transformOrigin: Item.Center
        scale: 1 - (1 - Motion.focusScale) * root.dimAmount
        opacity: 1 - (1 - Tokens.focusDim) * root.dimAmount
        // The texture is only forced while the effect needs it.
        layer.enabled: root.liveLayer && root.shaderBackend
        layer.smooth: true
        visible: !root.shaderBackend || !blur.visible

        Item {
            id: holder
            anchors.fill: parent
        }
    }

    // ---- the blur --------------------------------------------------------
    // blurMax 32 is the unit MultiEffect works in; Tokens.focusBlur (10 px) is
    // expressed as 10/32 of that and ramps with focus so it never pops on.
    MultiEffect {
        id: blur
        objectName: "focusBlur"
        anchors.fill: stage
        source: stage
        visible: root.liveLayer && root.shaderBackend
        autoPaddingEnabled: true
        blurEnabled: true
        blurMax: 32
        blur: (Tokens.focusBlur / blurMax) * root.dimAmount
        opacity: 1
    }

    // ---- the scrim -------------------------------------------------------
    // Above the content and above the blur. The focus panel is not a child of
    // FocusDim (the deck stacks it later), so the scrim never covers it.
    Rectangle {
        id: scrim
        objectName: "focusScrim"
        anchors.fill: parent
        color: "#000000"
        opacity: Tokens.focusScrim * root.scrim
        visible: root.scrim > 0.001
    }
}
