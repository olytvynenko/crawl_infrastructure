# Exit Code Monitor Integration Guide

This guide explains how to integrate the exit code monitor build and deployment into the existing Step Functions state machine.

## Overview

The integration adds two new stages:
1. **ExitCodeMonitorBuild** - Builds the Docker image (after CrawlerArmBuild)
2. **DeployExitCodeMonitor** - Deploys to clusters (after ClusterCreate)

## Architecture

```
┌─────────────────────┐
│  CrawlerArmBuild    │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ ExitCodeMonitorBuild│ ← NEW: Build monitor image
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   ClusterCreate     │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│DeployExitCodeMonitor│ ← NEW: Deploy to clusters
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   CrawlerRunner     │
└─────────────────────┘
```

## Implementation Steps

### 1. Build Lambda Deployment Package

```bash
cd pipeline/lambdas/deploy_exit_code_monitor
./build.sh
```

### 2. Apply Terraform Changes

```bash
cd pipeline

# Review changes
terraform plan

# Apply
terraform apply
```

This creates:
- CodeBuild project: `exit-code-monitor-build`
- Lambda function: `deploy-exit-code-monitor`
- IAM roles and policies

### 3. Modify main.tf

Add the following changes to `main.tf`:

#### A. Update cb_project_arns

```hcl
locals {
  cb_project_arns = [
    "arn:aws:codebuild:us-east-1:${data.aws_caller_identity.this.account_id}:project/${var.cluster_manager_project}",
    "arn:aws:codebuild:us-east-1:${data.aws_caller_identity.this.account_id}:project/${var.crawler_arm_build_project}",
    "arn:aws:codebuild:us-east-1:${data.aws_caller_identity.this.account_id}:project/${var.crawler_runner_project}",
    "arn:aws:codebuild:us-east-1:${data.aws_caller_identity.this.account_id}:project/${var.exit_code_monitor_build_project}",  # ADD THIS
  ]
```

#### B. Add Lambda Invoke Permission to Step Function Role

In the Step Functions execution role policy, add:

```hcl
{
  Effect = "Allow",
  Action = ["lambda:InvokeFunction"],
  Resource = aws_lambda_function.deploy_exit_code_monitor.arn
}
```

#### C. Add New States to State Machine

1. Change `CrawlerArmBuild` Next:
```hcl
CrawlerArmBuild = {
  # ... existing config ...
  Next = "CheckExitCodeMonitorBuild"  # Changed from "CheckClusterCreate"
}
```

2. Add new states after `CrawlerArmBuild`:
```hcl
CheckExitCodeMonitorBuild = {
  Type = "Choice",
  Choices = [
    {
      Variable      = "$.stages.exit_code_monitor_build",
      BooleanEquals = false,
      Next          = "CheckClusterCreate"
    }
  ],
  Default = "ExitCodeMonitorBuild"
},

ExitCodeMonitorBuild = {
  Type     = "Task",
  Resource = "arn:aws:states:::codebuild:startBuild.sync",
  Parameters = {
    ProjectName = var.exit_code_monitor_build_project
  },
  ResultPath = "$.exit_code_monitor_build_result",
  Retry = [
    {
      ErrorEquals = ["States.TaskFailed"],
      IntervalSeconds = 30,
      MaxAttempts     = 2,
      BackoffRate     = 2.0
    }
  ],
  Catch = [
    {
      ErrorEquals = ["States.ALL"],
      ResultPath = "$.exit_code_monitor_build_error",
      Next = "CheckClusterCreate"
    }
  ],
  Next = "CheckClusterCreate"
},
```

3. Change `NotifyClusterCreateSuccess` Next:
```hcl
NotifyClusterCreateSuccess = {
  # ... existing config ...
  Next = "DeployExitCodeMonitor"  # Changed from "CheckCrawlerBuild"
}
```

4. Add deployment state:
```hcl
DeployExitCodeMonitor = {
  Type = "Task",
  Resource = aws_lambda_function.deploy_exit_code_monitor.arn,
  Parameters = {
    clusters = ["nv", "nc", "ohio", "oregon"]
  },
  ResultPath = "$.exit_code_monitor_deploy_result",
  Retry = [
    {
      ErrorEquals = ["States.TaskFailed"],
      IntervalSeconds = 30,
      MaxAttempts     = 2,
      BackoffRate     = 2.0
    }
  ],
  Catch = [
    {
      ErrorEquals = ["States.ALL"],
      ResultPath = "$.exit_code_monitor_deploy_error",
      Next = "CheckCrawlerBuild"
    }
  ],
  Next = "CheckCrawlerBuild"
},
```

## Usage

### Default Execution (includes monitor)

```json
{
  "stages": {
    "crawler_arm_build": true,
    "exit_code_monitor_build": true,
    "cluster_create": true,
    "crawler_build": true
  }
}
```

### Skip Monitor Build

```json
{
  "stages": {
    "crawler_arm_build": true,
    "exit_code_monitor_build": false,
    "cluster_create": true,
    "crawler_build": true
  }
}
```

## Benefits

1. **Automated**: Monitor deploys automatically with cluster creation
2. **Version Control**: Monitor version tied to crawler ARM build
3. **Failure Resilient**: Pipeline continues even if monitor fails
4. **Configurable**: Can skip monitor build/deploy if needed

## Monitoring

### Check Build Status
```bash
# Get latest build
aws codebuild list-builds-for-project \
  --project-name exit-code-monitor-build \
  --max-items 1

# Check build details
aws codebuild batch-get-builds --ids <build-id>
```

### Check Deployment
```bash
# Check Lambda logs
aws logs tail /aws/lambda/deploy-exit-code-monitor
```

### Verify in Clusters
```bash
kubectl get deployment exit-code-monitor -n default
kubectl logs -l app=exit-code-monitor
```

## Troubleshooting

### Build Fails
- Check CodeBuild logs
- Verify CodeCommit has the exit_code_monitor directory

### Deployment Fails
- Check Lambda function logs
- Verify Lambda has network access to EKS clusters
- Check IAM permissions

### Monitor Not Running
- Verify image was pushed to ECR
- Check Kubernetes events: `kubectl describe deployment exit-code-monitor`