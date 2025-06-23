########################################################
# Glue Jobs Configuration
# - Delta Upsert Job (Glue 5.0)
# - Sitemap Seed Generator Job (Glue 5.0)
########################################################

data "aws_caller_identity" "current" {}

########################################################
# Local values
########################################################
locals {
  account_id         = data.aws_caller_identity.current.account_id
  delta_script_key = "${var.s3_prefix}/${var.wpapi_delta_upsert.job_name}/${filesha1(var.wpapi_delta_upsert.script_path)}.py"
  sitemap_script_key = "${var.s3_prefix}/${var.sitemap_generator.job_name}/${filesha1("${path.module}/${var.sitemap_generator.script_path}")}.py"
}

########################################################
# Upload scripts to S3
########################################################
resource "aws_s3_object" "delta_script" {
  bucket = var.s3_bucket
  key    = local.delta_script_key
  source = var.wpapi_delta_upsert.script_path
  etag = filemd5(var.wpapi_delta_upsert.script_path)
}

resource "aws_s3_object" "sitemap_script" {
  bucket       = var.s3_bucket
  key          = local.sitemap_script_key
  content = file("${path.module}/${var.sitemap_generator.script_path}")
  content_type = "text/plain"
  etag = filemd5("${path.module}/${var.sitemap_generator.script_path}")
}

########################################################
# Shared IAM policies
########################################################
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

# S3 access policy for both jobs
resource "aws_iam_policy" "glue_s3_access" {
  name = "glue-s3-access"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          "arn:aws:s3:::${var.s3_bucket}/*",
          "arn:aws:s3:::linxact-glue-shuffle/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          "arn:aws:s3:::${var.s3_bucket}",
          "arn:aws:s3:::linxact-glue-shuffle"
        ]
      }
    ]
  })
}

# SSM parameter access for crawl configuration
resource "aws_iam_policy" "glue_ssm_read" {
  name = "glue-ssm-read"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:aws:ssm:*:${local.account_id}:parameter/*"
      }
    ]
  })
}

# DynamoDB access for ImportData table (Delta job only)
resource "aws_iam_policy" "dynamodb_import_write" {
  name = "glue-dynamodb-import-write"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "dynamodb:PutItem"
        Resource = "arn:aws:dynamodb:us-east-1:${local.account_id}:table/ImportData"
      }
    ]
  })
}

########################################################
# Delta Upsert Job (Glue 5.0)
########################################################
resource "aws_iam_role" "delta_glue_job" {
  name = "${var.wpapi_delta_upsert.job_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume_glue.json
}

resource "aws_iam_role_policy_attachment" "delta_glue_managed" {
  role       = aws_iam_role.delta_glue_job.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy_attachment" "delta_s3_access" {
  role       = aws_iam_role.delta_glue_job.name
  policy_arn = aws_iam_policy.glue_s3_access.arn
}

resource "aws_iam_role_policy_attachment" "delta_ssm_read" {
  role       = aws_iam_role.delta_glue_job.name
  policy_arn = aws_iam_policy.glue_ssm_read.arn
}

resource "aws_iam_role_policy_attachment" "delta_dynamodb_write" {
  role       = aws_iam_role.delta_glue_job.name
  policy_arn = aws_iam_policy.dynamodb_import_write.arn
}

resource "aws_glue_job" "delta_upsert" {
  name = var.wpapi_delta_upsert.job_name
  role_arn = aws_iam_role.delta_glue_job.arn

  command {
    script_location = "s3://${var.s3_bucket}/${local.delta_script_key}"
    python_version  = "3"
  }

  glue_version      = var.wpapi_delta_upsert.glue_version
  worker_type       = var.wpapi_delta_upsert.worker_type
  number_of_workers = var.wpapi_delta_upsert.number_of_workers

  default_arguments = {
    "--s3bucket"                         = var.s3_bucket
    "--coalesce"         = var.wpapi_delta_upsert.coalesce
    "--stage"            = var.wpapi_delta_upsert.stage
    "--target_file_size" = var.wpapi_delta_upsert.target_file_size
    "--TempDir"          = "s3://${var.s3_bucket}/temp/"
    "--job-language"                     = "python"
    "--datalake-formats"                 = "delta"
    "--additional-python-modules"        = "delta-spark==3.3.0"
    "--user-jars-first"                  = "true"
    "--enable-metrics"                   = "true"
    "--enable-spark-ui"                  = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--spark-event-logs-path"            = "s3://${var.s3_bucket}/spark-event-logs/"
    "--conf"                             = "spark.sql.extensions=io.delta.sql.DeltaSparkSessionExtension --conf spark.sql.catalog.spark_catalog=org.apache.spark.sql.delta.catalog.DeltaCatalog --conf spark.delta.logStore.class=org.apache.spark.sql.delta.storage.S3SingleDriverLogStore --conf spark.sql.adaptive.enabled=true --conf spark.sql.adaptive.coalescePartitions.enabled=true --conf spark.driver.maxResultSize=4g --conf spark.shuffle.glue.s3ShuffleBucket=s3://linxact-glue-shuffle/shuffle-data/ --conf spark.ui.retainedStages=2500 --conf spark.sql.adaptive.localShuffleReader.enabled=false --conf spark.shuffle.readHostLocalDisk=false --conf spark.driver.extraClassPath=s3://aws-glue-etl-artifacts/release/com/amazonaws/chopper-plugin/3.3-amzn-LATEST.jar --conf spark.executor.extraClassPath=s3://aws-glue-etl-artifacts/release/com/amazonaws/chopper-plugin/3.3-amzn-LATEST.jar --conf spark.sql.shuffle.partitions=128 --conf spark.shuffle.reduceLocality.enabled=false"
  }

  depends_on = [aws_s3_object.delta_script]
}

########################################################
# Sitemap Seed Generator Job (Glue 5.0)
########################################################
resource "aws_iam_role" "sitemap_glue_job" {
  name               = "${var.sitemap_generator.job_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume_glue.json
}

resource "aws_iam_role_policy_attachment" "sitemap_glue_managed" {
  role       = aws_iam_role.sitemap_glue_job.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy_attachment" "sitemap_s3_access" {
  role       = aws_iam_role.sitemap_glue_job.name
  policy_arn = aws_iam_policy.glue_s3_access.arn
}

resource "aws_iam_role_policy_attachment" "sitemap_ssm_read" {
  role       = aws_iam_role.sitemap_glue_job.name
  policy_arn = aws_iam_policy.glue_ssm_read.arn
}

resource "aws_glue_job" "sitemap_seed_generator" {
  name     = var.sitemap_generator.job_name
  role_arn = aws_iam_role.sitemap_glue_job.arn

  command {
    script_location = "s3://${var.s3_bucket}/${local.sitemap_script_key}"
    python_version  = "3"
  }

  glue_version      = var.sitemap_generator.glue_version
  worker_type       = var.sitemap_generator.worker_type
  number_of_workers = var.sitemap_generator.number_of_workers

  default_arguments = {
    "--TempDir" = "s3://${var.s3_bucket}/temp/"
    "--job-language"                     = "python"
    "--enable-metrics"                   = "true"
    "--enable-spark-ui"                  = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--spark-event-logs-path"            = "s3://${var.s3_bucket}/spark-event-logs/"
  }

  depends_on = [aws_s3_object.sitemap_script]
}