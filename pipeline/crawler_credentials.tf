###############################################################################
# Crawler Credentials in Parameter Store
###############################################################################

# Store crawler AWS credentials securely
resource "aws_ssm_parameter" "crawler_aws_access_key_id" {
  name        = "/crawl/credentials/aws_access_key_id"
  description = "AWS Access Key ID for crawler"
  type        = "SecureString"
  value       = var.crawler_aws_access_key_id
  
  tags = {
    Purpose = "Crawler authentication"
  }
}

resource "aws_ssm_parameter" "crawler_aws_secret_access_key" {
  name        = "/crawl/credentials/aws_secret_access_key"
  description = "AWS Secret Access Key for crawler"
  type        = "SecureString"
  value       = var.crawler_aws_secret_access_key
  
  tags = {
    Purpose = "Crawler authentication"
  }
}

resource "aws_ssm_parameter" "crawler_ip_abuse_check_key" {
  name        = "/crawl/credentials/ip_abuse_check_key"
  description = "IP Abuse Check API Key for crawler"
  type        = "SecureString"
  value       = var.crawler_ip_abuse_check_key
  
  tags = {
    Purpose = "Crawler IP abuse checking"
  }
}

###############################################################################
# Update IAM policy for CodeBuild to read these parameters
###############################################################################
resource "aws_iam_policy" "codebuild_read_crawler_credentials" {
  name        = "CodeBuildReadCrawlerCredentials"
  description = "Allow CodeBuild to read crawler credentials from Parameter Store"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = [
          aws_ssm_parameter.crawler_aws_access_key_id.arn,
          aws_ssm_parameter.crawler_aws_secret_access_key.arn,
          aws_ssm_parameter.crawler_ip_abuse_check_key.arn
        ]
      }
    ]
  })
}

# Attach the policy to the CodeBuild role
resource "aws_iam_role_policy_attachment" "codebuild_crawler_credentials" {
  role       = module.crawler_ci.codebuild_role_name
  policy_arn = aws_iam_policy.codebuild_read_crawler_credentials.arn
}