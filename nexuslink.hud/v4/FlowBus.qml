pragma Singleton
// Lane T — throughput -> particle events (contract: BRIEF-V4-BUILD.md).
// Pure event/state model: no timers, no clocks. pump() runs once per stats
// frame via the Topology.statsRev edge, or by explicit call. Views subscribe
// with Connections { target: FlowBus; function onFlow(evt) { ... } } or poll
// `lastEvents`/`rates` bound to `epoch`.

import QtQml

QtObject {
    id: bus

    // Emitted once per pump for every throughput source whose rate is nonzero.
    // evt: {flow, a, b, rx, tx, rate, unit, t}
    //   rx = bytes/s (or rate units) flowing a -> b  (inbound to machine side)
    //   tx = bytes/s flowing b -> a                  (outbound from machine)
    // `rate` is rx+tx for duplex links; unit is "B/s" for byte flows, else
    // the source unit ("%", "MHz", "W") for activity links.
    signal flow(var evt)
    signal flowStarted(var evt)   // source crossed 0 -> nonzero
    signal flowStopped(var evt)   // source crossed nonzero -> 0/unknown

    // Latest state, keyed for binding.
    property var rates: ({})        // flowId -> {rx,tx,rate,unit,active}
    property var lastEvents: []     // bounded ring (<=128) of recent evts
    property int epoch: 0           // bumps per pump() — the view binding tick
    property int hotCount: 0        // sources currently nonzero
    property int eventCount: 0      // lifetime emitted flow() count
    property int lastPumpMs: 0

    property var _prevHot: ({})

    // QtObject.data only accepts QtObject children in this runtime — keep the
    // Connections on a typed property like Topology's FileView fix.
    property Connections statsConn: Connections {
        target: Topology
        function onStatsRevChanged() { bus.pump() }
    }

    function pump() {
        var fr = Topology.flowRates;      // {} until Topology builds scaffold
        var t = Date.now();
        var hot = {};
        var out = {};
        var evts = [];
        var nHot = 0;
        for (var fid in fr) {
            var f = fr[fid];
            var rate = f.rate;
            var isRate = rate !== Topology.unknown && isFinite(Number(rate));
            var active = f.active === true || (isRate && Number(rate) > 0);
            out[fid] = {
                rx: f.rx, tx: f.tx,
                rate: isRate ? Number(rate) : Topology.unknown,
                unit: f.unit, active: active
            };
            if (f.unit === "str")
                continue;                 // connectivity links never emit
            if (active && isRate) {
                nHot++;
                hot[fid] = true;
                var evt = {
                    flow: fid, a: f.a, b: f.b,
                    rx: f.rx, tx: f.tx,
                    rate: Number(rate), unit: f.unit, t: t
                };
                evts.push(evt);
                flow(evt);
                eventCount++;
                if (!_prevHot[fid])
                    flowStarted(evt);
            } else if (_prevHot[fid]) {
                flowStopped({ flow: fid, a: f.a, b: f.b, t: t });
            }
        }
        _prevHot = hot;
        hotCount = nHot;
        lastPumpMs = t;
        if (evts.length > 0) {
            var ring = lastEvents.concat(evts);
            if (ring.length > 128)
                ring = ring.slice(ring.length - 128);
            lastEvents = ring;
        }
        rates = out;
        epoch++;
    }

    // Current aggregate rate for a flow id (bytes/s where unit == "B/s"),
    // or the unknown sentinel.
    function rateOf(flowId) {
        var r = rates[flowId];
        if (r === undefined || r.rate === Topology.unknown)
            return Topology.unknown;
        return r.rate;
    }

    function isHot(flowId) {
        var r = rates[flowId];
        return r !== undefined && r.active === true;
    }
}
