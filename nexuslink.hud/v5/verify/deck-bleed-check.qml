import QtQuick
import Quickshell

import "v5/live"

// deck-bleed-check.qml - private offscreen check for the v5 full-bleed base.
//
// Quickshell only resolves the deck's directory imports ("feeds", "../kit")
// when the config root is the plugin root, so the runner copies this file to
// <plugin>/deck-bleed-check.qml before launch (it is kept in v5/verify/ so it
// ships with the plugin and does not sit in the runtime tree).
//
//   env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE QT_QPA_PLATFORM=offscreen \
//       HUD_BLEED_W=2560 HUD_BLEED_H=1440 HUD_BLEED_PNG=/path/out.png \
//       quickshell -n -p <plugin>/deck-bleed-check.qml
//
// It puts DeckV5 in a FloatingWindow of the requested size, waits for layout,
// prints one BLEEDCHECK line (fit, DeckView origin via mapToItem, scale, PNG
// path) and quits. The PNG is judged by work3/A2/check_pixels.py: the four
// corners and the middle of the top and bottom 40 px strips must equal
// Tokens.field within 2 per channel, which proves the opaque base covers the
// letterbox bands as well as the 1:1 case.
ShellRoot {
    id: shell

    FloatingWindow {
        id: win
        width: Number(Quickshell.env("HUD_BLEED_W") || 2560)
        height: Number(Quickshell.env("HUD_BLEED_H") || 1440)
        // deliberately NOT the field colour: any uncovered pixel would show it
        color: "magenta"
        title: "deck-bleed-check"

        DeckV5 {
            id: deck
            anchors.fill: parent
            shown: true
            window: win
        }

        Item {
            id: hook

            // DeckView is the only DeckV5 child that owns a findQuery property
            function findView(d) {
                var ch = d.children
                for (var i = 0; i < ch.length; i++) {
                    var c = ch[i]
                    if (c !== null && c !== undefined && c.findQuery !== undefined)
                        return c
                }
                return null
            }

            Timer {
                interval: 800
                running: true
                repeat: false
                onTriggered: {
                    var dv = hook.findView(deck)
                    if (dv === null) {
                        console.log("BLEEDCHECK size=" + win.width + "x" + win.height + " error=no DeckView child")
                        Qt.quit()
                        return
                    }
                    var p = dv.mapToItem(deck, 0, 0)
                    var png = String(Quickshell.env("HUD_BLEED_PNG") || "")
                    console.log("BLEEDCHECK size=" + win.width + "x" + win.height
                        + " deck=" + deck.width + "x" + deck.height
                        + " fit=" + deck.fit.toFixed(4)
                        + " scale=" + dv.scale.toFixed(4)
                        + " map=" + p.x.toFixed(2) + "," + p.y.toFixed(2)
                        + " png=" + png)
                    if (png === "") {
                        Qt.quit()
                        return
                    }
                    deck.grabToImage(function (r) {
                        var saved = r.saveToFile(png)
                        console.log("BLEEDGRAB saved=" + saved + " path=" + png
                            + " px=" + r.width + "x" + r.height)
                        Qt.quit()
                    })
                }
            }
        }
    }
}
