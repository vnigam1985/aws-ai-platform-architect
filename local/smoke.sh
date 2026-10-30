#!/usr/bin/env bash
# Week 0 smoke test. Proves the request path app -> gateway -> model works,
# and that the gateway enforces keys, model access and rate limits.
set -u
GW=${GW:-http://localhost:4000}
APP=${APP:-http://localhost:8000}
TEAM_KEY=${TEAM_KEY:-sk-team-retail-bank}
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1 (expected $3, got $2)"; fail=$((fail+1)); fi; }
call() { curl -s -o /dev/null -w '%{http_code}' "$GW/v1/chat/completions" -H "Content-Type: application/json" "$@"; }
body='{"model":"mock","messages":[{"role":"user","content":"hi"}]}'

check "no key is refused (401)"            "$(call -d "$body")" "401"
check "wrong key is refused (401)"         "$(call -H 'Authorization: Bearer sk-not-a-real-key-123' -d "$body")" "401"
check "team key works (200)"               "$(call -H "Authorization: Bearer $TEAM_KEY" -d "$body")" "200"
check "team key can't use other models (403)" "$(call -H "Authorization: Bearer $TEAM_KEY" -d '{"model":"gpt-5","messages":[{"role":"user","content":"hi"}]}')" "403"

# Rate limit: a demo key that allows only 2 requests per minute.
TEAM_KEY=sk-team-ratelimit-demo RPM=2 "$(dirname "$0")/team-key.sh" > /dev/null
codes=""
for i in 1 2 3; do codes="$codes$(call -H 'Authorization: Bearer sk-team-ratelimit-demo' -d "$body") "; done
check "3rd call in a minute is throttled (429)" "$(echo $codes | awk '{print $3}')" "429"

check "app answers through the gateway"    "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$APP/ask" -H 'Content-Type: application/json' -d '{"question":"How much is an international wire transfer?"}')" "200"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
