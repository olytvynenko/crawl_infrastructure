#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────────────────
#  Glue 5.x job – reads ALL runtime paths/ids from SSM, transforms crawl output,
#  upserts into a Delta Lake table on S3, and writes a Parquet snapshot
# ─────────────────────────────────────────────────────────────────────────────
import sys, math, boto3
from datetime import datetime, timezone
from botocore.exceptions import ClientError
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql import functions as F
from delta.tables import DeltaTable

# ─────────────────────────── CLI args (SSM-fetched removed)
args = getResolvedOptions(
    sys.argv,
    [
        "JOB_NAME",
        "s3bucket",
        "stage",
        "coalesce",
        "target_file_size",
    ],
)

# ─────────────────────────── Spark / Delta
sc = SparkContext.getOrCreate()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
spark.conf.set(
    "spark.delta.logStore.class",
    "org.apache.spark.sql.delta.storage.S3SingleDriverLogStore"
)
# 1) target ≈128 MB files
TARGET_BYTES = 128 * 1024 * 1024
spark.conf.set("spark.sql.files.maxPartitionBytes", TARGET_BYTES)

job = Job(glueContext)
job.init(args["JOB_NAME"], args)

# ─────────────────────────── read SSM params
ssm = boto3.client("ssm")


def ssm_value(name: str) -> str:
    return ssm.get_parameter(Name=name)["Parameter"]["Value"].strip("/")


RAW_PATH_REL = ssm_value("/crawl/path/results")
DELTA_PATH_REL = ssm_value("/crawl/path/dataset/delta")
MAJESTIC_PATH_REL = ssm_value("/crawl/path/majestic")
IP_PATH_REL = ssm_value("/crawl/path/ip_addresses")
DATASET_NAME = ssm_value("/crawl/dataset/current")
SNAPSHOT_PATH_REL = ssm_value("/crawl/path/dataset/snapshot")

IMPORT_ID_VAL = f"{DATASET_NAME}-{datetime.now(timezone.utc):%Y%m%d%H%M%S}"

# ─────────────────────────── build URIs
BUCKET = args["s3bucket"]
RAW_PATH = f"s3://{BUCKET}/{RAW_PATH_REL}"
DELTA_PATH = f"s3://{BUCKET}/{DELTA_PATH_REL}"
SNAPSHOT_PATH = f"s3://{BUCKET}/{SNAPSHOT_PATH_REL}"
IP_PATH = f"s3://{BUCKET}/{IP_PATH_REL}"

STAGE = args["stage"]
COALESCE_MIN = int(args["coalesce"])
TARGET_MB = int(args["target_file_size"])


# ─────────────────────────── helpers
def partition_column(c, n=2):
    return F.substring(F.regexp_replace(F.lower(c), "[^0-9a-z]", ""), 1, n)


def folder_size_mb(bucket, prefix):
    s3 = boto3.resource("s3")
    return int(sum(o.size for o in s3.Bucket(bucket).objects.filter(Prefix=prefix)) / 1_000_000)


def update_dynamodb(import_id, dataset, sorry_cnt, challenge_cnt):
    tbl = boto3.resource("dynamodb").Table("ImportData")
    try:
        item = tbl.get_item(Key={"id": import_id}).get("Item") or {}
    except ClientError:
        item = {}
    item.update(
        id=import_id,
        dataset=dataset,
        cf_sorry_block_rd_count=sorry_cnt,
        cf_challenge_rd_count=challenge_cnt,
    )
    tbl.put_item(Item=item)


# ─────────────────────────── load reference data
ip_df = spark.read.parquet(IP_PATH)

# ─────────────────────────── load & transform crawl data
raw = spark.read.parquet(RAW_PATH)

