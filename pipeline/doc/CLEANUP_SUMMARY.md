# Terraform Variables Cleanup Summary

This document summarizes the unused Terraform variables that were removed from the pipeline configuration.

## Removed Variables

### 1. EC2 Tag Variables
- **`ec2_tag_key`** (default: "AutoDelete")
- **`ec2_tag_value`** (default: "true")
- **Reason**: These variables were declared but never referenced in any Terraform configuration.

### 2. S3 Deletion Variables
- **`s3_folders_to_delete`** (default: [])
- **Reason**: The Step Functions state machine receives S3 deletion configuration through execution input JSON, not Terraform variables.

### 3. Default Data Paths Configuration
- **`default_data_paths_config`** (object with seed_path_prefix and results_path_prefix)
- **Reason**: Never used. The state machine expects paths in the execution input.

### 4. Sitemap Seed Generator Project
- **`sitemap_seed_generator_project`** (default: "sitemap-seed-generator")
- **Reason**: Never referenced in any Terraform configuration.

### 5. Direct Path Variables
- **`seed_base`** (default: "update/seed/")
- **`results_base`** (default: "update/results/")
- **Reason**: These were replaced by computed local values that derive paths from `data_path_prefix`.

## Files Modified

1. **`pipeline/variables.tf`**
   - Removed all unused variable declarations
   - Kept only actively used variables

2. **`pipeline/terraform.tfvars.json`**
   - Removed `s3_folders_to_delete` entry
   - Kept only used configuration values

## Variables Retained

The following variables are actively used and were kept:
- `data_path_prefix` - Used to construct dynamic paths
- `s3_deletion_delay_seconds` - Used in Lambda environment variables
- `s3_deletion_check_delay_seconds` - Used in Lambda environment variables
- All other variables that are referenced in the Terraform configuration

## Impact

No functional impact. The cleanup only removes unused declarations, making the codebase cleaner and easier to maintain.