# =============================================================================
# Week 7: observability and FinOps
# -----------------------------------------------------------------------------
#   - An application inference profile for the retail banking team, tagged
#     team=retail-banking. Bedrock costs through it show up under that tag in
#     Cost Explorer and the Cost and Usage Report. make week7 points the gateway
#     at it.
#   - A CloudWatch dashboard: Bedrock invocations, tokens in and out, throttles,
#     latency, plus the gateway 401/429 metrics from week 6
#   - An alarm when output tokens in a day go over the team allowance
#   - A monthly budget filtered by the team tag
# =============================================================================

data "terraform_remote_state" "w2" {
  backend = "local"
  config  = { path = "${path.module}/../week02-private-model/terraform.tfstate" }
}
data "terraform_remote_state" "w6" {
  backend = "local"
  config  = { path = "${path.module}/../week06-security/terraform.tfstate" }
}

data "aws_caller_identity" "me" {}

locals {
  model_id = data.terraform_remote_state.w2.outputs.model_id
  topic    = data.terraform_remote_state.w6.outputs.alerts_topic_arn
}

variable "email" {
  type = string
}

variable "daily_output_token_allowance" {
  type    = number
  default = 200000
}

variable "team_monthly_budget_usd" {
  type    = number
  default = 10
}

resource "aws_bedrock_inference_profile" "retail" {
  name        = "${var.prefix}-retail-banking"
  description = "Bank assistant traffic for the retail banking team (cost allocation)"
  model_source {
    # Copy the Canada profile, so team traffic keeps the same Canada-only routing.
    copy_from = "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.me.account_id}:inference-profile/${local.model_id}"
  }
  tags = {
    team = "retail-banking"
    app  = "maple-bank-assistant"
  }
}

resource "aws_cloudwatch_dashboard" "ai" {
  dashboard_name = "${var.prefix}-ai-platform"
  dashboard_body = jsonencode({
    widgets = [
      {
        type       = "text", x = 0, y = 0, width = 24, height = 2
        properties = { markdown = "## AI platform: Bedrock usage and gateway health\nTokens are what you pay for. Throttles and 429s mean a limit was hit. 401s mean blocked callers." }
      },
      {
        type = "metric", x = 0, y = 2, width = 12, height = 6
        properties = {
          title = "Tokens in and out", region = var.region, stat = "Sum", period = 3600, view = "timeSeries"
          metrics = [
            ["AWS/Bedrock", "InputTokenCount", "ModelId", local.model_id],
            [".", "OutputTokenCount", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 2, width = 12, height = 6
        properties = {
          title = "Invocations, errors and throttles", region = var.region, stat = "Sum", period = 300, view = "timeSeries"
          metrics = [
            ["AWS/Bedrock", "Invocations", "ModelId", local.model_id],
            [".", "InvocationClientErrors", ".", "."],
            [".", "InvocationServerErrors", ".", "."],
            [".", "InvocationThrottles", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 8, width = 12, height = 6
        properties = {
          title = "Model latency (ms)", region = var.region, period = 300, view = "timeSeries"
          metrics = [
            ["AWS/Bedrock", "InvocationLatency", "ModelId", local.model_id, { stat = "p50" }],
            ["...", { stat = "p90" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 8, width = 12, height = 6
        properties = {
          title = "Gateway: blocked (401) and throttled (429)", region = var.region, stat = "Sum", period = 300, view = "timeSeries"
          metrics = [
            ["${var.prefix}/ai-gateway", "gateway-401"],
            [".", "gateway-429"],
          ]
        }
      },
    ]
  })
}

resource "aws_cloudwatch_metric_alarm" "daily_tokens" {
  alarm_name          = "${var.prefix}-daily-output-tokens"
  alarm_description   = "Output tokens for the bank model went over the daily allowance"
  namespace           = "AWS/Bedrock"
  metric_name         = "OutputTokenCount"
  dimensions          = { ModelId = local.model_id }
  statistic           = "Sum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = var.daily_output_token_allowance
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.topic]
}

resource "aws_budgets_budget" "team" {
  name         = "${var.prefix}-team-retail-banking"
  budget_type  = "COST"
  limit_amount = tostring(var.team_monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Works once "team" is activated as a cost allocation tag (see the week 7 README).
  cost_filter {
    name   = "TagKeyValue"
    values = ["user:team$retail-banking"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.email]
  }
}

output "retail_profile_arn" { value = aws_bedrock_inference_profile.retail.arn }
output "dashboard" { value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.ai.dashboard_name}" }
