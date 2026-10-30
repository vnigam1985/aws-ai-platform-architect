# =============================================================================
# Week 6: detect and respond
# -----------------------------------------------------------------------------
#   - SNS topic that emails you
#   - Gateway abuse alarms from the LiteLLM logs:
#       burst of 401 (bad or revoked keys) and burst of 429 (limits hit, cost attack)
#   - CloudTrail trail (management events) so EventBridge can see API calls
#   - EventBridge rule: someone touched the Bedrock controls (guardrail or
#     invocation logging changed or deleted) -> email
#   - GuardDuty with AI Protection (optional, var.enable_guardduty), and an
#     EventBridge rule that emails you medium and high findings
# =============================================================================

data "terraform_remote_state" "w4" {
  backend = "local"
  config  = { path = "${path.module}/../week04-ai-gateway/terraform.tfstate" }
}

data "aws_caller_identity" "me" {}

locals {
  gw         = data.terraform_remote_state.w4.outputs
  account_id = data.aws_caller_identity.me.account_id
}

variable "email" {
  type = string
}

variable "enable_guardduty" {
  description = "GuardDuty has a 30-day free trial per account, then charges by volume. Leave false if you already use GuardDuty in this account."
  type        = bool
  default     = false
}

variable "guardduty_ai_feature_name" {
  description = "GuardDuty detector feature name for AI Protection. Check `aws guardduty list-detectors` / the GuardDuty docs if apply rejects it."
  type        = string
  default     = "AI_PROTECTION"
}

# ----------------------------------------------------------------- SNS -------
resource "aws_sns_topic" "alerts" {
  name = "${var.prefix}-platform-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.email # confirm the subscription email AWS sends you
}

data "aws_iam_policy_document" "sns" {
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "cloudwatch.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.sns.json
}

# ------------------------------------------------ gateway abuse alarms -------
locals {
  gateway_signals = {
    "gateway-401" = { pattern = "\"401 Unauthorized\"", threshold = 20, text = "Burst of 401 at the AI gateway: guessed, stolen or revoked keys" }
    "gateway-429" = { pattern = "\"429 Too Many Requests\"", threshold = 30, text = "Burst of 429 at the AI gateway: a runaway app or a cost attack (OWASP LLM Top 10: unbounded consumption)" }
  }
}

resource "aws_cloudwatch_log_metric_filter" "gateway" {
  for_each       = local.gateway_signals
  name           = "${var.prefix}-${each.key}"
  log_group_name = local.gw.gateway_log_group
  pattern        = each.value.pattern
  metric_transformation {
    name          = each.key
    namespace     = "${var.prefix}/ai-gateway"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "gateway" {
  for_each            = local.gateway_signals
  alarm_name          = "${var.prefix}-${each.key}"
  alarm_description   = each.value.text
  namespace           = "${var.prefix}/ai-gateway"
  metric_name         = each.key
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  depends_on          = [aws_cloudwatch_log_metric_filter.gateway]
}

# ------------------------------------------------------------- CloudTrail ----
resource "aws_s3_bucket" "trail" {
  bucket        = "${var.prefix}-trail-${local.account_id}"
  force_destroy = true # lab only
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket                  = aws_s3_bucket.trail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "trail_bucket" {
  statement {
    sid       = "AclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
  statement {
    sid       = "Write"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail.arn}/AWSLogs/${local.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = data.aws_iam_policy_document.trail_bucket.json
}

resource "aws_cloudtrail" "lab" {
  name                          = "${var.prefix}-trail"
  s3_bucket_name                = aws_s3_bucket.trail.id
  include_global_service_events = true
  is_multi_region_trail         = false
  depends_on                    = [aws_s3_bucket_policy.trail]
}

# ---------------------------------------------- Bedrock control tampering ----
resource "aws_cloudwatch_event_rule" "bedrock_controls" {
  name        = "${var.prefix}-bedrock-controls-changed"
  description = "Guardrail or invocation logging changed or deleted"
  event_pattern = jsonencode({
    source        = ["aws.bedrock"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["bedrock.amazonaws.com"]
      eventName = [
        "DeleteGuardrail", "UpdateGuardrail",
        "DeleteModelInvocationLoggingConfiguration", "PutModelInvocationLoggingConfiguration",
      ]
    }
  })
}

resource "aws_cloudwatch_event_target" "bedrock_controls" {
  rule = aws_cloudwatch_event_rule.bedrock_controls.name
  arn  = aws_sns_topic.alerts.arn
}

# --------------------------------------------------------------- GuardDuty ---
resource "aws_guardduty_detector" "this" {
  count  = var.enable_guardduty ? 1 : 0
  enable = true
}

resource "aws_guardduty_detector_feature" "ai" {
  count       = var.enable_guardduty ? 1 : 0
  detector_id = aws_guardduty_detector.this[0].id
  name        = var.guardduty_ai_feature_name
  status      = "ENABLED"
}

resource "aws_cloudwatch_event_rule" "guardduty" {
  name        = "${var.prefix}-guardduty-findings"
  description = "GuardDuty findings with severity 4 (medium) or higher"
  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail        = { severity = [{ numeric = [">=", 4] }] }
  })
}

resource "aws_cloudwatch_event_target" "guardduty" {
  rule = aws_cloudwatch_event_rule.guardduty.name
  arn  = aws_sns_topic.alerts.arn
}

output "alerts_topic_arn" { value = aws_sns_topic.alerts.arn }
