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
    ADMIN_EMAIL = SENDER  # Store admin email separately
except Exception as e:
    logger.error(f"Failed to fetch admin email from Parameter Store: {e}")
    SENDER = None
    ADMIN_EMAIL = None

# Get regular notification emails from environment variable
regular_admins = os.getenv("ADMIN_EMAILS", "").split(",")

# Stage descriptions for human-readable names
STAGE_DESCRIPTIONS = {
    "CrawlerArmBuild": "Crawler ARM Docker Image Build",
    "ClusterCreate": "EKS Cluster Infrastructure Creation",
    "CrawlWpapiHidden": "WordPress API Crawl (Hidden Content)",
    "CrawlWpapiNonHidden": "WordPress API Crawl (Non-Hidden Content)",
    "CrawlSitemapHidden": "Sitemap URL Crawl (Hidden Content)",
    "CrawlSitemapNonHidden": "Sitemap URL Crawl (Non-Hidden Content)",
    "WpapiDeltaUpsert": "WordPress API Data Delta Lake Update",
    "GenerateSitemapSeeds": "Sitemap Seed File Generation",
    "CrawlUrlsHidden": "Individual URL Crawl (Hidden Content)",
    "CrawlUrlsNonHidden": "Individual URL Crawl (Non-Hidden Content)",
    "SitemapsDeltaUpsert": "Sitemap Data Delta Lake Update",
    "ClusterDestroy": "EKS Cluster Infrastructure Cleanup",
    "VerifyResourceTermination": "Resource Termination Verification",
    "PipelineScheduled": "Pipeline Scheduled Execution",
    "PipelineStart": "Pipeline Execution Started"
}


def generate_html_content(
    stage_name: str,
    status: str,
    details: Dict[str, Any] = None,
    error_message: str = None
) -> str:
    """
    Generate HTML content for the email notification.
    
    Args:
        stage_name: Name of the stage that completed
        status: Either "SUCCESS" or "FAILED"
        details: Additional details about the stage execution
        error_message: Error message if the stage failed
    
    Returns:
        HTML content string
    """
    timestamp = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
    human_readable_stage = STAGE_DESCRIPTIONS.get(stage_name, stage_name)
    
    # Define colors and icons based on status
    if status == "SUCCESS":
        status_color = "#28a745"
        status_icon = "✅"
        status_text = "Completed Successfully"
        header_bg = "#d4edda"
        header_border = "#c3e6cb"
    elif status == "SCHEDULED":
        status_color = "#007bff"
        status_icon = "📅"
        status_text = "Scheduled"
        header_bg = "#cce5ff"
        header_border = "#b8daff"
    elif status == "STARTED":
        status_color = "#17a2b8"
        status_icon = "🚀"
        status_text = "Started"
        header_bg = "#d1ecf1"
        header_border = "#bee5eb"
    else:
        status_color = "#dc3545"
        status_icon = "❌"
        status_text = "Failed"
        header_bg = "#f8d7da"
        header_border = "#f5c6cb"
    
    # Build details HTML
    details_html = ""
    if details:
        details_items = []
        for key, value in details.items():
            formatted_key = key.replace("_", " ").title()
            details_items.append(f"<li><strong>{formatted_key}:</strong> {value}</li>")
        details_html = f"""
        <div style="margin-top: 20px;">
            <h3 style="color: #333; margin-bottom: 10px;">Execution Details:</h3>
            <ul style="list-style-type: none; padding-left: 0;">
                {''.join(details_items)}
            </ul>
        </div>
        """
    
    # Build error HTML if applicable
    error_html = ""
    if error_message:
        error_html = f"""
        <div style="margin-top: 20px; padding: 15px; background-color: #f8d7da; border: 1px solid #f5c6cb; border-radius: 5px;">
            <h3 style="color: #721c24; margin-top: 0;">Error Details:</h3>
            <p style="color: #721c24; margin: 0; white-space: pre-wrap;">{error_message}</p>
        </div>
        """
    
    html_content = f"""
    <!DOCTYPE html>
    <html>
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
    </head>
    <body style="margin: 0; padding: 0; font-family: Arial, sans-serif; background-color: #f4f4f4;">
        <div style="max-width: 600px; margin: 0 auto; background-color: #ffffff; padding: 0;">
            <!-- Header -->
            <div style="background-color: {header_bg}; border-bottom: 3px solid {header_border}; padding: 20px; text-align: center;">
                <h1 style="margin: 0; color: {status_color}; font-size: 24px;">
                    {status_icon} Pipeline Stage {status_text}
                </h1>
            </div>
            
            <!-- Content -->
            <div style="padding: 30px;">
                <h2 style="color: #333; margin-top: 0; margin-bottom: 20px; font-size: 20px;">
                    {human_readable_stage}
                </h2>
                
                <div style="background-color: #f8f9fa; padding: 15px; border-radius: 5px; margin-bottom: 20px;">
                    <table style="width: 100%; border-collapse: collapse;">
                        <tr>
                            <td style="padding: 5px 0;"><strong>Stage Name:</strong></td>
                            <td style="padding: 5px 0;">{stage_name}</td>
                        </tr>
                        <tr>
                            <td style="padding: 5px 0;"><strong>Status:</strong></td>
                            <td style="padding: 5px 0; color: {status_color}; font-weight: bold;">{status}</td>
                        </tr>
                        <tr>
                            <td style="padding: 5px 0;"><strong>Timestamp:</strong></td>
                            <td style="padding: 5px 0;">{timestamp}</td>
                        </tr>
                    </table>
                </div>
                
                {details_html}
                {error_html}
                
                <!-- Action Links -->
                <div style="margin-top: 30px; padding: 20px; background-color: #e9ecef; border-radius: 5px; text-align: center;">
                    <p style="margin: 0 0 15px 0; color: #666;">
                        For more information, please check the AWS Step Functions console.
                    </p>
                    <a href="https://console.aws.amazon.com/states/home" 
                       style="display: inline-block; padding: 10px 20px; background-color: #007bff; color: #ffffff; text-decoration: none; border-radius: 5px;">
                        View in AWS Console
                    </a>
                </div>
            </div>
            
            <!-- Footer -->
            <div style="background-color: #f8f9fa; padding: 20px; text-align: center; border-top: 1px solid #dee2e6;">
                <p style="margin: 0; color: #666; font-size: 12px;">
                    This is an automated notification from the Crawl Infrastructure Pipeline.<br>
                    Please do not reply to this email.
                </p>
            </div>
        </div>
    </body>
    </html>
    """
    
    return html_content


