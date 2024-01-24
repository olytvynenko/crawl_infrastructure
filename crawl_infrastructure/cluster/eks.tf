module "eks" {

  source  = "terraform-aws-modules/eks/aws"
  version = "19.15.3"

  cluster_name    = local.cluster_name
  cluster_version = "1.28"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  eks_managed_node_group_defaults = {
    ami_type = "AL2_ARM_64"
    #    ami_type = "AL2_x86_64"
  }

  eks_managed_node_groups = {
    default_node_group = {
      name           = "crawl-1"
      capacity_type  = "SPOT"
      instance_types = var.inst == 16 ? var.inst16 : var.inst == 8 ? var.inst8 : var.inst4
      min_size       = 1
      max_size       = 3
      desired_size   = 1
    }
  }

  aws_auth_roles = [
    # We need to add in the Karpenter node IAM role for nodes launched by Karpenter
    {
      rolearn  = module.karpenter.role_arn
      username = "system:node:{{EC2PrivateDNSName}}"
      groups = [
        "system:bootstrappers",
        "system:nodes",
      ]
    },
  ]

  node_security_group_tags = {
    "karpenter.sh/discovery" = local.cluster_name
  }

}
