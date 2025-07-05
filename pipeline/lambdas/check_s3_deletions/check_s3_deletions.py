#!/usr/bin/env python3
"""
check_s3_deletions.py - Check if scheduled S3 deletions were successful

This Lambda verifies that S3 folders scheduled for deletion no longer exist.
It can operate in two modes:
1. Check specific folders (when invoked by EventBridge after scheduled deletion)
2. Check for old objects in a bucket (legacy mode)
"""

import os
import json
import boto3
import time
import logging
from datetime import datetime
from typing import Dict, Any, List, Optional

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Initialize AWS clients
s3 = boto3.client("s3")
sns = boto3.client("sns")
events = boto3.client("events")
lambda_client = boto3.client("lambda")

# Environment variables
BUCKET = os.environ.get("BUCKET_NAME", "")
THRESH = int(os.environ.get("MAX_AGE_SECONDS", "259200"))  # 72 hours default
TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")
STAGE_NOTIFICATION_LAMBDA_ARN = os.environ.get("STAGE_NOTIFICATION_LAMBDA_ARN")


def check_folder_exists(bucket: str, prefix: str) -> Dict[str, Any]:
    """
    Check if a folder (prefix) exists in S3.
    
    Args:
        bucket: S3 bucket name
        prefix: Folder prefix to check
        
    Returns:
        Dictionary with check results
    """
    if not prefix.endswith("/"):
        prefix += "/"
    
    try:
        # Check if any objects exist with this prefix
        response = s3.list_objects_v2(
            Bucket=bucket,
            Prefix=prefix,
            MaxKeys=1
        )
        
        exists = "Contents" in response
        object_count = response.get("KeyCount", 0)
        
        return {
            "bucket": bucket,
            "prefix": prefix,
            "exists": exists,
            "object_count": object_count,
            "checked_at": datetime.utcnow().isoformat()
        }
        
    except s3.exceptions.NoSuchBucket:
        return {
            "bucket": bucket,
            "prefix": prefix,
            "exists": False,
            "object_count": 0,
            "error": "Bucket does not exist",
            "checked_at": datetime.utcnow().isoformat()
        }
    except Exception as e:
        logger.error(f"Error checking folder {bucket}/{prefix}: {e}")
        return {
            "bucket": bucket,
            "prefix": prefix,
            "exists": None,
            "object_count": None,
            "error": str(e),
            "checked_at": datetime.utcnow().isoformat()
        }


def send_check_notification(results: List[Dict[str, Any]], execution_id: str, deletion_time: str) -> None:
    """
    Send notification about deletion check results.
    
    Args:
        results: List of check results
        execution_id: Execution ID for tracking
        deletion_time: When deletions were scheduled
    """
    if not STAGE_NOTIFICATION_LAMBDA_ARN:
        logger.warning("Stage notification Lambda ARN not configured")
        return
    
    # Analyze results
    still_exist = [r for r in results if r.get("exists", False)]
    check_errors = [r for r in results if r.get("error")]
    
    status = "SUCCESS" if len(still_exist) == 0 and len(check_errors) == 0 else "FAILED"
    
    details = {
        "execution_id": execution_id,
        "deletion_scheduled_at": deletion_time,
        "checked_at": datetime.utcnow().isoformat(),
        "total_folders_checked": len(results),
        "folders_still_exist": len(still_exist),
        "check_errors": len(check_errors)
    }
    
    # Add details about folders that still exist
    if still_exist:
        details["existing_folders"] = [
            {
                "folder": f"{r['bucket']}/{r['prefix']}",
                "object_count": r.get("object_count", "unknown")
            }
            for r in still_exist
        ]
    
    # Add error details
    if check_errors:
        details["errors"] = [
            {
                "folder": f"{r['bucket']}/{r['prefix']}",
                "error": r.get("error", "Unknown error")
            }
            for r in check_errors
        ]
    
    try:
        # Invoke stage notification Lambda
        lambda_client.invoke(
            FunctionName=STAGE_NOTIFICATION_LAMBDA_ARN,
            InvocationType="Event",  # Async invocation
            Payload=json.dumps({
                "stage_name": "S3DeletionCheck",
                "status": status,
                "details": details,
                "admin_only": True
            })
        )
        logger.info("Deletion check notification sent")
    except Exception as e:
        logger.error(f"Failed to send notification: {e}")


