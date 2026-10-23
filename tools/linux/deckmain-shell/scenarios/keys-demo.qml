import QtQuick
import QtTest
import Quickshell

// keys-demo.qml - stretch: do synthetic key events reach a window inside this
// offscreen shell? Opens a FloatingWindow with a TextInput, activates it, sends
// h, u, d and Return through QtTest TestEvent, and logs the text it received.
//
//   tools/linux/deckmain-shell.sh --scenario keys-demo
//
// Output lines: "SCENARIO keys window.active=... field.activeFocus=..." before the
// keys, and "SCENARIO keys text=[...]" after. Expected text: [hud].
Item {
    id: scen

    property var hud: null
    property var log: null

    TestEvent { id: ev }

    FloatingWindow {
        id: win
        visible: true
        implicitWidth: 480
        implicitHeight: 160
        title: "keys-demo"
        color: "#000000"

        TextInput {
            id: field
            anchors.fill: parent
            anchors.margins: 16
            focus: true
            color: "#ffffff"
            font.pixelSize: 36
        }
    }

    Timer {
        id: go
        interval: 1500
        running: true
        repeat: false
        onTriggered: {
            scen.log("keys begin")
            field.forceActiveFocus()
            scen.log("keys field.activeFocus=" + field.activeFocus)
            ev.keyClick(Qt.Key_H, Qt.NoModifier, 0)
            ev.keyClick(Qt.Key_U, Qt.NoModifier, 0)
            ev.keyClick(Qt.Key_D, Qt.NoModifier, 0)
            ev.keyClick(Qt.Key_Return, Qt.NoModifier, 0)
            settle.start()
        }
    }

    Timer {
        id: settle
        interval: 400
        repeat: false
        onTriggered: {
            scen.log("keys text=[" + field.text + "] length=" + field.text.length)
            Qt.quit()
        }
    }
}
