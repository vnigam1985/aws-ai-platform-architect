#!/usr/bin/env bash
# Week 5: create the bank app's team key on the gateway and store it in
# Secrets Manager, where ECS injects it into the app as OPENAI_API_KEY.
set -euo pipefail
PREFIX=${1:-aiplat}
DIR=$(cd "$(dirname "$0")" && pwd)
W4="$DIR/../infra/week04-ai-gateway"; W5="$DIR/../infra/week05-private-app"
GW=$(cd "$W4" && terraform output -raw gateway_url)
MASTER=$(aws secretsmanager get-secret-value --secret-id "$(cd "$W4" && terraform output -raw master_key_secret)" --query SecretString --output text)
SECRET=$(cd "$W5" && terraform output -raw team_key_secret)
KEY="sk-team-retail-bank-$(openssl rand -hex 8)"
R=$("$DIR/probe.sh" "$PREFIX-prober" "{\"action\":\"http\",\"method\":\"POST\",\"url\":\"$GW/key/generate\",\"headers\":{\"Authorization\":\"Bearer $MASTER\"},\"body\":{\"key\":\"$KEY\",\"key_alias\":\"retail-banking-app\",\"models\":[\"bank-chat\"],\"rpm_limit\":60,\"tpm_limit\":20000,\"metadata\":{\"team\":\"retail-banking\"}}}")
echo "$R" | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if d.get("status")==200 else (print("Gateway said:",d) or 1))'
aws secretsmanager put-secret-value --secret-id "$SECRET" --secret-string "$KEY" > /dev/null
echo "Team key created on the gateway and stored in $SECRET"
