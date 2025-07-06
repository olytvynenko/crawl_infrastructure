###############################################################################
# IAM Policy for Exit Code Monitor CloudWatch Metrics
###############################################################################

# This policy should be attached to the EKS node instance role
# to allow the exit code monitor pods to send metrics to CloudWatch

data "aws_iam_policy_document" "exit_code_monitor_metrics" {
  statement {
    sid    = "CloudWatchMetrics"
    effect = "Allow"
    
    actions = [
      "cloudwatch:PutMetricData"
    ]
    
    resources = ["*"]
    
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["CrawlerIPMonitor"]
    }
  }
}

resource "aws_iam_policy" "exit_code_monitor_metrics" {
  name        = "exit-code-monitor-metrics"
  path        = "/"
  description = "Allow exit code monitor to send metrics to CloudWatch"
  policy      = data.aws_iam_policy_document.exit_code_monitor_metrics.json
}

# Note: This policy needs to be attached to the EKS node instance role
# in your cluster configuration. For Karpenter-managed nodes, add this
# to the EC2NodeClass role.

output "exit_code_monitor_metrics_policy_arn" {
  value       = aws_iam_policy.exit_code_monitor_metrics.arn
  description = "ARN of the IAM policy for exit code monitor metrics"
}