def send_notification(
    stage_name: str,
    status: str,
    details: Dict[str, Any] = None,
    error_message: str = None,
    admin_only: bool = False
) -> None:
    """
    Send email notification about stage completion.
    
    Args:
        stage_name: Name of the stage that completed
        status: Either "SUCCESS" or "FAILED"
        details: Additional details about the stage execution
        error_message: Error message if the stage failed
        admin_only: If True, send only to admin email from Parameter Store
    """
    if not SENDER:
        logger.error("Cannot send email: SENDER is not configured")
        return
    
    # Determine recipients based on admin_only flag
    if admin_only:
        if not ADMIN_EMAIL:
            logger.error("Cannot send admin-only email: ADMIN_EMAIL is not configured")
            return
        recipients = [ADMIN_EMAIL]
    else:
        if not regular_admins:
            logger.warning("No regular admin emails configured")
            return
        recipients = regular_admins
    
    # Prepare email content
    timestamp = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
    human_readable_stage = STAGE_DESCRIPTIONS.get(stage_name, stage_name)
    
    # Generate subject
    if status == "SUCCESS":
        subject = f"✅ Pipeline Success: {human_readable_stage}"
    elif status == "SCHEDULED":
        subject = f"📅 Pipeline Scheduled: {human_readable_stage}"
    elif status == "STARTED":
        subject = f"🚀 Pipeline Started: {human_readable_stage}"
    else:
        subject = f"❌ Pipeline Failed: {human_readable_stage}"
    
    # Generate HTML content
    html_body = generate_html_content(stage_name, status, details, error_message)
    
    # Generate text fallback
    text_body = f"""
Pipeline Stage {status}

Stage: {human_readable_stage} ({stage_name})
Status: {status}
Time: {timestamp}

{'Error: ' + error_message if error_message else ''}
{'Details: ' + json.dumps(details, indent=2) if details else ''}

Please check the AWS Step Functions console for more information.

This is an automated notification from the crawl pipeline.
"""
    
    # Send email
    try:
        ses.send_email(
            Source=SENDER,
            Destination={"ToAddresses": [email.strip() for email in recipients if email.strip()]},
            Message={
                "Subject": {"Data": subject},
                "Body": {
                    "Text": {"Data": text_body},
                    "Html": {"Data": html_body}
                }
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
        "error": "Error message if failed",
        "admin_only": true/false  # Optional, defaults to false
    }
    """
    logger.info(f"Received event: {json.dumps(event)}")
    
    # Extract parameters
    stage_name = event.get("stage_name", "Unknown Stage")
    status = event.get("status", "UNKNOWN")
    details = event.get("details", {})
    error_message = event.get("error")
    admin_only = event.get("admin_only", False)
    
    # Send notification
    try:
        send_notification(stage_name, status, details, error_message, admin_only)
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