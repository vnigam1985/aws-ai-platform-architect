# =============================================================================
# Week 3: guardrails as code
# -----------------------------------------------------------------------------
#   1. A Bedrock Guardrail for the bank: harmful content, prompt attacks,
#      card numbers and Social Insurance Numbers, and no investment advice
#   2. Model invocation logging to CloudWatch Logs (audit evidence)
#   3. A permissions boundary for every AI workload role. Even a role with
#      bedrock:* can then only:
#        - call the approved model
#        - with the bank guardrail attached
#        - in Canada (or through a US geo inference profile, see README)
#      and can never turn off invocation logging or delete the guardrail
#   4. A deliberately over-permissioned test Lambda with that boundary, to prove it
#
# Why a permissions boundary and not an SCP? SCPs need AWS Organizations and
# don't apply to the management account, so most learners can't test them in a
# personal account. The SCP version is in governance/scp-bedrock-guardrails.json.
# =============================================================================

data "terraform_remote_state" "w1" {
  backend = "local"
  config  = { path = "${path.module}/../week01-landing-zone/terraform.tfstate" }
}

data "terraform_remote_state" "w2" {
  backend = "local"
  config  = { path = "${path.module}/../week02-private-model/terraform.tfstate" }
}

data "aws_caller_identity" "me" {}

locals {
  net        = data.terraform_remote_state.w1.outputs
  model_id   = data.terraform_remote_state.w2.outputs.model_id
  model_arns = data.terraform_remote_state.w2.outputs.model_arns
  account_id = data.aws_caller_identity.me.account_id
}

# ---------------------------------------------------------- 1. guardrail -----
resource "aws_bedrock_guardrail" "bank" {
  name                      = "${var.prefix}-bank-assistant"
  description               = "Maple Leaf Bank assistant: safety, prompt attacks, PII, no investment advice"
  blocked_input_messaging   = "Sorry, I can't help with that request. Please contact Maple Leaf Bank support."
  blocked_outputs_messaging = "Sorry, I can't share that. Please contact Maple Leaf Bank support."

  content_policy_config {
    dynamic "filters_config" {
      for_each = ["HATE", "INSULTS", "SEXUAL", "VIOLENCE", "MISCONDUCT"]
      content {
        type            = filters_config.value
        input_strength  = "HIGH"
        output_strength = "HIGH"
      }
    }
    filters_config {
      # Prompt attack filtering applies to input only.
      type            = "PROMPT_ATTACK"
      input_strength  = "HIGH"
      output_strength = "NONE"
    }
  }

  topic_policy_config {
    topics_config {
      name       = "investment-advice"
      type       = "DENY"
      definition = "Recommendations about which stocks, funds, crypto or other investments to buy or sell."
      examples   = ["Which stock should I buy with my savings?", "Is bitcoin a good investment right now?"]
    }
  }

  sensitive_information_policy_config {
    pii_entities_config {
      type   = "CREDIT_DEBIT_CARD_NUMBER"
      action = "ANONYMIZE"
    }
    regexes_config {
      name        = "canadian-sin"
      description = "Canadian Social Insurance Number, 9 digits, optional spaces or dashes"
      pattern     = "\\b\\d{3}[- ]?\\d{3}[- ]?\\d{3}\\b"
      action      = "ANONYMIZE"
    }
  }
}

resource "aws_bedrock_guardrail_version" "v1" {
  guardrail_arn = aws_bedrock_guardrail.bank.guardrail_arn
  description   = "Week 3 baseline"
}

# --------------------------------------------- 2. model invocation logging ---
resource "aws_cloudwatch_log_group" "invocations" {
  name              = "/${var.prefix}/bedrock-invocations"
  retention_in_days = 30
}

data "aws_iam_policy_document" "bedrock_logging_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "bedrock_logging" {
  name               = "${var.prefix}-bedrock-invocation-logging"
  assume_role_policy = data.aws_iam_policy_document.bedrock_logging_assume.json
}

resource "aws_iam_role_policy" "bedrock_logging" {
  role = aws_iam_role.bedrock_logging.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.invocations.arn}:log-stream:*"
    }]
  })
}

resource "aws_bedrock_model_invocation_logging_configuration" "this" {
  logging_config {
    text_data_delivery_enabled      = true
    image_data_delivery_enabled     = false
    embedding_data_delivery_enabled = false
    cloudwatch_config {
      log_group_name = aws_cloudwatch_log_group.invocations.name
      role_arn       = aws_iam_role.bedrock_logging.arn
    }
  }
}

