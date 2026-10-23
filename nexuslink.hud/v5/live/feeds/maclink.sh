#!/usr/bin/env bash
# Mac link sample: one JSON line on stdout, link.json shape.
# Bounded: tailscale ping 2s, ssh 3s connect (cached 10s), always exit 0.
# Read-only on the Mac: pmset, sysctl, and `hermes kanban list --json` (no writes).
set -u

CACHE_DIR="${XDG_RUNTIME_DIR:-/tmp}/nexuslink-v5"
mkdir -p "$CACHE_DIR" 2>/dev/null || CACHE_DIR="/tmp/nexuslink-v5"
mkdir -p "$CACHE_DIR" 2>/dev/null
RING="$CACHE_DIR/maclink-rtt"
MACJSON="$CACHE_DIR/maclink-mac.json"
LOCK="$CACHE_DIR/maclink-ssh.lock"
KAN="$CACHE_DIR/maclink-kanban.json"
KLOCK="$CACHE_DIR/maclink-kanban.lock"
NOW=$(date +%s)

# ---- tailnet peer name for the Mac (never print keys)
PEER=$(tailscale status 2>/dev/null | awk '$4=="macOS" && $0 !~ /offline/ {print $2; exit}')
[ -n "${PEER:-}" ] || PEER=$(tailscale status 2>/dev/null | awk '$4=="macOS" {print $2; exit}')

TUNNEL="down"; ROUTE="none"; RTT=""
if [ -n "${PEER:-}" ]; then
    PING=$(tailscale ping --c 1 --timeout 2s "$PEER" 2>/dev/null)
    RTT=$(printf '%s\n' "$PING" | sed -n 's/.* in \([0-9][0-9.]*\)ms.*/\1/p' | head -1)
    case "$PING" in
        *"via DERP"*) ROUTE="relay" ;;
        *"via "*"direct"*|*pong*) ROUTE="direct" ;;
    esac
    [ -n "$RTT" ] && TUNNEL="active"
fi

# ---- ring buffer, last 60 samples (one per 12 s poll, about 12 minutes)
if [ -n "$RTT" ]; then
    printf '%s %s\n' "$NOW" "$RTT" >> "$RING" 2>/dev/null
    tail -n 60 "$RING" > "$RING.tmp" 2>/dev/null && mv "$RING.tmp" "$RING"
