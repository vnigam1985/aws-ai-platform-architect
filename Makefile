# AWS AI Platform Architect: 8-week build-along course. `make help` lists everything.
# Override settings like: make week1 PREFIX=mylab

SHELL   := /bin/bash
REGION  ?= ca-central-1
PREFIX  ?= aiplat
EMAIL   ?=
TF      := terraform
TFVARS  := -var region=$(REGION) -var prefix=$(PREFIX)
APPLY    = cd infra/$(1) && $(TF) init -input=false -upgrade >/dev/null && $(TF) apply -input=false -auto-approve $(TFVARS) $(2)
OUT      = $$(cd infra/$(1) && $(TF) output -raw $(2))
PROBE    = ./scripts/probe.sh

.DEFAULT_GOAL := help
help: ## Show all commands
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ----------------------------------------------------- week 0: local, $0 -----
local-up: ## Week 0: start app + LiteLLM gateway + Ollama locally (free)
	docker compose up -d --build
	docker compose exec ollama ollama pull qwen2.5:3b

local-keys: ## Week 0: create the bank app's team key on the local gateway
	./local/team-key.sh

local-test: ## Week 0: prove keys, model access and rate limits on the local gateway
	./local/smoke.sh

local-down: ## Week 0: stop the local lab
	docker compose down

check: ## Week 0: show which AWS account you're about to spend money in
	@aws sts get-caller-identity --query "{account:Account, arn:Arn}" --output table
	@echo "Region: $(REGION)   Prefix: $(PREFIX)   Alerts to: $(EMAIL)"

week0: ## Week 0: budget alert (needs EMAIL=you@example.com)
	@test -n "$(EMAIL)" || (echo "Set EMAIL=you@example.com" && exit 1)
	$(call APPLY,week00-budget,-var email=$(EMAIL))

# ---------------------------------------------------------- weeks 1 to 7 -----
week1: ## Week 1: private VPC (no internet), S3 endpoint, flow logs
	$(call APPLY,week01-landing-zone)

week2: ## Week 2: Bedrock VPC endpoint, endpoint-only IAM role, prober Lambdas
	$(call APPLY,week02-private-model)

week2-test: ## Week 2: prove the model is only reachable through the endpoint
	./scripts/week2-test.sh $(PREFIX)

week3: ## Week 3: Bedrock guardrail, invocation logging, permissions boundary
	$(call APPLY,week03-guardrails)

week3-test: ## Week 3: try to break the rules with an over-permissioned role
	./scripts/week3-test.sh $(PREFIX)

week4-images: ## Week 4: build the gateway image and push it to your ECR (needs Docker)
	./scripts/push-images.sh gateway $(REGION) $(PREFIX)

week4: ## Week 4: AI gateway (LiteLLM on Fargate, Aurora, internal ALB). Run week4-images after the first apply
	$(call APPLY,week04-ai-gateway)

week4-test: ## Week 4: keys, model access, token limits, all from inside the VPC
	./scripts/week4-test.sh $(PREFIX)

week5: ## Week 5: build + push the app, create its team key, run it privately
	./scripts/push-images.sh app $(REGION) $(PREFIX)
	$(call APPLY,week05-private-app,-var app_desired_count=0)
	./scripts/week5-key.sh $(PREFIX)
	$(call APPLY,week05-private-app,-var app_desired_count=1)

week5-test: ## Week 5: ask the private bank app questions from inside the VPC
	./scripts/week5-test.sh $(PREFIX)

week6: ## Week 6: alerts (gateway abuse, control tampering), CloudTrail (needs EMAIL)
	@test -n "$(EMAIL)" || (echo "Set EMAIL=you@example.com" && exit 1)
	$(call APPLY,week06-security,-var email=$(EMAIL))

week6-guardduty: ## Week 6: same, plus GuardDuty with AI Protection (30-day trial)
	@test -n "$(EMAIL)" || (echo "Set EMAIL=you@example.com" && exit 1)
	$(call APPLY,week06-security,-var email=$(EMAIL) -var enable_guardduty=true)

week7: ## Week 7: tagged inference profile, dashboard, token alarm, team budget (needs EMAIL)
	@test -n "$(EMAIL)" || (echo "Set EMAIL=you@example.com" && exit 1)
	$(call APPLY,week07-observability,-var email=$(EMAIL))
	$(call APPLY,week04-ai-gateway,-var bank_model_override=bedrock/converse/$$(cd ../week07-observability && $(TF) output -raw retail_profile_arn))

# --------------------------------------------------------------- week 8 ------
week8: ## Week 8: GitHub OIDC role for your fork (needs REPO=owner/name)
	@test -n "$(REPO)" || (echo "Set REPO=yourname/aws-ai-platform-architect" && exit 1)
	$(call APPLY,week08-cicd,-var github_repo=$(REPO))

week8-inventory: ## Week 8: compare models in use with the model inventory
	./scripts/aws-models-in-use.sh $(PREFIX) > /tmp/models-in-use.json
	python3 scripts/check_model_inventory.py --deployed /tmp/models-in-use.json

week8-gate: ## Week 8: run the release gate against the live app, from inside the VPC
	./scripts/release-gate.sh $(PREFIX)

# ------------------------------------------------------------ cost control ---
validate: ## Format-check and validate every week (no AWS account needed)
	@for d in infra/week0*; do (cd $$d && $(TF) init -backend=false -input=false >/dev/null && $(TF) validate -no-color | head -1 && $(TF) fmt -check) || exit 1; done

pause: ## Stop the always-on costs that can pause (ECS tasks to 0). Aurora pauses itself
	-$(call APPLY,week05-private-app,-var app_desired_count=0)
	-$(call APPLY,week04-ai-gateway,-var gateway_desired_count=0)

destroy: ## DELETE everything, newest week first (asks you to confirm)
	./scripts/destroy.sh $(REGION) $(PREFIX)
