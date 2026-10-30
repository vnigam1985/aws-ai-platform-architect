# Contributing

Thanks for helping make this roadmap better.

## Good contributions

- Fix a broken or outdated link (include the date you checked it)
- Add a high-quality resource: official docs, official sample repos, or well-reviewed courses
- Improve a lab with clearer steps or a fix you found while doing it
- Add a validated code sample (Terraform, IAM or SCP JSON)

## Rules

1. **No invented links or APIs.** Every link must open, and every code sample must use documented syntax.
2. **Official sources first.** Prefer docs.aws.amazon.com, the AWS blogs and `github.com/aws`, `github.com/awslabs`, `github.com/aws-samples`.
3. **Code must validate.** Terraform must pass `terraform fmt -check` and `terraform validate`, JSON and YAML must parse. CI checks this on your pull request.
4. **Keep it plain.** Short sentences, simple words. Readers include people learning in their second language.
5. **No affiliate links or paid promotions.**

## How to submit

1. Fork the repo and create a branch
2. Make your change
3. Update [VERIFICATION.md](VERIFICATION.md) if you checked links or facts
4. Open a pull request describing what you changed and why
