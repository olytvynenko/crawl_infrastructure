# handler.py
import os, boto3, datetime, time

s3 = boto3.client("s3")
sns = boto3.client("sns")

BUCKET = os.environ["BUCKET_NAME"]
THRESH = int(os.environ["MAX_AGE_SECONDS"])
TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]


def main(event, context):
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
