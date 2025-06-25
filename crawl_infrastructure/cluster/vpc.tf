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

# Simple cleanup to terminate orphaned EKS instances only
resource "null_resource" "cleanup_orphaned_instances" {
  triggers = {
    always = timestamp()
    region = var.region
    cluster_name = local.cluster_name
  }

  provisioner "local-exec" {
    when       = destroy
    command    = <<-EOT
      set -e

      echo "=== Terminating orphaned EKS instances for cluster: ${self.triggers.cluster_name} ==="

      # Find and terminate managed node group instances
      INSTANCES=$(aws ec2 describe-instances --region ${self.triggers.region} \
        --filters "Name=instance-state-name,Values=running,pending,stopping,stopped" \
                  "Name=tag:kubernetes.io/cluster/${self.triggers.cluster_name},Values=owned,shared" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || echo "")

      if [ ! -z "$INSTANCES" ] && [ "$INSTANCES" != "None" ]; then
        echo "Found EKS managed node instances: $INSTANCES"
        for instance_id in $INSTANCES; do
          echo "Terminating EKS node: $instance_id"
          aws ec2 terminate-instances --region ${self.triggers.region} --instance-ids $instance_id || true
        done
      else
        echo "No EKS managed node instances found"
      fi

      # Find and terminate Karpenter-managed instances
      KARPENTER_INSTANCES=$(aws ec2 describe-instances --region ${self.triggers.region} \
        --filters "Name=instance-state-name,Values=running,pending,stopping,stopped" \
                  "Name=tag:karpenter.sh/discovery,Values=${self.triggers.cluster_name}" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || echo "")

      if [ ! -z "$KARPENTER_INSTANCES" ] && [ "$KARPENTER_INSTANCES" != "None" ]; then
        echo "Found Karpenter instances: $KARPENTER_INSTANCES"
        for instance_id in $KARPENTER_INSTANCES; do
          echo "Terminating Karpenter node: $instance_id"
          aws ec2 terminate-instances --region ${self.triggers.region} --instance-ids $instance_id || true
        done
      else
        echo "No Karpenter instances found"
      fi

      # Wait for termination to complete
      if [ ! -z "$INSTANCES$KARPENTER_INSTANCES" ]; then
        echo "Waiting 60 seconds for instances to terminate..."
        sleep 60
        echo "Instance termination completed"
      fi

      echo "=== Orphaned instance cleanup finished ==="
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

}

resource "aws_vpc_endpoint" "ecr" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.ecr.dkr"
  vpc_endpoint_type = "Interface"
}