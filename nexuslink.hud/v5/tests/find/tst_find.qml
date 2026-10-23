import QtQuick
import QtTest
import "../.."

// tst_find.qml - Find in deck B with synthetic keys (qmltestrunner).
TestCase {
    id: tc

    name: "find"
    width: 2560
    height: 1440
    when: windowShown

    DeckSurface {
        id: deck

        width: 2560
        height: 1440
        animate: false
    }

    SignalSpy { id: edited; target: deck; signalName: "findQueryEdited" }
    SignalSpy { id: opened; target: deck; signalName: "findOpenRequested" }

    function hits() {
        var out = []
        for (var i = 0; i < 8; i++)
            out.push({ "path": "~/dir" + i + "/hit" + i + ".md", "kind": "md", "score": 0.5 })
        return out
    }

    function test_find_keys() {
        deck.findResults = hits()
        deck.focusRequest = "find"
        compare(deck.focusId, "find")
        compare(deck.wantsKeyboard, true)
        wait(60)

        keyClick("h"); keyClick("u"); keyClick("d")
        compare(edited.count, 0)
        tryCompare(edited, "count", 1, 1000)
        compare(edited.signalArguments[0][0], "hud")

        // selection rules: 0 top hit; 1 2 3 top row; 4 5 6 bottom row
        compare(deck.findSelected, 0)
        keyClick(Qt.Key_Down);  compare(deck.findSelected, 1)
        keyClick(Qt.Key_Right); compare(deck.findSelected, 2)
        keyClick(Qt.Key_Right); compare(deck.findSelected, 3)
        keyClick(Qt.Key_Down);  compare(deck.findSelected, 6)
        keyClick(Qt.Key_Down);  compare(deck.findSelected, 6)
        keyClick(Qt.Key_Left);  compare(deck.findSelected, 5)
        keyClick(Qt.Key_Left);  compare(deck.findSelected, 4)
        keyClick(Qt.Key_Up);    compare(deck.findSelected, 1)
        keyClick(Qt.Key_Up);    compare(deck.findSelected, 0)

        keyClick(Qt.Key_Down); keyClick(Qt.Key_Right); keyClick(Qt.Key_Right)
        keyClick(Qt.Key_Down); keyClick(Qt.Key_Left); keyClick(Qt.Key_Left)
        compare(deck.findSelected, 4)
        keyClick(Qt.Key_Return)
        compare(opened.count, 1)
        compare(opened.signalArguments[0][0], "~/dir4/hit4.md")

        keyClick(Qt.Key_Escape)
        compare(deck.focusId, "")
        compare(deck.wantsKeyboard, false)
        wait(20)
    }
}
