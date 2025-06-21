#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────────────────
#  Glue 5.x job – reads ALL runtime paths/ids from SSM, transforms crawl output,
#  upserts into a Delta Lake table on S3, and writes a Parquet snapshot
# ─────────────────────────────────────────────────────────────────────────────

import sys
import math
import boto3
from datetime import datetime, timezone
from botocore.exceptions import ClientError

from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql import functions as F
from delta.tables import DeltaTable
from pyspark.storagelevel import StorageLevel


# ─────────────────────────────────────────────────────────────────────────────
# Spark session helpers
# ─────────────────────────────────────────────────────────────────────────────
def create_spark_session():
    sc = SparkContext.getOrCreate()
    glue_ctx = GlueContext(sc)
    spark = glue_ctx.spark_session

    # Delta + no broadcast joins + ~128 MB files
    spark.conf.set(
        "spark.delta.logStore.class",
        "org.apache.spark.sql.delta.storage.S3SingleDriverLogStore",
    )
    spark.conf.set("spark.sql.autoBroadcastJoinThreshold", "-1")
    spark.conf.set("spark.sql.files.maxPartitionBytes", str(128 * 1024 * 1024))
    return sc, glue_ctx, spark


# ─────────────────────────────────────────────────────────────────────────────
# Parameter Store helpers
# ─────────────────────────────────────────────────────────────────────────────
_ssm = boto3.client("ssm")


def _get_param(key: str) -> str:
    """Fetch a single SSM parameter and strip leading/trailing slashes."""
    return _ssm.get_parameter(Name=key, WithDecryption=True)["Parameter"]["Value"].strip("/")


def read_ssm_params(keys: dict[str, str]) -> dict[str, str]:
    """Bulk-fetch SSM parameters given a `logical → SSM name` mapping."""
    return {logical: _get_param(ssm_name) for logical, ssm_name in keys.items()}


def with_type(prefix: str, ds_type: str) -> str:
    """
    Append the dataset-type (`h` or `nh`) plus a trailing slash to *prefix*.

    E.g.  "links/delta/dataset-2409" + "h"  →  "links/delta/dataset-2409/h/"
    """
    return f"{prefix.rstrip('/')}/{ds_type.strip('/')}/"


# ─────────────────────────────────────────────────────────────────────────────
# S3 URI builder
# ─────────────────────────────────────────────────────────────────────────────
def build_uris(args: dict, params: dict) -> dict[str, str]:
    bucket = args["s3bucket"]
    ds_type = params["type"]  # "h" or "nh"

    # Append dataset-type folder to every dataset-specific path
    raw_path = with_type(params["raw"], ds_type)
    delta_path = with_type(params["delta"], ds_type)
    snapshot_path = with_type(params["snapshot"], ds_type)

    return {
        "raw_path": f"s3://{bucket}/{raw_path}",
        "delta_path": f"s3://{bucket}/{delta_path}",
        "snapshot_path": f"s3://{bucket}/{snapshot_path}",
        "ip_path": f"s3://{bucket}/{params['ip']}",  # unchanged
        "raw_prefix": raw_path,  # for coalesce()
    }


# ─────────────────────────────────────────────────────────────────────────────
# Transform helpers
# ─────────────────────────────────────────────────────────────────────────────
def load_reference_data(spark, ip_path):
    return spark.read.parquet(ip_path)


