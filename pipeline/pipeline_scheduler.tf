###############################################################################
# Pipeline Advance Notification and Scheduling
###############################################################################

# Archive the Lambda function code
data "archive_file" "pipeline_advance_notification_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/pipeline_advance_notification"
  output_path = "${path.module}/build/lambda_pipeline_advance_notification.zip"
}

# Lambda function for pipeline advance notifications
resource "aws_lambda_function" "pipeline_advance_notification" {
  function_name = "pipeline-advance-notification"
  runtime       = "python3.11"
  handler       = "pipeline_advance_notification.lambda_handler"
  
  filename         = data.archive_file.pipeline_advance_notification_zip.output_path
  source_code_hash = data.archive_file.pipeline_advance_notification_zip.output_base64sha256
  
  role = aws_iam_role.scheduler_lambda_role.arn
  
  timeout     = 60
  memory_size = 256
  
  environment {
    variables = {
      STATE_MACHINE_ARN           = aws_sfn_state_machine.crawl.arn
      STAGE_NOTIFICATION_LAMBDA_ARN = aws_lambda_function.stage_notification.arn
      AUTO_START_PIPELINE         = var.auto_start_pipeline ? "true" : "false"
    }
  }
  
  description = "Sends advance notifications and optionally schedules pipeline execution"
}

###############################################################################
# IAM Role for Scheduler Lambda
###############################################################################

resource "aws_iam_role" "scheduler_lambda_role" {
  name = "pipeline-scheduler-lambda-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# Attach basic Lambda execution policy
resource "aws_iam_role_policy_attachment" "scheduler_lambda_basic" {
  role       = aws_iam_role.scheduler_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Policy for scheduler Lambda to access other services
resource "aws_iam_role_policy" "scheduler_lambda_policy" {
  name = "scheduler-lambda-policy"
  role = aws_iam_role.scheduler_lambda_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter"
        ]
        Resource = [
          "arn:aws:ssm:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:parameter/email/admin"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = [
          aws_lambda_function.stage_notification.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "states:StartExecution"
        ]
        Resource = [
          aws_sfn_state_machine.crawl.arn
        ]
      }
    ]
  })
}

###############################################################################
# CloudWatch Events Rules for Scheduling
###############################################################################

# Example: Daily pipeline run with 24-hour advance notification
# This rule triggers the advance notification Lambda 24 hours before the actual run
resource "aws_cloudwatch_event_rule" "pipeline_advance_notification" {
  count               = var.enable_scheduled_pipeline ? 1 : 0
  name                = "pipeline-advance-notification"
  description         = "Trigger advance notification 24 hours before pipeline execution"
  schedule_expression = var.pipeline_advance_notification_schedule  # e.g., "cron(0 10 * * ? *)" for daily at 10 AM
  is_enabled          = var.enable_scheduled_pipeline
}

resource "aws_cloudwatch_event_target" "pipeline_advance_notification" {
  count     = var.enable_scheduled_pipeline ? 1 : 0
  rule      = aws_cloudwatch_event_rule.pipeline_advance_notification[0].name
  target_id = "pipeline-advance-notification-lambda"
  arn       = aws_lambda_function.pipeline_advance_notification.arn
  
  input = jsonencode({
    pipeline_config = var.scheduled_pipeline_config
  })
}

resource "aws_lambda_permission" "allow_cloudwatch_advance_notification" {
  count         = var.enable_scheduled_pipeline ? 1 : 0
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pipeline_advance_notification.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.pipeline_advance_notification[0].arn
}

# Actual pipeline execution rule (24 hours after notification)
resource "aws_cloudwatch_event_rule" "pipeline_execution" {
  count               = var.enable_scheduled_pipeline && var.auto_start_pipeline ? 1 : 0
  name                = "pipeline-scheduled-execution"
  description         = "Execute pipeline on schedule"
  schedule_expression = var.pipeline_execution_schedule  # e.g., "cron(0 10 * * ? *)" for daily at 10 AM next day
  is_enabled          = var.enable_scheduled_pipeline && var.auto_start_pipeline
}

resource "aws_cloudwatch_event_target" "pipeline_execution" {
  count     = var.enable_scheduled_pipeline && var.auto_start_pipeline ? 1 : 0
  rule      = aws_cloudwatch_event_rule.pipeline_execution[0].name
  target_id = "pipeline-execution-sfn"
  arn       = aws_sfn_state_machine.crawl.arn
  role_arn  = aws_iam_role.eventbridge_sfn_role[0].arn
  
  input = jsonencode(var.scheduled_pipeline_config)
}

# IAM role for EventBridge to start Step Functions
resource "aws_iam_role" "eventbridge_sfn_role" {
  count = var.enable_scheduled_pipeline && var.auto_start_pipeline ? 1 : 0
  name  = "eventbridge-sfn-execution-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "eventbridge_sfn_policy" {
  count = var.enable_scheduled_pipeline && var.auto_start_pipeline ? 1 : 0
  name  = "eventbridge-sfn-execution-policy"
  role  = aws_iam_role.eventbridge_sfn_role[0].id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "states:StartExecution"
        Resource = aws_sfn_state_machine.crawl.arn
      }
    ]
  })
}

###############################################################################
# Variables for Pipeline Scheduling
###############################################################################

variable "enable_scheduled_pipeline" {
  description = "Enable scheduled pipeline execution with advance notifications"
  type        = bool
  default     = false
}

variable "auto_start_pipeline" {
  description = "Automatically start the pipeline after advance notification"
  type        = bool
  default     = false
}

variable "pipeline_advance_notification_schedule" {
  description = "Cron expression for advance notification (24 hours before execution)"
  type        = string
  default     = "cron(0 10 * * ? *)"  # Daily at 10 AM UTC
}

variable "pipeline_execution_schedule" {
  description = "Cron expression for actual pipeline execution"
  type        = string
  default     = "cron(0 10 * * ? *)"  # Daily at 10 AM UTC (next day)
}

variable "scheduled_pipeline_config" {
  description = "Configuration for scheduled pipeline execution"
  type = object({
    notifications_enabled = bool
    stages = map(bool)
  })
  default = {
    notifications_enabled = true
    stages = {}  # All stages enabled by default
  }
}