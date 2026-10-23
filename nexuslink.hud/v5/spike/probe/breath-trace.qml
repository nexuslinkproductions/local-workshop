import QtQuick
import "../../kit"

// Breath trace probe. Runs the shipped SwarmSphere with its tick live under the
// offscreen platform and samples the breath value, so the proof file can quote
// min, max and period instead of pointing at the token file.
Item {
    id: root
    width: 224
    height: 224

    property double t0: 0

    SwarmSphere {
        id: orb
        anchors.centerIn: parent
        size: 224
        animate: true
    }

    Component.onCompleted: console.log("period_s=" + (orb.breathPeriodMs / 1000).toFixed(3))

    Timer {
        interval: 50
        repeat: true
        running: true
        onTriggered: {
            var now = Date.now();
            if (root.t0 === 0) {
                root.t0 = now;
                return;
            }
            var el = now - root.t0;
            console.log("t=" + el + " breath=" + orb.breath.toFixed(4)
                        + " scale=" + orb.breathScale.toFixed(4)
                        + " bright=" + orb.breathBright.toFixed(4)
                        + " phase=" + orb.breathPhase.toFixed(4));
            if (el > 13000)
                Qt.quit();
        }
    }
}
