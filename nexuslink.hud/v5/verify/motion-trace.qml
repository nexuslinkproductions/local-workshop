import QtQuick

// motion-trace.qml - runner for the numeric motion proof. Owner M.
// The sampler lives in ../live/MotionTrace.qml so the plugin keeps one copy;
// this file is only the entry point the contract names.
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmlscene motion-trace.qml
Item {
    id: root
    width: 1
    height: 1

    Loader {
        anchors.fill: parent
        source: "../live/MotionTrace.qml"
    }
}
