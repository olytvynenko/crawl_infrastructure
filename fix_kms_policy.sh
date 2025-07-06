#!/bin/bash
#
# Fix for KMS policy circular dependency issue
# Run this if you see: "Error: Reference to undeclared module" for module.karpenter
#

echo "Fixing KMS policy circular dependency..."

# Check if we're in the right directory
if [ ! -f "crawl_infrastructure/cluster/kms.tf" ]; then
    echo "Error: Must run from crawl-infrastructure root directory"
    exit 1
fi

# Create backup
cp crawl_infrastructure/cluster/kms.tf crawl_infrastructure/cluster/kms.tf.backup

# Fix the policy
sed -i.bak 's/module.karpenter.node_instance_profile_arn/"ec2.amazonaws.com"/g' crawl_infrastructure/cluster/kms.tf
sed -i.bak 's/AWS = "ec2.amazonaws.com"/Service = "ec2.amazonaws.com"/g' crawl_infrastructure/cluster/kms.tf
sed -i.bak 's/Allow Karpenter nodes to use the key/Allow EC2 instances to use the key/g' crawl_infrastructure/cluster/kms.tf

echo "KMS policy fixed!"
echo ""
echo "Changes made:"
echo "- Removed reference to module.karpenter.node_instance_profile_arn"
echo "- Changed to use EC2 service principal"
echo "- This allows all EC2 instances (including Karpenter nodes) to use the KMS key"
echo ""
echo "Now commit the changes:"
echo "git add crawl_infrastructure/cluster/kms.tf"
echo "git commit -m 'Fix KMS policy circular dependency'"