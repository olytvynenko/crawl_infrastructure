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
    azs    = list(string)
    inst4  = list(string)
    inst8  = list(string)
    inst16 = list(string)
  }))
  default = {
    "eks_n_virginia" = {
      "create" = true
      "region" = "us-east-1"
      "name"   = "linxact-nv"
      "azs"    = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
      "inst4"  = []
      "inst8"  = []
      "inst16" = []
    },
    "eks_ohio" = {
      "create" = true
      "region" = "us-east-2"
      "name"   = "linxact-oh"
      "azs"    = ["us-east-2a", "us-east-2b", "us-east-2c"]
      "inst4"  = []
      "inst8"  = []
      "inst16" = []
    },
    "eks_oregon" = {
      "create" = true
      "region" = "us-west-2"
      "name"   = "linxact-or"
      "azs"    = ["us-west-2a", "us-west-2b", "us-west-2c", "us-west-2d"]
      "inst4"  = []
      "inst8"  = []
      "inst16" = []
    },
    "eks_n_california" = {
      "create" = true
      "region" = "us-west-1"
      "name"   = "linxact-nc"
      "azs"    = ["us-west-1b", "us-west-1c"]
      "inst4"  = []
      "inst8"  = []
      "inst16" = []
    },
  }
}

variable "karpenter_chart_version" {
  description = "Karpenter Helm chart version to be installed"
  type        = string
}

variable "karpenter_provisioner" {
  type = list(object({
    name            = string
    instance-family = list(string)
    instance-size   = list(string)
    topology        = list(string)
    labels          = optional(map(string))
    taints = optional(object({
      key    = string
      value  = string
      effect = string
    }))
  }))
}

#variable "cluster_configs" {
#  description = "A map of cluster configurations"
#  type        = map(object({
#    create                   = bool
#    name                     = string
#    region                   = string
#    azs                      = list(string)
#    inst4                     = number
#    inst8                     = number
#    inst16                    = number
#  }))
#}