# ---------------------------------------------- 3. permissions boundary ------
locals {
  guardrail_arn_prefix = "arn:aws:bedrock:${var.region}:${local.account_id}:guardrail/${aws_bedrock_guardrail.bank.guardrail_id}"
  invoke_actions = [
    "bedrock:InvokeModel",
    "bedrock:InvokeModelWithResponseStream",
  ]
}

data "aws_iam_policy_document" "boundary" {
  statement {
    sid       = "AllowEverythingTheRoleItselfAllows"
    actions   = ["*"]
    resources = ["*"]
  }

  statement {
    sid     = "DenyUnapprovedModels"
    effect  = "Deny"
    actions = local.invoke_actions
    not_resources = concat(local.model_arns, [
      "arn:aws:bedrock:${var.region}:${local.account_id}:application-inference-profile/*",
    ])
  }

  statement {
    sid       = "DenyCallsWithoutTheBankGuardrail"
    effect    = "Deny"
    actions   = local.invoke_actions
    resources = ["*"]
    condition {
      test     = "StringNotLike"
      variable = "bedrock:GuardrailIdentifier"
      values   = ["${local.guardrail_arn_prefix}*"]
    }
  }

  statement {
    sid       = "DenyCallsWithNoGuardrailAtAll"
    effect    = "Deny"
    actions   = local.invoke_actions
    resources = ["*"]
    condition {
      test     = "Null"
      variable = "bedrock:GuardrailIdentifier"
      values   = ["true"]
    }
  }

  statement {
    # Canada only. A ca. inference profile routes between ca-central-1 and
    # ca-west-1, so both are allowed. us.* and global.* profiles would be
    # denied here (global ones evaluate RequestedRegion as "unspecified").
    sid       = "DenyOutsideCanada"
    effect    = "Deny"
    actions   = local.invoke_actions
    resources = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = ["ca-central-1", "ca-west-1"]
    }
  }

  statement {
    sid    = "ProtectTheControls"
    effect = "Deny"
    actions = [
      "bedrock:DeleteModelInvocationLoggingConfiguration",
      "bedrock:PutModelInvocationLoggingConfiguration",
      "bedrock:DeleteGuardrail",
      "bedrock:UpdateGuardrail",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "boundary" {
  name        = "${var.prefix}-ai-workload-boundary"
  description = "Permissions boundary for every AI workload role (week 3)"
  policy      = data.aws_iam_policy_document.boundary.json
}

# --------------------------------------- 4. over-permissioned test Lambda ----
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "guarded" {
  name                 = "${var.prefix}-prober-guarded"
  assume_role_policy   = data.aws_iam_policy_document.lambda_assume.json
  permissions_boundary = aws_iam_policy.boundary.arn
}

resource "aws_iam_role_policy_attachment" "guarded_vpc" {
  role       = aws_iam_role.guarded.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "guarded_too_much" {
  role = aws_iam_role.guarded.id
  # Deliberately far too broad. The boundary is what keeps it safe.
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "bedrock:*", Resource = "*" }]
  })
}

data "archive_file" "prober" {
  type        = "zip"
  source_file = "${path.module}/../lambda/prober/handler.py"
  output_path = "${path.module}/build/prober.zip"
}

resource "aws_lambda_function" "guarded" {
  function_name    = "${var.prefix}-prober-guarded"
  role             = aws_iam_role.guarded.arn
  runtime          = "python3.13"
  handler          = "handler.handler"
  filename         = data.archive_file.prober.output_path
  source_code_hash = data.archive_file.prober.output_base64sha256
  timeout          = 120
  memory_size      = 256
  vpc_config {
    subnet_ids         = local.net.private_subnet_ids
    security_group_ids = [local.net.workloads_sg_id]
  }
}

output "guardrail_id" { value = aws_bedrock_guardrail.bank.guardrail_id }
output "guardrail_arn" { value = aws_bedrock_guardrail.bank.guardrail_arn }
output "guardrail_version" { value = aws_bedrock_guardrail_version.v1.version }
output "boundary_arn" { value = aws_iam_policy.boundary.arn }
output "invocation_log_group" { value = aws_cloudwatch_log_group.invocations.name }
