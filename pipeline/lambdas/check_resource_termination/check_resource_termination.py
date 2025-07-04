# check_resource_termination.py  – runtime: Python 3.9
import os, boto3, json, datetime
import logging
from typing import List, Dict, Any

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

ec2 = boto3.client("ec2")
ssm = boto3.client("ssm")
ses = boto3.client("ses")  # requires verified sender in SES

# Fetch admin email from Parameter Store - this Lambda only sends to admin
try:
    response = ssm.get_parameter(Name="/email/admin")
    SENDER = response["Parameter"]["Value"]
    ADMIN_EMAIL = SENDER  # This Lambda only sends to admin email
except Exception as e:
    logger.error(f"Failed to fetch admin email from Parameter Store: {e}")
    SENDER = None
    ADMIN_EMAIL = None

# Note: This Lambda ignores ADMIN_EMAILS env var and only uses Parameter Store admin email


def _get_tag_keys() -> List[str]:
    """Return a list of tag keys to search for.

    Expected env var:
      TAG_KEYS = '["key1", "key2"]'   (JSON array)

    Back-compat:
      If TAG_KEYS is empty but the legacy TAG_KEY is set, return [TAG_KEY].
    """
    raw = os.getenv("TAG_KEYS", "")
    if raw:
        try:
            keys = json.loads(raw)
            if not isinstance(keys, list) or not all(isinstance(k, str) for k in keys):
                raise ValueError
            return [k for k in keys if k.strip()]
        except Exception:
            logger.warning("TAG_KEYS is not valid JSON array, falling back to legacy TAG_KEY")
    legacy = os.getenv("TAG_KEY")
    return [legacy] if legacy else []


def offending_instances(tag_keys: list[str]) -> List[Dict[str, Any]]:
    """Get details of instances that should be terminated but are still running."""
    filters = [{"Name": "tag-key", "Values": tag_keys}]
    instances = []
    paginator = ec2.get_paginator("describe_instances")
    for page in paginator.paginate(Filters=filters):
        for res in page["Reservations"]:
            for inst in res["Instances"]:
                state = inst["State"]["Name"]
                if state not in ("terminated", "shutting-down"):
                    # Collect instance details for better reporting
                    instance_info = {
                        "InstanceId": inst["InstanceId"],
                        "InstanceType": inst.get("InstanceType", "Unknown"),
                        "State": state,
                        "LaunchTime": inst.get("LaunchTime", "").isoformat() if inst.get("LaunchTime") else "Unknown",
                        "Name": next((tag["Value"] for tag in inst.get("Tags", []) if tag["Key"] == "Name"), "No Name"),
                        "Tags": {tag["Key"]: tag["Value"] for tag in inst.get("Tags", [])}
                    }
                    instances.append(instance_info)
    return instances


