import QtQuick
import NexusHud.V5 1.0

// W2 CrewOrb proof sheet, three states side by side at 1:1:
//
//   A  rest      size 118, no text, the compact deck widget
//   B  expanded  size 224, orb grows to 1.4 x size (314 px), session titles below
//   C  detail    size 224, selectedIndex 0: the selected sub-swarm grows into
//                the centre, the rest dim, that session's detail below
//
// Render (the kit/qmldir registration lines are the integrator's, so point the
// import path at a scratch copy of kit/ with `CrewOrb 1.0 CrewOrb.qml` and
// `SwarmSphere 1.0 SwarmSphere.qml` appended):
//   QML_IMPORT_PATH=<dir with NexusHud/V5> \
//   tools/qml-shot.sh nexuslink.hud/v5/stills/w2-creworb-harness.qml \
//       nexuslink.hud/v5/stills/w2-creworb-sheet.png 1100 680
//
// The three component stills on the card are crops of this frame, 1:1, caption
// included: rest x 20 y 28 w 180 h 180; expanded x 185 y 28 w 354 h 460;
// detail x 665 y 28 w 354 h 560.
//
// Fixture: v5/fixtures/sessions.json as merged (three rows, idle_s 32 / 20 / 17
// so all three derive state "live"; the raw rows are copied here because the kit
// takes data by property and has no file I/O). Row 683c2c carries parent
// a1d052, so its sub-swarm sits next to its parent's.
Item {
    id: frame

    width: 1100
    height: 680

    FontLoader { source: "../fonts/Satoshi-Regular.ttf" }
    FontLoader { source: "../fonts/Satoshi-Medium.ttf" }
    FontLoader { source: "../fonts/Satoshi-Bold.ttf" }
    FontLoader { source: "../fonts/Satoshi-Black.ttf" }

    Rectangle {
        anchors.fill: parent
        color: Tokens.field
    }

    // v5/fixtures/sessions.json, the fields the orb reads.
    property var fixture: [
        {
            "id": "a01748",
            "model": "sonnet-5-5",
            "tools": 33,
            "tokens": 125381,
            "idle_s": 32,
            "title": "Draft vari8-beta issues for Marcel and Hanzlah",
            "activity": "starting new turn"
        },
        {
            "id": "a1d052",
            "model": "sonnet-5-5",
            "tools": 158,
            "tokens": 139559,
            "idle_s": 20,
            "title": "Enable marcel-mode",
            "activity": "delegate_task: subagent receiving stream response"
        },
        {
            "id": "683c2c",
            "parent": "a1d052",
            "model": "sonnet-5-5",
            "tools": 9,
            "tokens": 3645,
            "idle_s": 17,
            "title": "Composition study s1: widget-and-icon-first HUD",
            "activity": "receiving stream response"
        }
    ]


    // The proof sheet is authored at 1100x680 and scales to whatever frame the
    // harness is given, so a 2560x1440 render is the same sheet at 2.1x.
    Item {
        id: content
        width: 1100
        height: 680
        scale: Math.min(frame.width / 1100, frame.height / 680)
        transformOrigin: Item.TopLeft
        Text {
            x: 40
            y: 8
            text: "W2 CREWORB  REST 118 / EXPANDED 224 / DETAIL 224 (SESSION 0)  1:1"
            color: Tokens.textDim
            font.family: Tokens.fontFamily
            font.pixelSize: Tokens.sizeCaption
            font.weight: Tokens.weightBold
            font.letterSpacing: Tokens.sizeCaption * Tokens.trackLabel
        }

        Text {
            x: 40
            y: 34
            text: "REST"
            color: Tokens.textDim
            font.family: Tokens.fontFamily
            font.pixelSize: Tokens.sizeCaption
            font.weight: Tokens.weightMedium
            font.letterSpacing: Tokens.sizeCaption * Tokens.trackLabel
        }

        CrewOrb {
            x: 40
            y: 62
            size: 118
            sessions: frame.fixture
            animate: false
        }

        Text {
            x: 250
            y: 34
            text: "EXPANDED"
            color: Tokens.textDim
            font.family: Tokens.fontFamily
            font.pixelSize: Tokens.sizeCaption
            font.weight: Tokens.weightMedium
            font.letterSpacing: Tokens.sizeCaption * Tokens.trackLabel
        }

        CrewOrb {
            x: 250
            y: 107
            size: 224
            sessions: frame.fixture
            expanded: true
            animate: false
        }

        Text {
            x: 730
            y: 34
            text: "DETAIL  SESSION 0"
            color: Tokens.textDim
            font.family: Tokens.fontFamily
            font.pixelSize: Tokens.sizeCaption
            font.weight: Tokens.weightMedium
            font.letterSpacing: Tokens.sizeCaption * Tokens.trackLabel
        }

        CrewOrb {
            x: 730
            y: 107
            size: 224
            sessions: frame.fixture
            expanded: true
            selectedIndex: 0
            animate: false
        }

        Text {
            x: 40
            y: 600
            width: 1020
            text: "fixture: v5/fixtures/sessions.json (3 rows, idle_s 32/20/17 so state derives live for all three; "
                  + "rows a01748 125k, a1d052 140k, 683c2c 3.6k, and 683c2c is a child of a1d052). "
                  + "shell SwarmSphere animate false phase 0.37; sub-swarm dots are QML; text floor 16 px."
            color: Tokens.textDim
            font.family: Tokens.fontFamily
            font.pixelSize: Tokens.sizeCaption
            wrapMode: Text.WordWrap
        }
    }
}
