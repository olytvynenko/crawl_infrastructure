variable "cluster_name" {
  type = string
}

variable "cluster_endpoint" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

# Removed iam_role_arn and iam_role_name - Karpenter creates its own role

variable "repository_username" {
  type = string
}

variable "repository_password" {
  type = string
}

variable "karpenter_chart_version" {
  type = string
}

variable "karpenter_provisioner" {
  type = object({
    name              = string
    architectures     = list(string)
    instance-type     = optional(list(string))  # Made optional for backward compatibility
    instance-families = optional(list(string))  # New: specific families like ["r7g", "r6g"]
    instance-sizes    = optional(list(string))  # New: sizes like ["medium", "large"]
    topology          = list(string)
    labels            = optional(map(string))
    taints = optional(object({
      key    = string
      value  = string
      effect = string
    }))
  })
}

