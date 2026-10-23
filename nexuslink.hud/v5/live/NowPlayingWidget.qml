pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import "../kit"

// NowPlayingWidget.qml - v5 rest form for the MPRIS now-playing box (s10 now_playing).
//
// Box 400 x 76 at the s10 origin (l 80, t 84, r 480, b 160). Rows, top down:
//   y 0    label NOW PLAYING, artist on the same row to its right
//   y 22   track title, 26 px, one line, ellipsis at 380 px
//   y 52   transport glyphs: previous (x 300), play or pause (x 336), next (x 372), 24 px
//   y 56   level meter: 28 dots on a 10 px pitch, lit = round(28 * level)
//
// Input np: the object from NowPlayingFeed.nowPlaying, or fixtures/nowplaying.json.
// Freshness, as the other data widgets:
//   fresh  bright title, lit dots by level, glyphs live (dim where a control is absent)
//   empty  "nothing playing" in textDim, no dots lit, glyphs dim
//   error  "source error" in amber, no dots lit, glyphs dim
// No stale state: MPRIS pushes changes and carries no timestamp to age.
// Glyph clicks are not wired: WidgetBase's full-bounds MouseArea sits above the content.
WidgetBase {
    id: root

    property var np: ({ "status": "error", "reason": "", "title": "", "artist": "", "identity": "",
                        "playing": false, "canPrevious": false, "canNext": false,
                        "canToggle": false, "level": -1 })

    width: 400
    height: 76
    expandable: false

    readonly property int meterCount: 28
    readonly property real meterPitch: 10
    readonly property real meterDot: 2.86
    readonly property real dimOpacity: 0.22
    readonly property real disabledOpacity: 0.4

    readonly property string status: root.np && root.np.status ? String(root.np.status) : "error"
    readonly property bool isFresh: root.status === "fresh"
    readonly property bool isEmpty: root.status === "empty"
    readonly property bool isError: !root.isFresh && !root.isEmpty

    readonly property bool playing: root.isFresh && !!root.np.playing
    readonly property bool canPrev: root.isFresh && !!root.np.canPrevious
    readonly property bool canNext: root.isFresh && !!root.np.canNext
    readonly property bool canToggle: root.isFresh && !!root.np.canToggle

    readonly property real levelValue: root.isFresh && root.np ? Number(root.np.level) : -1
    readonly property int lit: (isFinite(root.levelValue) && root.levelValue >= 0)
        ? Math.round(root.meterCount * Math.min(1, root.levelValue)) : 0

    readonly property color titleColor: root.isError ? Tokens.amber
        : (root.isEmpty ? Tokens.textDim : Tokens.white)
    readonly property string titleText: root.isError ? "source error"
        : (root.isEmpty ? "nothing playing"
            : String(root.np.title || root.np.identity || ""))
    readonly property string artistText: root.isFresh ? String(root.np.artist || "") : ""

    function glyphOpacity(on) {
        if (root.isFresh)
            return on ? 1.0 : root.disabledOpacity
        return root.dimOpacity
    }

    // ---- label row ----------------------------------------------------------
    Text {
        id: label
        x: 0
        y: 0
        text: "NOW PLAYING"
        color: Tokens.textLabel
        font.family: Tokens.fontFamily
        font.pixelSize: 16
        font.weight: Tokens.weightBold
        font.letterSpacing: 16 * Tokens.trackLabel
    }

    Text {
        id: artist
        x: 188
        y: 0
        width: 212
        text: root.artistText
        elide: Text.ElideRight
        color: Tokens.textCaption
        font.family: Tokens.fontFamily
        font.pixelSize: 16
        font.weight: Tokens.weightRegular
    }

    // ---- track title --------------------------------------------------------
    Text {
        id: track
        x: 0
        y: 22
        width: 380
        height: 30
        text: root.titleText
        color: root.titleColor
        elide: Text.ElideRight
        font.family: Tokens.fontFamily
        font.pixelSize: 26
        font.weight: Tokens.weightMedium
        lineHeight: 30
        lineHeightMode: Text.FixedHeight
        verticalAlignment: Text.AlignTop
    }

    // ---- transport glyphs (24 px boxes, s10 coordinates) --------------------
    Shape {
        id: prevGlyph
        x: 300
        y: 52
        width: 24
        height: 24
        opacity: root.glyphOpacity(root.canPrev)
        ShapePath {
            strokeColor: "transparent"
            fillColor: Tokens.ink
            PathSvg { path: "M4 5h2.4v14H4zM20 5v14L8.6 12z" }
        }
    }

    Shape {
        id: pauseGlyph
        x: 336
        y: 52
        width: 24
        height: 24
        visible: root.playing
        opacity: root.glyphOpacity(root.canToggle)
        ShapePath {
            strokeColor: "transparent"
            fillColor: Tokens.ink
            PathSvg { path: "M6 5h4v14H6zM14 5h4v14h-4z" }
        }
    }

    Shape {
        id: playGlyph
        x: 336
        y: 52
        width: 24
        height: 24
        visible: !root.playing
        opacity: root.glyphOpacity(root.canToggle)
        ShapePath {
            strokeColor: "transparent"
            fillColor: Tokens.ink
            PathSvg { path: "M7 5v14l12-7z" }
        }
    }

    Shape {
        id: nextGlyph
        x: 372
        y: 52
        width: 24
        height: 24
        opacity: root.glyphOpacity(root.canNext)
        ShapePath {
            strokeColor: "transparent"
            fillColor: Tokens.ink
            PathSvg { path: "M18 5h2.4v14H18zM4 5v14l11.4-7z" }
        }
    }

    // ---- level meter: 28 dots, centre y 64 (svg top 56 + 8) ------------------
    Repeater {
        model: root.meterCount

        delegate: Rectangle {
            id: dot

            required property int index

            x: 8 + dot.index * root.meterPitch - root.meterDot
            y: 64 - root.meterDot
            width: 2 * root.meterDot
            height: 2 * root.meterDot
            radius: root.meterDot
            color: Tokens.ice
            opacity: dot.index < root.lit ? 1.0 : root.dimOpacity
        }
    }
}
