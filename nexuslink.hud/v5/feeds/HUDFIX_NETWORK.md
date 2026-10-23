# hudfix network actions (F8e)

`hudfix_network.py` is the Network view of the maintenance engine. It exports
one `ACTIONS` dict that F8a's `hudfix.py` merges with the other five modules,
and it runs standalone so this card does not wait for F8a:

    python3 nexuslink.hud/v5/feeds/hudfix_network.py --list
    python3 nexuslink.hud/v5/feeds/hudfix_network.py --plan network.latency
    python3 nexuslink.hud/v5/feeds/hudfix_network.py --run network.jitter --json
    python3 nexuslink.hud/v5/feeds/hudfix_network.py --self-check

Nothing here changes routing, addresses, DNS servers or the VPN. Five of the
commands it can run are reads, one flush is `safe`, and the binary allowlist is
asserted in the self-check rather than promised in prose.

## The actions

| Action | Class | Runs | Cost | Cache |
|---|---|---|---|---|
| `network.latency` | read | `ping -c 5` to the tailnet gateway and to `1.1.1.1`, mean rtt and ping's own mdev, loss per target | about 5 s | 10 s |
| `network.jitter` | read | `ping -c 20 -i 0.5 1.1.1.1`, mean absolute difference between consecutive rtts and its p95, one word verdict | about 11 s | 10 s |
| `network.route` | read | `netstat -rn -f inet`, `ifconfig`, `scutil --dns`: default route, interface, tunnel address, DNS servers and their interface, search domains | under 0.2 s | 10 s |
| `network.flush-dns` | safe | macOS `dscacheutil -flushcache` then `killall -HUP mDNSResponder`; Linux `resolvectl flush-caches` | under 1 s | none |
| `network.connectivity` | read | four checks: gateway reachable (the default route gateway, pinged), public reachable, DNS resolves, tunnel up | about 5 s | 10 s |

Every successful payload carries `ok`, `generated_at` (UTC ISO), `source`
(`live` or `fixture`), `action` and `class`, a plan and a dry run included: all
three are built by one envelope constructor, so no emit site can skip the
timestamp. A run payload lists `commands` as `{argv, exit}` entries, a plan
lists `{argv, why}`, both in run order and both naming the same argv sequence.
The run's list is the trace `_run` recorded for that operation, so it cannot
omit a command the run issued, the `tailscale status --json` gateway
resolution read included.
Error answers are smaller on purpose: a refusal or a failed fixture read is
`ok: false` with `reason` and `kind` and nothing else, and an unknown action is
`ok: false` with `reason` and `actions`. A read that did run but measured
nothing keeps the envelope and adds `ok: false` with a `reason`.

### Latency: what "tailnet gateway" means

A tailnet has no router, so the target is the node that carries this host's
traffic. Resolution order, recorded in `gateway_source`:

1. `--tailnet-gateway HOST` or `ctx["tailnet_gateway"]` if given.
2. The exit node in use, from `tailscale status --json` (`ExitNodeStatus`).
3. The first online peer that advertises subnet routes (`PrimaryRoutes`).
4. The first online peer by host name. On this two node tailnet that is the
   other machine, which is also the box the HUD is talking to; the fixture
   names it `node-linux`.

If tailscale is not running, the tailnet entry is `rtt_ms: null` with a
`reason`, the public entry is still measured, and the payload sets
`degraded: true`. A missing gateway never becomes a quiet zero. If nothing
answered at all, the payload is `ok: false` and the reason names each target;
zero answers is never reported as success.

### Jitter: the thresholds

`mean_abs_diff_ms` is the mean of `|rtt[i] - rtt[i-1]|` over consecutive
replies; `p95_abs_diff_ms` is its 95th percentile (nearest rank). Two other
numbers travel under their own names, because they are different statistics:
`rtt_ms.mdev_ms` is ping's own summary figure (mdev on macOS, stddev on Linux),
or the same standard deviation computed from the replies when a capture carries
no summary line, and `rtt_ms.range_ms` is plainly `max - min`. Neither is called
jitter and neither is called spread. The latency and connectivity entries
publish the same ping summary figure as `mdev_ms`; no payload in this module
carries a `jitter_ms` key.

The verdict, in this order, is also embedded in every payload under
`thresholds`:

