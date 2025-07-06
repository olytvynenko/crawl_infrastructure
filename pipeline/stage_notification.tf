###############################################################################
# Stage Notification Lambda Function
###############################################################################

# Archive the Lambda function code
data "archive_file" "stage_notification_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/stage_notification"
  output_path = "${path.module}/build/lambda_stage_notification.zip"
}

# IAM role for stage notification Lambda
resource "aws_iam_role" "stage_notification_lambda_role" {
  name = "pipeline-stage-notification-role"
  
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

# IAM policy for stage notification Lambda
resource "aws_iam_role_policy" "stage_notification_lambda_policy" {
  name = "pipeline-stage-notification-policy"
  role = aws_iam_role.stage_notification_lambda_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = [
          "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/email/*"
        ]
      }
    ]
  })
}

# Lambda function for stage notifications
resource "aws_lambda_function" "stage_notification" {
  function_name = "pipeline-stage-notification"
  runtime       = "python3.11"
  handler       = "stage_notification.lambda_handler"
  
  filename         = data.archive_file.stage_notification_zip.output_path
  source_code_hash = data.archive_file.stage_notification_zip.output_base64sha256
  
  role = aws_iam_role.stage_notification_lambda_role.arn
  
  timeout     = 30
  memory_size = 128
  
  environment {
    variables = {
      ADMIN_EMAILS = local.admin_emails_string
    }
  }
  
  description = "Sends email notifications for pipeline stage completions and failures"
}