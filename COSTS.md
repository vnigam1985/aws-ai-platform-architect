# What the course costs, and how to keep it low

Prices are approximate USD list prices for **ca-central-1**, read from the AWS Price List in October 2026. Your numbers may differ. **Set the week 0 budget first**, and check the [AWS Pricing Calculator](https://calculator.aws/).

## Per item, while it exists

| Item | Week | About | Notes |
| --- | --- | --- | --- |
| Local lab | 0 | $0 | Your laptop |
| AWS Budgets alerts | 0 | Free | |
| VPC, subnets, S3 gateway endpoint | 1 | Free | |
| VPC flow logs | 1 | Cents | 7-day retention |
| Interface endpoints | 2, 4 | $0.011/hour each in one AZ (about $8/month each) | 5 endpoints by week 4: about $1.30/day |
| Lambda probers | 2+ | Cents | |
| Nova Lite tokens | 2+ | Cents for the whole course | |
| Bedrock Guardrails | 3+ | $0.15 per 1,000 text units (content, topics), $0.10 (PII) | A few hundred calls in the course |
| Invocation logs, CloudWatch | 3+ | Cents | |
| Aurora Serverless v2 | 4 | $0.14 per ACU-hour while running; **$0 compute while paused**; storage $0.11/GB-month | Pauses after 10 idle minutes |
| Fargate gateway (1 vCPU, 2 GB) | 4 | About $0.054/hour (about $1.30/day) | `make pause` |
| Internal ALB | 4 | $0.02475/hour + usage (about $0.60/day) | |
| Fargate app (0.25 vCPU, 0.5 GB) | 5 | About $0.014/hour | `make pause` |
| ECR | 4, 5 | Cents | |
| CloudTrail (1 trail, management events) | 6 | No CloudTrail charge; S3 storage cents | |
| Alarms, metric filters, EventBridge | 6, 7 | Cents | |
| GuardDuty AI Protection | 6 | Optional. 30-day trial, then about $1.15/GB of events analyzed | |
| Dashboard | 7 | First 3 free | |

## Three ways to take the course

| Plan | What you do | Rough total |
| --- | --- | --- |
| **Sprint** (recommended) | Weeks 1 to 3 at your own pace, then weeks 4 to 8 within 2 weeks with `make pause` between sessions, then `make destroy` | $20 to $40 |
| Weekend | Build, learn and destroy every weekend (rebuild takes about 30 minutes) | $5 to $15 per weekend |
| Leave it running for a month | Everything up, never paused | About $100 to $120 |

These are estimates, not quotes. Check Cost Explorer after the first few days.

## Stop spending

```bash
make pause     # gateway and app tasks to 0 (Aurora pauses itself)
make destroy   # delete every week, newest first (type DESTROY to confirm)
```

A budget alert tells you. Only `make destroy` stops the spending. Endpoints and the ALB keep charging while paused.
