########################################################
# main.tf
########################################################

provider "aws" {
  region = "us-east-1"
}

############################################
# account ID for IAM ARNs
############################################
data "aws_caller_identity" "current" {}

#################
# 0. Upload the script
#################
locals {
  script_key = "${var.s3_prefix}/${var.delta_upsert_job_name}/${filesha1(var.delta_upsert_script_path)}.py"
  account_id = data.aws_caller_identity.current.account_id
}

resource "aws_s3_object" "script" {
  bucket = var.s3_bucket
  key    = local.script_key
  source = var.delta_upsert_script_path
  etag = filemd5(var.delta_upsert_script_path)
}

#################
# 1. IAM role for Glue
#################
data "aws_iam_policy_document" "assume_glue" {
  statement {
    effect = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue_job" {
  name = "${var.delta_upsert_job_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume_glue.json
}

# Managed Glue service role + S3 access for script/temp/output
resource "aws_iam_role_policy_attachment" "glue_managed" {
  role       = aws_iam_role.glue_job.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_policy" "extra_s3" {
  name = "${var.delta_upsert_job_name}-s3"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
        Resource = ["arn:aws:s3:::${var.s3_bucket}/*"]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "extra_s3" {
  role       = aws_iam_role.glue_job.name
  policy_arn = aws_iam_policy.extra_s3.arn
}

###############################################
# allow reading ALL our crawl parameters from SSM
###############################################
resource "aws_iam_policy" "glue_ssm_read" {
  name = "${var.delta_upsert_job_name}-ssm-read"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action = ["ssm:GetParameter", "ssm:GetParameters"],
        Resource = "arn:aws:ssm:*:${local.account_id}:parameter/crawl/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "glue_ssm_read_attach" {
  role       = aws_iam_role.glue_job.name
  policy_arn = aws_iam_policy.glue_ssm_read.arn
}

###############################################
# Glue role → DynamoDB:PutItem on table ImportData
###############################################
resource "aws_iam_policy" "dynamodb_import_write" {
  name = "${var.delta_upsert_job_name}-ddb-import-write"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = "dynamodb:PutItem",
        Resource = "arn:aws:dynamodb:us-east-1:${local.account_id}:table/ImportData"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "dynamodb_import_write_attach" {
  role       = aws_iam_role.glue_job.name
  policy_arn = aws_iam_policy.dynamodb_import_write.arn
}

###############################################
# Glue role → S3 for shuffle offload
###############################################
resource "aws_iam_policy" "glue_s3_full_access" {
  name = "${var.delta_upsert_job_name}-s3-full-access"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      # ── Object-level permissions (everything under the buckets) ────────────
      {
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ],
        Resource = [
          "arn:aws:s3:::linxact/*",
          "arn:aws:s3:::linxact-glue-shuffle/*"
        ]
      },

      # ── Bucket-level permissions (needed for list / location) ─────────────
      {
        Effect = "Allow",
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ],
        Resource = [
          "arn:aws:s3:::linxact",
          "arn:aws:s3:::linxact-glue-shuffle"
        ]
      }
    ]
  })
}


resource "aws_iam_role_policy_attachment" "glue_s3_shuffle_attach" {
  role       = aws_iam_role.glue_job.name
  policy_arn = aws_iam_policy.glue_s3_full_access.arn
}

#################
# 2. Glue job definition
#################
resource "aws_glue_job" "job" {
  name = var.delta_upsert_job_name
  role_arn = aws_iam_role.glue_job.arn

  command {
    script_location = "s3://${var.s3_bucket}/${local.script_key}"
    python_version  = "3"
  }

  glue_version = "5.0"   # Spark 3.4 & Delta 2.x
  worker_type = "G.8X"
  number_of_workers = 10

  default_arguments = {
    # your existing args
    "--s3bucket"         = var.s3_bucket
    "--coalesce"         = var.delta_upsert_coalesce
    "--stage"            = var.delta_upsert_stage
    "--target_file_size" = var.delta_upsert_target_file_size
    "--TempDir"          = "s3a://${var.s3_bucket}/temp/"
    "--updatePath"       = "s3://raw-bucket/incoming/${timestamp()}/"
    "--deltaPath"        = "s3://lakehouse/delta/"
    "--mergeKey"         = "order_id"
    "--job-language"     = "python"
    "--datalake-formats" = "delta"
    "--additional-python-modules" = "delta-spark==3.3.0"
    "--user-jars-first"  = "true"

    # === Offload shuffle to S3 ===
    # "--write-shuffle-files-to-s3"  = "true"

    # ─── ENABLE SPARK UI & CONTINUOUS LOGGING ───
    "--enable-metrics"  = "true"
    "--enable-spark-ui" = "true"
    "--enable-continuous-cloudwatch-log" = "true"

    # Path in S3 where Spark event logs will be written for the UI to pick up
    "--spark-event-logs-path" = "s3://${var.s3_bucket}/spark-event-logs/"

    "--TempDir" = "s3://${var.s3_bucket}/temp/"

    # Spark config to point at our shuffle bucket/prefix
    "--conf" = "spark.sql.extensions=io.delta.sql.DeltaSparkSessionExtension --conf spark.sql.catalog.spark_catalog=org.apache.spark.sql.delta.catalog.DeltaCatalog --conf spark.delta.logStore.class=org.apache.spark.sql.delta.storage.S3SingleDriverLogStore --conf spark.sql.adaptive.enabled=true --conf spark.sql.adaptive.coalescePartitions.enabled=true --conf spark.driver.maxResultSize=4g --conf spark.shuffle.glue.s3ShuffleBucket=s3://linxact-glue-shuffle/shuffle-data/ --conf spark.ui.retainedStages=2500 --conf spark.sql.adaptive.localShuffleReader.enabled=false --conf spark.shuffle.readHostLocalDisk=false --conf spark.driver.extraClassPath=s3://aws-glue-etl-artifacts/release/com/amazonaws/chopper-plugin/3.3-amzn-LATEST.jar --conf spark.executor.extraClassPath=s3://aws-glue-etl-artifacts/release/com/amazonaws/chopper-plugin/3.3-amzn-LATEST.jar --conf spark.sql.shuffle.partitions=128 --conf spark.shuffle.reduceLocality.enabled=false"
  }

  depends_on = [aws_s3_object.script]
}

#################
# 3. (Optional) Schedule the job
#################
# resource "aws_glue_trigger" "daily" { … }
