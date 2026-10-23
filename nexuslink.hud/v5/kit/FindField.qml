pragma ComponentBehavior: Bound

import QtQuick
import NexusHud.V5 1.0

// FindField.qml - v5 Find search field.
//
// Contract (W6 card plus the 2026-10-23 binding amendment, which wins):
//   query: string    live text, painted as typed
//   active: bool     true while the deck holds focus on the field
//   filter: string   "all" | "files" | "images" | "docs" | "downloads"
//   signal filterRequested(string requested)
//                    emitted when a filter word is tapped. The owner writes the
//                    value back into `filter`, so this component keeps no state
//                    of its own and no model.
//
// The amendment removed the magnifier and the doc count, so this file is the
// slim capsule with live query text: no lens, no dot ring, no counts, no
// process, no file access. yuri search is wired in the deck layer later.
// Name: FindField (the first draft name FindGlyph is NOT shipped), so the
// integrator registers FindField.qml.
Item {
    id: root

    property string query: ""
    property bool active: false
    property string filter: "all"
    property string placeholder: "Find"

    signal filterRequested(string requested)

    // ---- proportions ------------------------------------------------------
    // Measured off the s3 Find studies (comp-r1/s3/src/build.py): capsule
    // height 68, radius height/2, fill ice at 0.10 alpha, chips 50 high at
    // 20 px. The s3 focus page grows the pill to 900 on a 2560 canvas; 560 is
    // the deck-scale version of the same move. Text sits at Tokens.sizeBody
    // (26, the ramp token nearest the s3 28) inset Tokens.sp4 (34) rather than
    // s3's 78, because the search glyph that needed the 78 is gone. Tokens
    // missing for this component are requested in the PR body: fieldHeight,
    // fieldRestWidth, fieldActiveWidth, chipHeight.
    readonly property int fieldHeight: Tokens.findFieldHeight
    readonly property int fieldRestWidth: Tokens.findFieldRestWidth
    readonly property int fieldActiveWidth: Tokens.findFieldActiveWidth
    readonly property int fieldInset: Tokens.sp4                 // 34, text inset
    readonly property int chipsTop: fieldHeight + Tokens.sp3     // 89
    readonly property int chipHeight: Tokens.findChipHeight
    // Right band the five rest dots occupy (s3: right 30, pitch 22).
    readonly property int restDotBand: Tokens.findRestDotBand

    // ---- local design values ----------------------------------------------
    // Design numbers that no token carries yet. Each one is a named readonly
    // property so the value has a single home, and each one is a token request
    // in the PR body (capsuleFillAlpha, placeholderAlpha, caretWidth,
    // caretRadius, caretGap, caretAlpha, restDotInset, restDotPitch,
    // restDotSize, restDotChosenSize, restDotAlphaTop, restDotAlphaStep,
    // chipHoverScale, chipRestOpacity). Caret height is Tokens.sp4 (34), so it
    // reads the token directly instead of restating the number.
    readonly property real capsuleFillAlpha: 0.10       // capsule ice fill
    readonly property real placeholderAlpha: 0.60       // placeholder ink while the query is empty
    readonly property int caretWidth: 3                 // caret bar width
    readonly property int caretRadius: 2                // caret bar corner radius
    readonly property int caretGap: 4                   // caret gap after the typed text
    readonly property real caretAlpha: 0.9              // caret ink alpha
    readonly property int restDotInset: 30              // rest dots, right inset from the capsule edge
    readonly property int restDotPitch: 22              // rest dot cell size, so also the pitch
    readonly property int restDotSize: 10               // rest dot diameter
    readonly property int restDotChosenSize: 12         // chosen rest dot diameter, one size up
    readonly property real restDotAlphaTop: 0.62        // ice alpha of the first rest dot
    readonly property real restDotAlphaStep: 0.08       // alpha lost per rest dot
    readonly property real chipHoverScale: 1.05         // filter word lift under the pointer
    readonly property real chipRestOpacity: 0.55        // idle filter word alpha

    // The component keeps the active footprint at all times so a parent layout
    // never shifts when the field wakes: the capsule is centred, top aligned,
    // and the filter row occupies the lower band only while active.
    implicitWidth: fieldActiveWidth
    implicitHeight: chipsTop + chipHeight

    // ---- capsule width animation ------------------------------------------
    // Expand: Motion.expandMillis 347 ms with an OutBack curve tuned to peak at
    // 1.0487 (4.87 percent, inside the 4 to 6 band; Motion.expandOvershoot is
    // 0.05). Return: Motion.returnMillis 444 ms, OutCubic, no overshoot and
    // slower.
    //
    // Measured, not assumed: Qt 6.12 SpringAnimation in this build is frame
    // rate dependent and numerically unstable at the analytic spring constants
    // (spring = expandOmega^2 = 279 diverges past 1e5 within 32 ms; the same
    // spring measured 0.4 percent overshoot at one sample rate and 30 percent at
    // another). An OutBack curve with the same durations and overshoot gives
    // the identical feel with a value a verifier can reproduce at any frame
    // rate. Trace in the PR body.
    readonly property real expandOvershoot: Motion.curveOvershoot5   // OutBack parameter, peak 1.04871

    property real fieldWidth: fieldRestWidth

    NumberAnimation {
        id: grow
        target: root
        property: "fieldWidth"
        to: root.fieldActiveWidth
        duration: Motion.expandMillis
        easing.type: Easing.OutBack
        easing.overshoot: root.expandOvershoot
    }

    NumberAnimation {
        id: shrink
        target: root
        property: "fieldWidth"
        to: root.fieldRestWidth
        duration: Motion.returnMillis
        easing.type: Easing.OutCubic
    }

    // Grow and shrink both write fieldWidth, so the opposite animation is
    // stopped before the new one starts. Without the stop, a fast false-then-
    // true flip leaves the older shrink running: it outlasts the grow (444 ms
    // against 347 ms) and writes the rest width last, so the field ends at 380
    // while active is true. restart() also rewinds an animation already running
    // in the same direction, so a repeated flip re-expands from the width the
    // capsule actually has instead of being ignored.
    onActiveChanged: {
        if (root.active) {
            shrink.stop()
            grow.restart()
        } else {
            grow.stop()
            shrink.restart()
        }
    }

    // A declarative `active: true` never fires onActiveChanged, so snap the
    // initial width to the state the owner asked for.
    Component.onCompleted: root.fieldWidth = root.active ? root.fieldActiveWidth : root.fieldRestWidth

    // ---- capsule ----------------------------------------------------------
    // Filled surface, no border, no shadow: the visual law bans outlines and
    // boxes, and the amendment asks for a soft-fill pill.
    Rectangle {
        id: capsule
        x: Math.round((root.width - width) / 2)
        y: 0
        width: root.fieldWidth
        height: root.fieldHeight
        radius: height / 2
        color: Qt.rgba(Tokens.ice.r, Tokens.ice.g, Tokens.ice.b, root.capsuleFillAlpha)
        antialiasing: true
    }

    // ---- live query text ---------------------------------------------------
    Text {
        id: fieldText
        x: capsule.x + root.fieldInset
        y: (root.fieldHeight - height) / 2
        width: capsule.width - root.fieldInset * 2 - (root.active ? 0 : root.restDotBand)
        text: root.query.length > 0 ? root.query : root.placeholder
        color: root.query.length > 0
               ? Tokens.ink
               : Qt.rgba(Tokens.ink.r, Tokens.ink.g, Tokens.ink.b, root.placeholderAlpha)
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.pixelSize: Tokens.sizeBody
        elide: Text.ElideRight
        verticalAlignment: Text.AlignVCenter
    }

    // Caret: a solid ink bar at the end of the typed text, visible only while
    // the field is active. No blink timer: nothing on this deck runs a timer.
    Rectangle {
        id: caret
        visible: root.active
        x: fieldText.x + Math.min(fieldText.contentWidth, fieldText.width) + root.caretGap
        y: (root.fieldHeight - height) / 2
        width: root.caretWidth
        height: Tokens.sp4
        radius: root.caretRadius
        color: Tokens.ink
        opacity: root.caretAlpha
        antialiasing: true
    }

    // ---- rest dots ---------------------------------------------------------
    // Five filter dots inside the capsule while the field sleeps, taken from
    // the s3 rest pill (10 px dots, right inset 30, pitch 22, ice fading
    // 0.62 down to 0.30). They stay tappable, so a filter can be changed
    // without waking the field. Active filter: ink, one size up.
    Row {
        id: restDots
        visible: opacity > 0.01
        opacity: root.active ? 0 : 1
        anchors.right: capsule.right
        anchors.rightMargin: root.restDotInset
        anchors.verticalCenter: capsule.verticalCenter
        spacing: 0

        Behavior on opacity {
            NumberAnimation {
                duration: Motion.scrimMillis
                easing.type: Easing.OutCubic
            }
        }

        Repeater {
            model: ["all", "files", "images", "docs", "downloads"]

            delegate: Item {
                id: restDot
                required property string modelData
                required property int index

                readonly property bool chosen: root.filter === restDot.modelData

                width: root.restDotPitch
                height: root.restDotPitch

                Rectangle {
                    anchors.centerIn: parent
                    width: restDot.chosen ? root.restDotChosenSize : root.restDotSize
                    height: width
                    radius: width / 2
                    antialiasing: true
                    color: restDot.chosen
                           ? Tokens.ink
                           : Qt.rgba(Tokens.ice.r, Tokens.ice.g, Tokens.ice.b,
                                     root.restDotAlphaTop - restDot.index * root.restDotAlphaStep)
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.filterRequested(restDot.modelData)
                }
            }
        }
    }

    // ---- filters -----------------------------------------------------------
    // Five words, no capsules, no outlines: weight and brightness carry the
    // active filter. The row fades in only while the field is active and is
    // hidden at rest so the composed deck stays quiet and under 40 words.
    Row {
        id: chipRow
        x: Math.round((root.width - width) / 2)
        y: root.chipsTop
        height: root.chipHeight
        spacing: Tokens.sp3
        opacity: root.active ? 1 : 0
        visible: opacity > 0.01

        Behavior on opacity {
            NumberAnimation {
                duration: Motion.scrimMillis
                easing.type: Easing.OutCubic
            }
        }

        Repeater {
            model: [
                { "key": "all", "label": "All" },
                { "key": "files", "label": "Files" },
                { "key": "images", "label": "Images" },
                { "key": "docs", "label": "Docs" },
                { "key": "downloads", "label": "Downloads" }
            ]

            delegate: Item {
                id: chip
                required property var modelData

                width: chipLabel.width
                height: chipRow.height
                scale: chipHit.containsMouse ? root.chipHoverScale : 1.0
                transformOrigin: Item.Center

                Behavior on scale {
                    NumberAnimation {
                        duration: Motion.textOutMillis
                        easing.type: Easing.OutCubic
                    }
                }

                Text {
                    id: chipLabel
                    anchors.verticalCenter: parent.verticalCenter
                    text: chip.modelData.label
                    color: root.filter === chip.modelData.key ? Tokens.ink : Tokens.textDim
                    opacity: root.filter === chip.modelData.key ? 1.0 : root.chipRestOpacity
                    font.family: Tokens.fontFamily
                    font.weight: root.filter === chip.modelData.key
                                 ? Tokens.weightBold
                                 : Tokens.weightMedium
                    font.pixelSize: Tokens.sizeLabel
                }

                MouseArea {
                    id: chipHit
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.filterRequested(chip.modelData.key)
                }
            }
        }
    }
}
