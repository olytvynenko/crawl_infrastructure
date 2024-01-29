data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.n_virginia
}

module "eks_n_virginia" {
  #  count                   = var.clusters.eks_n_virginia.create ? 1 : 0
  source = "./cluster"
  providers = {
    aws = aws.n_virginia
    #    kubernetes = kubernetes.kub-linxact-nv-us-east-1
    #    helm = helm.helm-nv-us-east-1
  }
  cluster_name            = var.clusters.eks_n_virginia.name
  region                  = var.clusters.eks_n_virginia.region
  azs                     = var.clusters.eks_n_virginia.azs
  inst4                   = var.clusters.eks_n_virginia.inst4
  inst8                   = var.clusters.eks_n_virginia.inst8
  karpenter_chart_version = var.karpenter_chart_version
  karpenter_provisioner   = var.karpenter_provisioner
  repository_username     = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password     = data.aws_ecrpublic_authorization_token.token.password
}


module "karpenter_n_virginia" {
  source                  = "./karpenter"
  cluster_name            = module.eks_n_virginia.cluster_name
  cluster_endpoint        = module.eks_n_virginia.cluster_endpoint
  repository_username     = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password     = data.aws_ecrpublic_authorization_token.token.password
  oidc_provider_arn       = module.eks_n_virginia.oidc_provider_arn
  iam_role_arn            = module.eks_n_virginia.iam_role_arn
  karpenter_chart_version = var.karpenter_chart_version
  providers = {
    helm = helm.n_virginia
  }
}

#
#module "eks_ohio" {
#  count                   = var.clusters.eks_ohio.create ? 1 : 0
#  source                  = "./cluster"
#  providers               = {
#    aws = aws.ohio
#    kubernetes = kubernetes.kub-linxact-oh-us-east-2
#    helm = helm.helm-oh-us-east-2
#  }
#  cluster_name            = var.clusters.eks_ohio.name
#  region                  = var.clusters.eks_ohio.region
#  azs                     = var.clusters.eks_ohio.azs
#  inst4                   = var.clusters.eks_ohio.inst4
#  inst8                   = var.clusters.eks_ohio.inst8
#  karpenter_chart_version = var.karpenter_chart_version
#  karpenter_provisioner   = var.karpenter_provisioner
#  repository_username     = data.aws_ecrpublic_authorization_token.token.user_name
#  repository_password     = data.aws_ecrpublic_authorization_token.token.password
#}
#
#module "eks_oregon" {
#  count                   = var.clusters.eks_oregon.create ? 1 : 0
#  source                  = "./cluster"
#  providers               = {
#    aws = aws.oregon
#    kubernetes = kubernetes.linxact-or-us-west-2
#    helm = helm.helm-or-us-west-2
#  }
#  cluster_name            = var.clusters.eks_oregon.name
#  region                  = var.clusters.eks_oregon.region
#  azs                     = var.clusters.eks_oregon.azs
#  inst4                   = var.clusters.eks_oregon.inst4
#  inst8                   = var.clusters.eks_oregon.inst8
#  karpenter_chart_version = var.karpenter_chart_version
#  karpenter_provisioner   = var.karpenter_provisioner
#  repository_username     = data.aws_ecrpublic_authorization_token.token.user_name
#  repository_password     = data.aws_ecrpublic_authorization_token.token.password
#}
#
#module "eks_n_california" {
#  count                   = var.clusters.eks_n_california.create ? 1 : 0
#  source                  = "./cluster"
#  providers               = {
#    aws = aws.n_california
#    kubernetes = kubernetes.linxact-nc-us-west-1
#    helm = helm.helm-nc-us-west-1
#  }
#  cluster_name            = var.clusters.eks_n_california.name
#  region                  = var.clusters.eks_n_california.region
#  azs                     = var.clusters.eks_n_california.azs
#  inst4                   = var.clusters.eks_n_california.inst4
#  inst8                   = var.clusters.eks_n_california.inst8
#  karpenter_chart_version = var.karpenter_chart_version
#  karpenter_provisioner   = var.karpenter_provisioner
#  repository_username     = data.aws_ecrpublic_authorization_token.token.user_name
#  repository_password     = data.aws_ecrpublic_authorization_token.token.password
#}
