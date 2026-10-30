#!/usr/bin/env bash
# Week 2: same code, same role, same model. Inside the VPC it works,
# outside the VPC the role's aws:SourceVpce condition refuses it.
set -u
PREFIX=${1:-aiplat}
DIR=$(cd "$(dirname "$0")" && pwd)
MODEL=$(cd "$DIR/../infra/week02-private-model" && terraform output -raw model_id)
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1 (expected $3, got $2)"; fail=$((fail+1)); fi; }

echo "Calling $MODEL from inside the VPC (first call can take ~10s while Lambda attaches to the VPC)..."
IN=$("$DIR/probe.sh" "$PREFIX-prober" "{\"action\":\"probe\",\"model_id\":\"$MODEL\"}")
echo "$IN" | python3 -m json.tool
check "Bedrock resolves to private IPs inside the VPC" "$(echo "$IN" | python3 -c 'import json,sys;print(json.load(sys.stdin)["dns"]["private"])')" "True"
check "the model answers through the endpoint"        "$(echo "$IN" | python3 -c 'import json,sys;print(json.load(sys.stdin)["converse"]["status"])')" "OK"

echo; echo "Same call from the copy OUTSIDE the VPC..."
OUT=$("$DIR/probe.sh" "$PREFIX-prober-outside" "{\"action\":\"probe\",\"model_id\":\"$MODEL\"}")
echo "$OUT" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("  dns:",d["dns"]);print("  converse:",d["converse"])'
check "outside the VPC the same role is denied" "$(echo "$OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["converse"].get("error"))')" "AccessDeniedException"

echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
