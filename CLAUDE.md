# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repository manages Kubernetes cluster infrastructure for distributed web crawling operations across multiple AWS regions using Terraform and AWS EKS.

## Key Commands

### Local Development
```bash
# Initialize Terraform
terraform -chdir=crawl_infrastructure init

# Plan changes for a specific cluster
terraform -chdir=crawl_infrastructure workspace select nv
terraform -chdir=crawl_infrastructure plan

# Apply changes locally (use with caution)
terraform -chdir=crawl_infrastructure apply
```

### Production Deployment via CodeBuild
```bash
# Create clusters
aws codebuild start-build --project-name cluster-manager \
  --environment-variables-override name=ACTION,value=create name=CLUSTERS,value=nv

# Destroy clusters
aws codebuild start-build --project-name cluster-manager \
  --environment-variables-override name=ACTION,value=destroy name=CLUSTERS,value=nv

# Resize clusters (requires LEVEL: inst4, inst8, or inst16)
aws codebuild start-build --project-name cluster-manager \
  --environment-variables-override name=ACTION,value=resize name=CLUSTERS,value=nv name=LEVEL,value=inst8

# Plan changes
aws codebuild start-build --project-name cluster-manager \
  --environment-variables-override name=ACTION,value=plan name=CLUSTERS,value=nv
```

## Architecture Overview

### Repository Structure
- **`cluster_manager.py`** - Main orchestrator that runs Terraform commands across workspaces
- **`crawl_infrastructure/`** - Terraform configurations:
  - `cluster/` - EKS cluster setup with VPC and managed node groups
  - `karpenter/` - Karpenter autoscaler configurations (YAML templates)
  - `provisioners/` - Kubernetes resource provisioners
  - `terraform.tfvars.json` - Cluster configurations (nv, nc, ohio, oregon)
- **`pipeline/`** - AWS infrastructure for data processing:
  - `lambdas/` - Resource termination and S3 deletion monitoring
  - `spark/` - Delta Lake operations and sitemap processing
  - Terraform modules for Glue jobs and CI/CD

### Key Design Patterns

1. **Workspace-Based Multi-Cluster Management**: Each cluster (nv, nc, ohio, oregon) runs in a separate Terraform workspace, allowing independent lifecycle management.

2. **Instance Sizing Tiers**: Three predefined instance levels:
   - `inst4`: Small instances (t4g.medium, m6g.medium)
   - `inst8`: Medium instances (r7g.medium, r6g.medium)  
   - `inst16`: Large instances (r7g.large)

3. **Karpenter Autoscaling**: Dynamic node provisioning using ARM64-based instances (r7g, r6g, m7g series) with automatic scaling based on workload demands.

4. **Two-Phase Destroy**: When destroying clusters, Karpenter resources are removed first to handle finalizers, followed by complete infrastructure teardown.

5. **Configuration Hierarchy**:
   - Environment variables (ACTION, LEVEL, CLUSTERS)
   - AWS Parameter Store (`/crawl/clusters` for cluster list)
   - Local `terraform.tfvars.json` for detailed configurations

### AWS Resources Created

Each cluster deployment creates:
- EKS cluster with managed node groups
- VPC with public/private subnets across availability zones
- Karpenter for dynamic node provisioning
- IAM roles and policies for service accounts
- Security groups and network interfaces
- S3 buckets and DynamoDB tables for state management

### Important Notes

- All infrastructure uses ARM64 architecture for cost optimization
- Clusters are designed for batch web crawling workloads
- Resource cleanup includes orphaned ENI deletion after cluster destruction
- The system integrates with AWS Glue for data processing pipelines