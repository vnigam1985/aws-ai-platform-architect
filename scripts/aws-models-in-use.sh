#!/usr/bin/env bash
# Week 8: list the models the platform actually serves, as JSON for
# check_model_inventory.py. Sources of truth:
#   - the gateway's ECS task definition (BANK_MODEL)
#   - application inference profiles in the account (what each one copies)
set -euo pipefail
PREFIX=${1:-aiplat}
TD=$(aws ecs describe-services --cluster "$PREFIX-cluster" --services ai-gateway --query "services[0].taskDefinition" --output text)
BANK_MODEL=$(aws ecs describe-task-definition --task-definition "$TD" \
  --query "taskDefinition.containerDefinitions[0].environment[?name=='BANK_MODEL'].value | [0]" --output text)
PROFILES=$(aws bedrock list-inference-profiles --type-equals APPLICATION --output json)
python3 - "$BANK_MODEL" "$PROFILES" <<'PY'
import json, sys
bank_model, profiles = sys.argv[1], json.loads(sys.argv[2])
def kind(model_id):
    if model_id.startswith("global."): return "global-cross-region"
    if model_id.startswith("ca."): return "canada-cross-region"
    if model_id.startswith(("us.", "eu.", "apac.")): return "geo-cross-region-outside-canada"
    return "in-region"
def source_of(profile):
    # An application profile copied from the ca. profile lists the model in both
    # Canadian Regions. Report it the way the inventory names it.
    arns = [m["modelArn"] for m in profile.get("models", [])]
    base = arns[0].split("/")[-1]
    regions = {a.split(":")[3] for a in arns}
    if len(arns) > 1 and regions <= {"ca-central-1", "ca-west-1"}:
        return "ca." + base
    return base

target = bank_model.removeprefix("bedrock/converse/").removeprefix("bedrock/")
out = []
by_arn = {p["inferenceProfileArn"]: p for p in profiles.get("inferenceProfileSummaries", [])}
if target in by_arn:
    src = source_of(by_arn[target])
    out.append({"deployment_name": "gateway:bank-chat", "provider_model": src, "deployment_type": kind(src), "via": by_arn[target]["inferenceProfileName"]})
else:
    out.append({"deployment_name": "gateway:bank-chat", "provider_model": target, "deployment_type": kind(target)})
for arn, p in by_arn.items():
    if arn == target: continue
    src = source_of(p)
    out.append({"deployment_name": "profile:" + p["inferenceProfileName"], "provider_model": src, "deployment_type": kind(src)})
print(json.dumps(out, indent=2))
PY
