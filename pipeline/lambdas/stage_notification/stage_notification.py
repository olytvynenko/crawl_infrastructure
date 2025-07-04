#!/usr/bin/env python3
"""
stage_notification.py - Send email notifications for stage completions/failures

This Lambda function sends email notifications when pipeline stages complete
or fail. It's designed to be reusable across all stages in the Step Functions
state machine.
"""

import os
import boto3
import json
import logging
from datetime import datetime
from typing import Dict, Any, List

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Initialize AWS clients
ssm = boto3.client("ssm")
ses = boto3.client("ses")

# Fetch sender email from Parameter Store
try:
    response = ssm.get_parameter(Name="/email/admin")
    SENDER = response["Parameter"]["Value"]
except Exception as e:
    logger.error(f"Failed to fetch admin email from Parameter Store: {e}")
    SENDER = None

# Get admin emails from environment variable
admins = os.getenv("ADMIN_EMAILS", "").split(",")


def send_notification(
    stage_name: str,
    status: str,
    details: Dict[str, Any] = None,
    error_message: str = None
) -> None:
    """
    Send email notification about stage completion.
    
    Args:
        stage_name: Name of the stage that completed
        status: Either "SUCCESS" or "FAILED"
        details: Additional details about the stage execution
        error_message: Error message if the stage failed
    """
    if not SENDER:
        logger.error("Cannot send email: SENDER is not configured")
        return
    
    if not admins:
        logger.warning("No admin emails configured")
        return
    
    # Prepare email content
    timestamp = datetime.utcnow().isoformat()
    
    if status == "SUCCESS":
        subject = f"[SUCCESS] Pipeline Stage: {stage_name}"
        body = f"""
Pipeline Stage Completed Successfully

Stage: {stage_name}
Status: SUCCESS
Time: {timestamp}Z

Details:
{json.dumps(details, indent=2) if details else 'No additional details'}

This is an automated notification from the crawl pipeline.
"""
    else:
        subject = f"[FAILED] Pipeline Stage: {stage_name}"
        body = f"""
Pipeline Stage Failed

Stage: {stage_name}
Status: FAILED
Time: {timestamp}Z

Error: {error_message or 'No error message provided'}

Details:
{json.dumps(details, indent=2) if details else 'No additional details'}

Please check the AWS Step Functions console for more information.

This is an automated notification from the crawl pipeline.
"""
    
    # Send email
    try:
        ses.send_email(
            Source=SENDER,
            Destination={"ToAddresses": [email.strip() for email in admins if email.strip()]},
            Message={
                "Subject": {"Data": subject},
                "Body": {"Text": {"Data": body}}
            }
        )
        logger.info(f"Notification sent for stage {stage_name} with status {status}")
    except Exception as e:
        logger.error(f"Failed to send email notification: {e}")
        raise


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Lambda handler for stage notifications.
    
    Expected event structure:
    {
        "stage_name": "CrawlWpapiHidden",
        "status": "SUCCESS" or "FAILED",
        "details": {
            "dataset_type": "h",
            "workflow": "wordpress",
            "execution_time": 123
        },
        "error": "Error message if failed"
    }
    """
    logger.info(f"Received event: {json.dumps(event)}")
    
    # Extract parameters
    stage_name = event.get("stage_name", "Unknown Stage")
    status = event.get("status", "UNKNOWN")
    details = event.get("details", {})
    error_message = event.get("error")
    
    # Send notification
    try:
        send_notification(stage_name, status, details, error_message)
        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": f"Notification sent for {stage_name}",
                "status": status
            })
        }
    except Exception as e:
        logger.error(f"Error in lambda handler: {e}")
        return {
            "statusCode": 500,
            "body": json.dumps({
                "message": "Failed to send notification",
                "error": str(e)
            })
        }