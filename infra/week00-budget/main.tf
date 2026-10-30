# Week 0: a budget alert BEFORE you deploy anything else.
# A budget only alerts. It never stops spending. `make destroy` stops spending.

variable "email" {
  description = "Where budget alerts go."
  type        = string
}

variable "monthly_limit_usd" {
  description = "The whole course fits in roughly 30 to 60 USD if you destroy at the end of each sprint."
  type        = number
  default     = 100
}

resource "aws_budgets_budget" "lab" {
  name         = "${var.prefix}-ai-platform-lab"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 90
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.email]
  }
}
