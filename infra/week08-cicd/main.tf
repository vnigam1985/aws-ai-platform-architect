# =============================================================================
# Week 8: let GitHub Actions deploy, with no stored AWS keys
# -----------------------------------------------------------------------------
#   - GitHub's OIDC identity provider in your account
#   - A role that ONLY your fork's "lab" environment can assume
#   - Just enough permissions for the release pipeline:
#       read the model inventory facts, push the app image, roll out ECS,
#       and run the in-VPC prober for the release gate
# =============================================================================

data "aws_caller_identity" "me" {}

locals {
  account_id = data.aws_caller_identity.me.account_id
}

variable "github_repo" {
  description = "Your fork, as owner/name, for example vnigam1985/aws-ai-platform-architect"
  type        = string
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # No thumbprint needed: AWS trusts GitHub's OIDC endpoint through its own
  # certificate validation (thumbprint_list is optional in provider 6.x).
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:environment:lab"]
    }
  }
}

resource "aws_iam_role" "github_release" {
  name               = "${var.prefix}-github-release"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
}

resource "aws_iam_role_policy" "github_release" {
  role = aws_iam_role.github_release.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InventoryFacts"
        Effect   = "Allow"
        Action   = ["bedrock:ListInferenceProfiles", "bedrock:GetInferenceProfile", "bedrock:GetGuardrail", "bedrock:GetModelInvocationLoggingConfiguration"]
        Resource = "*"
      },
      {
        Sid      = "PushAppImage"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages"]
        Resource = "*"
      },
      {
        Sid      = "RollOutAndRollBack"
        Effect   = "Allow"
        Action   = ["ecs:DescribeServices", "ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition", "ecs:UpdateService", "ecs:ListTaskDefinitions"]
        Resource = "*"
      },
      {
        Sid      = "PassTaskRoles"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = ["arn:aws:iam::${local.account_id}:role/${var.prefix}-ecs-execution", "arn:aws:iam::${local.account_id}:role/${var.prefix}-bank-app"]
      },
      {
        Sid      = "RunTheReleaseGate"
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = "arn:aws:lambda:${var.region}:${local.account_id}:function:${var.prefix}-prober"
      },
      {
        Sid      = "FindTheLoadBalancer"
        Effect   = "Allow"
        Action   = "elasticloadbalancing:DescribeLoadBalancers"
        Resource = "*"
      },
    ]
  })
}

output "github_role_arn" { value = aws_iam_role.github_release.arn }
