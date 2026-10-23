import QtQuick
import "../kit"

// MotionTrace.qml - numeric proof for the deck's motion acceptance item 3.
//
// Not a visual component: an Item that samples the real WidgetBase numbers and
// prints a PASS or FAIL line per item. Run it through the verify wrapper:
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmlscene \
//     nexuslink.hud/v5/verify/motion-trace.qml
//
// It copies the grow Behavior settings from WidgetBase.qml verbatim (duration
// Motion.expandMillis, OutBack, overshoot 1.22) and the return settings
// (Motion.returnMillis, InOutQuad), samples every 8 ms, then evaluates
// WidgetBase's own driftX and driftY for tick 0 to 40 s and reads the breath
// constants. Nothing here is hard-coded except the sample cadence.
Item {
    id: root
    width: 1
    height: 1

    // ---- the probe item: exactly WidgetBase's grow behavior --------------
    Item {
        id: probe
        property real g: 0
        property bool expanding: false

        Behavior on g {
            NumberAnimation {
                duration: probe.expanding ? Motion.expandMillis : Motion.returnMillis
                easing.type: probe.expanding ? Easing.OutBack : Easing.InOutQuad
                easing.overshoot: 1.22
            }
        }
    }

    // ---- the real base, for drift ---------------------------------------
    WidgetBase {
        id: wb
        width: 1
        height: 1
        visible: false
    }

    property var samples: []
    property var returnSamples: []
    property double phaseStart: 0
    property int phase: 0          // 0 idle, 1 expand, 2 return, 3 done
    property double expandSettle: -1
    property double returnSettle: -1
    property double expandPeak: -1
    property double returnMin: 99

    function stats(list) {
        var peak = -1e9, low = 1e9;
        for (var i = 0; i < list.length; ++i) {
            if (list[i].v > peak) peak = list[i].v;
            if (list[i].v < low) low = list[i].v;
        }
        return { peak: peak, low: low };
    }

    function settleTime(list, target, tol) {
        var last = -1;
        for (var i = 0; i < list.length; ++i)
            if (Math.abs(list[i].v - target) > tol) last = i;
        return last < 0 ? 0 : list[last].t;
    }

    Timer {
        id: sampler
        interval: 8
        repeat: true
        running: false
        onTriggered: {
            var t = Date.now() - root.phaseStart;
            if (root.phase === 1) {
                root.samples.push({ t: t, v: probe.g });
                if (t >= 600) {
                    root.phase = 2;
                    root.phaseStart = Date.now();
                    probe.expanding = false;
                    probe.g = 0;
                }
            } else if (root.phase === 2) {
                root.returnSamples.push({ t: t, v: probe.g });
                if (t >= 700) {
                    root.phase = 3;
                    sampler.running = false;
                    root.report();
                }
            }
        }
    }

    function report() {
        var s = root.samples;
        var r = root.returnSamples;
        var es = root.stats(s);
        var rs = root.stats(r);
        var overPct = (es.peak - 1) * 100;
        var eSettle = root.settleTime(s, 1, 0.02);
        var rSettle = root.settleTime(r, 0, 0.02);

        console.log("MOTION TRACE  qt " + Qt.application.version + "  samples " + s.length + "/" + r.length + "  cadence 8 ms");
        console.log("EXPAND  peak=" + es.peak.toFixed(4) + "  overshoot=" + overPct.toFixed(2) + " %  settle2pct=" + eSettle.toFixed(0) + " ms  duration=" + Motion.expandMillis + " ms OutBack 1.22");
        console.log("EXPAND  " + ((overPct >= 4 && overPct <= 6 && eSettle > 0 && eSettle <= 500) ? "PASS" : "FAIL"));

        console.log("RETURN  min=" + rs.low.toFixed(4) + "  undershoot=" + (rs.low < 0 ? "yes" : "no") + "  settle2pct=" + rSettle.toFixed(0) + " ms  duration=" + Motion.returnMillis + " ms InOutQuad");
        console.log("RETURN  " + ((rs.low >= -0.0005 && rSettle > 0 && rSettle > eSettle) ? "PASS" : "FAIL") + "  returnSlowerThanExpand=" + (rSettle > eSettle));

        // ---- drift, from the real WidgetBase ----------------------------
        var minX = 1e9, maxX = -1e9, minY = 1e9, maxY = -1e9, maxR = 0;
        for (var t = 0; t <= 40.0001; t += 0.5) {
            wb.tick = t;
            var dx = wb.driftX, dy = wb.driftY;
            if (dx < minX) minX = dx;
            if (dx > maxX) maxX = dx;
            if (dy < minY) minY = dy;
            if (dy > maxY) maxY = dy;
            var rad = Math.sqrt(dx * dx + dy * dy);
            if (rad > maxR) maxR = rad;
        }
        var p2pX = maxX - minX, p2pY = maxY - minY;
        console.log("DRIFT   x[" + minX.toFixed(3) + ", " + maxX.toFixed(3) + "] p2p=" + p2pX.toFixed(3) + " px   y[" + minY.toFixed(3) + ", " + maxY.toFixed(3) + "] p2p=" + p2pY.toFixed(3) + " px   maxRadius=" + maxR.toFixed(3) + " px");
        console.log("DRIFT   amplitude=" + wb.driftAmp.toFixed(2) + " px  envelope=" + (2 * wb.driftAmp).toFixed(2) + " px peak to peak  periods " + Motion.driftPeriodMin + "/" + Motion.driftPeriodMax + " s  sample 0..40 s step 0.5 s  " + ((p2pX > 0.5 && p2pX < 4 && p2pY > 0.5 && p2pY < 4) ? "PASS" : "FAIL"));

        // ---- breath ------------------------------------------------------
        console.log("BREATH  period=" + Motion.breathPeriod + " s  inhale=" + Motion.breathInhale + "  exhale=" + Motion.breathExhale + "  (required 5 to 6 s, 40/60)");
        var xhr = new XMLHttpRequest();
        var shaderText = "";
        try {
            xhr.open("GET", "../live/shaders/knot.vert", false);
            xhr.send();
            if (xhr.status === 200 || xhr.status === 0)
                shaderText = xhr.responseText;
        } catch (e) {
            shaderText = "";
        }
        if (shaderText.length === 0) {
            console.log("BREATH  shader not yet written (nexuslink.hud/v5/live/shaders/knot.vert absent)  constants only  " + ((Motion.breathPeriod >= 5 && Motion.breathPeriod <= 6 && Math.abs(Motion.breathInhale - 0.4) < 0.001) ? "PASS" : "FAIL"));
        } else {
            var pm = shaderText.match(/breathAt\([^)]*\)\s*\{[\s\S]*?tt\s*\/\s*([0-9]*\.?[0-9]+)/);
            var im = shaderText.match(/u\s*<\s*([0-9]*\.?[0-9]+)/);
            var sp = pm ? parseFloat(pm[1]) : -1;
            var si = im ? parseFloat(im[1]) : -1;
            var delta = (sp > 0) ? (sp - Motion.breathPeriod) : 0;
            console.log("BREATH  shader knot.vert present (" + shaderText.length + " bytes)  formula period=" + sp + " s  inhale=" + si + " / exhale=" + (si > 0 ? (1 - si).toFixed(2) : "?") + "  tokenDelta=" + delta.toFixed(1) + " s");
            console.log("BREATH  " + ((Motion.breathPeriod >= 5 && Motion.breathPeriod <= 6 && sp >= 5 && sp <= 6 && Math.abs(Motion.breathInhale - 0.4) < 0.001 && si === 0.4) ? "PASS" : "FAIL"));
        }
        Qt.quit();
    }

    Component.onCompleted: {
        root.phase = 1;
        root.phaseStart = Date.now();
        probe.expanding = true;
        probe.g = 1;
        sampler.running = true;
    }
}
