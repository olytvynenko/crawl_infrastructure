provider "aws" {
  region = "us-east-1"
  alias  = "n_virginia"
}

provider "aws" {
  region = "us-east-2"
  alias  = "ohio"
}

provider "aws" {
  region = "us-west-2"
  alias  = "oregon"
}

provider "aws" {
  region = "us-west-1"
  alias  = "n_california"
}

module "eks_n_virginia" {
  count  = var.clusters.eks_n_virginia.create ? 1 : 0
  source = "./cluster"
  providers = {
    aws = aws.n_virginia
  }
  cluster_name = var.clusters.eks_n_virginia.name
  region       = var.clusters.eks_n_virginia.region
  azs          = var.clusters.eks_n_virginia.azs
  inst4        = var.clusters.eks_n_virginia.inst4
  inst8        = var.clusters.eks_n_virginia.inst8
}

module "eks_ohio" {
  count  = var.clusters.eks_ohio.create ? 1 : 0
  source = "./cluster"
  providers = {
    aws = aws.ohio
  }
  cluster_name = var.clusters.eks_ohio.name
  region       = var.clusters.eks_ohio.region
  azs          = var.clusters.eks_ohio.azs
  inst4        = var.clusters.ohio.inst4
  inst8        = var.clusters.eks_ohio.inst8
}

module "eks_oregon" {
  count  = var.clusters.eks_oregon.create ? 1 : 0
  source = "./cluster"
  providers = {
    aws = aws.oregon
  }
  cluster_name = var.clusters.eks_oregon.name
  region       = var.clusters.eks_oregon.region
  azs          = var.clusters.eks_oregon.azs
  inst4        = var.clusters.eks_oregon.inst4
  inst8        = var.clusters.eks_oregon.inst8
}

module "eks_n_california" {
  count  = var.clusters.eks_n_california.create ? 1 : 0
  source = "./cluster"
  providers = {
    aws = aws.n_california
  }
  cluster_name = var.clusters.eks_n_california.name
  region       = var.clusters.eks_n_california.region
  azs          = var.clusters.eks_n_california.azs
  inst4        = var.clusters.eks_n_california.inst4
  inst8        = var.clusters.eks_n_california.inst8
}

#module "eks_region" {
#  source = "./cluster"
#  for_each = var.clusters
#  count = each.value.create ? 1 : 0
#}