#!/usr/bin/env bash
# Ornith 256K, then MiniCPM 256K. File-based chain: no waiter argv contains a driver name.
cd ~/NEXUS_AI_CENTER/LOCAL-AI-LAB
CHALLENGERS=ornith-9b bash bench/bakeoff42/run-challengers.sh; echo "ORNITH-256K rc=$? $(date +%T)"
bash bench/bakeoff42/run-minicpm.sh; echo "MINICPM-256K rc=$? $(date +%T)"
