#!/usr/bin/env bash
# Prints the UDID of an available iPhone simulator on the newest iOS runtime.
# Prefers an "iPhone 14"-class (non-Pro) model when the runtime still has one.
set -euo pipefail
xcrun simctl list devices available -j | python3 -c '
import json, sys, re
devs = json.load(sys.stdin)["devices"]
def ver(k):
    m = re.search(r"iOS-(\d+)-(\d+)", k)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)
for runtime in sorted((k for k in devs if "iOS" in k), key=ver, reverse=True):
    phones = [d for d in devs[runtime] if d["name"].startswith("iPhone")]
    if not phones:
        continue
    plain = [d for d in phones if "Pro" not in d["name"] and "Plus" not in d["name"] and "Max" not in d["name"]]
    pick = (plain or phones)[0]
    print(pick["udid"])
    print(f"{pick['"'"'name'"'"']} ({runtime})", file=sys.stderr)
    break
'
