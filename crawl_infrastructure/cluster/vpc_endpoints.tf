# VPC Endpoints with secure policies

locals {
  # Common S3 buckets that need access
  allowed_s3_buckets = [
    "linxact-terraform-state",
    "linxact",
    "crawl-build-artifacts-${data.aws_caller_identity.current.account_id}",
    "linxact-glue-shuffle",
    "*-seeds",
    "*-results", 
    "*-dataset"
  ]
  
  # AWS managed buckets
  aws_managed_buckets = [
    "aws-glue-etl-artifacts",
    "prod-${var.region}-starport-layer-bucket"  # EKS layers
  ]
}

# Data source for AWS account info
data "aws_caller_identity" "current" {}

# S3 VPC Endpoint with restrictive policy
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.public_route_table_ids
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowS3ActionsInAccount"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:GetBucketVersioning",
          "s3:ListBucketMultipartUploads",
          "s3:ListMultipartUploadParts",
          "s3:AbortMultipartUpload"
        ]
        Resource = concat(
          # Bucket-level permissions
          [for bucket in local.allowed_s3_buckets : "arn:aws:s3:::${bucket}"],
          # Object-level permissions  
          [for bucket in local.allowed_s3_buckets : "arn:aws:s3:::${bucket}/*"]
        )
        Condition = {
          StringEquals = {
            "aws:PrincipalAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "AllowAWSManagedBuckets"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = concat(
          [for bucket in local.aws_managed_buckets : "arn:aws:s3:::${bucket}"],
          [for bucket in local.aws_managed_buckets : "arn:aws:s3:::${bucket}/*"]
        )
      },
      {
        Sid    = "AllowEKSServiceAccess"
        Effect = "Allow"
        Principal = {
          Service = [
            "eks.amazonaws.com",
            "eks-nodegroup.amazonaws.com"
          ]
        }
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::amazon-eks-*",
          "arn:aws:s3:::amazon-eks-*/*"
        ]
      }
    ]
  })
  
  tags = {
    Name = "${local.cluster_name}-s3-endpoint"
  }
}

# ECR API VPC Endpoint
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.public_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
  
  tags = {
    Name = "${local.cluster_name}-ecr-api-endpoint"
  }
}

# ECR Docker Registry VPC Endpoint (already exists, updating with security group)
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.public_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
  
  tags = {
    Name = "${local.cluster_name}-ecr-dkr-endpoint"
  }
}

# CloudWatch Logs VPC Endpoint
resource "aws_vpc_endpoint" "logs" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.public_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
  
  tags = {
    Name = "${local.cluster_name}-logs-endpoint"
  }
}

# STS VPC Endpoint for IAM role assumptions
resource "aws_vpc_endpoint" "sts" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.sts"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.public_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
  
  tags = {
    Name = "${local.cluster_name}-sts-endpoint"
  }
}

# SSM VPC Endpoint for Parameter Store access
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.public_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
  
  tags = {
    Name = "${local.cluster_name}-ssm-endpoint"
  }
}

# Security group for VPC endpoints
resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "${local.cluster_name}-vpc-endpoints-"
  vpc_id      = module.vpc.vpc_id
  description = "Security group for VPC endpoints"
  
  ingress {
    description = "Allow HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }
  
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "${local.cluster_name}-vpc-endpoints-sg"
  }
}