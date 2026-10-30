#!/usr/bin/env bash
# Week 5: ask the private bank app questions, from inside the VPC.
set -u
PREFIX=${1:-aiplat}
DIR=$(cd "$(dirname "$0")" && pwd)
APP=$(cd "$DIR/../infra/week05-private-app" && terraform output -raw app_url)
p() { "$DIR/probe.sh" "$PREFIX-prober" "$1"; }
echo "== Health =="
p "{\"action\":\"http\",\"url\":\"$APP/health\"}"; echo
echo "== Ask: app -> gateway -> Bedrock (with guardrail) =="
p "{\"action\":\"http\",\"method\":\"POST\",\"url\":\"$APP/ask\",\"body\":{\"question\":\"How much does an international wire transfer cost?\"}}" \
  | python3 -c 'import json,sys;b=json.load(sys.stdin)["body"];print("Answer:",b.get("answer"));print("Mode:",b.get("mode"),"| latency ms:",b.get("latency_ms"))'
echo "== Agent: money moves only with confirmation =="
p "{\"action\":\"http\",\"method\":\"POST\",\"url\":\"$APP/agent\",\"body\":{\"message\":\"Transfer 200 dollars from CHQ-1001 to SAV-2002\"}}" \
  | python3 -c 'import json,sys;b=json.load(sys.stdin)["body"];print("Answer:",b.get("answer"));print("Tool calls:",b.get("tool_calls"))'
