###############################################################################
# S3 Deletion Scheduler Lambda Functions
###############################################################################

# Archive for schedule_s3_deletion Lambda
data "archive_file" "schedule_s3_deletion_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/schedule_s3_deletion"
  output_path = "${path.module}/build/lambda_schedule_s3_deletion.zip"
}

# Archive for delete_s3_folders Lambda
data "archive_file" "delete_s3_folders_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/delete_s3_folders"
  output_path = "${path.module}/build/lambda_delete_s3_folders.zip"
}

# Lambda function to schedule S3 deletions
resource "aws_lambda_function" "schedule_s3_deletion" {
  function_name = "schedule-s3-deletion"
  runtime       = "python3.11"
  handler       = "schedule_s3_deletion.lambda_handler"
  
  filename         = data.archive_file.schedule_s3_deletion_zip.output_path
  source_code_hash = data.archive_file.schedule_s3_deletion_zip.output_base64sha256
  
  role = aws_iam_role.s3_deletion_scheduler_role.arn
  
  timeout     = 60
  memory_size = 256
  
  environment {
    variables = {
      DELETION_LAMBDA_ARN     = aws_lambda_function.delete_s3_folders.arn
      CHECK_LAMBDA_ARN        = aws_lambda_function.check_s3_deletions.arn
      DELETION_DELAY_SECONDS  = var.s3_deletion_delay_seconds
      CHECK_DELAY_SECONDS     = var.s3_deletion_check_delay_seconds
      REGULAR_ADMINS          = local.admin_emails_string
    }
  }
  
  description = "Schedules S3 folder deletions and subsequent checks"
}

# Lambda function to delete S3 folders
resource "aws_lambda_function" "delete_s3_folders" {
  function_name = "delete-s3-folders"
  runtime       = "python3.11"
  handler       = "delete_s3_folders.lambda_handler"
  
  filename         = data.archive_file.delete_s3_folders_zip.output_path
  source_code_hash = data.archive_file.delete_s3_folders_zip.output_base64sha256
  
  role = aws_iam_role.s3_deletion_executor_role.arn
  
  timeout     = 300  # 5 minutes for large deletions
  memory_size = 512
  
  environment {
    variables = {
      STAGE_NOTIFICATION_LAMBDA_ARN = aws_lambda_function.stage_notification.arn
    }
  }
  
  description = "Deletes specified S3 folders and their contents"
}


###############################################################################
# IAM Roles and Policies
###############################################################################

# IAM role for schedule_s3_deletion Lambda
resource "aws_iam_role" "s3_deletion_scheduler_role" {
  name = "s3-deletion-scheduler-role"
  
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

# IAM role for delete_s3_folders Lambda
resource "aws_iam_role" "s3_deletion_executor_role" {
  name = "s3-deletion-executor-role"
  
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

# Policy for schedule_s3_deletion Lambda
resource "aws_iam_role_policy" "s3_deletion_scheduler_policy" {
  name = "s3-deletion-scheduler-policy"
  role = aws_iam_role.s3_deletion_scheduler_role.id
  
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
        Resource = "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = [
          "arn:aws:ssm:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:parameter/s3/bucket",
          "arn:aws:ssm:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:parameter/crawl/dataset/current",
          "arn:aws:ssm:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:parameter/email/admin"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "events:PutRule",
          "events:PutTargets",
          "events:DeleteRule",
          "events:RemoveTargets",
          "events:DescribeRule"
        ]
        Resource = "arn:aws:events:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:rule/s3-deletion-*"
      },
      {
        Effect = "Allow"
        Action = [
          "lambda:AddPermission",
          "lambda:RemovePermission"
        ]
        Resource = [
          aws_lambda_function.delete_s3_folders.arn,
          aws_lambda_function.check_s3_deletions.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "iam:PassRole"
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-events-*"
      },
      {
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail"
        ]
        Resource = "*"
      }
    ]
  })
}

# Policy for delete_s3_folders Lambda
resource "aws_iam_role_policy" "s3_deletion_executor_policy" {
  name = "s3-deletion-executor-policy"
  role = aws_iam_role.s3_deletion_executor_role.id
  
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
        Resource = "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:DeleteObject"
        ]
        Resource = "*"  # Will be restricted by bucket policies
      },
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = aws_lambda_function.stage_notification.arn
      },
      {
        Effect = "Allow"
        Action = [
          "events:PutTargets",
          "events:DescribeRule",
          "events:ListTargetsByRule"
        ]
        Resource = "arn:aws:events:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:rule/s3-deletion-check-*"
      }
    ]
  })
}

# Add EventBridge permissions to existing Lambda role for check_s3_deletions
resource "aws_iam_role_policy" "check_s3_deletions_extra_policy" {
  name = "check-s3-deletions-extra-policy"
  role = aws_iam_role.lambda_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "events:DeleteRule",
          "events:RemoveTargets"
        ]
        Resource = "arn:aws:events:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:rule/s3-deletion-*"
      },
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = aws_lambda_function.stage_notification.arn
      }
    ]
  })
}