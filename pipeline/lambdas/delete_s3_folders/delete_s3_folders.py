#!/usr/bin/env python3
"""
delete_s3_folders.py - Delete specified S3 folders

This Lambda function deletes S3 folders/prefixes and their contents.
It's triggered by EventBridge after a scheduled delay.
"""

import os
import json
import boto3
import logging
from typing import Dict, Any, List
from datetime import datetime

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Initialize AWS clients
s3 = boto3.client("s3")
events = boto3.client("events")
lambda_client = boto3.client("lambda")

# Get configuration from environment
STAGE_NOTIFICATION_LAMBDA_ARN = os.environ.get("STAGE_NOTIFICATION_LAMBDA_ARN")


def delete_s3_folder(bucket: str, prefix: str) -> Dict[str, Any]:
    """
    Delete all objects in an S3 folder (prefix).
    
    Args:
        bucket: S3 bucket name
        prefix: Folder prefix to delete
        
    Returns:
        Dictionary with deletion results
    """
    if not prefix.endswith("/"):
        prefix += "/"
    
    deleted_count = 0
    errors = []
    
    try:
        # List and delete all objects with the prefix
        paginator = s3.get_paginator("list_objects_v2")
        
        for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
            objects = page.get("Contents", [])
            
            if objects:
                # Prepare delete request
                delete_objects = [{"Key": obj["Key"]} for obj in objects]
                
                # Delete objects in batches (S3 allows max 1000 per request)
                for i in range(0, len(delete_objects), 1000):
                    batch = delete_objects[i:i+1000]
                    response = s3.delete_objects(
                        Bucket=bucket,
                        Delete={"Objects": batch}
                    )
                    
                    # Count successful deletions
                    deleted_count += len(response.get("Deleted", []))
                    
                    # Track any errors
                    for error in response.get("Errors", []):
                        errors.append({
                            "key": error["Key"],
                            "code": error["Code"],
                            "message": error["Message"]
                        })
        
        return {
            "bucket": bucket,
            "prefix": prefix,
            "deleted_count": deleted_count,
            "errors": errors,
            "success": len(errors) == 0
        }
        
    except Exception as e:
        logger.error(f"Error deleting folder {bucket}/{prefix}: {e}")
        return {
            "bucket": bucket,
            "prefix": prefix,
            "deleted_count": deleted_count,
            "errors": [{"message": str(e)}],
            "success": False
        }


def send_notification(results: List[Dict[str, Any]], execution_id: str) -> None:
    """
    Send notification about deletion results.
    
    Args:
        results: List of deletion results
        execution_id: Execution ID for tracking
    """
    if not STAGE_NOTIFICATION_LAMBDA_ARN:
        logger.warning("Stage notification Lambda ARN not configured")
        return
    
    # Prepare notification details
    total_deleted = sum(r["deleted_count"] for r in results)
    failed_folders = [r for r in results if not r["success"]]
    
    status = "SUCCESS" if len(failed_folders) == 0 else "FAILED"
    
    details = {
        "execution_id": execution_id,
        "total_folders": len(results),
        "total_deleted_objects": total_deleted,
        "failed_folders": len(failed_folders),
        "timestamp": datetime.utcnow().isoformat()
    }
    
    # Add error details if any
    if failed_folders:
        details["failures"] = [
            {
                "folder": f"{r['bucket']}/{r['prefix']}",
                "errors": r["errors"]
            }
            for r in failed_folders
        ]
    
    try:
        # Invoke stage notification Lambda
        lambda_client.invoke(
            FunctionName=STAGE_NOTIFICATION_LAMBDA_ARN,
            InvocationType="Event",  # Async invocation
            Payload=json.dumps({
                "stage_name": "S3FolderDeletion",
                "status": status,
                "details": details,
                "admin_only": True
            })
        )
        logger.info("Deletion notification sent")
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


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Lambda handler to delete S3 folders.
    
    Expected event structure (from EventBridge):
    {
        "folders": [
            {"bucket": "my-bucket", "prefix": "path/to/folder/"},
            ...
        ],
        "execution_id": "step-functions-execution-id",
        "check_rule_name": "s3-deletion-check-xxx"  # Optional
    }
    """
    logger.info(f"Received event: {json.dumps(event)}")
    
    # Extract parameters
    folders = event.get("folders", [])
    execution_id = event.get("execution_id", "unknown")
    check_rule_name = event.get("check_rule_name")
    
    if not folders:
        logger.warning("No folders specified for deletion")
        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": "No folders to delete",
                "deleted_count": 0
            })
        }
    
    # Delete each folder
    results = []
    for folder in folders:
        bucket = folder.get("bucket")
        prefix = folder.get("prefix", "")
        
        if not bucket:
            logger.error(f"Invalid folder specification: {folder}")
            continue
        
        logger.info(f"Deleting folder: {bucket}/{prefix}")
        result = delete_s3_folder(bucket, prefix)
        results.append(result)
    
    # Send notification about results
    send_notification(results, execution_id)
    
    # Update the check rule if provided to include deletion results
    if check_rule_name:
        try:
            # Get current rule configuration
            rule = events.describe_rule(Name=check_rule_name)
            targets = events.list_targets_by_rule(Rule=check_rule_name)["Targets"]
            
            if targets:
                # Update the input to include deletion results
                current_input = json.loads(targets[0].get("Input", "{}"))
                current_input["deletion_results"] = results
                
                events.put_targets(
                    Rule=check_rule_name,
                    Targets=[{
                        "Id": "1",
                        "Arn": targets[0]["Arn"],
                        "Input": json.dumps(current_input)
                    }]
                )
                logger.info(f"Updated check rule {check_rule_name} with deletion results")
        except Exception as e:
            logger.warning(f"Failed to update check rule: {e}")
    
    # Prepare response
    total_deleted = sum(r["deleted_count"] for r in results)
    failed_count = sum(1 for r in results if not r["success"])
    
    return {
        "statusCode": 200 if failed_count == 0 else 500,
        "body": json.dumps({
            "message": f"Deleted {total_deleted} objects from {len(folders)} folders",
            "results": results,
            "failed_folders": failed_count,
            "execution_id": execution_id
        })
    }