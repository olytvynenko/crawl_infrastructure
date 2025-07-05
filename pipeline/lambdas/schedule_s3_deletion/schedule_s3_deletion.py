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
ses = boto3.client("ses")

# Get configuration from environment variables
DELETION_LAMBDA_ARN = os.environ.get("DELETION_LAMBDA_ARN")
CHECK_LAMBDA_ARN = os.environ.get("CHECK_LAMBDA_ARN")
DELETION_DELAY_SECONDS = int(os.environ.get("DELETION_DELAY_SECONDS", "259200"))  # 72 hours default
CHECK_DELAY_SECONDS = int(os.environ.get("CHECK_DELAY_SECONDS", "28800"))  # 8 hours default
ADMIN_EMAIL_PARAM = "/email/admin"
REGULAR_ADMINS = os.environ.get("REGULAR_ADMINS", "")


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


def get_admin_email() -> str:
    """Get admin email from Parameter Store."""
    try:
        response = ssm.get_parameter(Name=ADMIN_EMAIL_PARAM)
        return response["Parameter"]["Value"]
    except Exception as e:
        logger.error(f"Failed to get admin email: {e}")
        return None


def get_recipient_emails() -> List[str]:
    """Get list of recipient emails for notifications."""
    recipients = []
    
    # Add regular admins from environment variable
    if REGULAR_ADMINS:
        recipients.extend([email.strip() for email in REGULAR_ADMINS.split(",") if email.strip()])
    
    # Always include admin email as well
    admin_email = get_admin_email()
    if admin_email and admin_email not in recipients:
        recipients.append(admin_email)
    
    return recipients


