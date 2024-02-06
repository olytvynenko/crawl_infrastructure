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




