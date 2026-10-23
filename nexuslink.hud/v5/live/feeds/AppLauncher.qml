import QtQuick
import Quickshell

// AppLauncher.qml - v5 launcher adapter. Same three mechanisms the v4 plugin
// already uses (see LAUNCH-NOTES.md for file:line):
//   desktop entry -> Quickshell.execDetached(["gtk-launch", <id>])
//   plain command -> Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "v5"].concat(argv))
//   URL           -> Quickshell.execDetached(["uwsm-app", "--", "xdg-open", url])
// dryRun never launches anything: it logs the argv it would have run.
QtObject {
    id: root

    property bool dryRun: false

    function launch(app) {
        if (!app || !app.launch) {
            console.log("v5 launch: no launch spec for " + (app && app.id ? app.id : "?"))
            return
        }
        var spec = app.launch
        var argv = null
        if (spec.mode === "desktop" && spec.id) {
            argv = ["gtk-launch", String(spec.id)]
        } else if (spec.mode === "command" && spec.argv && spec.argv.length) {
            argv = ["bash", "-lc", 'exec "$@"', "v5-launch"].concat(spec.argv)
        } else if (spec.mode === "url" && spec.url) {
            argv = ["uwsm-app", "--", "xdg-open", String(spec.url)]
        } else {
            console.log("v5 launch: bad launch spec for " + (app.id ? app.id : "?"))
            return
        }
        if (dryRun) {
            console.log("v5 launch dry-run: " + JSON.stringify(argv))
            return
        }
        Quickshell.execDetached(argv)
    }
}
