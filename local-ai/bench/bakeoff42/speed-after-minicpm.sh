#!/usr/bin/env bash
# Waits for the MiniCPM suite (pid $1), then runs the decode speed push. File-based: no driver names in waiter argv.
while kill -0 "$1" 2>/dev/null; do sleep 20; done
cd ~/NEXUS_AI_CENTER/LOCAL-AI-LAB && bash bench/bakeoff42/speed-push.sh --skip pinned
echo "SPEED-PUSH rc=$? $(date +%T)"
