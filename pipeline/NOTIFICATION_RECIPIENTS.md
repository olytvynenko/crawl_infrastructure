# Notification Recipients Configuration

## Overview

The pipeline uses two SSM parameters for email configuration:

1. **`/email/admin`** (singular) - The primary administrator email
2. **`/email/admins`** (plural) - Comma-separated list of all administrator emails

## Critical Infrastructure Notifications (Admin Only)

The following notifications are sent **only** to the email address in `/email/admin`:

### 1. EC2 Instance Termination
- **Lambda**: `check_resource_termination`
- **When**: After cluster destruction, if EC2 instances remain
- **Reason**: Critical infrastructure alert requiring immediate attention

### 2. S3 Folder Deletion (All Stages)
- **Stage 1 - Scheduling**: When folders are scheduled for deletion
  - Lambda: `schedule_s3_deletion`
  - Immediate notification with deletion time and folder list
- **Stage 2 - Deletion**: When folders are actually deleted
  - Lambda: `delete_s3_folders`
  - Confirmation of deletion or errors
- **Stage 3 - Verification**: When checking if deletion was successful
  - Lambda: `check_s3_deletions`
  - Final verification status
- **Reason**: Irreversible data deletion requiring admin oversight

## General Pipeline Notifications (All Admins)

Other pipeline notifications (build success/failure, crawl completion, etc.) are sent to all emails in `/email/admins` via:
- **Lambda**: `stage_notification`
- **Configuration**: Uses the `admin_only` flag to determine recipients

## SNS Topic Subscriptions

The SNS topic `resources-deletion-missed` automatically subscribes all emails from `/email/admins`:
- **Managed by**: Terraform (`messenger.tf`)
- **Auto-update**: Yes, Terraform will automatically update subscriptions when `/email/admins` changes
- **Important**: New subscribers must confirm their subscription via email

## Updating Email Addresses

### To change the admin email:
```bash
aws ssm put-parameter --name /email/admin --value "new-admin@example.com" --overwrite
```

### To update the admin list:
```bash
aws ssm put-parameter --name /email/admins --value "admin1@example.com,admin2@example.com" --overwrite
```

### Apply changes:
```bash
terraform apply  # Updates SNS subscriptions and Lambda environment variables
```

## Notes

- When you change `/email/admin`, critical notifications will immediately go to the new address
- When you change `/email/admins`, Terraform will:
  - Remove SNS subscriptions for removed emails
  - Add SNS subscriptions for new emails
  - New subscribers must confirm via email link
- Lambda functions read SSM parameters at runtime, so email changes take effect immediately
- The admin email (`/email/admin`) serves as both sender and recipient for critical notifications