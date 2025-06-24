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
    cluster_name = local.cluster_name
  }

  provisioner "local-exec" {
    when       = destroy
    command    = <<-EOT
      set -e

      echo "Starting comprehensive VPC cleanup for ${self.triggers.vpc_id}"

      # 1. Clean up Kubernetes-managed Load Balancers first
      echo "=== Cleaning up Kubernetes Load Balancers ==="

      # Delete ALBs tagged with the cluster
      for arn in $(aws elbv2 describe-load-balancers --region ${self.triggers.region} --query "LoadBalancers[?VpcId=='${self.triggers.vpc_id}'].LoadBalancerArn" --output text 2>/dev/null || echo ""); do
        if [ ! -z "$arn" ]; then
          echo "Deleting ALB: $arn"
          aws elbv2 delete-load-balancer --region ${self.triggers.region} --load-balancer-arn $arn || true
        fi
      done

      # Delete Classic ELBs
      for name in $(aws elb describe-load-balancers --region ${self.triggers.region} --query "LoadBalancerDescriptions[?VpcId=='${self.triggers.vpc_id}'].LoadBalancerName" --output text 2>/dev/null || echo ""); do
        if [ ! -z "$name" ]; then
          echo "Deleting ELB: $name"
          aws elb delete-load-balancer --region ${self.triggers.region} --load-balancer-name $name || true
        fi
      done

      # Wait for Load Balancers to be deleted
      echo "Waiting 45 seconds for Load Balancers to be deleted..."
      sleep 45

      # 2. Release ALL Elastic IPs in the VPC
      echo "=== Releasing Elastic IPs ==="
      for allocation_id in $(aws ec2 describe-addresses --region ${self.triggers.region} --filters "Name=domain,Values=vpc" --query "Addresses[].AllocationId" --output text 2>/dev/null || echo ""); do
        if [ ! -z "$allocation_id" ] && [ "$allocation_id" != "None" ]; then
          echo "Disassociating EIP: $allocation_id"
          aws ec2 disassociate-address --region ${self.triggers.region} --allocation-id $allocation_id 2>/dev/null || true
          echo "Releasing EIP: $allocation_id"
          aws ec2 release-address --region ${self.triggers.region} --allocation-id $allocation_id 2>/dev/null || true
        fi
      done

      # 3. Delete NAT Gateways
      echo "=== Deleting NAT Gateways ==="
      for nat_id in $(aws ec2 describe-nat-gateways --region ${self.triggers.region} --filter "Name=vpc-id,Values=${self.triggers.vpc_id}" --filter "Name=state,Values=available" --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null || echo ""); do
        if [ ! -z "$nat_id" ] && [ "$nat_id" != "None" ]; then
          echo "Deleting NAT Gateway: $nat_id"
          aws ec2 delete-nat-gateway --region ${self.triggers.region} --nat-gateway-id $nat_id || true
        fi
      done

      # 4. Force delete ALL Network Interfaces in the VPC
      echo "=== Deleting Network Interfaces ==="
      for eni_id in $(aws ec2 describe-network-interfaces --region ${self.triggers.region} --filters "Name=vpc-id,Values=${self.triggers.vpc_id}" --query 'NetworkInterfaces[?Status==`available`].NetworkInterfaceId' --output text 2>/dev/null || echo ""); do
        if [ ! -z "$eni_id" ] && [ "$eni_id" != "None" ]; then
          echo "Deleting ENI: $eni_id"
          aws ec2 delete-network-interface --region ${self.triggers.region} --network-interface-id $eni_id 2>/dev/null || true
        fi
      done

      # 5. Delete VPC Endpoints that might be blocking
      echo "=== Deleting VPC Endpoints ==="
      for endpoint_id in $(aws ec2 describe-vpc-endpoints --region ${self.triggers.region} --filters "Name=vpc-id,Values=${self.triggers.vpc_id}" --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null || echo ""); do
        if [ ! -z "$endpoint_id" ] && [ "$endpoint_id" != "None" ]; then
          echo "Deleting VPC Endpoint: $endpoint_id"
          aws ec2 delete-vpc-endpoint --region ${self.triggers.region} --vpc-endpoint-id $endpoint_id 2>/dev/null || true
        fi
      done

      # 6. Delete Security Group Rules that might cause dependencies
      echo "=== Cleaning Security Group Rules ==="
      for sg_id in $(aws ec2 describe-security-groups --region ${self.triggers.region} --filters "Name=vpc-id,Values=${self.triggers.vpc_id}" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null || echo ""); do
        if [ ! -z "$sg_id" ] && [ "$sg_id" != "None" ]; then
          echo "Removing rules from Security Group: $sg_id"
          # Remove all ingress rules
          aws ec2 describe-security-groups --region ${self.triggers.region} --group-ids $sg_id --query 'SecurityGroups[0].IpPermissions' --output json | jq -r '.[] | @base64' | while read rule; do
            echo $rule | base64 -d | jq -c . | while read decoded_rule; do
              aws ec2 revoke-security-group-ingress --region ${self.triggers.region} --group-id $sg_id --ip-permissions "$decoded_rule" 2>/dev/null || true
            done
          done
          # Remove all egress rules
          aws ec2 describe-security-groups --region ${self.triggers.region} --group-ids $sg_id --query 'SecurityGroups[0].IpPermissionsEgress' --output json | jq -r '.[] | @base64' | while read rule; do
            echo $rule | base64 -d | jq -c . | while read decoded_rule; do
              aws ec2 revoke-security-group-egress --region ${self.triggers.region} --group-id $sg_id --ip-permissions "$decoded_rule" 2>/dev/null || true
            done
          done
        fi
      done

      # Wait for everything to be cleaned up
      echo "=== Final wait for resource cleanup ==="
      sleep 60

      # 7. Force detach Internet Gateway
      echo "=== Detaching Internet Gateway ==="
      aws ec2 detach-internet-gateway --region ${self.triggers.region} --internet-gateway-id ${self.triggers.igw_id} --vpc-id ${self.triggers.vpc_id} 2>/dev/null || true

      echo "=== VPC cleanup completed successfully ==="
    EOT
    on_failure = continue
  }
}

# Make sure VPC endpoints depend on the cleanup resource
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

  depends_on = [null_resource.cleanup_vpc_dependencies]
}

resource "aws_vpc_endpoint" "ecr" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.ecr.dkr"
  vpc_endpoint_type = "Interface"

  depends_on = [null_resource.cleanup_vpc_dependencies]
}