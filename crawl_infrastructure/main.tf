# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

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
  #  n_azs         = 3
}

module "eks_ohio" {
  count  = var.clusters.eks_ohio.create ? 1 : 0
  source = "./cluster"
  providers = {
    aws = aws.ohio
  }
  cluster_name = var.clusters.eks_ohio.name
  region       = var.clusters.eks_ohio.region
  #  n_azs         = 3
}

module "eks_oregon" {
  count  = var.clusters.eks_oregon.create ? 1 : 0
  source = "./cluster"
  providers = {
    aws = aws.oregon
  }
  cluster_name = var.clusters.eks_oregon.name
  region       = var.clusters.eks_oregon.region
  #  n_azs        = 3
}

module "eks_n_california" {
  count  = var.clusters.eks_n_california.create ? 1 : 0
  source = "./cluster"
  providers = {
    aws = aws.n_california
  }
  cluster_name = var.clusters.eks_n_california.name
  region       = var.clusters.eks_n_california.region
  #  n_azs        = 2
}