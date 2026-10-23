#!/usr/bin/env bash
# Mac link sample: one JSON line on stdout, link.json shape.
# Bounded: tailscale ping 2s, ssh 3s connect (cached 10s), always exit 0.
set -u

CACHE_DIR="${XDG_RUNTIME_DIR:-/tmp}/nexuslink-v5"
mkdir -p "$CACHE_DIR" 2>/dev/null || CACHE_DIR="/tmp/nexuslink-v5"
mkdir -p "$CACHE_DIR" 2>/dev/null
RING="$CACHE_DIR/maclink-rtt"
MACJSON="$CACHE_DIR/maclink-mac.json"
LOCK="$CACHE_DIR/maclink-ssh.lock"
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

# ---- ring buffer, last 24 samples
if [ -n "$RTT" ]; then
    printf '%s %s\n' "$NOW" "$RTT" >> "$RING" 2>/dev/null
    tail -n 24 "$RING" > "$RING.tmp" 2>/dev/null && mv "$RING.tmp" "$RING"
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

# ---- ssh once per 10s, flock so parallel feeds cannot stack
fresh() { [ -f "$MACJSON" ] && [ $(( $(date +%s) - $(stat -c %Y "$MACJSON" 2>/dev/null || echo 0) )) -lt 10 ]; }
if ! fresh; then
    (
        flock -w 5 9 || exit 0
        fresh && exit 0
        RAW=$(timeout 12 ssh -o BatchMode=yes -o ConnectTimeout=3 mac \
            'pmset -g batt; sysctl -n vm.loadavg; sysctl -n kern.boottime' 2>/dev/null) || exit 0
        [ -n "$RAW" ] || exit 0
        printf '%s\n' "$RAW" | awk '
            BEGIN { batt="null"; state="null"; rem="null"; up="null"; loads="[null,null,null]" }
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
            END { printf "{\"batt\":%s,\"state\":%s,\"rem\":%s,\"load\":%s,\"up_min\":%s}\n", batt, state, rem, loads, (up=="null"?"null":up) }
        ' > "$MACJSON.tmp" 2>/dev/null && mv "$MACJSON.tmp" "$MACJSON"
    ) 9>"$LOCK"
fi
MAC=$(cat "$MACJSON" 2>/dev/null)
case "$MAC" in \{*) : ;; *) MAC='{"batt":null,"state":null,"rem":null,"load":[null,null,null],"up_min":null}' ;; esac

printf '{"ts":%s,"ts_iso":"%s","route":"%s","tunnel":"%s","rtt_ms":{"last":%s,"median":%s,"min":%s,"max":%s,"samples":%s},"pulse_period_s":2.932,"mac":%s}\n' \
    "$NOW" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ROUTE" "$TUNNEL" \
    "$LAST" "$MED" "$MIN" "$MAX" "$SAMPLES" "$MAC"
exit 0
