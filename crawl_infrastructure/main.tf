data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.n_virginia
}

locals {
  env = {
    for zone in keys(var.clusters) : zone =>
    {
      cluster_name        = var.clusters[zone].name
      region              = var.clusters[zone].region
      azs                 = var.clusters[zone].azs
      inst4               = var.clusters[zone].inst4
      inst8               = var.clusters[zone].inst8
      inst16              = var.clusters[zone].inst16
      repository_username = data.aws_ecrpublic_authorization_token.token.user_name
      repository_password = data.aws_ecrpublic_authorization_token.token.password
    }
  }
}

module "cluster" {
  source = "./cluster"
  providers = {
    aws = aws
  }
  cluster_name        = local.env[terraform.workspace]["cluster_name"]
  region              = local.env[terraform.workspace]["region"]
  azs                 = local.env[terraform.workspace]["azs"]
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  eks_admin_username  = var.eks_admin_username
  codebuild_role_name = var.codebuild_role_name
}

# Wait for cluster to be ready before installing Karpenter
resource "null_resource" "wait_for_cluster" {
  depends_on = [module.cluster]
  
  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for EKS cluster to be ready..."
      aws eks wait cluster-active --name ${module.cluster.cluster_name} --region ${local.env[terraform.workspace]["region"]}
      
      echo "Updating kubeconfig..."
      aws eks update-kubeconfig --name ${module.cluster.cluster_name} --region ${local.env[terraform.workspace]["region"]}
      
      echo "Waiting for Kubernetes API to be responsive..."
      for i in {1..60}; do
        if kubectl get ns kube-system &>/dev/null; then
          echo "Kubernetes API is responsive"
          break
        fi
        echo "Waiting for Kubernetes API... ($i/60)"
        sleep 5
      done
      
      echo "Waiting for CoreDNS to be ready..."
      kubectl wait --for=condition=available --timeout=300s deployment/coredns -n kube-system || true
      
      echo "Verifying cluster authentication..."
      for i in {1..30}; do
        if aws eks get-token --cluster-name ${module.cluster.cluster_name} --region ${local.env[terraform.workspace]["region"]} &>/dev/null; then
          echo "Cluster authentication verified"
          break
        fi
        echo "Waiting for authentication... ($i/30)"
        sleep 2
      done
      
      # Give the cluster a moment to stabilize
      sleep 10
    EOT
  }
}

module "karpenter" {
  source                  = "./karpenter"
  cluster_name            = module.cluster.cluster_name
  cluster_endpoint        = module.cluster.cluster_endpoint
  repository_username     = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password     = data.aws_ecrpublic_authorization_token.token.password
  oidc_provider_arn       = module.cluster.oidc_provider_arn
  iam_role_arn            = module.cluster.iam_role_arn
  iam_role_name           = module.cluster.iam_role_name
  karpenter_chart_version = var.karpenter_chart_version
  providers = {
    helm = helm
  }
  karpenter_provisioner = {
    name          = "default"
    architectures = ["arm64"]
    instance-type = local.env[terraform.workspace][var.cluster_level]
    topology      = local.env[terraform.workspace]["azs"]
  }
  
  depends_on = [null_resource.wait_for_cluster]
}

resource "null_resource" "merge_kubeconfig" {
  count = module.cluster.cluster_name != "" ? 1 : 0
  depends_on = [module.cluster.cluster_id]
  triggers = {
    always = timestamp()
  }
  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --region ${local.env[terraform.workspace]["region"]} --name ${module.cluster.cluster_name} --alias ${module.cluster.cluster_name}-${local.env[terraform.workspace]["region"]}"
  }
}

