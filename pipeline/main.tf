##############################################################################
#  ✨  Terraform core & AWS provider
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
#  ✨  Optional S3 bucket for CodeBuild artifacts / logs
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
#  ✨  IAM role for Step Functions
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
#  ✨  Allow Step-Functions to invoke the new Lambda
##############################################################################
resource "aws_iam_role_policy" "sfn_invoke_lambda" {
  name = "invoke-check-termination-lambda"
  role = aws_iam_role.sfn_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action = ["lambda:InvokeFunction"],
        Resource = aws_lambda_function.check_resource_termination.arn
      },
      {
        Effect   = "Allow",
        Action = ["lambda:InvokeFunction"],
        Resource = aws_lambda_function.check_s3_deletions.arn
      },
      {
        Effect   = "Allow",
        Action = ["lambda:InvokeFunction"],
        Resource = aws_lambda_function.stage_notification.arn
      },
      {
        Effect   = "Allow",
        Action = ["lambda:InvokeFunction"],
        Resource = aws_lambda_function.schedule_s3_deletion.arn
      },
      {
        Effect   = "Allow",
        Action = ["ses:SendEmail", "ses:SendRawEmail"],
        Resource = "*"
      }
    ]
  })
}


##############################################################################
#  ✨  DynamoDB table for storing execution state
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
#  ✨  Enhanced IAM permissions for state management
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
          "s3:ListBucket",
          "s3:DeleteObject",
          "s3:DeleteObjects"
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
#  ✨  Step Functions state machine with unconditional destroy and conditional upsert
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
    StartAt = "CheckNotificationsForStart",
    States = {
      CheckNotificationsForStart = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.notifications_enabled",
            BooleanEquals = false,
            Next          = "CheckCrawlerArmBuild"
          }
        ],
        Default = "NotifyPipelineStart"
      },

      NotifyPipelineStart = {
        Type     = "Task",
        Resource = "arn:aws:states:::lambda:invoke",
        Parameters = {
          FunctionName = aws_lambda_function.stage_notification.arn,
          Payload = {
            "stage_name" = "PipelineStart",
            "status" = "STARTED",
            "details" = {
              "message" = "Pipeline execution started",
              "stages" = "$.stages"
            }
          }
        },
        ResultPath = null,
        Next = "CheckCrawlerArmBuild"
      },

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
        Next = "CheckNotificationsForClusterCreate"
      },

      CheckNotificationsForClusterCreate = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.notifications_enabled",
            BooleanEquals = false,
            Next          = "CheckCrawlWpapiHidden"
          }
        ],
        Default = "NotifyClusterCreateSuccess"
      },

      NotifyClusterCreateSuccess = {
        Type     = "Task",
        Resource = "arn:aws:states:::lambda:invoke",
        Parameters = {
          FunctionName = aws_lambda_function.stage_notification.arn,
          Payload = {
            "stage_name" = "ClusterCreate",
            "status" = "SUCCESS",
            "admin_only" = true,
            "details" = {
              "message" = "EKS cluster created successfully",
              "action" = "create",
              "resource" = "cluster"
            }
          }
        },
        ResultPath = null,
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
        ResultPath = "$.crawl_result",
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
            ResultPath = "$.error_info",
            Next = "CheckNotificationsForCrawlWpapiHiddenFailure"
          }
        ],
        Next = "CheckNotificationsForCrawlWpapiHidden"
      },

      CheckNotificationsForCrawlWpapiHidden = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.notifications_enabled",
            BooleanEquals = false,
            Next          = "CheckCrawlWpapiNonHidden"
          }
        ],
        Default = "NotifyCrawlWpapiHiddenSuccess"
      },

      NotifyCrawlWpapiHiddenSuccess = {
        Type     = "Task",
        Resource = "arn:aws:states:::lambda:invoke",
        Parameters = {
          FunctionName = aws_lambda_function.stage_notification.arn,
          Payload = {
            stage_name = "CrawlWpapiHidden",
            status = "SUCCESS",
            details = {
              dataset_type = "h",
              workflow = "wordpress",
              message = "WordPress API hidden content crawl completed successfully"
            }
          }
        },
        ResultPath = null,
        Retry = [
          {
            ErrorEquals = ["States.TaskFailed"],
            IntervalSeconds = 2,
            MaxAttempts     = 2,
            BackoffRate     = 1.5
          }
        ],
        Next = "CheckCrawlWpapiNonHidden"
      },

      CheckNotificationsForCrawlWpapiHiddenFailure = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.notifications_enabled",
            BooleanEquals = false,
            Next          = "HandleFailure"
          }
        ],
        Default = "NotifyCrawlWpapiHiddenFailure"
      },

      NotifyCrawlWpapiHiddenFailure = {
        Type     = "Task",
        Resource = "arn:aws:states:::lambda:invoke",
        Parameters = {
          FunctionName = aws_lambda_function.stage_notification.arn,
          Payload = {
            stage_name = "CrawlWpapiHidden",
            status = "FAILED",
            "error.$" = "$.error_info.Error",
            details = {
              dataset_type = "h",
              workflow = "wordpress",
              message = "WordPress API hidden content crawl failed"
            }
          }
        },
        ResultPath = null,
        Retry = [
          {
            ErrorEquals = ["States.TaskFailed"],
            IntervalSeconds = 2,
            MaxAttempts     = 2,
            BackoffRate     = 1.5
          }
        ],
        Next = "CheckClusterDestroy"
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
        ResultPath = "$.crawl_result",
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
            ResultPath = "$.error_info",
            Next = "NotifyCrawlWpapiNonHiddenFailure"
          }
        ],
        Next = "NotifyCrawlWpapiNonHiddenSuccess"
      },

      NotifyCrawlWpapiNonHiddenSuccess = {
        Type     = "Task",
        Resource = "arn:aws:states:::lambda:invoke",
        Parameters = {
          FunctionName = aws_lambda_function.stage_notification.arn,
          Payload = {
            stage_name = "CrawlWpapiNonHidden",
            status = "SUCCESS",
            details = {
              dataset_type = "nh",
              workflow = "wordpress",
              message = "WordPress API non-hidden content crawl completed successfully"
            }
          }
        },
        ResultPath = null,
        Retry = [
          {
            ErrorEquals = ["States.TaskFailed"],
            IntervalSeconds = 2,
            MaxAttempts     = 2,
            BackoffRate     = 1.5
          }
        ],
        Next = "CheckCrawlSitemapHidden"
      },

      NotifyCrawlWpapiNonHiddenFailure = {
        Type     = "Task",
        Resource = "arn:aws:states:::lambda:invoke",
        Parameters = {
          FunctionName = aws_lambda_function.stage_notification.arn,
          Payload = {
            stage_name = "CrawlWpapiNonHidden",
            status = "FAILED",
            "error.$" = "$.error_info.Error",
            details = {
              dataset_type = "nh",
              workflow = "wordpress",
              message = "WordPress API non-hidden content crawl failed"
            }
          }
        },
        ResultPath = null,
        Retry = [
          {
            ErrorEquals = ["States.TaskFailed"],
            IntervalSeconds = 2,
            MaxAttempts     = 2,
            BackoffRate     = 1.5
          }
        ],
        Next = "CheckClusterDestroy"
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
        Next = "CheckNotificationsForCrawlSitemapHidden"
      },

      CheckNotificationsForCrawlSitemapHidden = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.notifications_enabled",
            BooleanEquals = false,
            Next          = "CheckCrawlSitemapNonHidden"
          }
        ],
        Default = "NotifyCrawlSitemapHiddenSuccess"
      },

      NotifyCrawlSitemapHiddenSuccess = {
        Type     = "Task",
        Resource = "arn:aws:states:::lambda:invoke",
        Parameters = {
          FunctionName = aws_lambda_function.stage_notification.arn,
          Payload = {
            "stage_name" = "CrawlSitemapHidden",
            "status" = "SUCCESS",
            "details" = {
              "dataset_type" = "h",
              "workflow" = "sitemaps",
              "message" = "Sitemap hidden content crawl completed successfully"
            }
          }
        },
        ResultPath = null,
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
        Next = "CheckNotificationsForCrawlSitemapNonHidden"
      },

      CheckNotificationsForCrawlSitemapNonHidden = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.notifications_enabled",
            BooleanEquals = false,
            Next          = "CheckWpapiDeltaUpsert"
          }
        ],
        Default = "NotifyCrawlSitemapNonHiddenSuccess"
      },

      NotifyCrawlSitemapNonHiddenSuccess = {
        Type     = "Task",
        Resource = "arn:aws:states:::lambda:invoke",
        Parameters = {
          FunctionName = aws_lambda_function.stage_notification.arn,
          Payload = {
            "stage_name" = "CrawlSitemapNonHidden",
            "status" = "SUCCESS",
            "details" = {
              "dataset_type" = "nh",
              "workflow" = "sitemaps",
              "message" = "Sitemap non-hidden content crawl completed successfully"
            }
          }
        },
        ResultPath = null,
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
        Next = "CheckNotificationsForCrawlUrlsHidden"
      },

      CheckNotificationsForCrawlUrlsHidden = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.notifications_enabled",
            BooleanEquals = false,
            Next          = "CheckCrawlUrlsNonHidden"
          }
        ],
        Default = "NotifyCrawlUrlsHiddenSuccess"
      },

      NotifyCrawlUrlsHiddenSuccess = {
        Type     = "Task",
        Resource = "arn:aws:states:::lambda:invoke",
        Parameters = {
          FunctionName = aws_lambda_function.stage_notification.arn,
          Payload = {
            "stage_name" = "CrawlUrlsHidden",
            "status" = "SUCCESS",
            "details" = {
              "dataset_type" = "h",
              "workflow" = "urls",
              "message" = "URL hidden content crawl completed successfully"
            }
          }
        },
        ResultPath = null,
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
        Next = "CheckNotificationsForCrawlUrlsNonHidden"
      },

      CheckNotificationsForCrawlUrlsNonHidden = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.notifications_enabled",
            BooleanEquals = false,
            Next          = "CheckSitemapsDeltaUpsert"
          }
        ],
        Default = "NotifyCrawlUrlsNonHiddenSuccess"
      },

      NotifyCrawlUrlsNonHiddenSuccess = {
        Type     = "Task",
        Resource = "arn:aws:states:::lambda:invoke",
        Parameters = {
          FunctionName = aws_lambda_function.stage_notification.arn,
          Payload = {
            "stage_name" = "CrawlUrlsNonHidden",
            "status" = "SUCCESS",
            "details" = {
              "dataset_type" = "nh",
              "workflow" = "urls",
              "message" = "URL non-hidden content crawl completed successfully"
            }
          }
        },
        ResultPath = null,
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
            Next = "CheckScheduleS3Deletion"
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
        Catch = [
          {
            ErrorEquals = ["States.ALL"],
            ResultPath = "$.error",
            Next = "CheckNotificationsForClusterDestroyFailure"
          }
        ],
        Next = "CheckNotificationsForClusterDestroy"
      },

      CheckNotificationsForClusterDestroy = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.notifications_enabled",
            BooleanEquals = false,
            Next          = "VerifyResourceTermination"
          }
        ],
        Default = "NotifyClusterDestroySuccess"
      },

      NotifyClusterDestroySuccess = {
        Type     = "Task",
        Resource = "arn:aws:states:::lambda:invoke",
        Parameters = {
          FunctionName = aws_lambda_function.stage_notification.arn,
          Payload = {
            "stage_name" = "ClusterDestroy",
            "status" = "SUCCESS",
            "admin_only" = true,
            "details" = {
              "message" = "EKS cluster destroyed successfully",
              "action" = "destroy",
              "resource" = "cluster"
            }
          }
        },
        ResultPath = null,
        Next = "CheckScheduleS3Deletion"
      },

      CheckNotificationsForClusterDestroyFailure = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.notifications_enabled",
            BooleanEquals = false,
            Next          = "CheckScheduleS3Deletion"
          }
        ],
        Default = "NotifyClusterDestroyFailure"
      },

      NotifyClusterDestroyFailure = {
        Type     = "Task",
        Resource = "arn:aws:states:::lambda:invoke",
        Parameters = {
          FunctionName = aws_lambda_function.stage_notification.arn,
          Payload = {
            "stage_name"  = "ClusterDestroy",
            "status"      = "FAILED",
            "admin_only"  = true,
            "error.$"     = "$.error.Error",
            "details" = {
              "message" = "EKS cluster destruction failed",
              "action"  = "destroy",
              "resource" = "cluster"
            }
          }
        },
        ResultPath = null,
        Next = "CheckScheduleS3Deletion"
      },

      CheckScheduleS3Deletion = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.stages.schedule_s3_deletion",
            BooleanEquals = false,
            Next = "VerifyResourceTermination"
          },
          {
            Variable      = "$.s3_deletion_config.enabled",
            BooleanEquals = false,
            Next = "VerifyResourceTermination"
          }
        ],
        Default = "ScheduleS3Deletion"
      },

      ScheduleS3Deletion = {
        Type     = "Task",
        Resource = "arn:aws:states:::lambda:invoke",
        Parameters = {
          FunctionName = aws_lambda_function.schedule_s3_deletion.arn,
          Payload = {
            "folders.$"              = "$.s3_deletion_config.folders",
            "deletion_delay_seconds.$" = "$.s3_deletion_config.deletion_delay_seconds",
            "check_delay_seconds.$"    = "$.s3_deletion_config.check_delay_seconds",
            "execution_id.$"           = "$$.Execution.Name"
          }
        },
        ResultPath = "$.s3_deletion_result",
        Catch = [
          {
            ErrorEquals = ["States.ALL"],
            ResultPath = "$.s3_deletion_error",
            Next = "CheckNotificationsForS3DeletionFailure"
          }
        ],
        Next = "CheckNotificationsForS3DeletionSuccess"
      },

      CheckNotificationsForS3DeletionSuccess = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.notifications_enabled",
            BooleanEquals = false,
            Next          = "VerifyResourceTermination"
          }
        ],
        Default = "NotifyS3DeletionScheduled"
      },

      NotifyS3DeletionScheduled = {
        Type     = "Task",
        Resource = "arn:aws:states:::lambda:invoke",
        Parameters = {
          FunctionName = aws_lambda_function.stage_notification.arn,
          Payload = {
            "stage_name" = "ScheduleS3Deletion",
            "status"     = "SUCCESS",
            "admin_only" = true,
            "details" = {
              "message"               = "S3 folder deletions scheduled successfully",
              "folders_count.$"       = "$.s3_deletion_result.Payload.details.folders_count",
              "deletion_scheduled_for.$" = "$.s3_deletion_result.Payload.details.deletion_scheduled_for",
              "check_scheduled_for.$"    = "$.s3_deletion_result.Payload.details.check_scheduled_for"
            }
          }
        },
        ResultPath = null,
        Next = "VerifyResourceTermination"
      },

      CheckNotificationsForS3DeletionFailure = {
        Type = "Choice",
        Choices = [
          {
            Variable      = "$.notifications_enabled",
            BooleanEquals = false,
            Next          = "VerifyResourceTermination"
          }
        ],
        Default = "NotifyS3DeletionFailed"
      },

      NotifyS3DeletionFailed = {
        Type     = "Task",
        Resource = "arn:aws:states:::lambda:invoke",
        Parameters = {
          FunctionName = aws_lambda_function.stage_notification.arn,
          Payload = {
            "stage_name"  = "ScheduleS3Deletion",
            "status"      = "FAILED",
            "admin_only"  = true,
            "error.$"     = "$.s3_deletion_error.Error",
            "details" = {
              "message" = "Failed to schedule S3 folder deletions"
            }
          }
        },
        ResultPath = null,
        Next = "VerifyResourceTermination"
      },

      VerifyResourceTermination = {
        Type     = "Task",
        Resource = "arn:aws:states:::lambda:invoke",
        Parameters = {
          FunctionName = aws_lambda_function.check_resource_termination.arn,
          Payload = {}
        },
        ResultPath = null,
        Next       = "Success"
      }

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
#  ✨  Outputs
##############################################################################
output "state_machine_arn" {
  value       = aws_sfn_state_machine.crawl.arn
  description = "Run with: aws stepfunctions start-execution --state-machine-arn <ARN>"
}