def cleanup_eventbridge_rule(rule_name: str) -> None:
    """
    Clean up the EventBridge rule after execution.
    
    Args:
        rule_name: Name of the rule to delete
    """
    try:
        # Remove targets first
        events.remove_targets(Rule=rule_name, Ids=["1"])
        # Then delete the rule
        events.delete_rule(Name=rule_name)
        logger.info(f"Cleaned up EventBridge rule: {rule_name}")
    except Exception as e:
        logger.warning(f"Failed to cleanup rule {rule_name}: {e}")


def check_specific_folders(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Check specific folders for deletion verification.
    
    Args:
        event: Event data containing folders to check
        
    Returns:
        Check results
    """
    folders = event.get("folders", [])
    execution_id = event.get("execution_id", "unknown")
    deletion_time = event.get("deletion_time", "unknown")
    deletion_rule_name = event.get("deletion_rule_name")
    
    if not folders:
        logger.warning("No folders specified for checking")
        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": "No folders to check",
                "checked_count": 0
            })
        }
    
    # Check each folder
    results = []
    for folder in folders:
        bucket = folder.get("bucket")
        prefix = folder.get("prefix", "")
        
        if not bucket:
            logger.error(f"Invalid folder specification: {folder}")
            continue
        
        logger.info(f"Checking folder: {bucket}/{prefix}")
        result = check_folder_exists(bucket, prefix)
        results.append(result)
    
    # Send notification about results
    send_check_notification(results, execution_id, deletion_time)
    
    # Clean up EventBridge rules
    if deletion_rule_name:
        cleanup_eventbridge_rule(deletion_rule_name)
    
    # Count results
    still_exist_count = sum(1 for r in results if r.get("exists", False))
    error_count = sum(1 for r in results if r.get("error"))
    
    return {
        "statusCode": 200 if still_exist_count == 0 else 500,
        "body": json.dumps({
            "message": f"Checked {len(folders)} folders",
            "results": results,
            "folders_still_exist": still_exist_count,
            "check_errors": error_count,
            "execution_id": execution_id
        })
    }


def check_old_objects(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Legacy mode: Check for objects older than threshold in a bucket.
    
    Args:
        event: Event data (not used in legacy mode)
        
    Returns:
        Check results
    """
    if not BUCKET or not TOPIC_ARN:
        logger.error("BUCKET_NAME and SNS_TOPIC_ARN must be configured for legacy mode")
        return {"error": "Missing configuration"}
    
    now = time.time()
    offenders = []

    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET):
        for obj in page.get("Contents", []):
            age = now - obj["LastModified"].timestamp()
            if age > THRESH:
                offenders.append(f'{obj["Key"]} (age {age:.0f}s)')

    if offenders:
        msg = (
            f"Found {len(offenders)} object(s) older than "
            f"{THRESH} seconds in bucket '{BUCKET}':\n" +
            "\n".join(offenders)
        )
        sns.publish(
            TopicArn=TOPIC_ARN,
            Subject="S3 deletion alert",
            Message=msg,
        )
    
    return {"offenders": len(offenders)}


def main(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Lambda handler that routes to appropriate check mode.
    
    Args:
        event: Lambda event data
        context: Lambda context
        
    Returns:
        Check results
    """
    logger.info(f"Received event: {json.dumps(event)}")
    
    # Determine mode based on event structure
    if "folders" in event:
        # New mode: Check specific folders
        return check_specific_folders(event)
    else:
        # Legacy mode: Check for old objects
        return check_old_objects(event)