df = (
    raw.join(ip_df, "RootDomain", "left")
    .withColumn("Wordpress", F.col("Markers.Wordpress"))
    .withColumn("IpBlock", F.col("Markers.IpBlock"))
    .withColumn("CloudflareBlock", F.col("Markers.CloudflareBlock"))
    .withColumn("CloudflareChallenge", F.col("Markers.CloudflareChallenge"))
    .withColumn("Server", F.col("Meta.Server"))
    .withColumn("Wordcount", F.col("Meta.Wordcount"))
    .withColumn("link", F.explode("ExternalLinks"))
    .filter("link.Protocol IN ('http','https')")
    .drop("ExternalLinks")
    .withColumnRenamed('Title', 'MetaTitle')
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
    .withColumn("part", partition_column(F.col("LinkRootDomain")))
    .withColumn("stage", F.lit(STAGE))
    .filter("part <> ''")
)

df = df.persist()

# Cloudflare metrics -> DynamoDB
sorry_cnt = df.where("CloudflareBlock = true").select("RootDomain").agg(F.approx_count_distinct("RootDomain")).first()[
    0]
challenge_cnt = \
df.where("CloudflareChallenge = true").select("RootDomain").agg(F.approx_count_distinct("RootDomain")).first()[0]
update_dynamodb(IMPORT_ID_VAL, DATASET_NAME, sorry_cnt, challenge_cnt)

# ─────────────────────────── adaptive coalesce
data_mb = folder_size_mb(BUCKET, RAW_PATH_REL)
factor = max(math.ceil(data_mb / TARGET_MB), COALESCE_MIN)

links = (
    df.dropDuplicates(["LinkRootDomain", "LinkPath", "LinkQuery"])  # ensure unique keys
    .sortWithinPartitions("LinkRootDomain")
    .coalesce(factor)
)

df.unpersist()

# ─────────────────────────── prepare update DataFrame
updates = links.select(
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
    F.col("LinkDomain").alias("link_title"),
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
    "part", "stage"
)

merge_keys = [
    "link_root_domain",
    "link_path",
    "link_query",
    "root_domain",
    "path",
    "query"
]

# drop any duplicate rows in this batch on all six keys
updates = updates.dropDuplicates(merge_keys)

# ─────────────────────────── upsert to Delta
if not DeltaTable.isDeltaTable(spark, DELTA_PATH):
    (updates.write.format("delta")
     .partitionBy("part", "stage")
     .mode("overwrite")
     .save(DELTA_PATH))
else:
    delta_tbl = DeltaTable.forPath(spark, DELTA_PATH)
    cond = " AND ".join([f"t.{k}=s.{k}" for k in merge_keys])
    (delta_tbl.alias("t")
     .merge(updates.alias("s"), cond)
     .whenMatchedUpdateAll()
     .whenNotMatchedInsertAll()
     .execute())

# maintenance (optimize + vacuum)
# spark.sql(f"OPTIMIZE delta.`{DELTA_PATH}` ZORDER BY (link_root_domain)")
spark.conf.set("spark.databricks.delta.retentionDurationCheck.enabled", "false")
spark.sql(f"VACUUM delta.`{DELTA_PATH}` RETAIN 0 HOURS")

# ─────────────────────────── export Parquet snapshot
df_snapshot = spark.read.format("delta").load(DELTA_PATH)
(df_snapshot
 .write
 .partitionBy("part", "stage")
 .mode("overwrite")
 .parquet(SNAPSHOT_PATH))

# 1) Read the entire table into a DataFrame
# df = spark.read.format("delta").load(DELTA_PATH)
#
# from pyspark.sql import Window
#
# # 2) Assign a row‐number per group of your six keys, keeping the “latest” row
# window = Window.partitionBy(
#     "link_root_domain","link_path","link_query",
#     "root_domain","path","query"
# ).orderBy(F.desc("timestamp"))
#
# deduped = (
#     df.withColumn("rn", F.row_number().over(window))
#       .filter("rn = 1")
#       .drop("rn")
# )
#
# # 3) Overwrite the Delta table with the deduped DataFrame
# deduped.write \
#     .format("delta") \
#     .mode("overwrite") \
#     .option("overwriteSchema", "true") \
#     .partitionBy("part","stage") \
#     .save(DELTA_PATH)

# spark.sql(f"OPTIMIZE delta.`{DELTA_PATH}` ZORDER BY (link_root_domain)")

job.commit()
