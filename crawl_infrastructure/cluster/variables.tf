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

variable "azs" {
  type    = list(string)
  default = []
}