###############################################################################
# Local values for cluster configuration
###############################################################################
locals {
  # Always use module outputs - they will be populated after cluster creation
  cluster_endpoint = module.cluster.cluster_endpoint
  
  cluster_ca_certificate = module.cluster.cluster_certificate_authority_data
  
  # Always use the configured cluster name
  cluster_name = local.env[terraform.workspace]["cluster_name"]
}