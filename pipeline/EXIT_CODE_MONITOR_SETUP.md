# Exit Code Monitor Setup

The Exit Code Monitor is now integrated into the main pipeline Terraform configuration.

## Infrastructure Components

### 1. ECR Repository
- Created by: `exit_code_monitor.tf`
- Name: `exit-code-monitor`
- Includes lifecycle rules to keep only the last 5 images

### 2. CodeBuild Project
- Created by: `exit_code_monitor.tf`
- Name: `exit-code-monitor-build`
- Source: Uses the existing `kube_jobs` CodeCommit repository
- Builds from: `/pipeline/kube-jobs/exit_code_monitor/`

### 3. IAM Permissions
- Role: `codebuild-exit-code-monitor`
- Includes permissions for:
  - ECR push/pull
  - CodeCommit access
  - CloudWatch Logs

## Setup Steps

### 1. Apply Terraform Changes

```bash
cd pipeline
terraform plan
terraform apply
```

This will create:
- ECR repository for the Docker image
- CodeBuild project for building the image
- IAM roles and policies

### 2. Build the Docker Image

Option A: Using the provided script
```bash
./scripts/build_exit_code_monitor.sh --wait
```

Option B: Using AWS CLI directly
```bash
aws codebuild start-build --project-name exit-code-monitor-build
```

Option C: Using AWS Console
- Go to CodeBuild
- Find project "exit-code-monitor-build"
- Click "Start build"

### 3. Deploy to Kubernetes Clusters

After the image is built, deploy to each cluster:

```bash
# For each cluster (nv, nc, ohio, oregon)
kubectl config use-context linxact-nv-us-east-1
kubectl apply -f pipeline/kube-jobs/exit_code_monitor/deployment.yaml

# Verify deployment
kubectl get pods -l app=exit-code-monitor
kubectl logs -l app=exit-code-monitor -f
```

## Monitoring

### Check Build Status
```bash
aws codebuild batch-get-builds --ids <build-id> \
  --query 'builds[0].buildStatus'
```

### Check ECR Image
```bash
aws ecr describe-images --repository-name exit-code-monitor \
  --query 'imageDetails[*].[imageTags,imagePushedAt]' \
  --output table
```

### Check Kubernetes Deployment
```bash
kubectl get deployment exit-code-monitor
kubectl logs -l app=exit-code-monitor --tail=50
```

## Updating the Monitor

When you make changes to the exit code monitor:

1. Commit changes to CodeCommit:
```bash
git add pipeline/kube-jobs/exit_code_monitor/
git commit -m "Update exit code monitor"
git push
```

2. Trigger a new build:
```bash
./scripts/build_exit_code_monitor.sh --wait
```

3. Update deployments in each cluster:
```bash
kubectl rollout restart deployment exit-code-monitor
```

## Troubleshooting

### Build Fails
Check CodeBuild logs:
```bash
aws codebuild batch-get-builds --ids <build-id> \
  --query 'builds[0].logs.deepLink' --output text
```

### Image Not Found
Verify ECR repository exists:
```bash
aws ecr describe-repositories --repository-names exit-code-monitor
```

### Pod Not Starting
Check pod events:
```bash
kubectl describe pod -l app=exit-code-monitor
```

## Integration with Pipeline

The exit code monitor is included in the pipeline's CodeBuild project ARNs list in `main.tf`, which means:
- It inherits the same S3 artifact bucket
- It's included in IAM policies for pipeline operations
- It can be triggered as part of the pipeline workflow if needed