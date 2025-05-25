module "vpc" {

  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = var.vpc_name

  map_public_ip_on_launch = true

  cidr = "172.31.0.0/16"

  azs = length(var.azs) != 0 ? var.azs : data.aws_availability_zones.available.names

  #  intra_subnets = []
  public_subnets = ["172.31.0.0/20", "172.31.16.0/20", "172.31.32.0/20", "172.31.48.0/20"]
  #   public_subnets = ["172.31.0.0/20", "172.31.16.0/20"]

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = 1
    "karpenter.sh/discovery"                      = local.cluster_name
  }

}

# Clean up resources before destroying VPC to avoid DependencyViolation errors
resource "null_resource" "release_eips" {
  # Always run on destroy; capture VPC ID for use in the command
  triggers = {
    always = timestamp()
    vpc_id = module.vpc.vpc_id
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<EOT
for alloc in $(aws ec2 describe-addresses \
    --filters "Name=domain,Values=vpc" "Name=vpc-id,Values=${self.triggers.vpc_id}" \
    --query 'Addresses[*].AllocationId' --output text); do
  aws ec2 release-address --allocation-id $alloc
done
EOT
  }
}

resource "null_resource" "detach_igw" {
  depends_on = [null_resource.release_eips]

  # Capture IGW and VPC IDs for destroy-time provisioner
  triggers = {
    always = timestamp()
    vpc_id = module.vpc.vpc_id
    igw_id = module.vpc.igw_id
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<EOT
aws ec2 detach-internet-gateway \
    --internet-gateway-id ${self.triggers.igw_id} \
    --vpc-id ${self.triggers.vpc_id}
EOT
  }
}

resource "null_resource" "delete_enis" {
  depends_on = [null_resource.detach_igw]

  # Capture VPC ID
  triggers = {
    always = timestamp()
    vpc_id = module.vpc.vpc_id
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<EOT
for eni in $(aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=${self.triggers.vpc_id}" \
    --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text); do
  aws ec2 delete-network-interface --network-interface-id $eni
done
EOT
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.public_route_table_ids
  policy            = <<POLICY
{
  "Version": "2008-10-17",
  "Statement": [
    {
      "Action": "*",
      "Effect": "Allow",
      "Resource": "*",
      "Principal": "*"
    }
  ]
}
POLICY
}

resource "aws_vpc_endpoint" "ecr" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.ecr.dkr"
  vpc_endpoint_type = "Interface"
}