def send_scheduled_notification(
    folders: List[Dict[str, str]], 
    deletion_time: datetime, 
    check_time: datetime,
    execution_id: str
) -> None:
    """
    Send notification email about scheduled S3 deletions.
    
    Args:
        folders: List of folders scheduled for deletion
        deletion_time: When the deletion will occur
        check_time: When the verification will occur
        execution_id: Step Functions execution ID
    """
    sender = get_admin_email()
    if not sender:
        logger.warning("Cannot send notification: admin email not configured")
        return
        
    recipients = get_recipient_emails()
    if not recipients:
        logger.warning("No recipients configured for notifications")
        return
    
    # Get current time and timezone info
    current_utc = datetime.utcnow()
    
    # Convert to EST/EDT (US Eastern Time)
    # Note: For production, consider using pytz or zoneinfo for proper timezone handling
    # For now, using a simple offset (-5 for EST, -4 for EDT)
    # Assuming EDT during summer months (March-November)
    current_month = current_utc.month
    is_dst = 3 <= current_month <= 11
    tz_offset = -4 if is_dst else -5
    tz_name = "EDT" if is_dst else "EST"
    
    current_local = current_utc + timedelta(hours=tz_offset)
    deletion_time_local = deletion_time + timedelta(hours=tz_offset)
    check_time_local = check_time + timedelta(hours=tz_offset)
    
    # Generate email content
    subject = f"📅 S3 Deletion Scheduled: {len(folders)} folders at {deletion_time_local.strftime('%I:%M %p')} {tz_name}"
    
    # Build detailed folder list HTML with sizes if available
    folder_list_html = ""
    total_size_estimate = 0
    for folder in folders:
        s3_path = f"s3://{folder['bucket']}/{folder['prefix']}"
        folder_list_html += f"""
        <li style="margin-bottom: 8px;">
            <code style="background-color: #f5f5f5; padding: 4px 8px; border-radius: 4px; font-size: 14px;">
                {s3_path}
            </code>
        </li>"""
    
    html_body = f"""
    <!DOCTYPE html>
    <html>
    <head>
        <style>
            body {{ font-family: Arial, sans-serif; line-height: 1.6; color: #333; }}
            .container {{ max-width: 700px; margin: 0 auto; padding: 20px; }}
            .header {{ background-color: #fff3cd; border: 1px solid #ffeeba; padding: 20px; border-radius: 5px; margin-bottom: 20px; }}
            .header h2 {{ color: #856404; margin: 0 0 10px 0; }}
            .current-time {{ background-color: #e9ecef; padding: 10px; border-radius: 5px; margin-bottom: 20px; text-align: center; }}
            .details {{ background-color: #f8f9fa; padding: 20px; border-radius: 5px; margin: 20px 0; }}
            .details table {{ width: 100%; border-collapse: collapse; }}
            .details td {{ padding: 8px 0; vertical-align: top; }}
            .details td:first-child {{ font-weight: bold; width: 140px; }}
            .folder-list {{ background-color: #fff; border: 2px solid #dc3545; padding: 20px; border-radius: 5px; }}
            .folder-list h3 {{ color: #dc3545; margin-top: 0; }}
            .folder-list ul {{ list-style-type: none; padding-left: 0; }}
            .folder-list li {{ margin-bottom: 10px; }}
            code {{ background-color: #f8f9fa; padding: 6px 10px; border-radius: 4px; font-family: 'Courier New', monospace; font-size: 13px; display: inline-block; border: 1px solid #dee2e6; }}
            .warning {{ background-color: #f8d7da; border: 1px solid #f5c6cb; padding: 15px; border-radius: 5px; margin: 20px 0; }}
            .warning-icon {{ color: #dc3545; font-size: 1.2em; }}
            .time-highlight {{ color: #dc3545; font-weight: bold; font-size: 1.1em; }}
            .footer {{ margin-top: 30px; padding-top: 20px; border-top: 1px solid #dee2e6; color: #6c757d; font-size: 0.9em; }}
        </style>
    </head>
    <body>
        <div class="container">
            <div class="header">
                <h2>⚠️ S3 Deletion Scheduled - Action Required</h2>
                <p style="margin: 0; font-size: 1.1em;">{len(folders)} folder(s) will be <strong>permanently deleted</strong></p>
            </div>
            
            <div class="current-time">
                <strong>Current Time:</strong> {current_local.strftime('%B %d, %Y at %I:%M:%S %p')} {tz_name}
            </div>
            
            <div class="details">
                <h3 style="margin-top: 0;">📅 Deletion Schedule</h3>
                <table>
                    <tr>
                        <td>Deletion Time:</td>
                        <td>
                            <span class="time-highlight">{deletion_time_local.strftime('%B %d, %Y at %I:%M:%S %p')} {tz_name}</span><br>
                            <span style="color: #6c757d; font-size: 0.9em;">
                                ({deletion_time.strftime('%Y-%m-%d %H:%M:%S')} UTC)<br>
                                In {int((deletion_time - current_utc).total_seconds() / 60)} minutes ({round((deletion_time - current_utc).total_seconds() / 3600, 1)} hours)
                            </span>
                        </td>
                    </tr>
                    <tr>
                        <td>Verification Time:</td>
                        <td>
                            {check_time_local.strftime('%B %d, %Y at %I:%M:%S %p')} {tz_name}<br>
                            <span style="color: #6c757d; font-size: 0.9em;">
                                ({check_time.strftime('%Y-%m-%d %H:%M:%S')} UTC)<br>
                                {int((check_time - deletion_time).total_seconds() / 60)} minutes after deletion
                            </span>
                        </td>
                    </tr>
                    <tr>
                        <td>Execution ID:</td>
                        <td><code style="font-size: 11px;">{execution_id}</code></td>
                    </tr>
                </table>
            </div>
            
            <div class="warning">
                <p style="margin: 0;">
                    <span class="warning-icon">⚠️</span> <strong>WARNING:</strong> The following S3 folders and ALL their contents 
                    will be permanently deleted. This action cannot be undone or cancelled.
                </p>
            </div>
            
            <div class="folder-list">
                <h3>🗑️ Folders to be Deleted:</h3>
                <ul>
                    {folder_list_html}
                </ul>
            </div>
            
            <div class="footer">
                <p>
                    <strong>Next Steps:</strong><br>
                    • Review the folders listed above<br>
                    • Ensure any important data has been backed up<br>
                    • You will receive a confirmation email after deletion<br>
                    • A final verification email will confirm successful deletion
                </p>
                <p style="margin-top: 15px;">
                    <em>This is an automated notification from the Crawl Infrastructure Pipeline.<br>
                    Do not reply to this email.</em>
                </p>
            </div>
        </div>
    </body>
    </html>
    """
    
    text_body = f"""
WARNING: S3 DELETION SCHEDULED

{len(folders)} folder(s) will be PERMANENTLY DELETED.

Current Time: {current_local.strftime('%B %d, %Y at %I:%M:%S %p')} {tz_name}

DELETION SCHEDULE:
==================
Deletion Time: {deletion_time_local.strftime('%B %d, %Y at %I:%M:%S %p')} {tz_name}
               ({deletion_time.strftime('%Y-%m-%d %H:%M:%S')} UTC)
               In {int((deletion_time - current_utc).total_seconds() / 60)} minutes

Verification:  {check_time_local.strftime('%B %d, %Y at %I:%M:%S %p')} {tz_name}
               ({check_time.strftime('%Y-%m-%d %H:%M:%S')} UTC)

Execution ID: {execution_id}

FOLDERS TO BE DELETED:
=====================
{chr(10).join([f"• s3://{f['bucket']}/{f['prefix']}" for f in folders])}

⚠️  WARNING: These folders and ALL their contents will be permanently deleted.
This action cannot be undone or cancelled.

Next Steps:
- Review the folders listed above
- Ensure any important data has been backed up
- You will receive a confirmation email after deletion
- A final verification email will confirm successful deletion

This is an automated notification from the Crawl Infrastructure Pipeline.
"""
    
    # Send email
    try:
        ses.send_email(
            Source=sender,
            Destination={"ToAddresses": recipients},
            Message={
                "Subject": {"Data": subject},
                "Body": {
                    "Text": {"Data": text_body},
                    "Html": {"Data": html_body}
                }
            }
        )
        logger.info(f"Scheduled deletion notification sent to {', '.join(recipients)}")
    except Exception as e:
        logger.error(f"Failed to send notification email: {e}")


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
    # EventBridge "at" expression format: at(yyyy-mm-ddThh:mm:ss)
    # The time must be in UTC and at least 1 minute in the future
    schedule_expression = f"at({schedule_time.strftime('%Y-%m-%dT%H:%M:%S')})"
    logger.info(f"Creating rule with schedule expression: {schedule_expression}")
    
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
        logger.error(f"Failed to create EventBridge rule '{rule_name}' with expression '{schedule_expression}': {e}")
        logger.error(f"Schedule time was: {schedule_time.isoformat()}, current time: {datetime.utcnow().isoformat()}")
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
            "message": "No folders to schedule for deletion",
            "scheduled_deletions": 0,
            "details": {
                "folders_count": 0,
                "deletion_scheduled_for": None,
                "check_scheduled_for": None
            }
        }
    
    # Get bucket and dataset from SSM
    try:
        ssm_params = get_ssm_parameters()
        bucket = ssm_params["bucket"]
        dataset = ssm_params["dataset"]
    except Exception as e:
        logger.error(f"Failed to get SSM parameters: {e}")
        return {
            "message": "Failed to retrieve SSM parameters",
            "error": str(e),
            "details": {
                "folders_count": 0,
                "deletion_scheduled_for": None,
                "check_scheduled_for": None
            }
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
    # Ensure we're scheduling at least 1 minute in the future (EventBridge requirement)
    min_delay = max(60, deletion_delay)  # At least 60 seconds
    deletion_time = now + timedelta(seconds=min_delay)
    check_time = deletion_time + timedelta(seconds=check_delay)
    
    logger.info(f"Current time: {now.isoformat()}")
    logger.info(f"Deletion scheduled for: {deletion_time.isoformat()} ({min_delay} seconds from now)")
    logger.info(f"Check scheduled for: {check_time.isoformat()} ({check_delay} seconds after deletion)")
    
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
        
        # Send notification about scheduled deletions
        send_scheduled_notification(folders, deletion_time, check_time, execution_id)
        
        # Return the result directly for Step Functions
        return {
            "message": f"Scheduled deletion of {len(folders)} folders",
            "details": result
        }
        
    except Exception as e:
        logger.error(f"Error scheduling deletions: {e}")
        return {
            "message": "Failed to schedule deletions",
            "error": str(e),
            "details": {
                "folders_count": len(folders) if 'folders' in locals() else 0,
                "deletion_scheduled_for": None,
                "check_scheduled_for": None
            }
        }