###############################################################################
# Data sources for existing cluster information
###############################################################################

# Fetch cluster info when it exists
data "aws_eks_cluster" "cluster" {
  name = local.env[terraform.workspace]["cluster_name"]
  
  # Only fetch if we're not in default workspace
  count = terraform.workspace != "default" ? 1 : 0
}

# Get auth token for the cluster
data "aws_eks_cluster_auth" "cluster" {
  name = local.env[terraform.workspace]["cluster_name"]
  
  # Only fetch if we're not in default workspace
  count = terraform.workspace != "default" ? 1 : 0
}

###############################################################################
# Local values to handle both existing and new clusters
###############################################################################
locals {
  # Check if we have data source results
  has_cluster_data = length(data.aws_eks_cluster.cluster) > 0
  
  # Try to use data source first, fall back to module output
  cluster_endpoint = local.has_cluster_data ? data.aws_eks_cluster.cluster[0].endpoint : module.cluster.cluster_endpoint
  
  cluster_ca_certificate = local.has_cluster_data ? data.aws_eks_cluster.cluster[0].certificate_authority[0].data : module.cluster.cluster_certificate_authority_data
  
  cluster_auth_token = local.has_cluster_data ? data.aws_eks_cluster_auth.cluster[0].token : ""
  
  # Always use the configured cluster name
  cluster_name = local.env[terraform.workspace]["cluster_name"]
}