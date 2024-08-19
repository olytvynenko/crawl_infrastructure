module "eks" {

  source          = "terraform-aws-modules/eks/aws"
  version         = "~> 20.11"
  cluster_name    = local.cluster_name
  cluster_version = "1.30"

  authentication_mode = "API"

  enable_cluster_creator_admin_permissions = true

  vpc_id = module.vpc.vpc_id

  subnet_ids               = module.vpc.public_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  cluster_endpoint_public_access = true
  #  cluster_enabled_log_types      = ["audit", "api", "authenticator", "controllerManager", "scheduler"]
  cluster_enabled_log_types   = []
  create_cloudwatch_log_group = false

  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64"
  }

  eks_managed_node_groups = {
    default = {
      name           = "crawl-admin"
      capacity_type  = "ON_DEMAND"
      instance_types = ["c6a.large"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2
      taints = [
        {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        },
        {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_EXECUTE"
        }
      ]
      max_unavailable_percentage = 50
    }
  }

  #   cluster_identity_providers = {
  #     sts = {
  #       client_id = "sts.amazonaws.com"
  #     }
  #   }

  node_security_group_tags = {
    "karpenter.sh/discovery" = local.cluster_name
  }

}

# resource "aws_eks_access_entry" "admin" {
#   cluster_name  = local.cluster_name
#   principal_arn = "arn:aws:iam::411623750878:user/olexiy"
#   user_name = "olexiy"
# }
#
# resource "aws_eks_access_policy_association" "admin" {
#   cluster_name = local.cluster_name
#   policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
#   principal_arn = "arn:aws:iam::411623750878:user/olexiy"
#
#   access_scope {
#     type = "cluster"
#   }
#   # force the creation of the entry before the creation of the policy
#   depends_on = [aws_eks_access_entry.admin]
# }

# resource "aws_eks_access_entry" "karpenter" {
#   cluster_name  = local.cluster_name
#   principal_arn = module
# }

