# Governance

| File | What it is |
| --- | --- |
| [model-inventory/model_inventory.yaml](model-inventory/model_inventory.yaml) | The model inventory (OSFI E-23 style). Checked in CI and compared with what's deployed in week 8 |
| [scp-bedrock-guardrails.json](scp-bedrock-guardrails.json) | The **organization** version of the week 3 permissions boundary, as a Service Control Policy |

## SCP or permissions boundary?

| | Service Control Policy | Permissions boundary (this course) |
| --- | --- | --- |
| Needs AWS Organizations | Yes | No |
| Applies to | Every principal in the member accounts it's attached to, including admins | Only roles you attach it to |
| Applies to the management account | No | Yes, if attached |
| Who controls it | Central platform or security team | Whoever creates the role (so pair it with an IAM policy that requires the boundary on new roles) |

In a bank you'd use both: SCPs as the outer fence for every account, and boundaries for delegated role creation inside workload accounts.

### About the SCP

- It's a Canada-only pattern. AWS's October 2026 blog [Access OpenAI GPT models on Amazon Bedrock from Canada with cross-Region inference](https://aws.amazon.com/blogs/machine-learning/access-openai-gpt-models-on-amazon-bedrock-from-canada-with-cross-region-inference/) shows the variant that also allows chosen `us.` and `global.` profiles with the `bedrock:InferenceProfileArn` condition key. Read it before you allow any traffic to leave Canada.
- Global inference profiles evaluate `aws:RequestedRegion` as `unspecified`, so this SCP denies them, as intended here.
- Replace `PlatformAdmin` with the role your platform team uses. Test SCPs in a sandbox OU first.
