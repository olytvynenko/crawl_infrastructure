# Data Paths Configuration

This document explains how to configure data paths for the crawl pipeline, particularly for testing purposes.

## Overview

The pipeline uses configurable data paths for seed data and results. By default, it uses production paths (`update/seed/` and `update/results/`), but these can be changed for testing.

## Configuration Methods

### Method 1: Terraform Variables (Recommended for Testing)

1. **For Testing**: The `terraform.tfvars.json` file is already configured for test paths:
   ```json
   {
     "data_path_prefix": "test",
     "s3_folders_to_delete": [
       "test/seed/",
       "test/results/"
     ],
     "s3_deletion_delay_seconds": 300,
     "s3_deletion_check_delay_seconds": 420
   }
   ```

2. **For Production**: To switch back to production paths, update `terraform.tfvars.json`:
   ```json
   {
     "data_path_prefix": "update",
     "s3_folders_to_delete": [
       "update/seed/",
       "update/results/"
     ],
     "s3_deletion_delay_seconds": 86400,
     "s3_deletion_check_delay_seconds": 86520
   }
   ```

3. **Apply Changes**:
   ```bash
   terraform apply
   ```

### Method 2: State Machine Execution Input

When starting the State Machine execution, you can configure which S3 folders to delete through the input:

1. **Test Configuration**:
   ```json
   {
     "notifications_enabled": true,
     "stages": {
       "schedule_s3_deletion": true
     },
     "s3_deletion_config": {
       "enabled": true,
       "folders": [
         "test/seed/",
         "test/results/"
       ],
       "deletion_delay_seconds": 300,
       "check_delay_seconds": 420
     }
   }
   ```

2. **Production Configuration**:
   ```json
   {
     "notifications_enabled": true,
     "stages": {
       "schedule_s3_deletion": true
     },
     "s3_deletion_config": {
       "enabled": true,
       "folders": [
         "update/seed/",
         "update/results/"
       ],
       "deletion_delay_seconds": 86400,
       "check_delay_seconds": 86520
     }
   }
   ```

## Path Structure

The paths are constructed as follows:
- **Seed Path**: `{data_path_prefix}/seed/{workflow}/`
- **Results Path**: `{data_path_prefix}/results/{workflow}/`

Where:
- `data_path_prefix` is either "update" (production) or "test" (testing)
- `workflow` is the specific workflow (e.g., "wpapi", "sitemaps", "sm")

## Example Paths

### Production Paths:
- Seed: `update/seed/wpapi/`, `update/seed/sitemaps/`, `update/seed/sm/`
- Results: `update/results/wpapi/`, `update/results/sitemaps/`, `update/results/sm/`

### Test Paths:
- Seed: `test/seed/wpapi/`, `test/seed/sitemaps/`, `test/seed/sm/`
- Results: `test/results/wpapi/`, `test/results/sitemaps/`, `test/results/sm/`

## Starting State Machine with Test Configuration

### Using AWS CLI:
```bash
aws stepfunctions start-execution \
  --state-machine-arn arn:aws:states:us-east-1:ACCOUNT_ID:stateMachine:crawl-pipeline \
  --input file://example_state_machine_inputs.json
```

### Using AWS Console:
1. Go to Step Functions console
2. Select the crawl-pipeline state machine
3. Click "Start execution"
4. Copy the test configuration from `example_state_machine_inputs.json`
5. Paste into the input field and start execution

## Important Notes

1. **S3 Deletion**: The folders specified in `s3_deletion_config.folders` will be scheduled for deletion after cluster destruction.

2. **Timing**: 
   - `deletion_delay_seconds`: Time to wait before deleting (5 minutes for test, 24 hours for production)
   - `check_delay_seconds`: Time to wait before checking deletion status

3. **Safety**: Test paths are configured with shorter delays to allow quick verification of the deletion process.

4. **Terraform Apply Required**: After changing `terraform.tfvars.json`, you must run `terraform apply` to update the infrastructure with the new paths.