#!/usr/bin/env python3
import json
import sys
from pathlib import Path

log_file = Path(sys.argv[1])

score = 0
reasons = set()

files = set()
execs = set()

SYSTEM_WHITELIST = (
    "/etc/ld.so.cache",
    "/etc/localtime",
    "/usr/lib/",
    "/lib/",
    "/proc/self",
    "/proc/sys",
)

def is_whitelisted(path):
    return any(path.startswith(w) for w in SYSTEM_WHITELIST)

with log_file.open() as f:
    for line in f:
        if not line.startswith("{"):
            continue

        event = json.loads(line)

        if event["type"] == "open":
            path = event.get("file", "")
            if not path or is_whitelisted(path):
                continue

            files.add(path)

            if path.startswith("/tmp/"):
                reasons.add(f"File dropped in /tmp: {path}")

            elif path.startswith("/etc/"):
                score += 2
                reasons.add("Sensitive /etc access")

            elif path.startswith("/proc/"):
                score += 2
                reasons.add("Process introspection via /proc")

        elif event["type"] == "exec":
            cmd = event.get("comm", "")
            if not cmd:
                continue

            execs.add(cmd)

            if cmd in ("curl", "wget"):
                score += 3
                reasons.add("Outbound network tool execution")

            if cmd in ("bash", "sh"):
                score += 1
                reasons.add("Shell execution")

# /tmp drop score (once)
if any(p.startswith("/tmp/") for p in files):
    score += 1

# Verdict
if score >= 6:
    verdict = "malicious"
elif score >= 3:
    verdict = "suspicious"
else:
    verdict = "clean"

report = {
    "summary": {
        "verdict": verdict,
        "score": score,
        "reasons": sorted(reasons),
    },
    "files": sorted(files),
    "executions": sorted(execs),
}

print(json.dumps(report, indent=2))
