##############################################################################
# 0. Terraform core & AWS provider
##############################################################################
terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "this" {}

##############################################################################
# 1. Optional S3 bucket for CodeBuild artifacts / logs
##############################################################################
resource "aws_s3_bucket" "pipeline_artifacts" {
  bucket        = "crawl-build-artifacts-${data.aws_caller_identity.this.account_id}"
  force_destroy = true
}

locals {
  cb_project_arns = [
    "arn:aws:codebuild:us-east-1:${data.aws_caller_identity.this.account_id}:project/${var.cluster_manager_project}",
    "arn:aws:codebuild:us-east-1:${data.aws_caller_identity.this.account_id}:project/${var.crawler_arm_build_project}",
    "arn:aws:codebuild:us-east-1:${data.aws_caller_identity.this.account_id}:project/${var.crawler_runner_project}",
  ]
  dataset_base = var.dataset_base
  seed_base    = var.seed_base
  results_base = var.results_base
  # Add checkpoint steps
  checkpoint_step = {
    Type     = "Task"
    Resource = "arn:aws:states:::dynamodb:putItem"
    Parameters = {
      TableName = var.checkpoint_table
      Item = {
        execution_id = { "S.$" = "$$.Execution.Name" }
        step_name = { "S.$" = "$$.State.Name" }
        timestamp = { "S.$" = "$$.State.EnteredTime" }
        status = { "S" = "COMPLETED" }
      }
    }
    ResultPath = null
  }
}

##############################################################################
# 3. IAM role for Step Functions
##############################################################################

data "aws_iam_policy_document" "sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sfn_role" {
  name               = "crawl-stepfn-role"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
}

resource "aws_iam_role_policy" "sfn_codebuild" {
  name = "start-codebuilds-and-events"
  role = aws_iam_role.sfn_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "codebuild:StartBuild",
          "codebuild:BatchGetBuilds",
          "codebuild:BatchGetProjects"
        ],
        Resource = local.cb_project_arns
      },
      {
        Sid    = "EventBridgeManagedRuleForSyncTasks",
        Effect = "Allow",
        Action = [
          "events:PutRule",
          "events:PutTargets",
          "events:DescribeRule"
        ],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = [
          "glue:StartJobRun",
          "glue:GetJobRun",
          "glue:GetJobRuns"
        ],
        Resource = [
          "arn:aws:glue:us-east-1:${data.aws_caller_identity.this.account_id}:job/delta-upsert",
          "arn:aws:glue:us-east-1:${data.aws_caller_identity.this.account_id}:job/sitemap-seed-generator"
        ]
      }
    ]
  })
}

##############################################################################
# DynamoDB table for storing execution state
##############################################################################

resource "aws_dynamodb_table" "execution_checkpoints" {
  name         = var.checkpoint_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "execution_id"
  range_key    = "step_name"

  attribute {
    name = "execution_id"
    type = "S"
  }

  attribute {
    name = "step_name"
    type = "S"
  }

  tags = {
    Name = "Crawl Execution Checkpoints"
  }
}

##############################################################################
# Enhanced IAM permissions for state management
##############################################################################
resource "aws_iam_role_policy" "sfn_state_management" {
  name = "state-management-permissions"
  role = aws_iam_role.sfn_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ],
        Resource = aws_dynamodb_table.execution_checkpoints.arn
      },
      {
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ],
        Resource = [
          aws_s3_bucket.pipeline_artifacts.arn,
          "${aws_s3_bucket.pipeline_artifacts.arn}/*"
        ]
      }
    ]
  })
}


