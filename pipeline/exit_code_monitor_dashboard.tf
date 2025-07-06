###############################################################################
# CloudWatch Dashboard for Exit Code Monitor
###############################################################################

resource "aws_cloudwatch_dashboard" "exit_code_monitor" {
  dashboard_name = "exit-code-monitor"

  dashboard_body = jsonencode({
    widgets = [
      # Row 1: Overview
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 8
        height = 6
        properties = {
          metrics = [
            ["CrawlerIPMonitor", "MonitorHeartbeat", { stat = "Sum", period = 300 }]
          ]
          view    = "timeSeries"
          stacked = false
          region  = "us-east-1"
          title   = "Monitor Heartbeat"
          yAxis = {
            left = {
              label = "Heartbeats"
            }
          }
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 0
        width  = 8
        height = 6
        properties = {
          metrics = [
            ["CrawlerIPMonitor", "IPAbuseDetected", { stat = "Sum", period = 300 }]
          ]
          view    = "timeSeries"
          stacked = false
          region  = "us-east-1"
          title   = "IP Abuse Detections"
          yAxis = {
            left = {
              label = "Count"
            }
          }
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 0
        width  = 8
        height = 6
        properties = {
          metrics = [
            ["CrawlerIPMonitor", "NodesTainted", { stat = "Sum", period = 300 }]
          ]
          view    = "timeSeries"
          stacked = false
          region  = "us-east-1"
          title   = "Nodes Tainted"
          yAxis = {
            left = {
              label = "Count"
            }
          }
        }
      },
      
      # Row 2: Pod Processing
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["CrawlerIPMonitor", "PodsProcessed", { "ExitCode": "0", stat = "Sum", period = 300 }],
            [".", ".", { "ExitCode": "1", stat = "Sum", period = 300 }],
            [".", ".", { "ExitCode": "2", stat = "Sum", period = 300 }],
            [".", ".", { "ExitCode": "137", stat = "Sum", period = 300 }]
          ]
          view    = "timeSeries"
          stacked = true
          region  = "us-east-1"
          title   = "Pods Processed by Exit Code"
          yAxis = {
            left = {
              label = "Count"
            }
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["CrawlerIPMonitor", "TaintedNodesPercentage", { stat = "Average", period = 300 }]
          ]
          view    = "timeSeries"
          stacked = false
          region  = "us-east-1"
          title   = "Percentage of Nodes Tainted"
          yAxis = {
            left = {
              label = "Percent"
              min = 0
              max = 100
            }
          }
        }
      },
      
      # Row 3: Cluster Stats
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["CrawlerIPMonitor", "TotalNodes", { stat = "Average", period = 300 }],
            [".", "TaintedNodes", { stat = "Average", period = 300 }]
          ]
          view    = "timeSeries"
          stacked = false
          region  = "us-east-1"
          title   = "Node Counts"
          yAxis = {
            left = {
              label = "Count"
            }
          }
        }
      },
      
      # Row 4: Summary Stats
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 6
        height = 6
        properties = {
          metrics = [
            ["CrawlerIPMonitor", "IPAbuseDetected", { stat = "Sum", period = 2592000 }]
          ]
          view    = "singleValue"
          region  = "us-east-1"
          title   = "Total IP Abuse (30 days)"
        }
      },
      {
        type   = "metric"
        x      = 18
        y      = 12
        width  = 6
        height = 6
        properties = {
          metrics = [
            ["CrawlerIPMonitor", "PodsProcessed", { stat = "Sum", period = 86400 }]
          ]
          view    = "singleValue"
          region  = "us-east-1"
          title   = "Pods Processed (24h)"
        }
      }
    ]
  })
}

# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "monitor_down" {
  alarm_name          = "exit-code-monitor-down"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "MonitorHeartbeat"
  namespace           = "CrawlerIPMonitor"
  period              = "300"
  statistic           = "Sum"
  threshold           = "1"
  alarm_description   = "Exit code monitor is not sending heartbeats"
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.alert_topic.arn]
}

resource "aws_cloudwatch_metric_alarm" "high_ip_abuse_rate" {
  alarm_name          = "high-ip-abuse-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "IPAbuseDetected"
  namespace           = "CrawlerIPMonitor"
  period              = "300"
  statistic           = "Sum"
  threshold           = "10"
  alarm_description   = "High rate of IP abuse detections"

  alarm_actions = [aws_sns_topic.alert_topic.arn]
}

resource "aws_cloudwatch_metric_alarm" "too_many_tainted_nodes" {
  alarm_name          = "too-many-tainted-nodes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "TaintedNodesPercentage"
  namespace           = "CrawlerIPMonitor"
  period              = "300"
  statistic           = "Average"
  threshold           = "50"
  alarm_description   = "More than 50% of nodes are tainted"

  alarm_actions = [aws_sns_topic.alert_topic.arn]
}

# Output dashboard URL
output "exit_code_monitor_dashboard_url" {
  value = "https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=${aws_cloudwatch_dashboard.exit_code_monitor.dashboard_name}"
  description = "URL to CloudWatch dashboard for exit code monitor"
}