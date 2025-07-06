# Least-privilege IAM policy for CodeBuild cluster manager
data "aws_iam_policy_document" "codebuild_cluster_manager" {
  # SSM Parameter Store access
  statement {
    sid    = "SSMParameterAccess"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters"
    ]
    resources = [
      "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/crawl/*"
    ]
  }

  # Terraform state management
  statement {
    sid    = "TerraformStateAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketVersioning",
      "s3:GetBucketLocation"
    ]
    resources = [
      "arn:aws:s3:::linxact-terraform-state",
      "arn:aws:s3:::linxact-terraform-state/*"
    ]
  }

  statement {
    sid    = "TerraformLockTable"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable",
      "dynamodb:DescribeContinuousBackups",
      "dynamodb:DescribeTimeToLive",
      "dynamodb:ListTagsOfResource"
    ]
    resources = [
      "arn:aws:dynamodb:*:${data.aws_caller_identity.current.account_id}:table/terraform-locks"
    ]
  }

  # EKS cluster operations
  statement {
    sid    = "EKSClusterManagement"
    effect = "Allow"
    actions = [
      "eks:CreateCluster",
      "eks:DeleteCluster",
      "eks:DescribeCluster",
      "eks:UpdateClusterConfig",
      "eks:UpdateClusterVersion",
      "eks:ListClusters",
      "eks:TagResource",
      "eks:UntagResource"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "EKSNodeGroupManagement"
    effect = "Allow"
    actions = [
      "eks:CreateNodegroup",
      "eks:DeleteNodegroup",
      "eks:DescribeNodegroup",
      "eks:UpdateNodegroupConfig",
      "eks:UpdateNodegroupVersion",
      "eks:ListNodegroups"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "EKSAccessManagement"
    effect = "Allow"
    actions = [
      "eks:CreateAccessEntry",
      "eks:DeleteAccessEntry",
      "eks:DescribeAccessEntry",
      "eks:UpdateAccessEntry",
      "eks:ListAccessEntries",
      "eks:AssociateAccessPolicy",
      "eks:DisassociateAccessPolicy"
    ]
    resources = ["*"]
  }

  # VPC and networking
  statement {
    sid    = "VPCManagement"
    effect = "Allow"
    actions = [
      "ec2:CreateVpc",
      "ec2:DeleteVpc",
      "ec2:DescribeVpcs",
      "ec2:ModifyVpcAttribute",
      "ec2:CreateSubnet",
      "ec2:DeleteSubnet",
      "ec2:DescribeSubnets",
      "ec2:ModifySubnetAttribute",
      "ec2:CreateInternetGateway",
      "ec2:DeleteInternetGateway",
      "ec2:AttachInternetGateway",
      "ec2:DetachInternetGateway",
      "ec2:DescribeInternetGateways",
      "ec2:CreateRoute",
      "ec2:DeleteRoute",
      "ec2:CreateRouteTable",
      "ec2:DeleteRouteTable",
      "ec2:AssociateRouteTable",
      "ec2:DisassociateRouteTable",
      "ec2:DescribeRouteTables",
      "ec2:CreateNatGateway",
      "ec2:DeleteNatGateway",
      "ec2:DescribeNatGateways",
      "ec2:AllocateAddress",
      "ec2:ReleaseAddress",
      "ec2:DescribeAddresses"
    ]
    resources = ["*"]
  }

  # Security groups
  statement {
    sid    = "SecurityGroupManagement"
    effect = "Allow"
    actions = [
      "ec2:CreateSecurityGroup",
      "ec2:DeleteSecurityGroup",
      "ec2:DescribeSecurityGroups",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress"
    ]
    resources = ["*"]
  }

  # EC2 tagging and general operations
  statement {
    sid    = "EC2GeneralOperations"
    effect = "Allow"
    actions = [
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:DescribeTags",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeRegions",
      "ec2:DescribeInstances",
      "ec2:DescribeImages",
      "ec2:DescribeKeyPairs",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:DescribeVpcAttribute",
      "ec2:DescribePrefixLists",
      "ec2:DescribeSecurityGroupRules",
      "ec2:DescribeNetworkAcls"
    ]
    resources = ["*"]
  }

  # ENI cleanup operations
  statement {
    sid    = "ENICleanup"
    effect = "Allow"
    actions = [
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface"
    ]
    resources = ["*"]
  }

  # IAM operations for EKS
  statement {
    sid    = "IAMRoleManagement"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:ListRoles",
      "iam:UpdateRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy"
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/eks-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/karpenter-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*-eks-node-group-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/codebuild-cluster-manager"
    ]
  }

  statement {
    sid    = "IAMInstanceProfileManagement"
    effect = "Allow"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile"
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/karpenter-*"
    ]
  }

  statement {
    sid    = "IAMOIDCProvider"
    effect = "Allow"
    actions = [
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider"
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/*"
    ]
  }

  statement {
    sid    = "IAMPassRole"
    effect = "Allow"
    actions = [
      "iam:PassRole"
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/eks-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/karpenter-*"
    ]
  }

  # Karpenter-specific resources
  statement {
    sid    = "KarpenterSQS"
    effect = "Allow"
    actions = [
      "sqs:CreateQueue",
      "sqs:DeleteQueue",
      "sqs:GetQueueAttributes",
      "sqs:SetQueueAttributes",
      "sqs:TagQueue",
      "sqs:UntagQueue"
    ]
    resources = [
      "arn:aws:sqs:*:${data.aws_caller_identity.current.account_id}:karpenter-*"
    ]
  }

  statement {
    sid    = "KarpenterEventBridge"
    effect = "Allow"
    actions = [
      "events:PutRule",
      "events:DeleteRule",
      "events:DescribeRule",
      "events:PutTargets",
      "events:RemoveTargets",
      "events:TagResource",
      "events:UntagResource"
    ]
    resources = [
      "arn:aws:events:*:${data.aws_caller_identity.current.account_id}:rule/karpenter-*"
    ]
  }

  # ECR Public access for Karpenter images
  statement {
    sid    = "ECRPublicAccess"
    effect = "Allow"
    actions = [
      "ecr-public:GetAuthorizationToken",
      "ecr-public:BatchCheckLayerAvailability",
      "ecr-public:GetDownloadUrlForLayer"
    ]
    resources = ["*"]
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

  # VPC Endpoints
  statement {
    sid    = "VPCEndpoints"
    effect = "Allow"
    actions = [
      "ec2:CreateVpcEndpoint",
      "ec2:DeleteVpcEndpoints",
      "ec2:DescribeVpcEndpoints",
      "ec2:ModifyVpcEndpoint"
    ]
    resources = ["*"]
  }

  # Launch templates for Karpenter
  statement {
    sid    = "LaunchTemplates"
    effect = "Allow"
    actions = [
      "ec2:CreateLaunchTemplate",
      "ec2:DeleteLaunchTemplate",
      "ec2:CreateLaunchTemplateVersion",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeLaunchTemplateVersions"
    ]
    resources = ["*"]
  }

  # Auto Scaling for managed node groups
  statement {
    sid    = "AutoScaling"
    effect = "Allow"
    actions = [
      "autoscaling:CreateAutoScalingGroup",
      "autoscaling:DeleteAutoScalingGroup",
      "autoscaling:UpdateAutoScalingGroup",
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:CreateOrUpdateTags",
      "autoscaling:DeleteTags"
    ]
    resources = ["*"]
  }

  # Additional IAM policies for EKS managed node groups
  statement {
    sid    = "IAMServiceLinkedRole"
    effect = "Allow"
    actions = [
      "iam:CreateServiceLinkedRole"
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/eks.amazonaws.com/*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/eks-nodegroup.amazonaws.com/*"
    ]
  }

  # STS permissions for ECR Public
  statement {
    sid    = "STSServiceBearerToken"
    effect = "Allow"
    actions = [
      "sts:GetServiceBearerToken"
    ]
    resources = ["*"]
  }


  # Additional IAM permissions
  statement {
    sid    = "IAMPolicyManagement"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions"
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/*"
    ]
  }

}

# Create the managed policy
resource "aws_iam_policy" "codebuild_cluster_manager" {
  name        = "CodeBuildClusterManagerPolicy"
  description = "Least-privilege policy for CodeBuild to manage EKS clusters"
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