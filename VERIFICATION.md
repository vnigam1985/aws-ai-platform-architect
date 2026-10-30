# What was tested, and what wasn't

AWS AI changes every month. This file records what was checked before publishing, on **October 30, 2026**, so you know what to trust.

## Checked

| Check | Result |
| --- | --- |
| Every Terraform root in `infra/` | `terraform fmt -check` and `terraform validate` pass (Terraform 1.9.8, hashicorp/aws 6.71) |
| Bedrock model availability in ca-central-1 | Read from the "Supported models by Region" page and model cards, October 30, 2026. Nova Lite is available from ca-central-1 only through the `ca.` profile; Nova Micro and Pro aren't callable from ca-central-1 |
| Aurora Serverless v2 scale to zero | Supported from Aurora PostgreSQL 16.3; the lab uses 16.6 |
| Prices in COSTS.md | AWS Price List, ca-central-1, October 2026 |
| `bedrock:GuardrailIdentifier`, GuardDuty `AI_PROTECTION` feature name, OIDC thumbprint optional | Official docs, October 2026 |
| LiteLLM gateway image (main-stable) with Postgres | **Run with no network egress**: starts, migrates the database, creates team keys |
| LiteLLM passes `guardrailConfig` to the Bedrock Converse API, and reads the model from an environment variable, including an application inference profile ARN | **Run** against a local capture server |
| Week 0 local lab (same files as the Azure course) | **Run end to end**: 6/6 checks |
| Prober Lambda `http` and `eval` actions | **Run** locally against the bank app |
| Model inventory checker and models-in-use parsing | **Run** locally, including the Canada profile case |

## Links

Every external link in the README and the week guides (88 across this repo and its sister repo) was opened on October 30, 2026. Moved pages were updated to their new addresses.

## Not verified yet (please report what you see)

No AWS account was used to build this course, so **nothing has been deployed end to end**. In particular:

- `aws:SourceVpce` behaviour with a `ca.` cross-Region profile (whether the destination-Region authorization also sees the endpoint). If week 2's inside probe is denied, remove the condition from the foundation-model ARNs and keep it on the profile ARN, then tell us in an issue
- Whether `bedrock:GuardrailIdentifier` matches when the guardrail ARN is passed without a version suffix in the request (the prober and gateway pass the ARN and version separately)
- The `ModelId` dimension that CloudWatch uses for calls through `ca.` and application inference profiles (the week 7 README shows how to check)
- The exact uvicorn log text the week 6 metric filters match (`401 Unauthorized`, `429 Too Many Requests`) in the LiteLLM image you pull
- The LiteLLM endpoints used in week 7 (`/key/list`) on the image version you pull
- The `course-release` workflow against a live account
