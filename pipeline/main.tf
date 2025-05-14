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
# 1. (Optional) S3 bucket if you still need it for other artifacts
##############################################################################
resource "aws_s3_bucket" "pipeline_artifacts" {
  bucket        = "crawl-build-artifacts-${data.aws_caller_identity.this.account_id}"
  force_destroy = true
}

##############################################################################
# 2.  CodeBuild project names as variables
##############################################################################
variable "cluster_manager_project" { default = "cluster-manager" }
variable "crawler_arm_build_project" { default = "crawler-arm-build" }
variable "crawler_runner_project" { default = "crawler-runner" }

##############################################################################
# 3.  IAM role for Step Functions
##############################################################################
locals {
  cb_project_arns = [
    "arn:aws:codebuild:us-east-1:${data.aws_caller_identity.this.account_id}:project/${var.cluster_manager_project}",
    "arn:aws:codebuild:us-east-1:${data.aws_caller_identity.this.account_id}:project/${var.crawler_arm_build_project}",
    "arn:aws:codebuild:us-east-1:${data.aws_caller_identity.this.account_id}:project/${var.crawler_runner_project}",
  ]
}

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

# Extend / replace the inline policy attached to crawl-stepfn-role
resource "aws_iam_role_policy" "sfn_codebuild" {
  name = "start-codebuilds-and-events"
  role = aws_iam_role.sfn_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      # ---------- invoke CodeBuild & poll ----------
      {
        Effect = "Allow",
        Action = [
          "codebuild:StartBuild",
          "codebuild:BatchGetBuilds",
          "codebuild:BatchGetProjects"
        ],
        Resource = local.cb_project_arns
      },

      # ---------- allow Step Functions to create its EventBridge rule ----------
      {
        Sid    = "EventBridgeManagedRuleForSyncTasks"
        Effect = "Allow"
        Action = [
          "events:PutRule",
          "events:PutTargets",
          "events:DescribeRule"
        ]
        Resource = "*"
      }
    ]
  })
}

##############################################################################
# 4.  Step Functions state machine
##############################################################################
locals {
  state_machine_definition = jsonencode({
    Comment = "Create clusters → build image → run crawler → destroy clusters"
    StartAt = "ClusterCreate"
    States = {

      CrawlerArmBuild = {
        Type     = "Task"
        Resource = "arn:aws:states:::codebuild:startBuild.sync"
        Parameters = { ProjectName = var.crawler_arm_build_project }
        Catch = [
          { ErrorEquals = ["States.ALL"], Next = "ClusterDestroy" }
        ]
        Next = "ClusterCreate"
      }

      ClusterCreate = {
        Type     = "Task"
        Resource = "arn:aws:states:::codebuild:startBuild.sync"
        Parameters = {
          ProjectName = var.cluster_manager_project
          EnvironmentVariablesOverride = [
            { Name = "ACTION", Type = "PLAINTEXT", Value = "create" }
          ]
        }
        Catch = [
          { ErrorEquals = ["States.ALL"], Next = "ClusterDestroy" }
        ]
        Next = "CrawlerRunner"
      }

      CrawlerRunner = {
        Type     = "Task"
        Resource = "arn:aws:states:::codebuild:startBuild.sync"
        Parameters = { ProjectName = var.crawler_runner_project }
        Catch = [
          { ErrorEquals = ["States.ALL"], Next = "ClusterDestroy" }
        ]
        Next = "ClusterDestroy"
      }

      ClusterDestroy = {
        Type     = "Task"
        Resource = "arn:aws:states:::codebuild:startBuild.sync"
        Parameters = {
          ProjectName = var.cluster_manager_project
          EnvironmentVariablesOverride = [
            { Name = "ACTION", Type = "PLAINTEXT", Value = "destroy" }
          ]
        }
        End = true
      }
    }
  })
}

resource "aws_sfn_state_machine" "crawl" {
  name       = "crawl-build-state-machine"
  role_arn   = aws_iam_role.sfn_role.arn
  definition = local.state_machine_definition
}

##############################################################################
# 5.  Outputs
##############################################################################
output "state_machine_arn" {
  value       = aws_sfn_state_machine.crawl.arn
  description = "Run with: aws stepfunctions start-execution --state-machine-arn <ARN>"
}
