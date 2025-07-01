###############################################################################
# SNS topic + e-mail
###############################################################################
resource "aws_sns_topic" "alert_topic" {
  name = "resources-deletion-missed"
}

# resource "aws_sns_topic_subscription" "email_sub" {
#   topic_arn = aws_sns_topic.alert_topic.arn
#   protocol  = "email"
#   endpoint  = var.notification_email
# }

data "aws_ssm_parameter" "admins" {
  name = "/email/admins"
}

locals {
  # 1. Keep the raw string for direct use in the Lambda environment variables
  admin_emails_string = nonsensitive(data.aws_ssm_parameter.admins.value)

  # 2. Derive a map (<index> => <address>) for SNS subscriptions
  #    – keys are harmless indices, so no secret data appears in resource IDs
  admin_email_map = {
    for idx, raw in split(",", local.admin_emails_string) :
    idx => trimspace(raw)
    if trimspace(raw) != ""
  }
}

resource "aws_sns_topic_subscription" "email_sub" {
  for_each  = local.admin_email_map
  topic_arn = aws_sns_topic.alert_topic.arn
  protocol  = "email"
  endpoint  = each.value        # still marked sensitive, but keys are safe
}


###############################################################################
# IAM role for Lambda
###############################################################################
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "s3-deletion-checker"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "inline"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:ListBucket",
          "s3:GetObject"
        ]
        Effect = "Allow"
        Resource = [
          "arn:aws:s3:::${var.s3_bucket}",
          "arn:aws:s3:::${var.s3_bucket}/*"
        ]
      },
      {
        Action   = "sns:Publish",
        Effect   = "Allow",
        Resource = aws_sns_topic.alert_topic.arn
      },
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Effect   = "Allow"
        Resource = "arn:aws:logs:*:*:*"
      },
      # read EC2 instances ---------------------------------------------------
      {
        Action = ["ec2:DescribeInstances"]
        Effect   = "Allow"
        Resource = "*"
      },
      # read the admin e-mail list ------------------------------------------
      {
        Effect   = "Allow",
        Action = ["ssm:GetParameter"],
        Resource = "arn:aws:ssm:${var.base_aws_region}:${data.aws_caller_identity.this.account_id}:parameter/email/admins"
      },
      # send e-mails via SES -------------------------------------------------
      {
        Effect   = "Allow",
        Action = ["ses:SendEmail", "ses:SendRawEmail"],
        Resource = "*"
      },

    ]
  })
}

###############################################################################
# Lambda function - check resource termination
###############################################################################
data "archive_file" "check_resource_termination_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/check_resource_termination"
  output_path = "${path.module}/build/lambda_package_check_termination.zip"
}

resource "aws_lambda_function" "check_resource_termination" {
  function_name = "check-resource-termination"
  runtime       = "python3.11"
  handler       = "check_resource_termination.main"

  filename         = data.archive_file.check_resource_termination_zip.output_path
  source_code_hash = data.archive_file.check_resource_termination_zip.output_base64sha256

  role = aws_iam_role.lambda_role.arn

  timeout     = 60
  memory_size = 256

  environment {
    variables = {
      ADMIN_EMAILS = local.admin_emails_string
      TAG_KEYS = jsonencode(var.tag_keys)
    }
  }
}

###############################################################################
# Lambda function - check S3 deletion
###############################################################################
data "archive_file" "check_s3_deletions_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/check_s3_deletions"
  output_path = "${path.module}/build/lambda_package_check_s3_deletions.zip"
}

resource "aws_lambda_function" "check_s3_deletions" {
  function_name = "check-s3-deletions"
  runtime       = "python3.9"
  handler       = "handler.main"

  filename         = data.archive_file.check_s3_deletions_zip.output_path
  source_code_hash = data.archive_file.check_s3_deletions_zip.output_base64sha256

  role = aws_iam_role.lambda_role.arn

  timeout     = 60
  memory_size = 256
  environment {
    variables = {
      BUCKET_NAME     = var.s3_bucket
      MAX_AGE_SECONDS = 86400            # 24 h
      SNS_TOPIC_ARN   = aws_sns_topic.alert_topic.arn
      MESSENGER_PARAM = var.messenger_webhook_url == "" ? "" : aws_ssm_parameter.messenger_webhook[0].name

    }
  }
}

###############################################################################
# EventBridge schedule
###############################################################################
resource "aws_cloudwatch_event_rule" "daily" {
  name                = "check-s3-deletions-daily"
  schedule_expression = "rate(1 day)"
}

resource "aws_cloudwatch_event_target" "invoke_lambda" {
  rule      = aws_cloudwatch_event_rule.daily.name
  target_id = "lambda"
  arn       = aws_lambda_function.check_s3_deletions.arn
}

resource "aws_lambda_permission" "allow_events" {
  statement_id  = "AllowExecutionFromEvents"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.check_s3_deletions.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily.arn
}


###############################################################################
# Store it securely in Parameter Store
###############################################################################
resource "aws_ssm_parameter" "messenger_webhook" {
  count = var.messenger_webhook_url == "" ? 0 : 1

  name  = "/s3-monitor/messenger_webhook"
  type  = "SecureString"
  value = var.messenger_webhook_url
}

###############################################################################
# Let the Lambda read that parameter
###############################################################################
resource "aws_iam_role_policy" "lambda_ssm" {
  count = var.messenger_webhook_url == "" ? 0 : 1

  name = "ssm-parameter-for-webhook"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = ["ssm:GetParameter"],
        Effect   = "Allow",
        Resource = aws_ssm_parameter.messenger_webhook[0].arn
      }
    ]
  })
}
