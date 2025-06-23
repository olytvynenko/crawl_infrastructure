#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────────────────
#  Glue job – Process sitemap Parquet files to extract internal links
#  and create seed CSV files with ~5000 URLs per file
# ─────────────────────────────────────────────────────────────────────────────

import boto3
import sys
import math
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql import functions as F


# ─────────────────────────────────────────────────────────────────────────────
# Spark session helpers
# ─────────────────────────────────────────────────────────────────────────────
def create_spark_session():
    sc = SparkContext.getOrCreate()
    glue_ctx = GlueContext(sc)
    spark = glue_ctx.spark_session
    return sc, glue_ctx, spark


# ─────────────────────────────────────────────────────────────────────────────
# Parameter Store helpers
# ─────────────────────────────────────────────────────────────────────────────
_ssm = boto3.client("ssm")


# ─────────────────────────────────────────────────────────────────────────────
# Main processing function
# ─────────────────────────────────────────────────────────────────────────────
def process_sitemap_files(spark, sitemap_path, output_path):
    """
    Read sitemap Parquet files, extract InternalLinks, and save as CSV files
    with ~5000 URLs per partition.
    """
    print(f"Reading sitemap files from: {sitemap_path}")

    # Read the Parquet files
    df = spark.read.parquet(sitemap_path)
    print(f"Total records read: {df.count()}")

    # Explode InternalLinks array to get individual URLs
    urls_df = (
        df
        .select("PageType", "InternalLinks")
        .filter(F.col("PageType") == 13)
        .select(F.explode(F.col("InternalLinks")).alias("url"))
        .filter(F.col("url").isNotNull() & (F.col("url") != ""))
        .distinct()
    )

    total_urls = urls_df.count()
    print(f"Total unique internal URLs: {total_urls}")

    # Calculate number of partitions needed (~5000 URLs per partition)
    urls_per_partition = 5000
    num_partitions = max(1, math.ceil(total_urls / urls_per_partition))

    print(f"Repartitioning into {num_partitions} partitions with ~{urls_per_partition} URLs each")

    # Repartition and save as CSV
    output_full_path = f"{output_path}"

    (
        urls_df
        .repartition(num_partitions)
        .write
        .mode("overwrite")
        .option("header", "false")
        .csv(output_full_path)
    )

    print(f"Successfully saved {total_urls} URLs to {output_full_path}")
    return num_partitions, total_urls


# ─────────────────────────────────────────────────────────────────────────────
# Main entry-point
# ─────────────────────────────────────────────────────────────────────────────
def main():
    # Parse job arguments
    raw_args = getResolvedOptions(
        sys.argv, ["JOB_NAME", "in_path", "out_path"]
    )

    sc, glue_ctx, spark = create_spark_session()
    job = Job(glue_ctx)
    job.init(raw_args["JOB_NAME"], raw_args)

    bucket = _ssm.get_parameter(Name="/s3/bucket", WithDecryption=True)["Parameter"]["Value"]
    dataset = _ssm.get_parameter(Name="/crawl/dataset/current", WithDecryption=True)["Parameter"]["Value"]

    for links_type in ["h", "nh"]:
        # Get paths from job parameters
        sitemap_path = f"s3://{bucket}/{dataset}/{raw_args['in_path']}{links_type}"
        output_path = f"s3://{bucket}/{dataset}/{raw_args['out_path']}{links_type}"

        print(f"Input path: {sitemap_path}")
        print(f"Output path: {output_path}")

        # Process the files
        try:
            num_partitions, total_urls = process_sitemap_files(spark, sitemap_path, output_path)
            print(f"Successfully processed {total_urls} URLs into {num_partitions} CSV files")

        except Exception as e:
            print(f"Error processing sitemap files: {str(e)}")
            raise e

    job.commit()
    print("Job completed successfully")


if __name__ == "__main__":
    main()
