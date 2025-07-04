###############################################################################
# Stage Notification Lambda Function
###############################################################################

# Archive the Lambda function code
data "archive_file" "stage_notification_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/stage_notification"
  output_path = "${path.module}/build/lambda_stage_notification.zip"
}

# Lambda function for stage notifications
resource "aws_lambda_function" "stage_notification" {
  function_name = "pipeline-stage-notification"
  runtime       = "python3.11"
  handler       = "stage_notification.lambda_handler"
  
  filename         = data.archive_file.stage_notification_zip.output_path
  source_code_hash = data.archive_file.stage_notification_zip.output_base64sha256
  
  role = aws_iam_role.lambda_role.arn  # Reuse existing Lambda role from messenger.tf
  
  timeout     = 30
  memory_size = 128
  
  environment {
    variables = {
      ADMIN_EMAILS = local.admin_emails_string
    }
  }
  
  description = "Sends email notifications for pipeline stage completions and failures"
}