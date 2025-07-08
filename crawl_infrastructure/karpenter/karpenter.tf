module "karpenter" {

  source       = "terraform-aws-modules/eks/aws//modules/karpenter"
  version      = "~> 20.37"
  cluster_name = var.cluster_name

  # Don't create access entry - it conflicts with managed node group
  create_access_entry = false

  irsa_oidc_provider_arn = var.oidc_provider_arn

  irsa_namespace_service_accounts = ["karpenter:karpenter"]

  # Create dedicated IAM role for Karpenter nodes
  create_node_iam_role = true

  # Don't reuse the managed node group role
  # node_iam_role_arn = var.iam_role_arn

  enable_irsa = true

  create_instance_profile = true

  # Remove pod identity association as it's not configured
  create_pod_identity_association = false

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

# Add null resource to ensure OIDC provider is ready
resource "null_resource" "wait_for_oidc" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for OIDC provider to be ready..."
      sleep 30
    EOT
  }
  
  triggers = {
    oidc_provider_arn = var.oidc_provider_arn
  }
}

resource "helm_release" "karpenter" {
  depends_on = [
    module.karpenter,
    null_resource.wait_for_oidc
  ]
  namespace           = "karpenter"
  create_namespace    = true
  name                = "karpenter"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = var.repository_username
  repository_password = var.repository_password
  chart               = "karpenter"
  version = var.karpenter_chart_version
  
  # Wait for cluster to be ready
  wait = true
  wait_for_jobs = true
  timeout = 1200  # Increased to 20 minutes

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
        },
        {
          key      = "CriticalAddonsOnly"
          operator = "Equal"
          value    = "true"
          effect   = "NoExecute"
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
    # Removed role_name - not used in template
  })
  depends_on = [
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = templatefile("${path.module}/configs/karpenter-ec2nodeclass.yaml.tmpl", {
    cluster_name = var.cluster_name
    # Removed role_name - Karpenter auto-discovers its own role
  })
  depends_on = [
    helm_release.karpenter
  ]
}

# Cleanup Karpenter resources before destroying
resource "null_resource" "karpenter_cleanup" {
  triggers = {
    cluster_name = var.cluster_name
    region = data.aws_region.current.name
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "Cleaning up Karpenter resources..."
      # Update kubeconfig
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} || true
      
      # Delete all nodepools and node classes
      kubectl delete nodepools.karpenter.sh --all --timeout=60s || true
      kubectl delete ec2nodeclasses.karpenter.k8s.aws --all --timeout=60s || true
      
      # Wait for nodes to be terminated
      echo "Waiting for Karpenter nodes to terminate..."
      sleep 30
    EOT
    on_failure = continue
  }

  depends_on = [
    kubectl_manifest.karpenter_nodepool,
    kubectl_manifest.karpenter_node_class
  ]
}

# Data source to get current region
data "aws_region" "current" {}


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

output "karpenter_node_iam_role_name" {
  value = module.karpenter.node_iam_role_name
}