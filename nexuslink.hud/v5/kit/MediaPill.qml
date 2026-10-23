pragma ComponentBehavior: Bound

import QtQuick
import NexusHud.V5 1.0

// MediaPill.qml - the now-playing capsule, bottom left.
// Owner: worker M. Pure QtQuick, no Quickshell import (DeckMain feeds it).
//
// Contract (do not rename without telling the lead):
//   title, artist: string, playing: bool, available: bool
//   signal toggleRequested()          emitted when the pill is clicked
//
// Reference: hud-candidates/comp-r1/s5/e/e-rest.png. Measured there at 2560x1440:
// capsule x 250 to 567 (317 wide), y 1284 to 1340 (56 high); fill ice at 0.10
// alpha (Tokens.capsuleFillAlpha, the FindField fill); a 3-column, 4-row dot
// level meter at the left (acid dots lit, dim ice dots unlit); title in Satoshi
// Medium 20 px, ink, starting at x 330 and ending at x 546.
//
// Rules kept here: no boxes, outlines or glow; no Canvas; the only animation is
// ONE NumberAnimation (the level meter), running only while playing and visible;
// no Timer and no per-frame JS function.
Item {
    id: root

    property string title: ""
    property string artist: ""
    property bool playing: false
    property bool available: false

    signal toggleRequested()

    // ---- proportions (measured on e-rest.png, see the header) -------------
    readonly property int pillWidth: 317
    readonly property int pillHeight: 56
    readonly property int glyphInset: 32                         // glyph left edge from the capsule left
    readonly property int glyphCols: 3
    readonly property int glyphRows: 4
    readonly property real glyphPitch: 11                        // dot centre to centre
    readonly property real glyphDot: 5                           // dot diameter
    readonly property real glyphCentreDy: 4                      // reference glyph sits 4 px below centre
    readonly property int textGap: Tokens.sp3                    // 21: glyph right edge to text
    readonly property int textRightInset: Tokens.sp3             // 21: text right edge to capsule right
    readonly property int textSize: Tokens.sizeLabel             // 20 px, the ramp step nearest the reference
    readonly property real unlitAlpha: 0.30                      // dim ice dot: unlit, or paused
    readonly property real hoverFillAlpha: 0.16                  // capsule fill under the pointer
    readonly property int levelCycleMs: 4000                     // one full level cycle, slow
    readonly property int levelSteps: 4                          // each column lights 1 to 4 dots

    // ---- derived -----------------------------------------------------------
    readonly property real glyphX: glyphInset
    readonly property real glyphY: (pillHeight - (glyphRows - 1) * glyphPitch - glyphDot) / 2 + glyphCentreDy
    readonly property real textX: glyphX + (glyphCols - 1) * glyphPitch + glyphDot + textGap
    readonly property real textAvail: Math.max(0, pillWidth - textX - textRightInset)
    readonly property bool showArtist: artist.length > 0 && artistProbe.implicitWidth <= textAvail
    readonly property string label: showArtist ? title + " - " + artist : title

    // Level driver. `step` runs 0 to levelSteps once per cycle. Column c shows
    // level 1 + ((floor(step) + c) mod 4), so the three columns move against
    // each other like a meter, and step 4 equals step 0 (seamless loop).
    property real step: 0

    NumberAnimation {
        id: levelWave
        target: root
        property: "step"
        from: 0
        to: root.levelSteps
        duration: root.levelCycleMs
        loops: Animation.Infinite
        running: root.playing && root.available && root.visible
    }

    function levelFor(column) {
        return 1 + ((Math.floor(root.step) + column) % root.levelSteps)
    }

    implicitWidth: pillWidth
    implicitHeight: pillHeight
    width: pillWidth
    height: pillHeight

    // Gone when no player is available: fully transparent, and no hit area
    // (hit.enabled is bound to the same flag). Layout stays put.
    opacity: root.available ? 1 : 0

    // ---- capsule -----------------------------------------------------------
    Rectangle {
        id: capsule
        anchors.fill: parent
        radius: height / 2
        antialiasing: true
        color: Qt.rgba(Tokens.ice.r, Tokens.ice.g, Tokens.ice.b,
                       hit.containsMouse && root.available ? root.hoverFillAlpha : Tokens.capsuleFillAlpha)

        Behavior on color {
            ColorAnimation {
                duration: Motion.scrimMillis
                easing.type: Easing.OutCubic
            }
        }
    }

    // ---- level meter -------------------------------------------------------
    // Twelve dots, index = row * 3 + column, row 0 at the top. A dot is lit when
    // its level from the bottom is below its column's level. Paused or at rest
    // every dot is the same dim ice, so the glyph is static.
    Repeater {
        model: root.glyphCols * root.glyphRows

        delegate: Rectangle {
            id: dot
            required property int index

            readonly property int column: dot.index % root.glyphCols
            readonly property int row: Math.floor(dot.index / root.glyphCols)
            readonly property int fromBottom: root.glyphRows - 1 - dot.row

            x: root.glyphX + dot.column * root.glyphPitch
            y: root.glyphY + dot.row * root.glyphPitch
            width: root.glyphDot
            height: root.glyphDot
            radius: width / 2
            antialiasing: true
            color: root.playing && dot.fromBottom < root.levelFor(dot.column)
                   ? Tokens.acid
                   : Qt.rgba(Tokens.ice.r, Tokens.ice.g, Tokens.ice.b, root.unlitAlpha)
        }
    }

    // ---- title -------------------------------------------------------------
    // One line, elided on the right inside the capsule. The artist follows
    // " - " only when the whole label fits (decided on implicitWidth).
    Text {
        id: titleText
        x: root.textX
        y: (root.pillHeight - height) / 2
        width: root.textAvail
        text: root.label
        color: Tokens.ink
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.pixelSize: root.textSize
        elide: Text.ElideRight
        maximumLineCount: 1
        wrapMode: Text.NoWrap
    }

    // Width probe for the artist decision. Never painted.
    Text {
        id: artistProbe
        visible: false
        text: root.title + " - " + root.artist
        font.family: Tokens.fontFamily
        font.weight: Tokens.weightMedium
        font.pixelSize: root.textSize
    }

    // ---- hit area ----------------------------------------------------------
    MouseArea {
        id: hit
        anchors.fill: parent
        enabled: root.available
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggleRequested()
    }

    // Read by tests/media/tst_media.qml.
    readonly property alias hitEnabled: hit.enabled
    readonly property alias hovered: hit.containsMouse
    readonly property alias fillColor: capsule.color
    readonly property alias truncated: titleText.truncated
    readonly property alias titleX: titleText.x
    readonly property alias titleWidth: titleText.width
    readonly property alias levelRunning: levelWave.running
}
