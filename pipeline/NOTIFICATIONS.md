# Pipeline Notifications Control

## Overview

The Step Functions pipeline now supports a global notifications control parameter that allows you to enable or disable all email notifications.

## Usage

Add the `notifications_enabled` parameter to your Step Functions execution input:

```json
{
  "notifications_enabled": false,  // Disable all notifications
  "stages": {
    // ... your stage configuration
  }
}
```

## Default Behavior

- **If `notifications_enabled` is omitted**: Notifications are **enabled** (default behavior)
- **If `notifications_enabled` is `true`**: Notifications are **enabled** 
- **If `notifications_enabled` is `false`**: Notifications are **disabled**
- **If `notifications_enabled` is any other value**: Notifications are **enabled** (defaults to true)

## Example: Disable Notifications

To run the pipeline without any email notifications:

```json
{
  "notifications_enabled": false,
  "stages": {
    "crawler_arm_build": true,
    "cluster_create": true,
    "crawl_wpapi_hidden": true
    // ... other stages
  }
}
```

## Example: Enable Notifications (Default)

To run with notifications, you can either:

1. **Explicitly enable** (optional):
```json
{
  "notifications_enabled": true,
  "stages": {
    "crawler_arm_build": true,
    "cluster_create": true
    // ... other stages
  }
}
```

2. **Omit the parameter** (recommended for default behavior):
```json
{
  "stages": {
    "crawler_arm_build": true,
    "cluster_create": true
    // ... other stages
  }
}
```

3. **Use minimal input** (runs all stages with notifications):
```json
{}
```

## Current Notification Points

### Regular Notifications (sent to /email/admins list)

#### Pipeline Start
1. **PipelineStart**: Notifies when the pipeline execution begins

#### Success Notifications
1. **CrawlWpapiHidden**: Notifies when WordPress API hidden content crawl completes successfully
2. **CrawlWpapiNonHidden**: Notifies when WordPress API non-hidden content crawl completes successfully
3. **CrawlSitemapHidden**: Notifies when Sitemap hidden content crawl completes successfully
4. **CrawlSitemapNonHidden**: Notifies when Sitemap non-hidden content crawl completes successfully
5. **CrawlUrlsHidden**: Notifies when URL hidden content crawl completes successfully
6. **CrawlUrlsNonHidden**: Notifies when URL non-hidden content crawl completes successfully

#### Failure Notifications
1. **CrawlWpapiHidden**: Notifies when WordPress API hidden content crawl fails
2. **CrawlWpapiNonHidden**: Notifies when WordPress API non-hidden content crawl fails

### Admin-Only Notifications (sent only to /email/admin)

#### Infrastructure Notifications
1. **ClusterCreate**: Notifies when the EKS cluster is created successfully
2. **ClusterDestroy**: Notifies when the EKS cluster is destroyed successfully

#### Resource Monitoring
1. **VerifyResourceTermination**: Always runs (not controlled by notifications_enabled) - checks for EC2 instances that should have been terminated and sends alerts ONLY to admin email

## Stage Skip Behavior

When a stage is skipped (by setting it to `false` in the `stages` object), no notifications are sent for that stage - neither success nor failure. This is because skipped stages are not executed at all.

Example:
```json
{
  "notifications_enabled": true,
  "stages": {
    "crawler_arm_build": false  // This stage is skipped, no notifications sent
  }
}
```

## Email Routing

### Two Email Lists:
1. **Regular Admins** (`/email/admins` SSM Parameter): Receives most pipeline notifications
2. **Admin Email** (`/email/admin` SSM Parameter): Receives only critical infrastructure notifications

### Routing Logic:
- **Regular stages** (crawling tasks) → Send to `/email/admins` list
- **Infrastructure stages** (ClusterCreate, ClusterDestroy) → Send ONLY to `/email/admin`
- **EC2 termination checks** → Send ONLY to `/email/admin`

This separation ensures that infrastructure-related notifications go only to the main administrator, while regular pipeline progress notifications go to the broader team.

## Implementation Details

The state machine uses AWS Step Functions Choice states to check the `notifications_enabled` parameter before executing any notification task. When notifications are disabled, the pipeline skips directly to the next stage.

The `stage_notification` Lambda function supports an `admin_only` parameter in its payload to route emails to the appropriate recipient list.