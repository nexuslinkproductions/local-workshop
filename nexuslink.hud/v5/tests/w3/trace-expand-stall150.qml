import QtQuick

// Entry point for the stalled-frame run of LocalOrbTrace.qml: the same expand,
// with the event loop blocked for 150 ms right after the trigger. This is the
// frame the old SpringAnimation diverged on (W2 measured 1.0 -> 26076).
LocalOrbTrace {
    mode: "expand"
    stallMs: 150
}
