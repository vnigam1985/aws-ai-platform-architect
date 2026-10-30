#!/usr/bin/env bash
# Week 4: test the AI gateway from inside the VPC (through the prober Lambda).
# The gateway is on an internal load balancer: your laptop can't reach it.
set -u
PREFIX=${1:-aiplat}
DIR=$(cd "$(dirname "$0")" && pwd)
W4="$DIR/../infra/week04-ai-gateway"
GW=$(cd "$W4" && terraform output -raw gateway_url)
MASTER=$(aws secretsmanager get-secret-value --secret-id "$(cd "$W4" && terraform output -raw master_key_secret)" --query SecretString --output text)
FN="$PREFIX-prober"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1 (expected $3, got $2)"; fail=$((fail+1)); fi; }
http() { "$DIR/probe.sh" "$FN" "$1"; }
code() { python3 -c 'import json,sys;print(json.load(sys.stdin).get("status"))'; }
chat() { echo "{\"action\":\"http\",\"method\":\"POST\",\"url\":\"$GW/v1/chat/completions\",\"headers\":{\"Authorization\":\"Bearer $1\"},\"body\":{\"model\":\"$2\",\"max_tokens\":60,\"messages\":[{\"role\":\"user\",\"content\":\"$3\"}]}}"; }

echo "Gateway: $GW (internal). Waking the database if it's paused can take ~15 seconds."
check "gateway is healthy"                 "$(http "{\"action\":\"http\",\"url\":\"$GW/health/liveliness\"}" | code)" "200"

# A demo team key: 2 requests per minute, only the bank-chat model.
DEMO="sk-team-demo-$(date +%s)"
http "{\"action\":\"http\",\"method\":\"POST\",\"url\":\"$GW/key/generate\",\"headers\":{\"Authorization\":\"Bearer $MASTER\"},\"body\":{\"key\":\"$DEMO\",\"key_alias\":\"$DEMO\",\"models\":[\"bank-chat\"],\"rpm_limit\":2}}" > /dev/null

check "a made-up key is refused (401)"     "$(http "$(chat none bank-chat hi)" | code)" "401"
R=$(http "$(chat "$DEMO" bank-chat 'What does an AI gateway do? One sentence.')")
check "team key works (200)"               "$(echo "$R" | code)" "200"
echo "$R" | python3 -c 'import json,sys;b=json.load(sys.stdin)["body"];print("      answer:", b["choices"][0]["message"]["content"] if isinstance(b,dict) and "choices" in b else b)'
check "team key can't use other models (403)" "$(http "$(chat "$DEMO" some-other-model hi)" | code)" "403"
c3=$(http "$(chat "$DEMO" bank-chat hi)" | code)
check "3rd call in a minute is throttled (429)" "$c3" "429"

echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
