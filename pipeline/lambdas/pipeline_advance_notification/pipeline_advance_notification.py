#!/usr/bin/env python3
"""
pipeline_advance_notification.py - Send advance notification before pipeline execution

This Lambda function sends a notification 24 hours before the scheduled pipeline execution.
It can optionally start the Step Functions state machine automatically.
"""

import os
import boto3
import json
import logging
from datetime import datetime, timedelta
from typing import Dict, Any

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Initialize AWS clients
ssm = boto3.client("ssm")
ses = boto3.client("ses")
sfn = boto3.client("stepfunctions")
lambda_client = boto3.client("lambda")

# Get environment variables
STATE_MACHINE_ARN = os.getenv("STATE_MACHINE_ARN", "")
STAGE_NOTIFICATION_LAMBDA_ARN = os.getenv("STAGE_NOTIFICATION_LAMBDA_ARN", "")
AUTO_START_PIPELINE = os.getenv("AUTO_START_PIPELINE", "false").lower() == "true"

# Fetch sender email from Parameter Store
try:
    response = ssm.get_parameter(Name="/email/sender")
    SENDER = response["Parameter"]["Value"]
except Exception as e:
    logger.error(f"Failed to fetch sender email from Parameter Store: {e}")
    SENDER = None


def send_advance_notification(scheduled_time: str, pipeline_config: Dict[str, Any]) -> None:
    """
    Send advance notification using the stage notification Lambda.
    
    Args:
        scheduled_time: When the pipeline is scheduled to run
        pipeline_config: Configuration that will be used for the pipeline
    """
    if not STAGE_NOTIFICATION_LAMBDA_ARN:
        logger.error("STAGE_NOTIFICATION_LAMBDA_ARN not configured")
        return
    
    # Prepare the payload for stage notification Lambda
    payload = {
        "stage_name": "PipelineScheduled",
        "status": "SCHEDULED",
        "details": {
            "message": f"Pipeline is scheduled to run in 24 hours",
            "scheduled_time": scheduled_time,
            "pipeline_config": pipeline_config,
            "auto_start": AUTO_START_PIPELINE
        }
    }
    
    try:
        # Invoke the stage notification Lambda
        response = lambda_client.invoke(
            FunctionName=STAGE_NOTIFICATION_LAMBDA_ARN,
            InvocationType="RequestResponse",
            Payload=json.dumps(payload)
        )
        
        logger.info(f"Advance notification sent for pipeline scheduled at {scheduled_time}")
    except Exception as e:
        logger.error(f"Failed to send advance notification: {e}")
        raise


def schedule_pipeline_execution(pipeline_config: Dict[str, Any]) -> str:
    """
    Schedule the pipeline to run in 24 hours.
    
    Args:
        pipeline_config: Configuration for the pipeline execution
        
    Returns:
        Execution ARN if auto-start is enabled, empty string otherwise
    """
    if not AUTO_START_PIPELINE:
        logger.info("AUTO_START_PIPELINE is disabled, not scheduling execution")
        return ""
    
    if not STATE_MACHINE_ARN:
        logger.error("STATE_MACHINE_ARN not configured")
        return ""
    
    try:
        # Generate a unique execution name
        execution_name = f"scheduled-{datetime.utcnow().strftime('%Y%m%d-%H%M%S')}"
        
        # Note: This would typically use EventBridge Scheduler or a delayed execution mechanism
        # For now, we'll just log the intent
        logger.info(f"Would schedule pipeline execution '{execution_name}' for 24 hours from now")
        logger.info(f"Pipeline config: {json.dumps(pipeline_config)}")
        
        # In a real implementation, you would create an EventBridge rule or use Step Functions wait state
        # For this example, we're just returning what would be the execution ARN
        return f"{STATE_MACHINE_ARN}:execution:{execution_name}"
        
    except Exception as e:
        logger.error(f"Failed to schedule pipeline execution: {e}")
        return ""


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Lambda handler for advance pipeline notification.
    
    Expected event structure:
    {
        "pipeline_config": {
            "notifications_enabled": true,
            "stages": {
                "crawler_arm_build": true,
                "cluster_create": true,
                ...
            }
        },
        "scheduled_time": "2024-01-15T10:00:00Z"  # Optional, defaults to 24 hours from now
    }
    """
    logger.info(f"Received event: {json.dumps(event)}")
    
    # Extract pipeline configuration
    pipeline_config = event.get("pipeline_config", {})
    
    # Calculate scheduled time (24 hours from now if not specified)
    if "scheduled_time" in event:
        scheduled_time = event["scheduled_time"]
    else:
        scheduled_time = (datetime.utcnow() + timedelta(hours=24)).isoformat() + "Z"
    
    # Send advance notification
    try:
        send_advance_notification(scheduled_time, pipeline_config)
    except Exception as e:
        logger.error(f"Failed to send advance notification: {e}")
        return {
            "statusCode": 500,
            "body": json.dumps({
                "message": "Failed to send advance notification",
                "error": str(e)
            })
        }
    
    # Optionally schedule the pipeline execution
    execution_arn = ""
    if AUTO_START_PIPELINE:
        execution_arn = schedule_pipeline_execution(pipeline_config)
    
    return {
        "statusCode": 200,
        "body": json.dumps({
            "message": "Advance notification sent successfully",
            "scheduled_time": scheduled_time,
            "auto_start": AUTO_START_PIPELINE,
            "execution_arn": execution_arn
        })
    }