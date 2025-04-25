##########################
# EKS Module Inputs
##########################

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS cluster endpoint URL"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the OIDC provider for IAM"
  type        = string
}

variable "iam_role_arn" {
  description = "ARN of the IAM role for node bootstrapping"
  type        = string
}

variable "iam_role_name" {
  description = "Name of the IAM role for node bootstrapping"
  type        = string
}

variable "repository_username" {
  description = "Username for any container registry credentials"
  type        = string
}

variable "repository_password" {
  description = "Password for any container registry credentials"
  type        = string
}

variable "karpenter_chart_version" {
  description = "Helm chart version for Karpenter"
  type        = string
}

variable "karpenter_provisioner" {
  description = "Settings for the Karpenter Provisioner"
  type = object({
    name          = string
    architectures = list(string)
    instance-type = list(string)
    topology      = list(string)
    labels        = optional(map(string))
    taints = optional(object({
      key    = string
      value  = string
      effect = string
    }))
  })
}

##########################
# Terraform Backend Inputs
##########################

variable "region" {
  description = "AWS region where the S3 backend and DynamoDB lock table live"
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Name of the S3 bucket to store Terraform state"
  type        = string
}

variable "lock_table_name" {
  description = "Name of the DynamoDB table for Terraform state locks"
  type        = string
}

variable "backend_prefix" {
  description = "Key prefix in the S3 bucket for this project’s state files (e.g. \"eks\")"
  type        = string
  default     = "eks"
}
