module "eks" {

  #  count = var.create ? 1 : 0

  source  = "terraform-aws-modules/eks/aws"
  version = "19.15.3"

  cluster_name    = local.cluster_name
  cluster_version = "1.28"

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  cluster_endpoint_public_access = true
  cluster_enabled_log_types      = ["audit", "api", "authenticator", "controllerManager", "scheduler"]

  eks_managed_node_group_defaults = {
    #    ami_type = "AL2_ARM_64"
    ami_type = "AL2_x86_64"
  }

  eks_managed_node_groups = {
    default = {
      name          = "crawl-admin"
      capacity_type = "ON_DEMAND"
      #      instance_types = var.inst == 16 ? var.inst16 : var.inst == 8 ? var.inst8 : var.inst4
      instance_types = ["t3.medium", "t3a.medium"]
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

  cluster_identity_providers = {
    sts = {
      client_id = "sts.amazonaws.com"
    }
  }

  aws_auth_users = [
    {
      userarn  = "arn:aws:iam::411623750878:user/olexiy"
      username = "arseny"
      groups   = ["system:masters"]
    }
  ]

  aws_auth_roles = [
    # We need to add in the Karpenter node IAM role for nodes launched by Karpenter
    {
      #      rolearn  = module.karpenter.role_arn
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
