module "eks" {

  source          = "terraform-aws-modules/eks/aws"
  version         = "~> 20.37"
  cluster_name    = local.cluster_name
  cluster_version = "1.33"

  authentication_mode = "API"

  # --- ⬇️ new: authorise CodeBuild role ----------------------------
  access_entries = {
    codebuild = {
      principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.codebuild_role_name}"
      # type = "STANDARD"

      # attach a managed policy that gives full cluster access
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }     # whole cluster
        }
      }
    }
  }
  # -----------------------------------------------------------------

  enable_cluster_creator_admin_permissions = true

  vpc_id = module.vpc.vpc_id

  subnet_ids               = module.vpc.public_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  cluster_endpoint_public_access = true
  create_cloudwatch_log_group    = false
  cluster_enabled_log_types = ["audit", "api", "authenticator", "controllerManager", "scheduler"]
  #   cluster_enabled_log_types      = []

  eks_managed_node_group_defaults = {
    ami_type = "AL2023_x86_64_STANDARD"
  }

  #   eks_managed_node_groups = {}

  eks_managed_node_groups = {
    default = {
      name           = "crawl-admin"
      capacity_type  = "ON_DEMAND"
      instance_types = ["m7i.large"]
      min_size       = 2
      max_size = 2
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
      
      # Launch template for encrypted EBS volumes
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 30
            volume_type           = "gp3"
            encrypted             = true
            kms_key_id           = aws_kms_key.ebs.id
            delete_on_termination = true
          }
        }
      }
    }
  }

  node_security_group_tags = {
    "karpenter.sh/discovery" = local.cluster_name
  }

}



