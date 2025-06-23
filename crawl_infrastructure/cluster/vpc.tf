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

# Enhanced cleanup to handle all AWS resources that block IGW detachment
resource "null_resource" "cleanup_vpc_dependencies" {
  triggers = {
    always = timestamp()
    vpc_id = module.vpc.vpc_id
    igw_id = module.vpc.igw_id
    region = var.region
  }

  provisioner "local-exec" {
    when       = destroy
    command    = <<-EOT
      # Release all Elastic IPs in the VPC
      for allocation_id in $(aws ec2 describe-addresses --region ${self.triggers.region} --filters "Name=domain,Values=vpc" --query 'Addresses[?NetworkInterfaceId!=null].AllocationId' --output text); do
        echo "Releasing EIP: $allocation_id"
        aws ec2 release-address --region ${self.triggers.region} --allocation-id $allocation_id || true
      done

      # Delete NAT Gateways (if any)
      for nat_id in $(aws ec2 describe-nat-gateways --region ${self.triggers.region} --filter "Name=vpc-id,Values=${self.triggers.vpc_id}" --query 'NatGateways[?State==`available`].NatGatewayId' --output text); do
        echo "Deleting NAT Gateway: $nat_id"
        aws ec2 delete-nat-gateway --region ${self.triggers.region} --nat-gateway-id $nat_id || true
      done

      # Wait a bit for NAT gateways to be deleted
      sleep 30

      # Now detach the IGW
      echo "Detaching IGW: ${self.triggers.igw_id} from VPC: ${self.triggers.vpc_id}"
      aws ec2 detach-internet-gateway --region ${self.triggers.region} --internet-gateway-id ${self.triggers.igw_id} --vpc-id ${self.triggers.vpc_id} || true
    EOT
    on_failure = continue
  }
}


# Clean up resources before destroying VPC to avoid DependencyViolation errors
# resource "null_resource" "detach_igw" {
#
#   triggers = {
#     always = timestamp()
#     vpc_id = module.vpc.vpc_id
#     igw_id = module.vpc.igw_id
#   }
#
#   provisioner "local-exec" {
#     when        = destroy
#     command     = "aws ec2 detach-internet-gateway --internet-gateway-id ${self.triggers.igw_id} --vpc-id ${self.triggers.vpc_id}"
#     on_failure  = continue
#   }
# }


# resource "null_resource" "delete_enis" {
#   triggers = {
#     always = timestamp()
#     vpc_id = module.vpc.vpc_id
#     igw_id = module.vpc.igw_id
#   }
#
#   provisioner "local-exec" {
#     when    = destroy
#     command = "for eip in $(aws ec2 describe-addresses --filters Name=domain,Values=vpc --query 'Addresses[].AllocationId' --output text); do aws ec2 disassociate-address --allocation-id $eip 2>/dev/null; aws ec2 release-address --allocation-id $eip 2>/dev/null; done; aws ec2 detach-internet-gateway --internet-gateway-id ${self.triggers.igw_id} --vpc-id ${self.triggers.vpc_id}"
#     on_failure = continue
#   }
# }


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