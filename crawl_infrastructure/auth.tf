###############################################################################
# Get the current AWS partition (aws, aws-us-gov, aws-cn)
###############################################################################
data "aws_partition" "this" {}

###############################################################################
# Get current AWS account ID
###############################################################################
data "aws_caller_identity" "current" {}

###############################################################################
# Build the policy ARN for EKS Cluster Admin Access
###############################################################################
locals {
  admin_policy_arn = "arn:${data.aws_partition.this.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
}

###############################################################################
# EKS Access Entry + Policy Association
###############################################################################
# Note: If this resource already exists, you may need to import it manually:
# terraform import aws_eks_access_entry.console_user "cluster-name:arn:aws:iam::account-id:user/username"

resource "aws_eks_access_entry" "console_user" {
  cluster_name  = module.cluster.cluster_name
  principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${var.eks_admin_username}"
  
  lifecycle {
    # Prevent recreation if it already exists
    create_before_destroy = false
  }
}

resource "aws_eks_access_policy_association" "console_user_admin" {
  cluster_name  = module.cluster.cluster_name
  principal_arn = aws_eks_access_entry.console_user.principal_arn
  policy_arn = local.admin_policy_arn         # ← now a real policy
  access_scope { type = "cluster" }
}