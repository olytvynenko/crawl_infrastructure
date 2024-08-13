module "aws_auth" {
  source                    = "terraform-aws-modules/eks/aws//modules/aws-auth"
  version                   = "~> 20.0"
  manage_aws_auth_configmap = true
  aws_auth_roles = [
    {
      #            rolearn  = module.karpenter.role_arn
      username = "system:node:{{EC2PrivateDNSName}}"
      groups = [
        "system:bootstrappers",
        "system:nodes",
      ]
    },
  ]
  aws_auth_users = [
    {
      userarn  = "arn:aws:iam::411623750878:user/olexiy"
      username = "olexiy"
      groups   = ["system:masters"]
    }
  ]
}