#!/usr/bin/env python3
"""secret scan fallback (no gitleaks). usage: secret_scan.py FILE...   prints file:line:rule only, never the value. exit 1 on hit"""
import re, sys, os
R = {
 "sk-key": r"\bsk-[A-Za-z0-9_\-]{20,}", "ghp/pat": r"\b(ghp_|gho_|ghu_|ghs_|github_pat_)[A-Za-z0-9_]{20,}",
 "hf_": r"\bhf_[A-Za-z0-9]{20,}", "AKIA": r"\bAKIA[0-9A-Z]{16}\b", "slack": r"\bxox[abprs]-[A-Za-z0-9\-]{10,}",
 "private-key": r"-----BEGIN [A-Z ]*PRIVATE KEY-----", "bearer": r"\bBearer\s+[A-Za-z0-9._\-]{20,}",
 "lek-token": r"lek_l[i]ve", "assign": r"(?i)\b(api[_-]?key|secret|passw(or)?d|token|auth)\b[\"']?\s*[:=]\s*[\"']?[A-Za-z0-9/+_\-]{16,}",
 "iban": r"\b[A-Z]{2}\d{2}(?:\s?\d{4}){3,6}\b",
}
RX = {k: re.compile(v) for k, v in R.items()}
BADNAME = re.compile(r"(^|/)(\.env(\..*)?|auth\.json|auth\.lock|state\.db.*|.*\.pem|.*\.key|id_rsa.*)$")
hits = 0
for f in sys.argv[1:]:
    if BADNAME.search(f): print(f"{f}:0:forbidden-filename"); hits += 1; continue
    try: data = open(f, "rb").read()
    except Exception as e: print(f"{f}:0:unreadable"); hits += 1; continue
    if b"\0" in data[:4096]: print(f"{f}:0:binary"); hits += 1; continue
    for i, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
        for k, rx in RX.items():
            if rx.search(line): print(f"{f}:{i}:{k}"); hits += 1
print(f"scanned {len(sys.argv)-1} files, {hits} hits")
sys.exit(1 if hits else 0)
