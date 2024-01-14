# Filter out local zones, which are not currently supported
# with managed node groups
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  #  cluster_name = "${var.cluster_name}-${random_string.suffix.result}"
  cluster_name = var.cluster_name
}

resource "random_string" "suffix" {
  length  = 8
  special = false
}

resource "null_resource" "merge_kubeconfig" {
  count      = module.eks.cluster_name != "" ? 1 : 0
  depends_on = [module.eks.cluster_id]
  triggers = {
    always = timestamp()
  }
  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --region ${var.region} --name ${local.cluster_name} --alias ${local.cluster_name}-${var.region}"
  }
}


