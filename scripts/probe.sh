#!/usr/bin/env bash
# Send a JSON event to a prober Lambda and print the result.
# Usage: probe.sh <function-name> '<json payload>'
set -euo pipefail
FN=$1; PAYLOAD=$2
OUT=$(mktemp)
aws lambda invoke --function-name "$FN" --cli-binary-format raw-in-base64-out \
  --payload "$PAYLOAD" "$OUT" > /dev/null
cat "$OUT"; rm -f "$OUT"
