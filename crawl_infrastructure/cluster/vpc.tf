module "vpc" {

  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = var.vpc_name

  map_public_ip_on_launch = true

  cidr = "172.31.0.0/16"

  azs = length(var.azs) != 0 ? var.azs : data.aws_availability_zones.available.names

  #  intra_subnets = []
  #  public_subnets = ["172.31.0.0/20", "172.31.16.0/20", "172.31.32.0/20", "172.31.48.0/20", "172.31.64.0/20", "172.31.80.0/20", "172.31.96.0/20", "172.31.112.0/20"]
  public_subnets = ["172.31.0.0/20", "172.31.16.0/20", "172.31.32.0/20", "172.31.48.0/20"]

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = 1
    "karpenter.sh/discovery"                      = local.cluster_name
  }

}