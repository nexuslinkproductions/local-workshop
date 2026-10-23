import QtQuick
import QtTest
import "../../actions.js" as Actions

// tst_actions.qml - the pure JS command table: ids, argv, unknown ids, plans.
// Run by tests/quick/run.sh. Nothing here starts a process.
TestCase {
    name: "QuickActionTable"

    function test_fiveIdsInOrder() {
        compare(JSON.stringify(Actions.IDS),
                JSON.stringify(["visualizer", "apps", "screen-scan", "text-scan", "power"]))
    }

    function test_idToArgv() {
        compare(JSON.stringify(Actions.commandFor("screen-scan", {})),
                JSON.stringify(["omarchy-capture-screenshot"]))
        compare(JSON.stringify(Actions.commandFor("text-scan", {})),
                JSON.stringify(["omarchy-capture-text"]))
        compare(JSON.stringify(Actions.commandFor("power", {})),
                JSON.stringify(["omarchy-menu", "system"]))
    }

    function test_deckActionsHaveNoArgv() {
        compare(Actions.commandFor("visualizer", {}), null)
        compare(Actions.commandFor("apps", {}), null)
        compare(Actions.plan("visualizer", {}).deck, "media")
        compare(Actions.plan("apps", {}).deck, "launcher")
    }

    function test_unknownIdsGiveNull() {
        compare(Actions.commandFor("reboot", {}), null)
        compare(Actions.commandFor("", {}), null)
        compare(Actions.commandFor("power; rm -rf /", {}), null)
        compare(Actions.plan("bogus", {}).known, false)
        compare(Actions.plan("bogus", {}).argv, null)
    }

    function test_argvIsNeverAShellString() {
        for (var i = 0; i < Actions.IDS.length; ++i) {
            var argv = Actions.commandFor(Actions.IDS[i], {})
            if (argv === null)
                continue
            for (var j = 0; j < argv.length; ++j) {
                verify(argv[j].indexOf(" ") < 0, Actions.IDS[i] + " argv has no spaces")
                verify(argv[j].indexOf(";") < 0 && argv[j].indexOf("|") < 0,
                       Actions.IDS[i] + " argv has no shell operators")
            }
        }
    }

    function test_binDirPrefixIsOptional() {
        compare(Actions.commandFor("power", { binDir: "/opt/omarchy/bin" })[0],
                "/opt/omarchy/bin/omarchy-menu")
        compare(Actions.commandFor("power", {})[0], "omarchy-menu")
    }

    function test_commandTableHasFiveRows() {
        var rows = Actions.commandTable({})
        compare(rows.length, 5)
        compare(rows[0].id, "visualizer")
        compare(rows[4].id, "power")
    }
}
