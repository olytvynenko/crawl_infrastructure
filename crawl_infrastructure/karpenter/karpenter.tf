module "karpenter" {

  source = "terraform-aws-modules/eks/aws//modules/karpenter"
  #   version = "20.0"
  cluster_name = var.cluster_name

  irsa_oidc_provider_arn = var.oidc_provider_arn

  irsa_namespace_service_accounts = ["karpenter:karpenter"]

  # 19 > 20
  #   create_iam_role      = false
  create_node_iam_role = false

  # 19 > 20
  node_iam_role_arn = var.iam_role_arn

  # 19 > 20
  # irsa_use_name_prefix = true

  # 19 > 20
  enable_irsa             = true
  create_instance_profile = true

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }

}

resource "helm_release" "karpenter" {
  namespace           = "karpenter"
  create_namespace    = true
  name                = "karpenter"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = var.repository_username
  repository_password = var.repository_password
  chart               = "karpenter"
  version             = var.karpenter_chart_version

  set {
    name  = "settings.aws.clusterName"
    value = var.cluster_name
  }

  set {
    name  = "settings.aws.clusterEndpoint"
    value = var.cluster_endpoint
  }

  set {
    name = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
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
    name  = "settings.aws.defaultInstanceProfile"
    value = module.karpenter.instance_profile_name
  }

  set {
    name  = "settings.aws.interruptionQueueName"
    value = module.karpenter.queue_name
  }
}

resource "kubectl_manifest" "karpenter_provisioner" {
  yaml_body = templatefile("${path.module}/configs/karpenter-provisioner.yaml.tmpl", {
    name          = var.karpenter_provisioner.name
    architectures = var.karpenter_provisioner.architectures
    instance-type = var.karpenter_provisioner.instance-type
    topology      = var.karpenter_provisioner.topology
    taints        = var.karpenter_provisioner.taints
    labels        = var.karpenter_provisioner.labels
  })
  depends_on = [
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "karpenter_node_template" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1alpha1
    kind: AWSNodeTemplate
    metadata:
      name: default
    spec:
      subnetSelector:
        karpenter.sh/discovery: ${var.cluster_name}
      securityGroupSelector:
        karpenter.sh/discovery: ${var.cluster_name}
      amiFamily: Ubuntu
      blockDeviceMappings:
          - deviceName: /dev/sda1
            ebs:
              volumeSize: 20Gi
              volumeType: gp2
              encrypted: false
      tags:
        Name: ${var.cluster_name}-node
        created-by: "karpneter"
        karpenter.sh/discovery: ${var.cluster_name}
  YAML
  depends_on = [
    helm_release.karpenter
  ]
}

output "karpenter_irsa_arn" {
  # 19 > 20
  # value = module.karpenter.irsa_arn
  value = module.karpenter.iam_role_arn
}

output "karpenter_aws_node_instance_profile_name" {
  value = module.karpenter.instance_profile_name
}

output "karpenter_sqs_queue_name" {
  value = module.karpenter.queue_name
}

output "role_arn" {
  # 19 > 20
  #   value = module.karpenter.role_arn
  value = module.karpenter.node_iam_role_arn
}