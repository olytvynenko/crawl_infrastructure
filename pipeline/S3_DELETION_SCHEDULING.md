# S3 Deletion Scheduling

This document describes the S3 deletion scheduling feature added to the crawl infrastructure pipeline.

## Overview

After cluster destruction, the pipeline can automatically schedule the deletion of specified S3 folders. This feature helps clean up temporary data and results after a configurable delay period.

**Important**: All paths are relative to `s3://{bucket}/{dataset}/` where:
- `{bucket}` is retrieved from the `/s3/bucket` SSM parameter
- `{dataset}` is retrieved from the `/crawl/dataset/current` SSM parameter

## How It Works

1. **Scheduling Stage**: After `ClusterDestroy` completes, a new stage `ScheduleS3Deletion`:
   - Creates EventBridge rules to schedule deletions
   - Sends an immediate email notification listing all folders scheduled for deletion
   - Includes deletion time and verification time in the notification

2. **Deletion Execution**: When the scheduled time arrives, the `delete-s3-folders` Lambda:
   - Deletes all objects in the specified folders
   - Sends a notification about the deletion results
   - Updates the check rule with deletion results

3. **Deletion Verification**: After the check delay, the `check-s3-deletions` Lambda:
   - Verifies that the folders no longer exist
   - Sends a notification if any folders still contain objects
   - Cleans up the EventBridge rules

## Notifications

The system sends three types of notifications:

1. **Scheduling Notification** (immediate):
   - Lists all folders scheduled for deletion
   - Shows when deletion will occur
   - Shows when verification will occur

2. **Deletion Notification** (after deletion delay):
   - Confirms which folders were deleted
   - Reports any errors encountered

3. **Verification Notification** (after check delay):
   - Confirms if all folders were successfully deleted
   - Lists any folders that still exist

## Configuration

### Step Functions Input

Add the following to your Step Functions input:

```json
{
  "stages": {
    "schedule_s3_deletion": true  // Enable S3 deletion scheduling
  },
  "s3_deletion_config": {
    "folders": [
      "update/results/crawl-",      // Relative to s3://{bucket}/{dataset}/
      "temp/processing/",           // Will delete s3://{bucket}/{dataset}/temp/processing/
      "scratch/"                    // Will delete s3://{bucket}/{dataset}/scratch/
    ],
    "deletion_delay_seconds": 259200,  // Seconds to wait before deletion (72 hours)
    "check_delay_seconds": 28800       // Seconds to wait after deletion before checking (8 hours)
  }
}
```

### Terraform Variables

Configure default behavior in your `.tfvars` file:

```hcl
# List of S3 folders to delete after cluster destruction
# Paths are relative to s3://{bucket}/{dataset}/
s3_folders_to_delete = [
  "update/results/crawl-",      # Deletes s3://{bucket}/{dataset}/update/results/crawl-*
  "temp/processing/",           # Deletes s3://{bucket}/{dataset}/temp/processing/
  "scratch/"                    # Deletes s3://{bucket}/{dataset}/scratch/
]

# Delay before deletion in seconds (default: 259200 = 72 hours)
s3_deletion_delay_seconds = 259200

# Delay before checking if deletion was successful in seconds (default: 28800 = 8 hours)
s3_deletion_check_delay_seconds = 28800
```

## Notifications

The system sends email notifications for:

1. **Scheduling Success/Failure**: When S3 deletions are scheduled
2. **Deletion Results**: After deletion execution (success/failure details)
3. **Verification Results**: If any folders still exist after deletion

All notifications are sent to the admin email configured in `/email/admin` SSM parameter.

## Lambda Functions

### schedule-s3-deletion
- Fetches bucket and dataset from SSM parameters
- Transforms relative paths to absolute S3 paths
- Creates EventBridge rules for scheduled deletion and verification
- Configurable delays in seconds via environment variables or input parameters

### delete-s3-folders
- Performs the actual S3 object deletions
- Handles large folders with pagination
- Reports deletion statistics

### check-s3-deletions
- Verifies folders were successfully deleted
- Supports both specific folder checking and legacy age-based checking
- Cleans up EventBridge rules after execution

## Security

- Lambda functions have least-privilege IAM policies
- S3 delete permissions are granted only to the deletion executor Lambda
- EventBridge rules are automatically cleaned up after execution

## Monitoring

- All Lambda executions are logged to CloudWatch
- Failed deletions trigger email notifications
- EventBridge rules are visible in the AWS Console for tracking scheduled executions

## Example Use Case

After running a crawl that generates temporary data:

1. Configure the folders to delete in your Step Functions input using relative paths
2. The Lambda fetches the current bucket and dataset from SSM parameters
3. The pipeline schedules deletion for 259200 seconds (72 hours) later
4. You receive notification when deletion is scheduled
5. After 259200 seconds (72 hours), folders are deleted and you're notified
6. After 28800 more seconds (8 hours), the system verifies deletion and notifies you of any issues

### Path Resolution Example

If SSM parameters contain:
- `/s3/bucket` = "linxact"
- `/crawl/dataset/current` = "links/delta/dataset-2409"

And you specify folder: `"update/results/crawl-"`

The system will delete: `s3://linxact/links/delta/dataset-2409/update/results/crawl-*`