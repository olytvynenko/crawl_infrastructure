# Notification Flow Summary

## Email Senders

There are two different email sending mechanisms in the pipeline:

### 1. SES Direct Email (Uses `/email/sender`)
- **Sender**: Configured in `/email/sender` SSM parameter
- **Used by**:
  - `pipeline-stage-notification` Lambda (main notification system)
  - `schedule_s3_deletion` Lambda (for immediate scheduling notification)
  - `pipeline-advance-notification` Lambda
  - `check-resource-termination` Lambda

### 2. SNS Topic Email (Uses AWS Default Sender)
- **Sender**: AWS SNS default (e.g., `no-reply@sns.amazonaws.com`)
- **Topic**: `resources-deletion-missed`
- **Used by**:
  - `check_s3_deletions` Lambda in legacy mode
  - `check-resource-termination` Lambda (legacy, if configured)

## Notification Paths

### S3 Deletion Flow

1. **Scheduling Notification** (Immediate)
   - Lambda: `schedule_s3_deletion`
   - Method: Direct SES call
   - Sender: `/email/sender` ✓

2. **Deletion Complete Notification** (After 5 min)
   - Lambda: `delete_s3_folders` → `pipeline-stage-notification`
   - Method: Invokes stage notification Lambda
   - Sender: `/email/sender` ✓

3. **Deletion Check Notification** (After 7 min)
   - Lambda: `check_s3_deletions` → `pipeline-stage-notification`
   - Method: Invokes stage notification Lambda
   - Sender: `/email/sender` ✓

### EC2 Termination Check
- Lambda: `check-resource-termination`
- Method: Direct SES call
- Sender: `/email/sender` ✓

## Why You Might See Different Senders

If you're seeing emails from different senders, it could be:

1. **SNS Legacy Mode**: The `check_s3_deletions` Lambda has a legacy mode that uses SNS instead of the stage notification Lambda. This would send from AWS's default address.

2. **Old Lambda Versions**: If Lambda functions haven't been redeployed after the sender change.

3. **Cached Values**: The stage notification Lambda caches the sender email for 5 minutes.

## To Ensure Consistent Sender

1. **Redeploy all Lambda functions**:
   ```bash
   terraform apply -target=aws_lambda_function.stage_notification
   terraform apply -target=aws_lambda_function.check_resource_termination
   terraform apply -target=aws_lambda_function.schedule_s3_deletion
   ```

2. **Verify no legacy SNS usage**:
   ```bash
   # Check if legacy mode is being used
   aws logs tail /aws/lambda/check-s3-deletions --since 1h | grep "SNS"
   ```

3. **Check Lambda environment variables**:
   ```bash
   aws lambda get-function-configuration --function-name check-s3-deletions \
     --query 'Environment.Variables'
   ```

## Expected Behavior

All notifications should come from the email address configured in `/email/sender` except:
- SNS topic notifications (if legacy mode is triggered)
- Any old Lambda invocations still in cache