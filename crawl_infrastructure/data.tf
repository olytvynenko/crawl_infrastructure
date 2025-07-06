###############################################################################
# Local values for cluster configuration
###############################################################################

# Data sources to ensure fresh cluster information
data "aws_eks_cluster" "cluster" {
  count = module.cluster.cluster_endpoint != "" ? 1 : 0
  name  = local.env[terraform.workspace]["cluster_name"]
  
  depends_on = [module.cluster]
}

data "aws_eks_cluster_auth" "cluster" {
  count = module.cluster.cluster_endpoint != "" ? 1 : 0
  name  = local.env[terraform.workspace]["cluster_name"]
  
  depends_on = [module.cluster]
}

locals {
  # Use data source if available, otherwise fall back to module outputs
  cluster_endpoint = try(data.aws_eks_cluster.cluster[0].endpoint, module.cluster.cluster_endpoint)
  
  cluster_ca_certificate = try(data.aws_eks_cluster.cluster[0].certificate_authority[0].data, module.cluster.cluster_certificate_authority_data)
  
  # Always use the configured cluster name
  cluster_name = local.env[terraform.workspace]["cluster_name"]
}