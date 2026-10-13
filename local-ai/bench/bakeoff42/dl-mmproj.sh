#!/usr/bin/env bash
# dl-mmproj.sh: fetch Ministral BF16 mmproj (R4: downloads need no GPU lock). Verifies size + sha256.
set -uo pipefail
cd /home/nexuslink/NEXUS_AI_CENTER/LOCAL-AI-LAB
D=models/llm/mistralai/Ministral-3-14B-Instruct-2512-GGUF
F=$D/Ministral-3-14B-Instruct-2512-BF16-mmproj.gguf
URL=https://huggingface.co/mistralai/Ministral-3-14B-Instruct-2512-GGUF/resolve/main/Ministral-3-14B-Instruct-2512-BF16-mmproj.gguf
EXP=879258784
SHA=ab7616148b7081030fd38e410c9213ce8346a8b0588291c8ca279058e78cfae7
echo "[$(date +%T)] start mmproj dl"
nice -n 10 ionice -c 3 curl -L --fail --retry 3 -C - -o "$F.part" "$URL" || { echo "DL FAILED"; exit 1; }
mv -f "$F.part" "$F"
SZ=$(stat -c%s "$F"); echo "[$(date +%T)] size $SZ exp $EXP"
[ "$SZ" = "$EXP" ] || { echo "SIZE MISMATCH"; exit 1; }
GOT=$(sha256sum "$F" | awk '{print $1}'); [ "$GOT" = "$SHA" ] && echo "[$(date +%T)] sha ok" || { echo "SHA MISMATCH $GOT"; exit 1; }
echo DONE
