# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Cluster name"
  type        = string
  default     = "linxact"
}

variable "vpc_name" {
  description = "VPC name"
  type        = string
  default     = "linxact-vpc"
}

variable "normal_instances" {
  description = "Normal instances"
  type        = list(string)
  default     = ["t4g.medium", "m6g.medium", "m7g.medium", "m6gd.medium"]
}

variable "recrawl_normal_instances" {
  description = "Normal instances"
  type        = list(string)
  default     = ["r7g.medium", "r6g.medium"]
}

variable "enhanced_instances" {
  description = "Normal instances"
  type        = list(string)
  default     = ["r7g.medium", "r6g.medium", "r6gd.medium", "x2gd.medium", "r7gd.medium"]
}

variable "recrawl_enhanced_instances" {
  description = "Normal instances"
  type        = list(string)
  default     = ["x2gd.medium"]
}

variable "clusters" {
  type = map(object({
    create = bool
    region = string
    name   = string
  }))
  default = {
    "eks_n_virginia" = {
      "create" = true
      "region" = "us-east-1"
      "name"   = "linxact-nv"
    },
    "eks_ohio" = {
      "create" = true
      "region" = "us-east-2"
      "name"   = "linxact-oh"
    },
    "eks_oregon" = {
      "create" = true
      "region" = "us-west-2"
      "name"   = "linxact-or"
    },
    "eks_n_california" = {
      "create" = true
      "region" = "us-west-1"
      "name"   = "linxact-nc"
    },
  }
}
