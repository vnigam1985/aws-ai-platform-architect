#!/usr/bin/env bash
# Week 8: run the golden questions against the live app from inside the VPC.
# Exit 0 = GO, 1 = NO-GO.
set -euo pipefail
PREFIX=${1:-aiplat}
DIR=$(cd "$(dirname "$0")" && pwd)
APP=${APP_URL:-$(cd "$DIR/../infra/week05-private-app" && terraform output -raw app_url)}
CASES=$(python3 -c 'import json;print(json.dumps(json.load(open("'"$DIR"'/../evals/release-gate.json"))["cases"]))')
R=$("$DIR/probe.sh" "$PREFIX-prober" "{\"action\":\"eval\",\"url\":\"$APP\",\"cases\":$CASES}")
echo "$R" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for r in d["results"]:
    print(("PASS " if r["pass"] else "FAIL ") + r["id"] + ("" if r["pass"] else f"  missing={r[\"missing\"]} forbidden={r[\"forbidden\"]} answer={r[\"answer\"][:100]!r}"))
print(f"\nRELEASE GATE: {d[\"passed\"]}/{d[\"total\"]} passed -> {d[\"gate\"]}")
sys.exit(0 if d["gate"] == "GO" else 1)'
