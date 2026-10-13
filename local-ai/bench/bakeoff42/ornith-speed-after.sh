#!/usr/bin/env bash
# After the running speed sweep (pid $1): Ornith points again, pinned (as in its suite).
while kill -0 "$1" 2>/dev/null; do sleep 20; done
cd ~/NEXUS_AI_CENTER/LOCAL-AI-LAB && bash bench/bakeoff42/speed-push.sh --only '^or-'
echo "ORNITH-SPEED rc=$? $(date +%T)"