def transform_raw(df_raw, ip_df, stage):
    df = (
        df_raw.join(ip_df, "RootDomain", "left")
        .withColumn("Wordpress", F.col("Markers.Wordpress"))
        .withColumn("IpBlock", F.col("Markers.IpBlock"))
        .withColumn("CloudflareBlock", F.col("Markers.CloudflareBlock"))
        .withColumn("CloudflareChallenge", F.col("Markers.CloudflareChallenge"))
        .withColumn("Server", F.col("Meta.Server"))
        .withColumn("Wordcount", F.col("Meta.Wordcount"))
        .withColumn("link", F.explode("ExternalLinks"))
        .filter("link.Protocol IN ('http','https')")
        .drop("ExternalLinks")
        .withColumnRenamed("Title", "MetaTitle")
        .withColumn("LinkDomain", F.col("link.Domain"))
        .withColumn("LinkRootDomain", F.col("link.RootDomain"))
        .withColumn("LinkPath", F.col("link.Path"))
        .withColumn("LinkQuery", F.col("link.Query"))
        .withColumn("LinkProtocol", F.col("link.Protocol"))
        .withColumn("Text", F.col("link.Text"))
        .withColumn("Img", F.col("link.Img"))
        .withColumn("Rel", F.col("link.Rel"))
        .withColumn("Title", F.col("link.Title"))
        .drop("link")
        .withColumn(
            "part",
            F.expr("substring(regexp_replace(lower(LinkRootDomain),'[^0-9a-z]',''),1,2)"),
        )
        .withColumn("stage", F.lit(stage))
        .filter("part <> ''")
    )
    return df


def compute_cloudflare_metrics(df):
    sorry = (
        df.select("CloudflareBlock", "RootDomain")
        .filter("CloudflareBlock = true")
        .select("RootDomain")
        .distinct()
        .count()
    )
    challenge = (
        df.select("CloudflareChallenge", "RootDomain")
        .filter("CloudflareChallenge = true")
        .select("RootDomain")
        .distinct()
        .count()
    )
    return sorry, challenge


def update_dynamodb(import_id, dataset, sorry, challenge):
    tbl = boto3.resource("dynamodb").Table("ImportData")
    try:
        item = tbl.get_item(Key={"id": import_id}).get("Item") or {}
    except ClientError:
        item = {}
    item.update(
        id=import_id,
        dataset=dataset,
        cf_sorry_block_rd_count=sorry,
        cf_challenge_rd_count=challenge,
    )
    tbl.put_item(Item=item)


def adaptive_coalesce(df, bucket, prefix, target_mb, coalesce_min):
    """
    Compute an appropriate `coalesce(n)` based on the size of `prefix`.
    """
    s3 = boto3.resource("s3")
    mb = int(
        sum(o.size for o in s3.Bucket(bucket).objects.filter(Prefix=prefix)) / 1_000_000
    )
    n = max(math.ceil(mb / target_mb), coalesce_min)
    return (
        df.dropDuplicates(["LinkRootDomain", "LinkPath", "LinkQuery"])
        .sortWithinPartitions("LinkRootDomain")
        .coalesce(n)
    )


def prepare_updates(links):
    return (
        links.select(
            F.col("LinkDomain").alias("link_domain"),
            F.col("LinkRootDomain").alias("link_root_domain"),
            F.col("LinkPath").alias("link_path"),
            F.col("LinkQuery").alias("link_query"),
            F.col("LinkProtocol").alias("link_protocol"),
            F.col("Domain").alias("domain"),
            F.col("RootDomain").alias("root_domain"),
            F.col("Path").alias("path"),
            F.col("Query").alias("query"),
            F.col("Protocol").alias("protocol"),
            F.col("Text").alias("text"),
            F.col("Img").alias("img"),
            F.col("Rel").alias("rel"),
            F.col("Title").alias("link_title"),
            F.col("MetaTitle").alias("meta_title"),
            F.col("Wordcount").alias("wordcount"),
            F.col("Server").alias("server"),
            F.col("Ips").alias("ips"),
            F.col("CCs").alias("ccs"),
            F.col("Wordpress").alias("wordpress"),
            F.col("Https").alias("https"),
            F.col("ExternalLinkCount").alias("external_link_count"),
            F.col("InternalLinkCount").alias("internal_link_count"),
            F.col("ExternalDomainCount").alias("domain_count"),
            F.col("ExternalRootDomainCount").alias("root_domain_count"),
            F.col("WpMeta.DateGmt").alias("date_gmt"),
            F.col("WpMeta.ModifiedGmt").alias("modified_gmt"),
            F.col("WpMeta.PostWordcount").alias("post_wordcount"),
            F.col("CloudflareChallenge").alias("cf_challenge"),
            F.col("CloudflareBlock").alias("cf_sorry_block"),
            F.col("IpBlock").alias("aws_block_ip"),
            F.col("TimeStamp").alias("timestamp"),
            "part",
            "stage",
        )
        .dropDuplicates(
            ["link_root_domain", "link_path", "link_query", "root_domain", "path", "query"]
        )
    )