| Verdict | Rule |
|---|---|
| `unstable` | loss >= 5 percent, or mean abs diff >= 8 ms, or p95 >= 20 ms |
| `jittery` | any loss below 5 percent, or mean abs diff >= 2 ms, or p95 >= 5 ms |
| `steady` | no loss, mean abs diff < 2 ms and p95 < 5 ms |

20 samples at 0.5 s spacing take about 9.5 s. At 1 s spacing the same count
would take 19 s, and an expanded view that hangs for 19 s reads as broken, so
0.5 s is the documented choice. Fewer than two replies gives `verdict: null`
with a reason and `ok: false`, instead of a word the data does not support.

### Route

`default_routes` lists every `default` row, not just the first, with `usable`
and `link_level` computed: macOS carries several (`en0`, `bridge0`, `utun4`,
`bridge100`) and hiding them would be a lie about the table. `default_route` is
the first usable row. `tunnel` is the interface whose address sits in a
Tailscale range (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`), with its peer and MTU.
`dns.servers` deduplicates the same resolver seen in several blocks and keeps
the interface each nameserver is bound to, so the tailnet resolver is visible
as such (`tailnet: true`).

Live collection needs `netstat`, `ifconfig` and `scutil`, so `network.route`
and `network.connectivity` refuse to run live off macOS with
`{"ok": false, "kind": "not_this_host"}` (exit 0 from `plan`, exit 2 from
`run`), and they answer normally from a fixture on any host.
`network.flush-dns` has a real Linux path (`resolvectl flush-caches`). Its
Linux command is the linux-only part; the action itself is not `linux_only`,
because the macOS path is the one the HUD uses.

### Flush DNS

    dscacheutil -flushcache
    killall -HUP mDNSResponder

`killall` here names exactly one process, `mDNSResponder`, and sends `SIGHUP`,
which makes it reload its cache. It is not a pattern kill and it kills nothing:
the daemon stays up. That is the documented macOS flush, and the alternative
(`sudo killall -9 mDNSResponder`) would be a real outage, so it is not offered.

The plan states the interruption: name resolution for about a second or two,
a lookup that lands in the window can fail once and succeed on retry. The class
is `safe`, `needs_confirmation` is `false`, because the state is rebuilt on the
next lookup and there is nothing to lose. `changes_nothing` is `false`, since
this is the one action that does touch the host.

Fixture mode refuses to run it (`kind: "fixture"`, exit 0) and the self-check
only ever calls `plan` and `--dry-run` with a runner that raises if touched, so
no test can flush a real cache.

## Timeouts

`--timeout-scale FACTOR` multiplies every command timeout, for a slow host. The
accepted range is a finite float from 0.01 to 3600; anything else, NaN and the
infinities included, is a bad argument:

    {"ok": false, "reason": "--timeout-scale must be between 0.01 and 3600, got 1e+06",
     "kind": "bad_argument"}

on stdout, exit 2, refused before a context is built and before any timeout is
computed. The cap is not decoration: 1000000 times a 10 s base overflows the
poll timeout inside `subprocess.run` (an `OverflowError` traceback, exit 1), and
`inf` cannot be converted to an integer at all, so both used to escape the
"exit 2 only for bad arguments" rule.

## Cache

Four files for the four reads, all atomic (temp file plus `os.replace`):

    ~/.local/state/nexuslink/hudfix_network_latency.json
    ~/.local/state/nexuslink/hudfix_network_jitter.json
    ~/.local/state/nexuslink/hudfix_network_route.json
    ~/.local/state/nexuslink/hudfix_network_connectivity.json

10 s floor, so two button presses in a row cost one measurement. The key is the
setting, not the resolved peer (`tailnet_gateway: "auto"` plus the public host
for latency, the action and host for route and connectivity), because a key
that needed a `tailscale status` call to compute would make a cache hit issue a
command. The resolved peer is inside the cached payload. A hit returns
`cached: true` with `cache_age_s`, the original numbers, an empty `commands`
list (the hit ran nothing) and every `{argv, exit}` entry of the run it answers
from under `cached_from`, the gateway resolution read included; a miss returns
`cached: false`. `flush-dns` is never cached: it
exists to be repeated. `--state-dir` or `--cache-path` moves the files.
`--fixture` never reads or writes them, with or without `--cache-path`.

## Fixture mode

`--fixture PATH` (a file, or a directory containing `network.json`) answers
from the recording and touches no host state: no ping, no netstat, no clock
derived age, no cache file, no fallback to live. Every value comes from the
fixture:

    tailnet_gateway   the resolved peer, for the latency plan
    tailscale         the status JSON block (BackendState, TailscaleIPs, Peer)
    dns_probe         the recorded lookup: name, addresses, error, elapsed_ms
    commands          ping_gateway, ping_tailnet_gateway, ping_public,
                      ping_jitter, netstat_route, ifconfig, scutil_dns

`ping_gateway` is the default route gateway from the recorded netstat table and
is the only capture the connectivity gateway check reads; the tailnet peer is a
different host and is not a stand in for it. A fixture that carries no
`ping_gateway` says the gateway was not measured instead of borrowing a number
from another target.

A fixture the caller names has to exist: a missing file, or a directory without
`network.json`, is a usage error and exit 2. A file that is there but
unreadable, not JSON, or not an object at the top level is an answer like any
other: `{"ok": false, "reason": "fixture is not JSON: ...", "kind":
"malformed"}` (or `"unreadable"`) on stdout with exit 0, and no fall back to
live. The error shape is `ok`, `reason` and `kind`.

Connectivity booleans are computed from those inputs, never read as booleans:
the self-check flips one input at a time (empty DNS answer, stopped backend,
100 percent loss on the gateway ping, 100 percent loss on the public ping) and
proves exactly one boolean moves.

The one value a fixture run still takes from the clock is `generated_at`, so a
HUD tick always has a timestamp. Every measured value is byte identical between
two fixture runs, and the self-check asserts that for latency and jitter
(numbers, loss, samples, verdict) rather than trusting it.

`v5/fixtures/network.json` is a real capture from this MacBook (2026-10-23),
sanitised: tailnet IPv4 addresses are `100.100.x`, tailnet IPv6 addresses are
`fd00::x`, node host names are `node-mac`, `node-linux` and `node-old-mac`, the
tailnet DNS name is `example-tailnet.ts.net`, ether addresses are zeroed and the
owner's name is removed. The LAN gateway and the bridge addresses are as
recorded. `ping_gateway` is a separate capture of the default route gateway
(192.168.0.1), which is what the connectivity gateway check reads.
`v5/fixtures/network_down.json` is the same host with the LAN, DNS and tunnel
down, built by hand so every check has one failing input.

Re-record:

    ping -c 5 -W 1000 <tailnet-peer>       > ping_tailnet_gateway.txt
    ping -c 5 -W 1000 1.1.1.1              > ping_public.txt
    ping -c 20 -i 0.5 -W 1000 1.1.1.1      > ping_jitter.txt
    ping -c 3 -W 1000 <lan-gateway>        > ping_gateway.txt
    netstat -rn -f inet                    > netstat.txt
    ifconfig                               > ifconfig.txt
    scutil --dns                           > scutil.txt
    tailscale status --json                > tailscale.json

then paste the texts into the `commands` object under the matching keys and the
tailscale fields into `tailscale`, and replace the tailnet addresses, the node
host names and the owner's name before committing.

## Contract for F8a

    ACTIONS = {"<name>": {"class", "doc", "plan", "run", "linux_only"}}

`plan(ctx=None)` returns the dry-run object with `generated_at`, `items`,
`bytes` and `total_bytes` (always 0 here, nothing is deleted), `commands`,
`effect`, `interrupts`, `needs_confirmation`, `changes_nothing`, and for
latency and jitter a `cache` block. Its `commands` are `{argv, why}` entries in
run order, naming exactly the argv the run publishes as `{argv, exit}` from its
trace; the self-check compares the two lists so they cannot drift.

`run(ctx=None, confirm=None)` performs the action. With `ctx["dry_run"]` true
it returns the plan with `ran: false`. `confirm` is accepted and ignored: no
action here is reversible or destructive.

`ctx` may be a dict or an object; these keys are read, everything else is
ignored: `fixture`, `runner`, `now`, `dry_run`, `host`, `state_dir`,
`cache_dir`, `cache_path`, `tailnet_gateway`, `target`, `dns_name`, `cache`,
`timeout_scale`, `ping_cmd`. `runner` is `(argv, timeout) -> (stdout, stderr,
code)` and exists so a test can prove no command ran. `timeout_scale` is the
`--timeout-scale` factor: every value passed to `runner` and to `subprocess` is
the base timeout times it, from the one place `_run` reads it. The CLI accepts
0.01 to 3600 and refuses anything else with exit 2 (see Timeouts); a ctx built
by hand with a value outside that range, or with NaN, leaves the base alone.

## Self-check

    python3 nexuslink.hud/v5/feeds/hudfix_network.py --self-check

exit 0 and 19 checks, each named in the JSON: the action table and classes; the
binary allowlist over fixture plans, live plans and real calls; the CLI
contract (`--list --json` is one line, unknown action exit 2); a missing named
fixture is exit 2 while three malformed files are ok false with exit 0; latency
and jitter numbers identical twice from the fixture, and honest absence (no
captures, no jitter capture) reported as ok false; the three verdict thresholds
plus 2 percent and 100 percent loss; the route parse; connectivity all true, all
false, and one flipped input at a time (DNS, tunnel, gateway, public); the cache
answering the second call with no commands, the original argv under
`cached_from`, and expiring after 10 s, for all four reads; fixture mode
creating no file and ignoring a `--cache-path` it was handed; `flush-dns`
calling neither the runner nor `subprocess` in a plan or a dry run; the host
refusals; no absolute home path; five plans leaving the state dir byte
identical; `--timeout-scale 0.25` reaching every command timeout while the
default 1.0 leaves the base numbers alone; and the payload contract: a stamp on
every plan, dry run, run and `--list`, the stated scale range refused at both
ends by the validator and at the CLI (exit 2, no traceback), and `commands`
equal to the runner's call count and argv for latency (3) and connectivity (5),
with `cached_from` carrying all of them.

## Not offered, and why

The Network view is allowed to diagnose, not to steer. These are the user's
network, not the HUD's:

| Not offered | Why |
|---|---|
| `route add` / `route delete` / `route change`, `networksetup -set*`, `ip route add` | moving traffic between interfaces is a decision with a blast radius the HUD cannot see. A wrong route takes the Mac off the tailnet and off the LAN at once. |
| `tailscale up` / `down` / `set`, exit node changes | toggling the tunnel can cut the HUD's own link to Linux, and the card says the VPN is the user's. |
| changing DNS servers or `/etc/resolv.conf`, `scutil --set` | same class as routing: a bad resolver breaks naming for every app. |
| `pfctl` rules, MTU changes, Wi-Fi power/bandwidth toggles | firewall and link settings are not diagnosable from a widget and a wrong value is silent. |
| `speedtest`, HTTP fetches to a speed endpoint | the card allows no third party HTTP beyond one DNS lookup; a speed test moves gigabytes and needs a consent model the view does not have. |
| `arp -d`, `ndp -c`, flushing the neighbour cache | looks like the DNS flush but can stall every connection for seconds with no self healing guarantee. |
| `killall -9 mDNSResponder`, `launchctl kickstart` | a hard kill of the resolver is an outage, not a cache clear. |
| traceroute / mtr | extra ICMP budget and a 30 s spinner for a number the view does not show. |

A future Network view that wants any of these should file its own card with a
`reversible` or `destructive` class and a hold-to-confirm plan, not widen this
module.

## Registration

`feeds/README.md` belongs to another card (W8 owns it; F8a registers the CLI
there). This module needs one line in that table: `hudfix_network.py`, live
source `ping`, `netstat`, `ifconfig`, `scutil`, `tailscale status`, fixture
`v5/fixtures/network.json`. Not edited here, so the merge cannot collide.

## Ping parser provenance

F3's `game_mode.py` (branch `v5/f3-gamemode`, head
`33903de97dc1d0d2492067ac4d4cb1fe0b91a2c5`) was not merged into
`v5/main-deck` when this module was written, so `ping_argv`, `parse_ping`,
`net_entry`, `null_entry` and `ping_host_error` are copied from it. One key is
renamed: F3 publishes the ping summary's mdev/stddev as `jitter_ms`, which is
not jitter, so this module calls it `mdev_ms` in the parser and in every entry.
The remaining keys (`rtt_ms`, `loss`, `samples`, `host`, `reason`) are
unchanged, so the two readers still agree about the same ping. The copy adds
`count` and `interval` arguments and `parse_ping_times` / `parse_ping_counts`
for the jitter statistics. When F3 merges, F8a can import
`game_mode.parse_ping`, rename that one key, and delete the copy.
