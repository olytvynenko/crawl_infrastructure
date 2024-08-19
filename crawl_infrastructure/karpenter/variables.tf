variable "cluster_name" {
  type = string
}

variable "cluster_endpoint" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "iam_role_arn" {
  type = string
}

variable "iam_role_name" {
  type = string
}

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