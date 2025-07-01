# check_resource_termination.py  – runtime: Python 3.9
import os, boto3, json, datetime
import logging
from typing import List

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

ec2 = boto3.client("ec2")
ssm = boto3.client("ssm")
ses = boto3.client("ses")  # requires verified sender in SES

SENDER = "alex@fromkyiv.com"  # <-- replace with a verified address
admins = os.getenv("ADMIN_EMAILS", "").split(",")


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


def offending_instances(tag_keys: list[str]) -> list[str]:
    # Build one EC2 filter per tag key
    # filters = [{"Name": f"tag:{key}", "Values": ["*"]} for key in tag_keys]
    filters = [{"Name": "tag-key", "Values": tag_keys}]
    inst_ids = []
    paginator = ec2.get_paginator("describe_instances")
    for page in paginator.paginate(Filters=filters):
        for res in page["Reservations"]:
            for inst in res["Instances"]:
                state = inst["State"]["Name"]
                if state not in ("terminated", "shutting-down"):
                    inst_ids.append(inst["InstanceId"])
    return inst_ids


def send_email(recipients: list[str], instances: list[str]) -> None:
    if instances:
        body = (
            "The following EKS EC2 instances were expected to be terminated "
            f"but are still in state:= {instances}\n"
            f"Time: {datetime.datetime.utcnow().isoformat()}Z"
        )
        subject = "[ALERT] EC2 instances not terminated"
    else:
        body = (
            "All EKS EC2 instances are terminated"
            f"Time: {datetime.datetime.utcnow().isoformat()}Z"
        )
        subject = "[INFO] EC2 instances terminated"

    ses.send_email(
        Source=SENDER,
        Destination={"ToAddresses": recipients},
        Message={
            "Subject": {"Data": subject},
            "Body": {"Text": {"Data": body}}
        },
    )


def main(event, context):  # Lambda handler
    tag_keys = _get_tag_keys()
    if not tag_keys:
        logger.error("No tag keys supplied – nothing to do")
        return

    offenders = offending_instances(tag_keys=tag_keys)
    if offenders:
        if admins:
            send_email(admins, offenders)
    else:
        if admins:
            send_email(admins, [])
    return {"offenders": offenders}
