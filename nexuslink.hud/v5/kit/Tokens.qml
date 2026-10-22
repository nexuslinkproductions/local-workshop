pragma Singleton

import QtQuick

// Tokens.qml - v5 deck design tokens. Pure QtQuick: numbers, colours and names
// only. No animation, no shell-runtime import, no components.
//
// Sources (read only, never edited from here):
//   hud-candidates/comp-r1/s1/src/build.py:20      palette ICE/AZ/CY/WH/ACID/AMB
//   hud-candidates/comp-r1/s1/src/build.py:10-24   guides GX/GY/TX/TY, knot, safe margin
//   hud-candidates/comp-r1/s1/README.md            layout maths, type scale, focus env
//   hud-candidates/comp-r1/s2/src/data.json        feed shapes for v5/fixtures/
//   nexuslink.hud/v4/Style.qml                     red (v4 "alert"); s1 ships no red
// Shared with the design lead: the values are the s1 set until s2 PNGs land.
QtObject {
    id: tokens

    // ---- target canvas ---------------------------------------------------
    // DP-2 main screen. Every guide below is a measured pixel for this size;
    // the deck lays out in these units and never scales them by hand.
    readonly property int targetW: 2560
    readonly property int targetH: 1440

    // Base grid. All spacing is a multiple or a Fibonacci step of it.
    readonly property int unit: 8

    // ---- golden and thirds guides ---------------------------------------
    // phi cuts: 0.382 and 0.618 on both axes (s1 build.py GX/GY).
    // goldenY1 carries the knot centre; goldenY2 is the lower band.
    readonly property real phi: 1.618033988749895
    readonly property real goldenX1: 978        // round(0.382 * 2560) = 977.92
    readonly property real goldenX2: 1582       // round(0.618 * 2560) = 1582.08
    readonly property real goldenY1: 550        // round(0.382 * 1440) = 550.08
    readonly property real goldenY2: 890        // round(0.618 * 1440) = 889.92
    // thirds: 2560/3 = 853.33, 2*2560/3 = 1706.67, 1440/3 = 480, 2*1440/3 = 960
    readonly property real thirdX1: 853
    readonly property real thirdX2: 1707
    readonly property real thirdY1: 480
    readonly property real thirdY2: 960
    readonly property real centreX: 1280
    readonly property real centreY: 720

    // ---- spacing ---------------------------------------------------------
    // Fibonacci steps from the 8 px base: each ratio is phi to within 0.02.
    // Units: px. Use sp4 (34) as the default gap, sp6 (89) between groups.
    readonly property int sp1: 8
    readonly property int sp2: 13
    readonly property int sp3: 21
    readonly property int sp4: 34
    readonly property int sp5: 55
    readonly property int sp6: 89
    readonly property int sp7: 144
    readonly property int sp8: 233
    readonly property int sp9: 377
    readonly property var spacing: [8, 13, 21, 34, 55, 89, 144, 233, 377]
    readonly property int safeMargin: 96        // s1: nothing closer than 96 px to an edge
    readonly property int gutter: 34

    // ---- knot ------------------------------------------------------------
    // Centred on the upper golden line, 37.5 percent of the screen height.
    readonly property int knotDiameter: 540
    readonly property real knotCentreX: 1280
    readonly property real knotCentreY: 550
    // Four hero widgets sit on the thirds power points, radius 112 (s1).
    readonly property int heroRadius: 112
    readonly property var powerPoints: ({
        "crew":  { "x": 853,  "y": 480 },
        "find":  { "x": 1707, "y": 480 },
        "mac":   { "x": 853,  "y": 960 },
        "local": { "x": 1707, "y": 960 }
    })

    // ---- palette ---------------------------------------------------------
    // s1 build.py:20 is the authority: ICE, AZ, CY, WH, ACID, AMB.
    readonly property color ice: "#8fd8e8"
    readonly property color azure: "#60a5fa"
    readonly property color cyan: "#00c8f0"
    readonly property color white: "#f4f8fb"
    readonly property color acid: "#c8f31d"
    readonly property color amber: "#ffb454"
    // s1 has no red face. This is v4 Style.qml "alert" (#ff4a3d), kept so the
    // deck has one hot colour in the same family; do not re-derive per card.
    readonly property color red: "#ff4a3d"
    // Field and text (s1 build.py:203, 207-214).
    readonly property color field: "#06080a"
    readonly property color ink: "#eaf4f8"
    readonly property color textLabel: "#b3d0da"
    readonly property color textCaption: "#a8c4cf"
    readonly property color textDim: "#8fb2c0"
    readonly property color textDate: "#9fc3cf"
    readonly property color nothing: "transparent"
    readonly property var palette: ({
        "ice": "#8fd8e8",
        "azure": "#60a5fa",
        "cyan": "#00c8f0",
        "white": "#f4f8fb",
        "acid": "#c8f31d",
        "amber": "#ffb454",
        "red": "#ff4a3d",
        "field": "#06080a"
    })

    // ---- type ------------------------------------------------------------
    // Satoshi. One family string: measured on Qt 6.12.0 on this Mac, four
    // FontLoaders over the four faces all report name "Satoshi", Qt.fontFamilies()
    // holds only "Satoshi", and weight selects the face (advance width of "HHHHH"
    // at 68 px: 400 239.69, 500 245.47, 700 252.27, 900 259.69). The name tables
    // do declare the style-linked families "Satoshi Medium" and "Satoshi Black"
    // as nameID 1, but they do NOT resolve in Qt: a TextMetrics on either one
    // measures the same as a bogus family name, and Qt logs "Replace uses of
    // missing font family". So load the four files, then pick the weight.
    readonly property string fontFamily: "Satoshi"
    readonly property string fontFamilyFallback: "sans-serif"
    readonly property var fontFiles: ({
        "400": "fonts/Satoshi-Regular.ttf",
        "500": "fonts/Satoshi-Medium.ttf",
        "700": "fonts/Satoshi-Bold.ttf",
        "900": "fonts/Satoshi-Black.ttf"
    })
    readonly property int weightRegular: 400
    readonly property int weightMedium: 500
    readonly property int weightBold: 700
    readonly property int weightBlack: 900

    // Ramp in px. 16 is the floor for everything the deck paints (s1 type
    // scale 16 / 26 / 68 / 110 / 168, plus 20 and 44 for label and title).
    readonly property int minTypeSize: 16
    readonly property int sizeCaption: 16
    readonly property int sizeLabel: 20
    readonly property int sizeBody: 26
    readonly property int sizeTitle: 44
    readonly property int sizeHero: 68
    readonly property int sizeReadout: 110
    readonly property int sizeClock: 168
    readonly property var ramp: [16, 20, 26, 44, 68, 110, 168]
    // Tracking in em (s1: .26em on labels, .04em on names, .01em on the clock).
    readonly property real trackLabel: 0.26
    readonly property real trackName: 0.04
    readonly property real trackClock: 0.01

    // ---- focus and softness ---------------------------------------------
    // Focus mode dims and blurs everything that is not the stage. The band
    // 0.18 to 0.3 is the approved range; motion-r1 focusEnv.opacity sits at the
    // ceiling (0.3) and s1 rendered 0.16, so the deck default is inside both.
    readonly property real focusDimMin: 0.18
    readonly property real focusDimMax: 0.30
    readonly property real focusDim: 0.26
    readonly property real focusScrim: 0.35
    readonly property int focusBlurMin: 8
    readonly property int focusBlurMax: 12
    readonly property int focusBlur: 10
    readonly property real focusScale: 0.965        // s1 crew-focus and motion-r1 focusEnv
    // Ambient swarm tick (plan constraint 3: one GPU pass, 24 to 30 Hz).
    readonly property int swarmTickHzMin: 24
    readonly property int swarmTickHz: 30
}
