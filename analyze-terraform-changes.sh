#!/bin/bash

# Script to analyze Terraform changes without AWS credentials

echo "=== Terraform Changes Analysis ==="
echo ""
echo "This script analyzes what changes were made to the Terraform configuration"
echo "without requiring AWS credentials."
echo ""

# Navigate to pipeline directory
cd pipeline

echo "1. IAM Policy Changes:"
echo "----------------------"
echo "✅ Created new file: iam_policies.tf"
echo "   - Defines CodeBuildClusterManagerPolicy (least-privilege for cluster management)"
echo "   - Defines CodeBuildCrawlerRunnerPolicy (least-privilege for running crawlers)"
echo ""

echo "2. Modified Files:"
echo "-----------------"
echo "✅ pipeline/cluster_manager.tf"
echo "   - Changed: aws_iam_role_policy_attachment from AdministratorAccess"
echo "   - To: Custom policy aws_iam_policy.codebuild_cluster_manager.arn"
echo ""

echo "✅ pipeline/modules/crawler-ci/main.tf"
echo "   - Changed: aws_iam_role_policy_attachment from AdministratorAccess"
echo "   - To: Variable policy var.crawler_runner_policy_arn"
echo ""

echo "✅ pipeline/modules/crawler-ci/variables.tf"
echo "   - Added: New variable 'crawler_runner_policy_arn'"
echo ""

echo "✅ pipeline/kube_jobs.tf"
echo "   - Added: crawler_runner_policy_arn parameter to module call"
echo ""

echo "3. Resources that will be created:"
echo "---------------------------------"
echo "🆕 aws_iam_policy.codebuild_cluster_manager"
echo "   - Permissions for: SSM, S3, DynamoDB, EKS, VPC, IAM, etc."
echo "   - Scoped to specific resources where possible"
echo ""

echo "🆕 aws_iam_policy.codebuild_crawler_runner"
echo "   - Permissions for: EKS describe, SSM, S3 (crawler buckets), ECR"
echo "   - Much more restricted than cluster manager"
echo ""

echo "4. Resources that will be modified:"
echo "----------------------------------"
echo "🔄 aws_iam_role_policy_attachment.cb_cluster_manager (was cb_admin)"
echo "   - Detach: AdministratorAccess"
echo "   - Attach: CodeBuildClusterManagerPolicy"
echo ""

echo "🔄 aws_iam_role_policy_attachment.cb_crawler_runner (was cb_admin)"
echo "   - Detach: AdministratorAccess"
echo "   - Attach: CodeBuildCrawlerRunnerPolicy"
echo ""

echo "5. Security Improvements:"
echo "------------------------"
echo "✅ Removed overly permissive AdministratorAccess"
echo "✅ Implemented least-privilege access"
echo "✅ Scoped permissions to specific resources"
echo "✅ Separated concerns (cluster management vs crawler execution)"
echo ""

echo "6. Testing Recommendations:"
echo "--------------------------"
echo "1. First run 'terraform plan' to verify changes"
echo "2. Apply to a test environment first"
echo "3. Monitor CloudTrail for any permission denied errors"
echo "4. Adjust policies if needed based on actual usage"
echo ""

echo "To configure AWS credentials and run Terraform:"
echo "----------------------------------------------"
echo "1. Configure AWS: aws configure"
echo "2. Plan changes: cd pipeline && terraform plan"
echo "3. Apply changes: cd pipeline && terraform apply"
echo ""
echo "Or use CodeBuild: ./run-terraform-pipeline.sh plan nv"