fi
SAMPLES="[]"; LAST="null"; MED="null"; MIN="null"; MAX="null"
if [ -s "$RING" ]; then
    read -r LAST MED MIN MAX SAMPLES < <(awk '
        { v[n++]=$2; s=s (n>1?",":"") $2 }
        END {
            if (n==0) { print "null null null null []"; exit }
            for (i=0;i<n;i++) for (j=i+1;j<n;j++) if (v[j]<v[i]) { t=v[i]; v[i]=v[j]; v[j]=t }
            m=(n%2)?v[int(n/2)]:(v[n/2-1]+v[n/2])/2
            # last raw sample is the last line of the ring, not the sorted array
            printf "%s %.2f %.2f %.2f [%s]\n", last, m, v[0], v[n-1], s
        }' last="$(tail -1 "$RING" | awk '{print $2}')" "$RING")
fi

# ---- battery, load, thermal: ssh once per 10s, flock so parallel feeds cannot stack
fresh() { [ -f "$MACJSON" ] && [ $(( $(date +%s) - $(stat -c %Y "$MACJSON" 2>/dev/null || echo 0) )) -lt 10 ]; }
if ! fresh; then
    (
        flock -w 5 9 || exit 0
        fresh && exit 0
        RAW=$(timeout 12 ssh -o BatchMode=yes -o ConnectTimeout=3 mac \
            'pmset -g batt; sysctl -n vm.loadavg; sysctl -n kern.boottime; pmset -g therm' 2>/dev/null) || exit 0
        [ -n "$RAW" ] || exit 0
        printf '%s\n' "$RAW" | awk '
            BEGIN { batt="null"; state="null"; rem="null"; up="null"; loads="[null,null,null]"; th="null" }
            /%/ {
                if (match($0, /[0-9]+%/)) { batt=substr($0, RSTART, RLENGTH-1) }
                if (match($0, /%; *[A-Za-z ]+/)) {
                    state=substr($0, RSTART+2, RLENGTH-2); sub(/^ +/,"",state); sub(/ +$/,"",state)
                    state="\"" state "\""
                }
                if (match($0, /[0-9]+:[0-9]+ remaining/)) { rem=substr($0, RSTART, RLENGTH-10); rem="\"" rem "\"" }
            }
            /^\{/ && /[0-9]\.[0-9]/ {
                gsub(/[{}]/,""); n=split($0,a," "); if (n>=3) loads="[" a[1] "," a[2] "," a[3] "]"
            }
            /sec =/ {
                if (match($0, /sec = [0-9]+/)) { s=substr($0, RSTART+6, RLENGTH-6); if (s+0>0) up=int((systime()-s)/60) }
            }
            /No thermal warning level/ { th="\"nominal\"" }
            /CPU_Speed_Limit/ {
                if (match($0, /= *[0-9]+/)) {
                    v=substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", v)
                    th=(v+0 < 100) ? "\"throttled\"" : "\"nominal\""
                }
            }
            END { printf "{\"batt\":%s,\"state\":%s,\"rem\":%s,\"load\":%s,\"up_min\":%s,\"thermal\":%s}\n", batt, state, rem, loads, (up=="null"?"null":up), th }
        ' > "$MACJSON.tmp" 2>/dev/null && mv "$MACJSON.tmp" "$MACJSON"
    ) 9>"$LOCK"
fi
MAC=$(cat "$MACJSON" 2>/dev/null)
case "$MAC" in \{*) : ;; *) MAC='{"batt":null,"state":null,"rem":null,"load":[null,null,null],"up_min":null,"thermal":null}' ;; esac

# ---- Mac Kanban queue counts (running, ready, blocked): own 30 s cache, one ssh per 30 s.
# The Mac counts the top-level task status keys (4-space indent); only counts cross the wire.
kfresh() { [ -f "$KAN" ] && [ $(( $(date +%s) - $(stat -c %Y "$KAN" 2>/dev/null || echo 0) )) -lt 30 ]; }
if ! kfresh; then
    (
        flock -w 5 8 || exit 0
        kfresh && exit 0
        RAW=$(timeout 12 ssh -o BatchMode=yes -o ConnectTimeout=3 mac \
            'H="$HOME/.local/bin/hermes"; [ -x "$H" ] || H="$HOME/.hermes/hermes-agent/.hermes/bin/hermes"; env -u HERMES_DELEGATED_CHILD_CONTEXT -u HERMES_KANBAN_TASK -u HERMES_KANBAN_RUN_ID -u HERMES_KANBAN_CLAIM_LOCK "$H" kanban list --json 2>/dev/null | sed -n "s/^    .status.: *.\([a-z_]*\).*/\1/p" | sort | uniq -c' 2>/dev/null)
        [ -n "$RAW" ] || exit 0
        printf '%s\n' "$RAW" | awk '
            { c[$2]=$1 }
            END { printf "{\"running\":%d,\"ready\":%d,\"blocked\":%d}\n", c["running"]+0, c["ready"]+0, c["blocked"]+0 }
        ' > "$KAN.tmp" 2>/dev/null && mv "$KAN.tmp" "$KAN"
    ) 8>"$KLOCK"
fi
KANJ=$(cat "$KAN" 2>/dev/null)
case "$KANJ" in \{*) : ;; *) KANJ=null ;; esac
MAC="${MAC%\}}"
MAC="$MAC,\"kanban\":$KANJ}"

printf '{"ts":%s,"ts_iso":"%s","route":"%s","tunnel":"%s","rtt_ms":{"last":%s,"median":%s,"min":%s,"max":%s,"samples":%s},"pulse_period_s":2.932,"mac":%s}\n' \
    "$NOW" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ROUTE" "$TUNNEL" \
    "$LAST" "$MED" "$MIN" "$MAX" "$SAMPLES" "$MAC"
exit 0
