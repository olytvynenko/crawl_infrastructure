#!/usr/bin/env python3
"""
schedule_s3_deletion.py - Schedule S3 folder deletions and subsequent checks

This Lambda function schedules:
1. S3 folder deletions after a specified delay
2. A check to verify deletions were successful
"""

import os
import json
import boto3
import logging
from datetime import datetime, timedelta
from typing import Dict, Any, List

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Initialize AWS clients
events = boto3.client("events")
lambda_client = boto3.client("lambda")
iam = boto3.client("iam")
ssm = boto3.client("ssm")

# Get configuration from environment variables
DELETION_LAMBDA_ARN = os.environ.get("DELETION_LAMBDA_ARN")
CHECK_LAMBDA_ARN = os.environ.get("CHECK_LAMBDA_ARN")
DELETION_DELAY_SECONDS = int(os.environ.get("DELETION_DELAY_SECONDS", "259200"))  # 72 hours default
CHECK_DELAY_SECONDS = int(os.environ.get("CHECK_DELAY_SECONDS", "28800"))  # 8 hours default


def get_ssm_parameters() -> Dict[str, str]:
    """
    Fetch S3 bucket and dataset from SSM parameters.
    
    Returns:
        Dictionary with 'bucket' and 'dataset' keys
    """
    try:
        response = ssm.get_parameters(
            Names=["/s3/bucket", "/crawl/dataset/current"],
            WithDecryption=True
        )
        
        params = {}
        for param in response["Parameters"]:
            if param["Name"] == "/s3/bucket":
                params["bucket"] = param["Value"]
            elif param["Name"] == "/crawl/dataset/current":
                params["dataset"] = param["Value"]
        
        if "bucket" not in params or "dataset" not in params:
            raise ValueError("Missing required SSM parameters")
            
        logger.info(f"Retrieved SSM parameters: bucket={params['bucket']}, dataset={params['dataset']}")
        return params
        
    except Exception as e:
        logger.error(f"Failed to fetch SSM parameters: {e}")
        raise


