module "karpenter" {

  source       = "terraform-aws-modules/eks/aws//modules/karpenter"
  version      = "~> 20.37"
  cluster_name = var.cluster_name

  create_access_entry = false

  irsa_oidc_provider_arn = var.oidc_provider_arn

  irsa_namespace_service_accounts = ["karpenter:karpenter"]

  create_node_iam_role = false

  node_iam_role_arn = var.iam_role_arn

  enable_irsa = true

  create_instance_profile = true

  create_pod_identity_association = true

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }

}

# resource "helm_release" "karpenter_crd" {
#   depends_on = [module.karpenter]
#   namespace           = "karpenter"
#   create_namespace    = true
#   name                = "karpenter-crd"
#   repository          = "oci://public.ecr.aws/karpenter"
#   chart               = "karpenter-crd"
#   repository_username = var.repository_username
#   repository_password = var.repository_password
#   version             = var.karpenter_chart_version
#   replace             = true
#   force_update        = true
#
# }

resource "helm_release" "karpenter" {
  depends_on = [module.karpenter]
  namespace           = "karpenter"
  create_namespace    = true
  name                = "karpenter"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = var.repository_username
  repository_password = var.repository_password
  chart               = "karpenter"
  version = var.karpenter_chart_version

  set {
    name  = "settings.clusterName"
    value = var.cluster_name
  }

  set {
    name  = "settings.clusterEndpoint"
    value = var.cluster_endpoint
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    # 19 > 20
    # value = module.karpenter.irsa_arn
    value = module.karpenter.iam_role_arn
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/sts-regional-endpoints"
    value = "true"
    type  = "string"
  }

  set {
    name  = "settings.defaultInstanceProfile"
    value = module.karpenter.instance_profile_name
  }

  set {
    name  = "settings.interruptionQueueName"
    value = module.karpenter.queue_name
  }

  # Use values block for complex configuration
  values = [
    yamlencode({
      replicas = 2
      tolerations = [
        {
          key      = "CriticalAddonsOnly"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }
      ]
    })
  ]

}

resource "kubectl_manifest" "karpenter_nodepool" {
  yaml_body = templatefile("${path.module}/configs/karpenter-nodepool.yaml.tmpl", {
    cluster_name  = var.cluster_name
    name          = var.karpenter_provisioner.name
    architectures = var.karpenter_provisioner.architectures
    instance-type = var.karpenter_provisioner.instance-type
    topology      = var.karpenter_provisioner.topology
    taints        = var.karpenter_provisioner.taints
    labels        = var.karpenter_provisioner.labels
    role_name     = var.iam_role_name
  })
  depends_on = [
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = templatefile("${path.module}/configs/karpenter-ec2nodeclass.yaml.tmpl", {
    cluster_name = var.cluster_name
    role_name    = var.iam_role_name
  })
  depends_on = [
    helm_release.karpenter
  ]
}

# Keep your existing helm_release as is, but add this:
# resource "null_resource" "karpenter_cleanup" {
#
#   provisioner "local-exec" {
#     when    = destroy
#     command = <<-EOT
#       # Try to clean up Karpenter resources before Helm uninstall
#       kubectl --ignore-not-found=true delete nodepools --all || true
#       kubectl --ignore-not-found=true delete ec2nodeclass --all || true
#       sleep 5
#     EOT
#     on_failure = continue
#   }
#
#     # This ensures cleanup runs BEFORE cluster destruction
#   lifecycle {
#     create_before_destroy = true
#   }
#
#
#   depends_on = [helm_release.karpenter]
# }


output "karpenter_irsa_arn" {
  value = module.karpenter.iam_role_arn
}

output "karpenter_aws_node_instance_profile_name" {
  value = module.karpenter.instance_profile_name
}

output "karpenter_sqs_queue_name" {
  value = module.karpenter.queue_name
}

output "role_arn" {
  value = module.karpenter.node_iam_role_arn
}