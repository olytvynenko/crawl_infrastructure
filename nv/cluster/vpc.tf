module "vpc" {

  #  count = var.create ? 1 : 0

  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = var.vpc_name

  cidr = "10.0.0.0/16"

  #  azs = slice(data.aws_availability_zones.available.names, 0, min(3, length(data.aws_availability_zones.available.names)))
  azs = length(var.azs) != 0 ? var.azs : data.aws_availability_zones.available.names
  #  azs = data.aws_availability_zones.available.names

  private_subnets = ["10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24", "10.0.4.0/24"]
  public_subnets  = ["10.0.5.0/24", "10.0.6.0/24", "10.0.7.0/24", "10.0.8.0/24", "10.0.9.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = 1
    "karpenter.sh/discovery"                      = local.cluster_name
  }
}