def create_scheduled_rule(
    rule_name: str,
    description: str,
    schedule_time: datetime,
    target_lambda_arn: str,
    input_data: Dict[str, Any]
) -> str:
    """
    Create an EventBridge rule to trigger a Lambda at a specific time.
    
    Args:
        rule_name: Name for the EventBridge rule
        description: Description of the rule
        schedule_time: When to trigger the Lambda
        target_lambda_arn: ARN of the Lambda to invoke
        input_data: Data to pass to the Lambda
        
    Returns:
        ARN of the created rule
    """
    # Create a one-time schedule expression
    schedule_expression = f"at({schedule_time.strftime('%Y-%m-%dT%H:%M:%S')})"
    
    try:
        # Create or update the rule
        response = events.put_rule(
            Name=rule_name,
            Description=description,
            ScheduleExpression=schedule_expression,
            State="ENABLED"
        )
        rule_arn = response["RuleArn"]
        logger.info(f"Created EventBridge rule: {rule_name}")
        
        # Add Lambda target to the rule
        events.put_targets(
            Rule=rule_name,
            Targets=[
                {
                    "Id": "1",
                    "Arn": target_lambda_arn,
                    "Input": json.dumps(input_data)
                }
            ]
        )
        
        # Add permission for EventBridge to invoke the Lambda
        try:
            lambda_client.add_permission(
                FunctionName=target_lambda_arn,
                StatementId=f"EventBridge-{rule_name}",
                Action="lambda:InvokeFunction",
                Principal="events.amazonaws.com",
                SourceArn=rule_arn
            )
        except lambda_client.exceptions.ResourceConflictException:
            # Permission already exists
            logger.info(f"Permission already exists for rule {rule_name}")
        
        return rule_arn
        
    except Exception as e:
        logger.error(f"Failed to create EventBridge rule: {e}")
        raise


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Lambda handler to schedule S3 deletions and subsequent checks.
    
    Expected event structure:
    {
        "folders": [
            "relative/path/to/folder/",  # Relative to s3://{bucket}/{dataset}/
            ...
        ],
        "deletion_delay_seconds": 259200,  # Optional, uses env var if not provided
        "check_delay_seconds": 28800,      # Optional, uses env var if not provided
        "execution_id": "step-functions-execution-id"  # For tracking
    }
    """
    logger.info(f"Received event: {json.dumps(event)}")
    
    # Extract parameters
    relative_folders = event.get("folders", [])
    deletion_delay = event.get("deletion_delay_seconds", DELETION_DELAY_SECONDS)
    check_delay = event.get("check_delay_seconds", CHECK_DELAY_SECONDS)
    execution_id = event.get("execution_id", datetime.utcnow().strftime("%Y%m%d-%H%M%S"))
    
    if not relative_folders:
        logger.warning("No folders specified for deletion")
        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": "No folders to schedule for deletion",
                "scheduled_deletions": 0
            })
        }
    
    # Get bucket and dataset from SSM
    try:
        ssm_params = get_ssm_parameters()
        bucket = ssm_params["bucket"]
        dataset = ssm_params["dataset"]
    except Exception as e:
        logger.error(f"Failed to get SSM parameters: {e}")
        return {
            "statusCode": 500,
            "body": json.dumps({
                "message": "Failed to retrieve SSM parameters",
                "error": str(e)
            })
        }
    
    # Transform relative paths to absolute paths
    folders = []
    for relative_path in relative_folders:
        # Ensure path ends with /
        if not relative_path.endswith("/"):
            relative_path += "/"
        
        # Construct full prefix: dataset/relative_path
        full_prefix = f"{dataset}/{relative_path}"
        
        folders.append({
            "bucket": bucket,
            "prefix": full_prefix
        })
        
        logger.info(f"Transformed path: {relative_path} -> s3://{bucket}/{full_prefix}")
    
    # Calculate schedule times
    now = datetime.utcnow()
    deletion_time = now + timedelta(seconds=deletion_delay)
    check_time = deletion_time + timedelta(seconds=check_delay)
    
    # Create unique rule names based on execution ID
    deletion_rule_name = f"s3-deletion-{execution_id}"
    check_rule_name = f"s3-deletion-check-{execution_id}"
    
    try:
        # Schedule the deletion Lambda
        deletion_rule_arn = create_scheduled_rule(
            rule_name=deletion_rule_name,
            description=f"Delete S3 folders at {deletion_time.isoformat()}",
            schedule_time=deletion_time,
            target_lambda_arn=DELETION_LAMBDA_ARN,
            input_data={
                "folders": folders,
                "execution_id": execution_id,
                "scheduled_by": "pipeline",
                "check_rule_name": check_rule_name  # So deletion Lambda can update check rule
            }
        )
        
        # Schedule the check Lambda
        check_rule_arn = create_scheduled_rule(
            rule_name=check_rule_name,
            description=f"Check S3 deletions at {check_time.isoformat()}",
            schedule_time=check_time,
            target_lambda_arn=CHECK_LAMBDA_ARN,
            input_data={
                "folders": folders,
                "execution_id": execution_id,
                "deletion_time": deletion_time.isoformat(),
                "deletion_rule_name": deletion_rule_name
            }
        )
        
        result = {
            "deletion_scheduled_for": deletion_time.isoformat(),
            "check_scheduled_for": check_time.isoformat(),
            "deletion_rule_arn": deletion_rule_arn,
            "check_rule_arn": check_rule_arn,
            "folders_count": len(folders),
            "execution_id": execution_id
        }
        
        logger.info(f"Successfully scheduled deletions and checks: {json.dumps(result)}")
        
        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": f"Scheduled deletion of {len(folders)} folders",
                "details": result
            })
        }
        
    except Exception as e:
        logger.error(f"Error scheduling deletions: {e}")
        return {
            "statusCode": 500,
            "body": json.dumps({
                "message": "Failed to schedule deletions",
                "error": str(e)
            })
        }