data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.n_virginia
}

locals {
  env = {
    for zone in keys(var.clusters) : zone =>
    {
      cluster_name        = var.clusters[zone].name
      region              = var.clusters[zone].region
      azs                 = var.clusters[zone].azs
      inst4               = var.clusters[zone].inst4
      inst8               = var.clusters[zone].inst8
      repository_username = data.aws_ecrpublic_authorization_token.token.user_name
      repository_password = data.aws_ecrpublic_authorization_token.token.password
    }
  }
}

module "cluster" {
  source = "./cluster"
  providers = {
    aws = aws
  }
  cluster_name        = local.env[terraform.workspace]["cluster_name"]
  region              = local.env[terraform.workspace]["region"]
  azs                 = local.env[terraform.workspace]["azs"]
  inst4               = local.env[terraform.workspace]["inst4"]
  inst8               = local.env[terraform.workspace]["inst8"]
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
}

module "karpenter" {
  source                  = "./karpenter"
  cluster_name            = module.cluster.cluster_name
  cluster_endpoint        = module.cluster.cluster_endpoint
  repository_username     = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password     = data.aws_ecrpublic_authorization_token.token.password
  oidc_provider_arn       = module.cluster.oidc_provider_arn
  iam_role_arn            = module.cluster.iam_role_arn
  karpenter_chart_version = var.karpenter_chart_version
  providers = {
    helm = helm
  }
  karpenter_provisioner = {
    name            = "default"
    architectures   = ["arm64"]
    instance-family = local.env[terraform.workspace]["inst4"]
    topology        = local.env[terraform.workspace]["azs"]
  }
}