def generate_html_content(instances: List[Dict[str, Any]]) -> str:
    """Generate HTML content for the email notification."""
    timestamp = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
    
    if instances:
        # Alert - instances not terminated
        status_color = "#dc3545"
        status_icon = "⚠️"
        status_text = "EC2 Instances Not Terminated"
        header_bg = "#f8d7da"
        header_border = "#f5c6cb"
        
        # Build instances table
        instance_rows = []
        for inst in instances:
            relevant_tags = [f"{k}: {v}" for k, v in inst["Tags"].items() 
                           if k not in ["Name"] and not k.startswith("aws:")][:3]
            tags_display = "<br>".join(relevant_tags) if relevant_tags else "No tags"
            
            instance_rows.append(f"""
            <tr>
                <td style="padding: 10px; border: 1px solid #dee2e6;">{inst["InstanceId"]}</td>
                <td style="padding: 10px; border: 1px solid #dee2e6;">{inst["Name"]}</td>
                <td style="padding: 10px; border: 1px solid #dee2e6;">{inst["InstanceType"]}</td>
                <td style="padding: 10px; border: 1px solid #dee2e6; color: #dc3545; font-weight: bold;">{inst["State"]}</td>
                <td style="padding: 10px; border: 1px solid #dee2e6;">{inst["LaunchTime"]}</td>
                <td style="padding: 10px; border: 1px solid #dee2e6; font-size: 12px;">{tags_display}</td>
            </tr>
            """)
        
        instances_html = f"""
        <div style="margin-top: 20px;">
            <h3 style="color: #721c24; margin-bottom: 10px;">Instances That Should Be Terminated:</h3>
            <div style="overflow-x: auto;">
                <table style="width: 100%; border-collapse: collapse; margin-bottom: 20px;">
                    <thead>
                        <tr style="background-color: #f8f9fa;">
                            <th style="padding: 10px; border: 1px solid #dee2e6; text-align: left;">Instance ID</th>
                            <th style="padding: 10px; border: 1px solid #dee2e6; text-align: left;">Name</th>
                            <th style="padding: 10px; border: 1px solid #dee2e6; text-align: left;">Type</th>
                            <th style="padding: 10px; border: 1px solid #dee2e6; text-align: left;">State</th>
                            <th style="padding: 10px; border: 1px solid #dee2e6; text-align: left;">Launch Time</th>
                            <th style="padding: 10px; border: 1px solid #dee2e6; text-align: left;">Tags</th>
                        </tr>
                    </thead>
                    <tbody>
                        {''.join(instance_rows)}
                    </tbody>
                </table>
            </div>
            <div style="padding: 15px; background-color: #fff3cd; border: 1px solid #ffeeba; border-radius: 5px;">
                <p style="margin: 0; color: #856404;">
                    <strong>Action Required:</strong> Please investigate why these instances were not terminated as expected. 
                    They may be incurring unnecessary costs.
                </p>
            </div>
        </div>
        """
    else:
        # Success - all instances terminated
        status_color = "#28a745"
        status_icon = "✅"
        status_text = "All EC2 Instances Terminated"
        header_bg = "#d4edda"
        header_border = "#c3e6cb"
        instances_html = """
        <div style="margin-top: 20px; padding: 20px; background-color: #d4edda; border: 1px solid #c3e6cb; border-radius: 5px;">
            <p style="margin: 0; color: #155724; text-align: center; font-size: 16px;">
                All expected EC2 instances have been successfully terminated.
            </p>
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
        <div style="max-width: 800px; margin: 0 auto; background-color: #ffffff; padding: 0;">
            <!-- Header -->
            <div style="background-color: {header_bg}; border-bottom: 3px solid {header_border}; padding: 20px; text-align: center;">
                <h1 style="margin: 0; color: {status_color}; font-size: 24px;">
                    {status_icon} {status_text}
                </h1>
            </div>
            
            <!-- Content -->
            <div style="padding: 30px;">
                <h2 style="color: #333; margin-top: 0; margin-bottom: 20px; font-size: 20px;">
                    EC2 Instance Termination Check
                </h2>
                
                <div style="background-color: #f8f9fa; padding: 15px; border-radius: 5px; margin-bottom: 20px;">
                    <table style="width: 100%; border-collapse: collapse;">
                        <tr>
                            <td style="padding: 5px 0;"><strong>Check Time:</strong></td>
                            <td style="padding: 5px 0;">{timestamp}</td>
                        </tr>
                        <tr>
                            <td style="padding: 5px 0;"><strong>Instances Found:</strong></td>
                            <td style="padding: 5px 0; color: {status_color}; font-weight: bold;">{len(instances)}</td>
                        </tr>
                    </table>
                </div>
                
                {instances_html}
                
                <!-- Action Links -->
                <div style="margin-top: 30px; padding: 20px; background-color: #e9ecef; border-radius: 5px; text-align: center;">
                    <p style="margin: 0 0 15px 0; color: #666;">
                        View EC2 instances in the AWS Console for more details.
                    </p>
                    <a href="https://console.aws.amazon.com/ec2/home#Instances:" 
                       style="display: inline-block; padding: 10px 20px; background-color: #007bff; color: #ffffff; text-decoration: none; border-radius: 5px;">
                        View EC2 Console
                    </a>
                </div>
            </div>
            
            <!-- Footer -->
            <div style="background-color: #f8f9fa; padding: 20px; text-align: center; border-top: 1px solid #dee2e6;">
                <p style="margin: 0; color: #666; font-size: 12px;">
                    This is an automated notification from the Resource Termination Monitor.<br>
                    Please do not reply to this email.
                </p>
            </div>
        </div>
    </body>
    </html>
    """
    
    return html_content


def send_email(recipients: List[str], instances: List[Dict[str, Any]]) -> None:
    """Send HTML-formatted email notification about EC2 instance status.
    
    Note: This function ignores the recipients parameter and only sends to ADMIN_EMAIL.
    """
    if not SENDER or not ADMIN_EMAIL:
        logger.error("Cannot send email: ADMIN_EMAIL is not configured")
        return
    
    timestamp = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
    
    # Generate subject
    if instances:
        subject = f"⚠️ Alert: {len(instances)} EC2 Instances Not Terminated"
    else:
        subject = "✅ Success: All EC2 Instances Terminated"
    
    # Generate HTML content
    html_body = generate_html_content(instances)
    
    # Generate text fallback
    if instances:
        instance_list = "\n".join([f"- {inst['InstanceId']} ({inst['Name']}) - State: {inst['State']}" 
                                  for inst in instances])
        text_body = f"""
EC2 Instance Termination Alert

The following EC2 instances were expected to be terminated but are still running:

{instance_list}

Time: {timestamp}

Please investigate why these instances were not terminated as expected.
"""
    else:
        text_body = f"""
EC2 Instance Termination Check - Success

All expected EC2 instances have been successfully terminated.

Time: {timestamp}
"""
    
    # Send email
    try:
        ses.send_email(
            Source=SENDER,
            Destination={"ToAddresses": [ADMIN_EMAIL]},  # Only send to admin
            Message={
                "Subject": {"Data": subject},
                "Body": {
                    "Text": {"Data": text_body},
                    "Html": {"Data": html_body}
                }
            },
        )
        logger.info(f"Email sent to admin ({ADMIN_EMAIL}) about {len(instances)} instances")
    except Exception as e:
        logger.error(f"Failed to send email: {e}")
        raise


def main(event, context):  # Lambda handler
    tag_keys = _get_tag_keys()
    if not tag_keys:
        logger.error("No tag keys supplied – nothing to do")
        return {"offenders": []}

    offenders = offending_instances(tag_keys=tag_keys)
    
    # Always send email to admin if configured
    if ADMIN_EMAIL:
        send_email([], offenders)  # Recipients parameter is ignored
    
    # Return instance IDs for compatibility
    return {"offenders": [inst["InstanceId"] for inst in offenders]}
