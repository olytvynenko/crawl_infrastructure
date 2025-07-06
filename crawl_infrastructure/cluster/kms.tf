# KMS key for EBS encryption

# Create a KMS key for EBS encryption
resource "aws_kms_key" "ebs" {
  description             = "KMS key for EBS volume encryption in ${local.cluster_name} cluster"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  tags = {
    Name        = "${local.cluster_name}-ebs-kms"
    Cluster     = local.cluster_name
    Purpose     = "EBS encryption"
    ManagedBy   = "Terraform"
  }
}

# Create an alias for easier identification
resource "aws_kms_alias" "ebs" {
  name          = "alias/${local.cluster_name}-ebs"
  target_key_id = aws_kms_key.ebs.key_id
}

# KMS key policy to allow EBS service and current account
resource "aws_kms_key_policy" "ebs" {
  key_id = aws_kms_key.ebs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow EBS service to use the key"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:CreateGrant",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        Sid    = "Allow EC2 instances to use the key"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        Sid    = "Allow autoscaling service for EKS managed nodes"
        Effect = "Allow"
        Principal = {
          Service = "autoscaling.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })
}

# Enable EBS encryption by default in the region
resource "aws_ebs_encryption_by_default" "enabled" {
  enabled = true
}

# Set the default KMS key for EBS encryption
resource "aws_ebs_default_kms_key" "ebs" {
  key_arn = aws_kms_key.ebs.arn
}