##############################################################################
# 4. Step Functions state machine with unconditional destroy and conditional upsert
##############################################################################
locals {
  retry_specific = {
    ErrorEquals = ["CodeBuild.BuildFailed"]
    IntervalSeconds = 60
    BackoffRate     = 2.0
    MaxAttempts     = 3
  }

  retry_all = {
    ErrorEquals = ["States.ALL"]
    IntervalSeconds = 60
    BackoffRate     = 2.0
    MaxAttempts     = 3
  }

  # Complete enhanced state machine with all checkpoints
  enhanced_state_machine_definition = jsonencode({
    Comment = "Crawling pipeline with dynamic stage skipping",
    StartAt = "CheckCrawlerArmBuild",
    States = {
      CheckCrawlerArmBuild = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.stages.crawler_arm_build",
            BooleanEquals = false,
            Next          = "CheckClusterCreate"
          }
        ],
        Default = "CrawlerArmBuild"
      },

      CrawlerArmBuild = {
        Type     = "Task",
        Resource = "arn:aws:states:::codebuild:startBuild.sync",
        Parameters = {
          ProjectName = var.crawler_arm_build_project
        },
        ResultPath = null,
        Retry = [
          {
            ErrorEquals = ["States.TaskFailed"],
            IntervalSeconds = 30,
            MaxAttempts     = 3,
            BackoffRate     = 2.0
          }
        ],
        Catch = [
          {
            ErrorEquals = ["States.ALL"],
            Next = "HandleFailure"
          }
        ],
        Next = "CheckClusterCreate"
      },

      CheckClusterCreate = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.stages.cluster_create",
            BooleanEquals = false,
            Next          = "CheckCrawlWpapiHidden"
          }
        ],
        Default = "ClusterCreate"
      },

      ClusterCreate = {
        Type     = "Task",
        Resource = "arn:aws:states:::codebuild:startBuild.sync",
        Parameters = {
          ProjectName = var.cluster_manager_project,
          EnvironmentVariablesOverride = [
            { Name = "ACTION", Type = "PLAINTEXT", Value = "create" },
            { Name = "CLUSTERS", Type = "PLAINTEXT", Value = "nv" }
          ]
        },
        ResultPath = null,
        Retry = [
          {
            ErrorEquals = ["States.TaskFailed"],
            IntervalSeconds = 30,
            MaxAttempts     = 3,
            BackoffRate     = 2.0
          }
        ],
        Catch = [
          {
            ErrorEquals = ["States.ALL"],
            Next = "HandleFailure"
          }
        ],
        Next = "CheckCrawlWpapiHidden"
      },

      CheckCrawlWpapiHidden = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.stages.crawl_wpapi_hidden",
            BooleanEquals = false,
            Next          = "CheckCrawlWpapiNonHidden"
          }
        ],
        Default = "CrawlWpapiHidden"
      },

      CrawlWpapiHidden = {
        Type     = "Task",
        Resource = "arn:aws:states:::codebuild:startBuild.sync",
        Parameters = {
          ProjectName = var.crawler_runner_project,
          EnvironmentVariablesOverride = [
            { Name = "DATASET_TYPE", Type = "PLAINTEXT", Value = "h" },
            { Name = "WORKFLOW", Type = "PLAINTEXT", Value = "wordpress" },
            { Name = "SEED_PATH", Type = "PLAINTEXT", Value = "update/seed/${var.wpapi_delta_upsert.stage}/" },
            { Name = "OUT_PATH", Type = "PLAINTEXT", Value = "update/results/${var.wpapi_delta_upsert.stage}/" }
          ]
        },
        ResultPath = null,
        Retry = [
          {
            ErrorEquals = ["States.TaskFailed"],
            IntervalSeconds = 60,
            MaxAttempts     = 2,
            BackoffRate     = 2.0
          }
        ],
        Catch = [
          {
            ErrorEquals = ["States.ALL"],
            Next = "CheckClusterDestroy"
          }
        ],
        Next = "CheckCrawlWpapiNonHidden"
      },

      CheckCrawlWpapiNonHidden = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.stages.crawl_wpapi_non_hidden",
            BooleanEquals = false,
            Next          = "CheckCrawlSitemapHidden"
          }
        ],
        Default = "CrawlWpapiNonHidden"
      },

      CrawlWpapiNonHidden = {
        Type     = "Task",
        Resource = "arn:aws:states:::codebuild:startBuild.sync",
        Parameters = {
          ProjectName = var.crawler_runner_project,
          EnvironmentVariablesOverride = [
            { Name = "DATASET_TYPE", Type = "PLAINTEXT", Value = "nh" },
            { Name = "WORKFLOW", Type = "PLAINTEXT", Value = "wordpress" },
            { Name = "SEED_PATH", Type = "PLAINTEXT", Value = "update/seed/${var.wpapi_delta_upsert.stage}/" },
            { Name = "OUT_PATH", Type = "PLAINTEXT", Value = "update/results/${var.wpapi_delta_upsert.stage}/" }
          ]
        },
        ResultPath = null,
        Retry = [
          {
            ErrorEquals = ["States.TaskFailed"],
            IntervalSeconds = 60,
            MaxAttempts     = 2,
            BackoffRate     = 2.0
          }
        ],
        Catch = [
          {
            ErrorEquals = ["States.ALL"],
            Next = "CheckClusterDestroy"
          }
        ],
        Next = "CheckCrawlSitemapHidden"
      },

      CheckCrawlSitemapHidden = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.stages.crawl_sitemap_hidden",
            BooleanEquals = false,
            Next          = "CheckCrawlSitemapNonHidden"
          }
        ],
        Default = "CrawlSitemapHidden"
      },

      CrawlSitemapHidden = {
        Type     = "Task",
        Resource = "arn:aws:states:::codebuild:startBuild.sync",
        Parameters = {
          ProjectName = var.crawler_runner_project,
          EnvironmentVariablesOverride = [
            { Name = "DATASET_TYPE", Type = "PLAINTEXT", Value = "h" },
            { Name = "WORKFLOW", Type = "PLAINTEXT", Value = "sitemaps" },
            { Name = "SEED_PATH", Type = "PLAINTEXT", Value = "update/seed/sitemaps/" },
            { Name = "OUT_PATH", Type = "PLAINTEXT", Value = "update/results/sitemaps/" }
          ]
        },
        ResultPath = null,
        Retry = [
          {
            ErrorEquals = ["States.TaskFailed"],
            IntervalSeconds = 60,
            MaxAttempts     = 2,
            BackoffRate     = 2.0
          }
        ],
        Catch = [
          {
            ErrorEquals = ["States.ALL"],
            Next = "CheckClusterDestroy"
          }
        ],
        Next = "CheckCrawlSitemapNonHidden"
      },

      CheckCrawlSitemapNonHidden = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.stages.crawl_sitemap_non_hidden",
            BooleanEquals = false,
            Next = "CheckWpapiDeltaUpsert"
          }
        ],
        Default = "CrawlSitemapNonHidden"
      },

      CrawlSitemapNonHidden = {
        Type     = "Task",
        Resource = "arn:aws:states:::codebuild:startBuild.sync",
        Parameters = {
          ProjectName = var.crawler_runner_project,
          EnvironmentVariablesOverride = [
            { Name = "DATASET_TYPE", Type = "PLAINTEXT", Value = "nh" },
            { Name = "WORKFLOW", Type = "PLAINTEXT", Value = "sitemaps" },
            { Name = "SEED_PATH", Type = "PLAINTEXT", Value = "update/seed/sitemaps/" },
            { Name = "OUT_PATH", Type = "PLAINTEXT", Value = "update/results/sitemaps/" }
          ]
        },
        ResultPath = null,
        Retry = [
          {
            ErrorEquals = ["States.TaskFailed"],
            IntervalSeconds = 60,
            MaxAttempts     = 2,
            BackoffRate     = 2.0
          }
        ],
        Catch = [
          {
            ErrorEquals = ["States.ALL"],
            Next = "CheckClusterDestroy"
          }
        ],
        Next = "CheckWpapiDeltaUpsert"
      },

      CheckWpapiDeltaUpsert = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.stages.delta_upsert",
            BooleanEquals = false,
            Next = "CheckGenerateSitemapSeeds"
          }
        ],
        Default = "WpapiDeltaUpsert"
      },

      WpapiDeltaUpsert = {
        Type     = "Task",
        Resource = "arn:aws:states:::glue:startJobRun.sync",
        Parameters = {
          JobName = var.wpapi_delta_upsert.job_name,
          Arguments = {
            "--stage" = var.wpapi_delta_upsert.stage,
            "--coalesce" = tostring(var.wpapi_delta_upsert.coalesce),
            "--target_file_size" = tostring(var.wpapi_delta_upsert.target_file_size)
          }
        },
        ResultPath = null,
        Catch = [
          {
            ErrorEquals = ["States.ALL"],
            Next = "CheckClusterDestroy"
          }
        ],
        Next = "CheckGenerateSitemapSeeds"
      },

      CheckGenerateSitemapSeeds = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.stages.generate_sitemap_seeds",
            BooleanEquals = false,
            Next          = "CheckCrawlUrlsHidden"
          }
        ],
        Default = "GenerateSitemapSeeds"
      },

      GenerateSitemapSeeds = {
        Type     = "Task",
        Resource = "arn:aws:states:::glue:startJobRun.sync",
        Parameters = {
          JobName = var.sitemap_generator.job_name,
          Arguments = {
            "--in_path"  = "update/results/sitemaps/",
            "--out_path" = "update/seed/${var.sitemap_generator.stage}/"
          }
        },
        ResultPath = null,
        Retry = [
          {
            ErrorEquals = ["States.TaskFailed"],
            IntervalSeconds = 30,
            MaxAttempts     = 3,
            BackoffRate     = 2.0
          }
        ],
        Catch = [
          {
            ErrorEquals = ["States.ALL"],
            Next = "CheckClusterDestroy"
          }
        ],
        Next = "CheckCrawlUrlsHidden"  # or whatever the next stage should be
      },

      CheckCrawlUrlsHidden = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.stages.crawl_urls_hidden",
            BooleanEquals = false,
            Next          = "CheckCrawlUrlsNonHidden"
          }
        ],
        Default = "CrawlUrlsHidden"
      },

      CrawlUrlsHidden = {
        Type     = "Task",
        Resource = "arn:aws:states:::codebuild:startBuild.sync",
        Parameters = {
          ProjectName = var.crawler_runner_project,
          EnvironmentVariablesOverride = [
            { Name = "DATASET_TYPE", Type = "PLAINTEXT", Value = "h" },
            { Name = "WORKFLOW", Type = "PLAINTEXT", Value = "links" },
            { Name = "SEED_PATH", Type = "PLAINTEXT", Value = "update/seed/sm/" },
            { Name = "OUT_PATH", Type = "PLAINTEXT", Value = "update/results/sm/" }
          ]
        },
        ResultPath = null,
        Retry = [
          {
            ErrorEquals = ["States.TaskFailed"],
            IntervalSeconds = 30,
            MaxAttempts     = 2,
            BackoffRate     = 2.0
          }
        ],
        Catch = [
          {
            ErrorEquals = ["States.ALL"],
            Next = "CheckCrawlUrlsNonHidden"
          }
        ],
        Next = "CheckCrawlUrlsNonHidden"
      },

      CheckCrawlUrlsNonHidden = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.stages.crawl_urls_non_hidden",
            BooleanEquals = false,
            Next = "CheckSitemapsDeltaUpsert"
          }
        ],
        Default = "CrawlUrlsNonHidden"
      },

      CrawlUrlsNonHidden = {
        Type     = "Task",
        Resource = "arn:aws:states:::codebuild:startBuild.sync",
        Parameters = {
          ProjectName = var.crawler_runner_project,
          EnvironmentVariablesOverride = [
            { Name = "DATASET_TYPE", Type = "PLAINTEXT", Value = "nh" },
            { Name = "WORKFLOW", Type = "PLAINTEXT", Value = "links" },
            { Name = "SEED_PATH", Type = "PLAINTEXT", Value = "update/seed/sm/" },
            { Name = "OUT_PATH", Type = "PLAINTEXT", Value = "update/results/sm/" }
          ]
        },
        ResultPath = null,
        Retry = [
          {
            ErrorEquals = ["States.TaskFailed"],
            IntervalSeconds = 30,
            MaxAttempts     = 2,
            BackoffRate     = 2.0
          }
        ],
        Catch = [
          {
            ErrorEquals = ["States.ALL"],
            Next = "CheckClusterDestroy"
          }
        ],
        Next = "CheckSitemapsDeltaUpsert"
      },

      CheckSitemapsDeltaUpsert = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.stages.sitemaps_delta_upsert",
            BooleanEquals = false,
            Next          = "CheckClusterDestroy"
          }
        ],
        Default = "SitemapsDeltaUpsert"
      },

      SitemapsDeltaUpsert = {
        Type     = "Task",
        Resource = "arn:aws:states:::glue:startJobRun.sync",
        Parameters = {
          JobName = var.wpapi_delta_upsert.job_name,
          Arguments = {
            "--stage" = "sm",
            "--coalesce" = tostring(var.wpapi_delta_upsert.coalesce),
            "--target_file_size" = tostring(var.wpapi_delta_upsert.target_file_size)
          }
        },
        ResultPath = null,
        Catch = [
          {
            ErrorEquals = ["States.ALL"],
            Next = "CheckClusterDestroy"
          }
        ],
        Next = "CheckClusterDestroy"
      },

      CheckClusterDestroy = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.stages.cluster_destroy",
            BooleanEquals = false,
            Next          = "Success"
          }
        ],
        Default = "ClusterDestroy"
      },

      ClusterDestroy = {
        Type     = "Task",
        Resource = "arn:aws:states:::codebuild:startBuild.sync",
        Parameters = {
          ProjectName = var.cluster_manager_project,
          EnvironmentVariablesOverride = [
            { Name = "ACTION", Type = "PLAINTEXT", Value = "destroy" },
            { Name = "CLUSTERS", Type = "PLAINTEXT", Value = "nv" }
          ]
        },
        ResultPath = null,
        Retry = [
          {
            ErrorEquals = ["States.TaskFailed"],
            IntervalSeconds = 30,
            MaxAttempts     = 3,
            BackoffRate     = 2.0
          }
        ],
        Next = "Success"
      },

      Success = {
        Type = "Succeed"
      },

      HandleFailure = {
        Type  = "Fail",
        Cause = "Pipeline execution failed"
      }
    }
  })
}


resource "aws_sfn_state_machine" "crawl" {
  name       = "crawl-build-state-machine"
  role_arn   = aws_iam_role.sfn_role.arn
  definition = local.enhanced_state_machine_definition
}

##############################################################################
# 5. Outputs
##############################################################################
output "state_machine_arn" {
  value       = aws_sfn_state_machine.crawl.arn
  description = "Run with: aws stepfunctions start-execution --state-machine-arn <ARN>"
}
