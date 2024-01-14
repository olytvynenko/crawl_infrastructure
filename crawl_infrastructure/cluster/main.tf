# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

#provider "aws" {
#  region  = "us-east-1"
#  alias   = "n_virginia"
#}
#
#provider "aws" {
#  region  = "us-east-2"
#  alias   = "ohio"
#}
#
#provider "aws" {
#  region  = "us-west-2"
#  alias   = "oregon"
#}
#
#provider "aws" {
#  region  = "us-west-1"
#  alias   = "n_california"
#}



# Filter out local zones, which are not currently supported 
# with managed node groups
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  #  cluster_name = "${var.cluster_name}-${random_string.suffix.result}"
  cluster_name = var.cluster_name
}

resource "random_string" "suffix" {
  length  = 8
  special = false
}

resource "null_resource" "merge_kubeconfig" {
  count      = module.eks.cluster_name != "" ? 1 : 0
  depends_on = [module.eks.cluster_id]
  triggers = {
    always = timestamp()
  }
  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --name ${local.cluster_name} --alias ${local.cluster_name}-${var.region}"
  }
}


