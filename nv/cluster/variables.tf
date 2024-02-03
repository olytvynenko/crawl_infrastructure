variable "create" {
  description = "Create or not"
  type        = bool
  default     = false
}

variable "repository_username" {
  description = "Repository username"
  type        = string
}

variable "repository_password" {
  description = "Repository password"
  type        = string
}

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

variable "create_eks" {
  type    = bool
  default = false
}

variable "inst4" {
  description = "Normal instances"
  type        = list(string)
  default     = ["t4g.medium", "m6g.medium", "m7g.medium", "m6gd.medium"]
}

variable "inst8" {
  description = "Normal instances"
  type        = list(string)
  default     = ["r7g.medium", "r6g.medium", "r6gd.medium", "x2gd.medium", "r7gd.medium"]
}

variable "inst16" {
  description = "Normal instances"
  type        = list(string)
  default     = ["r7g.large"]
}

variable "azs" {
  type    = list(string)
  default = []
}

variable "inst" {
  type    = number
  default = 4
}