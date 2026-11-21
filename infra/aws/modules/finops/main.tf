# ==============================================================================
# Module: FinOps (AWS Budgets, Cost Threshold Alarms & Notifications)
# ==============================================================================

resource "aws_sns_topic" "cost_alerts" {
  name = "${var.app_name}-${var.environment}-cost-alerts"

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-cost-alerts"
  })
}

resource "aws_budgets_budget" "monthly_spend" {
  name              = "${var.app_name}-${var.environment}-monthly-budget"
  budget_type       = "COST"
  limit_amount      = tostring(var.monthly_budget_limit_usd)
  limit_unit        = "USD"
  time_period_start = "2026-01-01_00:00"
  time_unit         = "MONTHLY"

  cost_filter {
    name = "TagKeyValue"
    values = [
      "user:Project$${var.app_name}"
    ]
  }

  # Alert 1: Forecasted spend exceeds 80% of budget
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.alert_email_addresses
    subscriber_sns_topic_arns  = [aws_sns_topic.cost_alerts.arn]
  }

  # Alert 2: Actual spend reaches 100% of budget
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.alert_email_addresses
    subscriber_sns_topic_arns  = [aws_sns_topic.cost_alerts.arn]
  }

  tags = var.tags
}
