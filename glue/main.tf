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
  script_key = "${var.s3_prefix}/${var.job_name}/${filesha1(var.script_path)}.py"
  account_id = data.aws_caller_identity.current.account_id
}

resource "aws_s3_object" "script" {
  bucket = var.s3_bucket
  key    = local.script_key
  source = var.script_path                  # file on your laptop / CI runner
  etag = filemd5(var.script_path)         # forces new upload when the file changes
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
  name               = "${var.job_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume_glue.json
}

# Managed Glue service role + S3 access for script/temp/output
resource "aws_iam_role_policy_attachment" "glue_managed" {
  role       = aws_iam_role.glue_job.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_policy" "extra_s3" {
  name = "${var.job_name}-s3"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
        Resource = [
          "arn:aws:s3:::${var.s3_bucket}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "extra_s3" {
  role       = aws_iam_role.glue_job.name
  policy_arn = aws_iam_policy.extra_s3.arn
}

###############################################
# after the extra_s3 attachment
###############################################
resource "aws_iam_policy" "glue_ssm_read" {
  name = "${var.job_name}-ssm-read"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = "ssm:GetParameter",
        Resource = [
          # exactly the three keys the script fetches
          "arn:aws:ssm:*:${local.account_id}:parameter/crawl/path/results",
          "arn:aws:ssm:*:${local.account_id}:parameter/crawl/path/dataset/delta",
          "arn:aws:ssm:*:${local.account_id}:parameter/crawl/import/id",
          "arn:aws:ssm:*:${local.account_id}:parameter/crawl/path/majestic",
          "arn:aws:ssm:*:${local.account_id}:parameter/crawl/path/ip_addresses",
          "arn:aws:ssm:*:${local.account_id}:parameter/crawl/dataset/current"
        ]
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
  name = "${var.job_name}-ddb-import-write"

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


#################
# 2. Glue job definition
#################
resource "aws_glue_job" "job" {
  name     = var.job_name
  role_arn = aws_iam_role.glue_job.arn

  command {
    # what Glue actually runs
    script_location = "s3://${var.s3_bucket}/${local.script_key}"
    python_version  = "3"
  }

  glue_version = "5.0"       # Spark 3.4 & Delta 2.x
  worker_type       = "G.2X"
  number_of_workers = 10
  execution_class = "FLEX"      # cheaper if the job can wait in queue

  default_arguments = {
    "--s3bucket"         = var.s3_bucket
    "--coalesce"         = var.coalesce
    "--stage"            = var.stage
    "--target_file_size" = var.target_file_size
    "--TempDir"          = "s3a://${var.s3_bucket}/temp/"
    "--updatePath"       = "s3://raw-bucket/incoming/${timestamp()}/"
    "--deltaPath"        = "s3://lakehouse/delta/"
    "--mergeKey"         = "order_id"
    "--job-language" = "python"

    # 1) Tell Glue to wire in Delta Lake support
    "--datalake-formats" = "delta"

    # 2) Pull in the matching Python wheel
    "--additional-python-modules" = "delta-spark==3.3.0"

    # 3) Ensure your wheel’s JARs land on the classpath first
    "--user-jars-first" = "true"

    # 4) Inject both static configs at job bootstrap
    "--conf" = "spark.sql.extensions=io.delta.sql.DeltaSparkSessionExtension --conf spark.sql.catalog.spark_catalog=org.apache.spark.sql.delta.catalog.DeltaCatalog --conf spark.delta.logStore.class=org.apache.spark.sql.delta.storage.S3SingleDriverLogStore --conf spark.sql.shuffle.partitions=200 --conf spark.sql.adaptive.enabled=true --conf spark.sql.adaptive.coalescePartitions.enabled=true --conf spark.driver.maxResultSize=2g"

    # ─── Force s3a to use the us-east-1 endpoint ───
    # "--conf" = "fs.s3a.endpoint=s3.us-east-1.amazonaws.com"
  }

  depends_on = [aws_s3_object.script]   # ensure the script is uploaded first
}

#################
# 3. (Optional) Schedule the job
#################
# resource "aws_glue_trigger" "daily" {
#   name     = "${var.job_name}-daily"
#   type     = "SCHEDULED"
#   schedule = "cron(0 2 * * ? *)"       # 02:00 UTC every day
#
#   actions {
#     job_name = aws_glue_job.job.name
#     arguments = {
#       "--updatePath" = "s3://raw-bucket/daily/${formatdate("YYYY-MM-dd", timestamp())}/"
#     }
#   }
# }
