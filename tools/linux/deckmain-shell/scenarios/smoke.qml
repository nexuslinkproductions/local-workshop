import QtQuick

// smoke.qml - the first scenario. Waits 3 s, logs the status fields that hud
// exposes directly, then quits.
//
//   tools/linux/deckmain-shell.sh --scenario smoke
//
// shell.qml gives a scenario two things: hud (the DeckMain instance, so
// hud.clockText, hud.sessions, hud.apps, hud.findResults, hud.focusId ...) and
// log(msg), which prints "SCENARIO <msg>". The scenario root must be an Item.
Item {
    id: scen

    property var hud: null
    property var log: null

    function count(v) {
        return (v === null || v === undefined) ? "null" : String(v.length)
    }

    Timer {
        interval: 3000
        running: true
        repeat: false
        onTriggered: {
            var h = scen.hud
            scen.log("status clockText=" + h.clockText
                     + " sessions=" + scen.count(h.sessions)
                     + " apps=" + scen.count(h.apps)
                     + " findResults=" + scen.count(h.findResults)
                     + " focusId=" + h.focusId
                     + " enabled=" + h.v5DeckEnabled)
            Qt.quit()
        }
    }
}
