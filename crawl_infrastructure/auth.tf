###############################################################################
# Get the current AWS partition (aws, aws-us-gov, aws-cn)
###############################################################################
data "aws_partition" "this" {}

###############################################################################
# Build the policy ARN for EKS Cluster Admin Access
###############################################################################
locals {
  admin_policy_arn = "arn:${data.aws_partition.this.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
}

###############################################################################
# EKS Access Entry + Policy Association
###############################################################################
resource "aws_eks_access_entry" "console_user" {
  cluster_name  = module.cluster.cluster_name
  principal_arn = "arn:aws:iam::411623750878:user/olexiy"
}

resource "aws_eks_access_policy_association" "console_user_admin" {
  cluster_name  = module.cluster.cluster_name
  principal_arn = aws_eks_access_entry.console_user.principal_arn
  policy_arn = local.admin_policy_arn         # ← now a real policy
  access_scope { type = "cluster" }
}