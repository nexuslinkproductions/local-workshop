import QtQuick

// Text audit for the deck scene. Loads _deck_audit.qml (a copy of deck.qml with the state
// markers filled in by verify/audit.sh), waits for layout, then walks every visible text
// item, maps its content rectangle to scene coordinates and prints
//   AUDIT texts=N words=W minPx=P overlaps=O clipped=C
//   OVERLAP_CHECK violations=O
// plus one line per violation. Run with the software offscreen platform (no GPU needed).
Item {
    id: root
    width: 2560
    height: 1440

    Loader {
        id: scene
        anchors.fill: parent
        source: "_deck_audit.qml"
    }

    function collect(it, eo, out) {
        if (!it || !it.visible)
            return
        var o = eo * it.opacity
        if (o < 0.12)
            return
        if (it.contentWidth !== undefined && it.contentHeight !== undefined && it.text !== undefined
                && String(it.text).length > 0 && it.font !== undefined) {
            var p = it.mapToItem(root, 0, 0)
            var cw = Math.min(it.contentWidth, it.width > 0 ? it.width : it.contentWidth)
            out.push({
                text: String(it.text),
                x: p.x, y: p.y, w: cw, h: it.contentHeight,
                px: it.font.pixelSize > 0 ? it.font.pixelSize : it.font.pointSize,
                clipped: it.truncated === true || (it.contentWidth > it.width + 1 && it.width > 0 && it.elide === undefined)
            })
        }
        var kids = it.children
        for (var i = 0; i < kids.length; i++)
            collect(kids[i], o, out)
    }

    Timer {
        interval: 1800
        running: true
        onTriggered: {
            var list = []
            root.collect(scene.item, 1, list)
            var overlaps = []
            for (var i = 0; i < list.length; i++) {
                for (var j = i + 1; j < list.length; j++) {
                    var a = list[i], b = list[j]
                    var ox = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x)
                    var oy = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y)
                    if (ox > 2 && oy > 2)
                        overlaps.push([i, j, Math.round(ox), Math.round(oy)])
                }
            }
            var words = 0
            var minPx = 9999
            var clipped = 0
            for (var k = 0; k < list.length; k++) {
                words += String(list[k].text).trim().split(/\s+/).length
                if (list[k].px < minPx)
                    minPx = list[k].px
                if (list[k].clipped)
                    clipped++
            }
            for (var m = 0; m < list.length; m++)
                console.log("TEXT " + JSON.stringify(list[m]))
            for (var n = 0; n < overlaps.length; n++)
                console.log("OVERLAP " + JSON.stringify(list[overlaps[n][0]].text) + " x " + JSON.stringify(list[overlaps[n][1]].text) + " by " + overlaps[n][2] + "x" + overlaps[n][3])
            console.log("AUDIT texts=" + list.length + " words=" + words + " minPx=" + minPx + " overlaps=" + overlaps.length + " clipped=" + clipped)
            console.log("OVERLAP_CHECK violations=" + overlaps.length)
            Qt.quit()
        }
    }
}
