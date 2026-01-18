#!/usr/bin/env python3
import json
import sys
from pathlib import Path

log_file = Path(sys.argv[1])

score = 0
reasons = set()
urls = set()
executed_scripts = set()
files = set()
execs = set()

seen_tmp_drop = False
seen_network_tool = False
executions = []


SYSTEM_WHITELIST = (
    "/etc/ld.so.cache",
    "/etc/localtime",
    "/usr/lib/",
    "/lib/",
    "/proc/self",
    "/proc/sys",
    "/tmp/sample.sh"
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
                files.add(path)
                score += 1
                reasons.add(f"File dropped in /tmp: {path}")
                seen_tmp_drop = True

            elif path.startswith("/etc/"):
                score += 2
                reasons.add("Sensitive /etc access")

            elif path.startswith("/proc/"):
                score += 2
                reasons.add("Process introspection via /proc")

        elif event["type"] == "exec":
            binary = event.get("file", "")
            arg1 = event.get("arg1", "")
            arg2 = event.get("arg2", "")

            executions.append({
                "binary": binary,
                "arg1": arg1,
                "arg2": arg2
            })

            # Bash qui exécute un script
            if binary.endswith("/bash") and arg1.startswith("/"):
                executed_scripts.add(arg1)
                score += 1
                reasons.add(f"Bash executed script: {arg1}")

            # Curl / Wget → URL
            if binary.endswith("/curl") and arg1.startswith("http"):
                urls.add(arg1)
                score += 3
                reasons.add("Outbound network access via curl")

# /tmp drop score (once)
#if any(p.startswith("/tmp/") for p in files):
#    score += 1
for f in files:
    if f in executed_scripts:
        score += 2
        reasons.add(f"Executed dropped file: {f}")

if seen_tmp_drop and seen_network_tool:
    score += 5
    reasons.add("Downloaded or staged payload executed from /tmp")
    cmd = event.get("comm", "")
    if not cmd:
        pass
    binary = event.get("file", "")
    arg1 = event.get("arg1", "")
    arg2 = event.get("arg2", "")

    executions.append({
        "binary": binary,
        "arg1": arg1,
        "arg2": arg2
    })

    # Bash qui exécute un script
    if binary.endswith("/bash") and arg1.startswith("/"):
        executed_scripts.add(arg1)
        score += 1
        reasons.add(f"Bash executed script: {arg1}")

    # Curl / Wget → URL
    if binary.endswith("/curl") and arg1.startswith("http"):
        urls.add(arg1)
        score += 3
        reasons.add("Outbound network access via curl")

# /tmp drop score (once)
#if any(p.startswith("/tmp/") for p in files):
#    score += 1
for f in files:
    if f in executed_scripts:
        score += 2
        reasons.add(f"Executed dropped file: {f}")

if seen_tmp_drop and seen_network_tool:
    score += 5
    reasons.add("Downloaded or staged payload executed from /tmp")

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
        "reasons": sorted(reasons)
    },
    "files": sorted(files),
    "executions": executions,
    "network": {
        "urls": sorted(urls)
    }
}

print(json.dumps(report, indent=2))
