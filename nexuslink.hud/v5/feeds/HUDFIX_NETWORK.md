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
| `network.connectivity` | read | four checks: gateway reachable, public reachable, DNS resolves, tunnel up | about 5 s | 10 s |

Every payload carries `ok`, `generated_at` (UTC ISO), `source` (`live` or
`fixture`), `action` and `class`.

### Latency: what "tailnet gateway" means

A tailnet has no router, so the target is the node that carries this host's
traffic. Resolution order, recorded in `gateway_source`:

1. `--tailnet-gateway HOST` or `ctx["tailnet_gateway"]` if given.
2. The exit node in use, from `tailscale status --json` (`ExitNodeStatus`).
3. The first online peer that advertises subnet routes (`PrimaryRoutes`).
4. The first online peer by host name. On this two node tailnet that is
   `omarchylink`, which is also the box the HUD is talking to.

If tailscale is not running, the tailnet entry is `rtt_ms: null` with a
`reason`, the public entry is still measured, and the payload sets
`degraded: true`. A missing gateway never becomes a quiet zero.

### Jitter: the thresholds

`mean_abs_diff_ms` is the mean of `|rtt[i] - rtt[i-1]|` over consecutive
replies; `p95_abs_diff_ms` is its 95th percentile (nearest rank). Ping's own
`mdev` (macOS) or `stddev` (Linux) is published separately as `rtt_ms.spread`,
because standard deviation and mean absolute difference are different
statistics and the HUD should not pretend otherwise.

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
with a reason instead of a word the data does not support.

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
`cached: true` with `cache_age_s` and the original numbers; a miss returns
`cached: false`. `flush-dns` is never cached: it exists to be repeated.
`--state-dir` or `--cache-path` moves the files; `--fixture` never reads or
writes them.

## Fixture mode

`--fixture PATH` (a file, or a directory containing `network.json`) answers
from the recording and touches no host state: no ping, no netstat, no clock
derived age, no cache file, no fallback to live. Every value comes from the
fixture:

    tailnet_gateway   the resolved peer, for the plan and connectivity fallback
    tailscale         the status JSON block (BackendState, TailscaleIPs, Peer)
    dns_probe         the recorded lookup: name, addresses, error, elapsed_ms
    commands          ping_tailnet_gateway, ping_public, ping_jitter,
                      netstat_route, ifconfig, scutil_dns

Connectivity booleans are computed from those inputs, never read as booleans:
the self-check flips one input at a time (empty DNS answer, stopped backend,
100 percent loss on the gateway ping) and proves exactly one boolean moves.

The one value a fixture run still takes from the clock is `generated_at`, so a
HUD tick always has a timestamp. Every measured value is byte identical between
two fixture runs, and the self-check asserts that for latency and jitter
(numbers, loss, samples, verdict) rather than trusting it.

`v5/fixtures/network.json` is a real capture from this MacBook (2026-10-23),
sanitised: tailnet node addresses are `100.100.x`, the tailnet DNS name is
`example-tailnet.ts.net`, ether addresses are zeroed. The LAN gateway and the
bridge addresses are as recorded. `v5/fixtures/network_down.json` is the same
host with the LAN, DNS and tunnel down, built by hand so every check has one
failing input.

Re-record:

    ping -c 5 -W 1000 <tailnet-peer>       > ping_gateway.txt
    ping -c 5 -W 1000 1.1.1.1              > ping_public.txt
    ping -c 20 -i 0.5 -W 1000 1.1.1.1      > ping_jitter.txt
    netstat -rn -f inet                    > netstat.txt
    ifconfig                               > ifconfig.txt
    scutil --dns                           > scutil.txt
    tailscale status --json                > tailscale.json

then paste the texts into the `commands` object and the tailscale fields into
`tailscale`, and replace the tailnet addresses before committing.

## Contract for F8a

    ACTIONS = {"<name>": {"class", "doc", "plan", "run", "linux_only"}}

`plan(ctx=None)` returns the dry-run object with `items`, `bytes` and
`total_bytes` (always 0 here, nothing is deleted), `commands` (exact argv),
`effect`, `interrupts`, `needs_confirmation`, `changes_nothing`, and for
latency and jitter a `cache` block.

`run(ctx=None, confirm=None)` performs the action. With `ctx["dry_run"]` true
it returns the plan with `ran: false`. `confirm` is accepted and ignored: no
action here is reversible or destructive.

`ctx` may be a dict or an object; these keys are read, everything else is
ignored: `fixture`, `runner`, `now`, `dry_run`, `host`, `state_dir`,
`cache_dir`, `cache_path`, `tailnet_gateway`, `target`, `dns_name`, `cache`,
`ping_cmd`. `runner` is `(argv, timeout) -> (stdout, stderr, code)` and exists
so a test can prove no command ran.

## Self-check

    python3 nexuslink.hud/v5/feeds/hudfix_network.py --self-check

exit 0 and 17 checks, each named in the JSON: the action table and classes; the
binary allowlist over fixture plans, live plans and real calls; the CLI
contract (`--list` is one line, unknown action exit 2); a missing named fixture
is exit 2; latency and jitter numbers identical twice from the fixture; the
three verdict thresholds plus 2 percent and 100 percent loss; the route parse;
connectivity all true, all false, and one flipped input at a time; the cache
answering the second call command free and expiring after 10 s; fixture mode
creating no file; `flush-dns` calling neither the runner nor `subprocess` in a
plan or a dry run; the host refusals; no absolute home path; and five plans
leaving the state dir byte identical.

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
`net_entry`, `null_entry` and `ping_host_error` are copied from it and keep its
JSON keys (`rtt_ms`, `jitter_ms`, `loss`, `samples`, `host`, `reason`) so the
two readers can never disagree about the same ping. The copy adds `count` and
`interval` arguments and `parse_ping_times` / `parse_ping_counts` for the
jitter statistics. When F3 merges, F8a can import `game_mode.parse_ping` and
delete the copy; the key names stay.