def upsert_delta(spark, updates, delta_path, merge_keys):
    if not DeltaTable.isDeltaTable(spark, delta_path):
        (
            updates.write.format("delta")
            .partitionBy("part", "stage")
            .mode("overwrite")
            .save(delta_path)
        )
    else:
        tbl = DeltaTable.forPath(spark, delta_path)
        cond = " AND ".join([f"t.{k}=s.{k}" for k in merge_keys])
        (
            tbl.alias("t")
            .merge(updates.alias("s"), cond)
            .whenMatchedUpdateAll()
            .whenNotMatchedInsertAll()
            .execute()
        )


def write_snapshot(spark, delta_path, snapshot_path):
    df = spark.read.format("delta").load(delta_path)
    (
        df.write.partitionBy("part", "stage")
        .mode("overwrite")
        .parquet(snapshot_path)
    )


# ─────────────────────────────────────────────────────────────────────────────
# Main entry-point
# ─────────────────────────────────────────────────────────────────────────────
def main():
    # 1 · parse job args and init Glue
    raw_args = getResolvedOptions(
        sys.argv, ["JOB_NAME", "s3bucket", "stage", "coalesce", "target_file_size"]
    )
    sc, glue_ctx, spark = create_spark_session()
    job = Job(glue_ctx)
    job.init(raw_args["JOB_NAME"], raw_args)

    # 2 · SSM parameters (+ new dataset/type)
    ssm_keys = {
        "raw": "/crawl/path/results",
        "delta": "/crawl/path/dataset/delta",
        "snapshot": "/crawl/path/dataset/snapshot",
        "ip": "/crawl/path/ip_addresses",
        "dataset": "/crawl/dataset/current",
        "type": "/crawl/dataset/type",  # NEW
    }
    p = read_ssm_params(ssm_keys)

    # 3 · Build S3 URIs (add dataset-type sub-folder)
    uris = build_uris(raw_args, p)

    import_id = f"{p['dataset']}-{datetime.now(timezone.utc):%Y%m%d%H%M%S}"

    # 4 · Read reference + raw, transform
    ip_df = load_reference_data(spark, uris["ip_path"])
    raw_df = spark.read.parquet(uris["raw_path"])
    df = transform_raw(raw_df, ip_df, raw_args["stage"])

    # 5 · OPTIONAL checkpoint to cut lineage depth
    ckpt_path = f"s3://{raw_args['s3bucket']}/tmp/checkpoint-{import_id}"
    df.write.mode("overwrite").parquet(ckpt_path)
    df = spark.read.parquet(ckpt_path)

    # 6 · Metrics → DynamoDB
    sorry, challenge = compute_cloudflare_metrics(df)
    update_dynamodb(import_id, p["dataset"], sorry, challenge)

    # 7 · Coalesce adaptively (prefix includes dataset-type now)
    links = adaptive_coalesce(
        df,
        raw_args["s3bucket"],
        uris["raw_prefix"],  # << includes h/ or nh/
        int(raw_args["target_file_size"]),
        int(raw_args["coalesce"]),
    )

    sample_count = links.sample(0.01).count() * 100
    print(f"Links count: {sample_count}")

    updates = prepare_updates(links)

    # 8 · Upsert into Delta + snapshot
    merge_keys = [
        "link_root_domain",
        "link_path",
        "link_query",
        "root_domain",
        "path",
        "query",
    ]
    upsert_delta(spark, updates, uris["delta_path"], merge_keys)
    write_snapshot(spark, uris["delta_path"], uris["snapshot_path"])

    job.commit()


if __name__ == "__main__":
    main()
