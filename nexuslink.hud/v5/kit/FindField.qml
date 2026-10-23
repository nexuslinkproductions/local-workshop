pragma ComponentBehavior: Bound

import QtQuick
import NexusHud.V5 1.0
import "icons" as Icons

// FindField.qml - v5 Find pill with a live TextInput, filter words, busy dots.
//
// Full-deck overlay in absolute deck coordinates (2560 x 1440). Only the pill,
// the filter words and the rest word take pointer input; the rest is transparent.
//
// Contract
//   query: string      text shown when the input is not the source (IPC, deck)
//   active: bool       Find is open: the pill glides to the top centre, input focused
//   filter: string     all | files | images | docs | downloads (filter row)
//   busy: bool         three pulsing dots at the right end while a search runs
//   note: string       one short feed note under the filter row
//   typedText          the text in the input (read only)
//   signals            openRequested() on a click on the rest pill
//                      queryEdited(text) one 120 ms debounce after each typing pause
//                      filterRequested(key) on a filter word
//                      navigateRequested(dx, dy) Left/Right (dx) and Up/Down (dy)
//                      activateRequested() Return
//                      closeRequested() Escape
//   functions          focusInput(), releaseFocus(), clearText()
Item {
    id: root

    property string query: ""
    property bool active: false
    property string filter: "all"
    property bool busy: false
    property string note: ""
    property string placeholder: "Find"
    readonly property string typedText: input.text

    signal openRequested()
    signal queryEdited(string text)
    signal filterRequested(string requested)
    signal navigateRequested(int dx, int dy)
    signal activateRequested()
    signal closeRequested()

    // ---- geometry (deck space) ---------------------------------------------
    // Tokens where a token exists. The open width 900 and the two origins are
    // read off s3-find-results.png (FIND-SPEC.md); Tokens.findFieldActiveWidth
    // (560) belongs to the old box and is not used here.
    readonly property int pillHeight: Tokens.findFieldHeight           // 68
    readonly property int restX: 1960
    readonly property int restY: 338
    readonly property int restWidth: Tokens.findFieldRestWidth         // 380
    readonly property int openX: 830
    readonly property int openY: 226
    readonly property int openWidth: 900
    readonly property int textInset: 84                                // s3: text at x + 84
    readonly property int textSize: 30
    readonly property int chipsCentreY: 346
    readonly property int chipCapsuleH: 44
    readonly property int chipPad: 22
    readonly property real overshoot: 1.22

    // ---- pill ----------------------------------------------------------------
    Rectangle {
        id: pill

        x: root.active ? root.openX : root.restX
        y: root.active ? root.openY : root.restY
        width: root.active ? root.openWidth : root.restWidth
        height: root.pillHeight
        radius: height / 2
        antialiasing: true
        color: Qt.rgba(Tokens.ice.r, Tokens.ice.g, Tokens.ice.b, Tokens.capsuleFillAlpha)

        Behavior on x {
            NumberAnimation {
                duration: root.active ? Motion.expandMillis : Motion.returnMillis
                easing.type: root.active ? Easing.OutBack : Easing.OutCubic
                easing.overshoot: root.overshoot
            }
        }
        Behavior on y {
            NumberAnimation {
                duration: root.active ? Motion.expandMillis : Motion.returnMillis
                easing.type: root.active ? Easing.OutBack : Easing.OutCubic
                easing.overshoot: root.overshoot
            }
        }
        Behavior on width {
            NumberAnimation {
                duration: root.active ? Motion.expandMillis : Motion.returnMillis
                easing.type: root.active ? Easing.OutBack : Easing.OutCubic
                easing.overshoot: root.overshoot
            }
        }

        MouseArea {
            anchors.fill: parent
            enabled: !root.active
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openRequested()
        }
    }

    // Rest word and five faint type dots (the rest pill, unchanged from s3).
    // The search glyph sits at the left of the pill in both states (s3).
    Icons.Glyph {
        id: searchGlyph
        glyph: "find"
        color: Tokens.ice
        size: 28
        x: pill.x + 36 - width / 2
        y: pill.y + (root.pillHeight - height) / 2
    }

    Text {
        id: restWord
        visible: !root.active
        x: pill.x + 64
        y: pill.y + (root.pillHeight - height) / 2
        text: root.placeholder
        color: Tokens.ink
        opacity: 0.62
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.pixelSize: 28
        renderType: Text.NativeRendering
    }

    Row {
        id: restDots
        visible: !root.active
        spacing: 12
        x: pill.x + pill.width - 30 - width
        y: pill.y + (root.pillHeight - height) / 2

        Repeater {
            model: 5

            delegate: Rectangle {
                id: restDot
                required property int index

                width: 10
                height: 10
                radius: 5
                antialiasing: true
                color: Tokens.ice
                opacity: 0.62 - restDot.index * 0.08
            }
        }
    }

    // ---- typed query ---------------------------------------------------------
    TextInput {
        id: input

        x: pill.x + root.textInset
        y: pill.y
        width: pill.width - root.textInset - (root.busy ? 78 : 44)
        height: root.pillHeight
        visible: root.active
        enabled: root.active
        activeFocusOnPress: true
        selectByMouse: true
        verticalAlignment: TextInput.AlignVCenter
        leftPadding: 0
        rightPadding: 0
        topPadding: 0
        bottomPadding: 0
        color: Tokens.white
        selectionColor: Tokens.azure
        selectedTextColor: Tokens.field
        font.family: Tokens.fontFamily
        font.pixelSize: root.textSize
        font.weight: Tokens.weightMedium
        renderType: Text.NativeRendering

        // Caret: a solid ice bar. No blink timer: nothing here runs while idle.
        cursorDelegate: Rectangle {
            width: 2
            height: 34
            color: Tokens.ice
        }

        // Every edit restarts the one debounce timer; the emit happens after a pause.
        onTextEdited: debounce.restart()

        Keys.onPressed: function (event) {
            if (event.key === Qt.Key_Left) {
                event.accepted = true
                root.navigateRequested(-1, 0)
            } else if (event.key === Qt.Key_Right) {
                event.accepted = true
                root.navigateRequested(1, 0)
            } else if (event.key === Qt.Key_Up) {
                event.accepted = true
                root.navigateRequested(0, -1)
            } else if (event.key === Qt.Key_Down) {
                event.accepted = true
                root.navigateRequested(0, 1)
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                event.accepted = true
                root.activateRequested()
            } else if (event.key === Qt.Key_Escape) {
                event.accepted = true
                root.closeRequested()
            }
        }
    }

    // The one debounce timer. Single shot, not running at rest.
    Timer {
        id: debounce

        interval: 120
        repeat: false
        onTriggered: root.queryEdited(input.text)
    }

    // Busy: three small pulsing dots at the right end of the pill (only while
    // a search runs; the pulse is an animation, not a timer).
    Row {
        id: busyDots
        visible: root.active && root.busy
        spacing: 7
        x: pill.x + pill.width - 42 - width
        y: pill.y + (root.pillHeight - height) / 2

        Repeater {
            model: 3

            delegate: Rectangle {
                id: busyDot
                required property int index

                width: 7
                height: 7
                radius: 3.5
                color: Tokens.ice
                opacity: 0.25

                SequentialAnimation on opacity {
                    running: root.active && root.busy
                    loops: Animation.Infinite
                    PauseAnimation { duration: busyDot.index * 150 }
                    NumberAnimation { to: 1.0; duration: 300 }
                    NumberAnimation { to: 0.25; duration: 500 }
                }
            }
        }
    }

    // ---- filter words ----------------------------------------------------------
    // Filter chips: an icon each (s3 glyphs), the word on the chosen chip only.
    Row {
        id: chipRow
        visible: root.active
        spacing: Tokens.sp2
        height: root.chipCapsuleH
        x: Math.round(Tokens.centreX - width / 2)
        y: root.chipsCentreY - root.chipCapsuleH / 2

        Repeater {
            model: [
                { "key": "all", "label": "All", "glyph": "filter-all" },
                { "key": "files", "label": "Files", "glyph": "filter-files" },
                { "key": "images", "label": "Images", "glyph": "filter-images" },
                { "key": "docs", "label": "Docs", "glyph": "filter-docs" },
                { "key": "downloads", "label": "Downloads", "glyph": "filter-downloads" }
            ]

            delegate: Rectangle {
                id: chip

                required property var modelData

                readonly property bool chosen: root.filter === chip.modelData.key

                height: root.chipCapsuleH
                width: chipContent.width + root.chipPad * 2
                radius: height / 2
                antialiasing: true
                color: chip.chosen
                       ? Qt.rgba(Tokens.ice.r, Tokens.ice.g, Tokens.ice.b, Tokens.capsuleFillAlpha)
                       : "transparent"

                // Icon on every chip; the word shows on the chosen one only.
                Row {
                    id: chipContent
                    x: Math.round((chip.width - width) / 2)
                    y: Math.round((chip.height - height) / 2)
                    spacing: Tokens.sp2

                    Icons.Glyph {
                        glyph: chip.modelData.glyph
                        color: chip.chosen ? Tokens.ink : Tokens.textDim
                        size: 26
                    }

                    Text {
                        id: chipLabel
                        visible: chip.chosen
                        text: chip.modelData.label
                        color: Tokens.ink
                        font.family: Tokens.fontFamily
                        font.weight: Tokens.weightBold
                        font.pixelSize: Tokens.sizeLabel
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.filterRequested(chip.modelData.key)
                }
            }
        }
    }

    Text {
        id: noteText
        visible: root.active && root.note !== ""
        x: Math.round(Tokens.centreX - width / 2)
        y: root.chipsCentreY + root.chipCapsuleH / 2 + Tokens.sp2
        text: root.note
        color: Tokens.textCaption
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightRegular
        font.pixelSize: Tokens.sizeCaption
    }

    // ---- focus and text, driven by DeckSurface ----------------------------------
    // Both deferred one event-loop turn as well: `active` may still be settling
    // in the same binding pass that set focusId.
    function focusInput() {
        if (root.active)
            input.forceActiveFocus()
        Qt.callLater(function () {
            if (root.active) {
                input.forceActiveFocus()
                input.cursorPosition = input.text.length
            }
        })
    }

    function releaseFocus() {
        debounce.stop()
        input.focus = false
    }

    // Escape empties the typed text and drops any pending debounce.
    function clearText() {
        debounce.stop()
        input.text = ""
    }

    // A query written from outside (IPC, deck) is shown without re-emitting.
    onQueryChanged: {
        if (input.text !== root.query)
            input.text = root.query
    }
}
