#!/usr/bin/env python3
"""Stub feed reader for the stale scenario (tests/stale). Not a real reader.

  stale_reader.py once3 COUNTFILE   answers on calls 1 and 3, prints a good
                                    payload with a fresh generated_at; silent
                                    (exit 1) on call 2 and from call 4 on.
                                    The call count lives in COUNTFILE.
  stale_reader.py hang              never answers. The DeckMain watchdog kills it.
"""
import datetime
import json
import os
import sys
import time


def main(argv):
    mode = argv[1] if len(argv) > 1 else "hang"
    if mode == "hang":
        time.sleep(600)
        return 0
    if mode == "once3" and len(argv) > 2:
        path = argv[2]
        count = 0
        if os.path.exists(path):
            with open(path) as handle:
                count = int(handle.read().strip() or 0)
        count += 1
        with open(path, "w") as handle:
            handle.write(str(count))
        if count in (1, 3):
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            print(json.dumps({"ok": True, "generated_at": stamp,
                              "rtt_ms": {"median": 7.5}, "mac": {"batt": 90, "load": [1.2]}}))
            return 0
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
