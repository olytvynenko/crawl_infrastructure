###############################################################################
# Exit Code Monitor - Build Project for existing crawler-arm ECR
###############################################################################

# This builds the exit code monitor and pushes to the existing crawler-arm ECR repo
# as a separate tag, avoiding the need for a new ECR repository

# Data source to get existing crawler-arm ECR repository
data "aws_ecr_repository" "crawler_arm" {
  name = "crawler-arm"
}

# CodeBuild project to build exit code monitor
resource "aws_codebuild_project" "exit_code_monitor_build" {
  name          = var.exit_code_monitor_build_project
  service_role  = aws_iam_role.cb_role.arn  # Reuse cluster manager role

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                      = "aws/codebuild/standard:7.0"
    type                       = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode            = true

    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = data.aws_region.current.id
    }

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = data.aws_caller_identity.this.account_id
    }

    environment_variable {
      name  = "ECR_REPOSITORY_URI"
      value = data.aws_ecr_repository.crawler_arm.repository_url
    }
  }

  source {
    type            = "CODECOMMIT"
    location        = aws_codecommit_repository.kube_jobs.clone_url_http
    git_clone_depth = 1
    buildspec       = <<-EOT
      version: 0.2
      phases:
        pre_build:
          commands:
            - echo Logging in to Amazon ECR...
            - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $ECR_REPOSITORY_URI
            - cd pipeline/kube-jobs/exit_code_monitor
            - IMAGE_TAG=exit-code-monitor-latest
            - IMAGE_URI=$ECR_REPOSITORY_URI:$IMAGE_TAG
        build:
          commands:
            - echo Build started on `date`
            - docker build -t exit-code-monitor .
            - docker tag exit-code-monitor $IMAGE_URI
        post_build:
          commands:
            - echo Build completed on `date`
            - docker push $IMAGE_URI
            - echo "Image pushed to $IMAGE_URI"
            # Create/update SSM parameter with the image URI for easy reference
            - aws ssm put-parameter --name "/crawler/exit-code-monitor/image" --value "$IMAGE_URI" --type "String" --overwrite || true
    EOT
  }

  tags = {
    Name = "exit-code-monitor-build"
  }
}

# Create ZIP archive for Lambda function
data "archive_file" "deploy_exit_code_monitor_zip" {
  type        = "zip"
  source_file = "${path.module}/lambdas/deploy_exit_code_monitor/deploy_exit_code_monitor.py"
  output_path = "${path.module}/lambdas/deploy_exit_code_monitor/deploy_exit_code_monitor.zip"
}

# Lambda function to deploy exit code monitor to EKS clusters
resource "aws_lambda_function" "deploy_exit_code_monitor" {
  filename         = data.archive_file.deploy_exit_code_monitor_zip.output_path
  source_code_hash = data.archive_file.deploy_exit_code_monitor_zip.output_base64sha256
  function_name    = "deploy-exit-code-monitor"
  role             = aws_iam_role.lambda_role.arn
  handler          = "deploy_exit_code_monitor.lambda_handler"
  runtime          = "python3.11"
  timeout          = 300
  memory_size      = 512

  environment {
    variables = {
      ECR_REPOSITORY_URI = data.aws_ecr_repository.crawler_arm.repository_url
      IMAGE_TAG          = "exit-code-monitor-latest"
    }
  }
}

# Add permissions for Lambda to access EKS
resource "aws_iam_role_policy" "lambda_eks_access" {
  name = "lambda-eks-access"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter"
        ]
        Resource = "arn:aws:ssm:*:${data.aws_caller_identity.this.account_id}:parameter/crawler/exit-code-monitor/*"
      }
    ]
  })
}

# Update the variables.tf to include the new project name
# (This would go in variables.tf, shown here for completeness)
# variable "exit_code_monitor_build_project" {
#   default = "exit-code-monitor-build"
# }