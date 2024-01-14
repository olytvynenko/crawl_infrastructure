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
  count  = 1
  source = "./cluster"
  providers = {
    aws = aws.n_virginia
  }
  cluster_name = "linxact-nv"
  region       = "us-east-1"
}

module "eks_ohio" {
  count  = 1
  source = "./cluster"
  providers = {
    aws = aws.ohio
  }
  cluster_name = "linxact-oh"
  region       = "us-east-2"
}