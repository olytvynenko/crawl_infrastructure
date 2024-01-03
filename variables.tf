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
  default     = "linxact-nv"
}

variable "vpc_name" {
  description = "VPC name"
  type        = string
  default     = "linxact-nc-vpc"
}
