# Minimal IAM policy for CodeBuild cluster manager
data "aws_iam_policy_document" "codebuild_cluster_manager" {
  # Core permissions for Terraform and cluster management
  statement {
    sid    = "TerraformAndCore"
    effect = "Allow"
    actions = [
      "ssm:Get*",
      "s3:*",
      "dynamodb:*",
      "eks:*",
      "ec2:*",
      "iam:*",
      "sqs:*",
      "events:*",
      "autoscaling:*",
      "ecr-public:*",
      "logs:*",
      "sts:GetServiceBearerToken"
    ]
    resources = ["*"]
  }
}

# Create the managed policy
resource "aws_iam_policy" "codebuild_cluster_manager" {
  name        = "CodeBuildClusterManagerPolicy"
  description = "Minimal policy for CodeBuild to manage EKS clusters"
  policy      = data.aws_iam_policy_document.codebuild_cluster_manager.json
}

# Separate policy for CodeCommit and CloudWatch Logs access
data "aws_iam_policy_document" "codebuild_source_access" {
  # CodeCommit access for source code
  statement {
    sid    = "CodeCommitAccess"
    effect = "Allow"
    actions = [
      "codecommit:GetBranch",
      "codecommit:GetCommit",
      "codecommit:GetRepository",
      "codecommit:ListBranches",
      "codecommit:ListRepositories",
      "codecommit:BatchGetRepositories",
      "codecommit:GitPull"
    ]
    resources = [
      "arn:aws:codecommit:us-east-1:${data.aws_caller_identity.current.account_id}:crawl-infrastructure"
    ]
  }

  # CloudWatch Logs access for build logs
  statement {
    sid    = "CloudWatchLogsAccess"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/cluster-manager",
      "arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/cluster-manager:*"
    ]
  }
}

resource "aws_iam_policy" "codebuild_source_access" {
  name        = "CodeBuildSourceAccessPolicy"
  description = "Policy for CodeBuild to access CodeCommit and CloudWatch Logs"
  policy      = data.aws_iam_policy_document.codebuild_source_access.json
}

# Data source for current AWS account is defined in glue_jobs.tf

# Least-privilege IAM policy for CodeBuild crawler runner
data "aws_iam_policy_document" "codebuild_crawler_runner" {
  # EKS access for running crawler jobs
  statement {
    sid    = "EKSAccess"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
      "eks:ListClusters",
      "eks:AccessKubernetesApi"
    ]
    resources = ["*"]
  }

  # SSM Parameter Store access for configuration
  statement {
    sid    = "SSMParameterAccess"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath"
    ]
    resources = [
      "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/*"
    ]
  }

  # S3 access for crawler data
  statement {
    sid    = "S3DataAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ]
    resources = [
      "arn:aws:s3:::*-seeds",
      "arn:aws:s3:::*-seeds/*",
      "arn:aws:s3:::*-results",
      "arn:aws:s3:::*-results/*",
      "arn:aws:s3:::*-dataset",
      "arn:aws:s3:::*-dataset/*"
    ]
  }

  # CloudWatch Logs for CodeBuild
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/*"
    ]
  }

  # ECR access for container images
  statement {
    sid    = "ECRAccess"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage"
    ]
    resources = ["*"]
  }

  # STS for assuming EKS roles
  statement {
    sid    = "STSAssumeRole"
    effect = "Allow"
    actions = [
      "sts:AssumeRole"
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/eks-*"
    ]
  }
}

# Create the managed policy for crawler runner
resource "aws_iam_policy" "codebuild_crawler_runner" {
  name        = "CodeBuildCrawlerRunnerPolicy"
  description = "Least-privilege policy for CodeBuild to run crawler jobs on EKS"
  policy      = data.aws_iam_policy_document.codebuild_crawler_runner.json
}