##############################################################################
# 0. Terraform & AWS provider
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
# 1.  S3 bucket for pipeline artifacts
##############################################################################
resource "aws_s3_bucket" "pipeline_artifacts" {
  bucket        = "crawl-build-artifacts-${data.aws_caller_identity.this.account_id}"
  force_destroy = true
}

##############################################################################
# 2.  CodePipeline service role
##############################################################################
data "aws_iam_policy_document" "pipeline_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codepipeline" {
  name               = "crawl-build-pipeline-role"
  assume_role_policy = data.aws_iam_policy_document.pipeline_assume.json
}

resource "aws_iam_role_policy_attachment" "pipeline_full_access" {
  role       = aws_iam_role.codepipeline.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodePipeline_FullAccess"
}

resource "aws_iam_role_policy" "pipeline_codecommit_read" {
  name = "codecommit-readonly-for-pipeline"
  role = aws_iam_role.codepipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CodeCommitRead"
        Effect = "Allow"
        Action = [
          "codecommit:Get*",
          "codecommit:BatchGet*",
          "codecommit:GitPull",

          # needed for the Source action to create the source ZIP
          "codecommit:UploadArchive",
          "codecommit:GetUploadArchiveStatus"
        ]
        Resource = "arn:aws:codecommit:us-east-1:${data.aws_caller_identity.this.account_id}:linxact-crawler"
      }
    ]
  })
}

##############################################################################
# S3 access for the artifact bucket
##############################################################################
resource "aws_iam_role_policy" "pipeline_artifacts_s3" {
  name = "codepipeline-s3-artifacts"
  role = aws_iam_role.codepipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ArtifactBucketRW"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetObjectVersion",
          "s3:GetBucketLocation"
        ]
        Resource = [
          # objects inside bucket
          "${aws_s3_bucket.pipeline_artifacts.arn}/*",
          # (and optionally the bucket itself for GetBucketLocation)
          aws_s3_bucket.pipeline_artifacts.arn
        ]
      }
    ]
  })
}

##############################################################################
# CodeBuild: allow the pipeline to start builds & poll status
##############################################################################
locals {
  cb_project_arns = [
    "arn:aws:codebuild:us-east-1:${data.aws_caller_identity.this.account_id}:project/cluster-manager",
    "arn:aws:codebuild:us-east-1:${data.aws_caller_identity.this.account_id}:project/crawler-arm-build",
    "arn:aws:codebuild:us-east-1:${data.aws_caller_identity.this.account_id}:project/crawler-runner",
  ]
}

resource "aws_iam_role_policy" "pipeline_codebuild_invoke" {
  name = "codepipeline-start-codebuild"
  role = aws_iam_role.codepipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "StartAndPollBuilds"
        Effect = "Allow"
        Action = [
          "codebuild:StartBuild",
          "codebuild:BatchGetBuilds",
          "codebuild:BatchGetProjects"
        ]
        Resource = local.cb_project_arns
      }
    ]
  })
}


##############################################################################
# 3.  CodeBuild project names (variables)
##############################################################################
variable "cluster_manager_project" { default = "cluster-manager" }
variable "crawler_arm_build_project" { default = "crawler-arm-build" }
variable "crawler_runner_project" { default = "crawler-runner" }

##############################################################################
# 4.  CodePipeline (Source + 3 build stages + destroy)
##############################################################################
resource "aws_codepipeline" "crawl" {
  name     = "crawl-build-only"
  role_arn = aws_iam_role.codepipeline.arn

  artifact_store {
    location = aws_s3_bucket.pipeline_artifacts.bucket
    type     = "S3"
  }

  # ── Stage 0 – Source ────────────────────────────────────────────────────
  stage {
    name = "Source"

    action {
      name     = "FetchRepo"
      category = "Source"
      owner    = "AWS"
      provider = "CodeCommit"
      version  = "1"
      output_artifacts = ["SourceZip"]

      configuration = {
        RepositoryName = "linxact-crawler"
        BranchName     = "master"
      }
    }
  }

  # ── Stage 1 – create clusters ──────────────────────────────────────────
  stage {
    name = "ClusterCreate"

    action {
      name     = "ClusterManagerCreate"
      category = "Build"
      owner    = "AWS"
      provider = "CodeBuild"
      version  = "1"
      input_artifacts = ["SourceZip"]

      configuration = {
        ProjectName = var.cluster_manager_project
        EnvironmentVariables = jsonencode([
          { name = "ACTION", value = "create", type = "PLAINTEXT" }
        ])
      }
    }
  }

  # ── Stage 2 – build ARM image ──────────────────────────────────────────
  stage {
    name = "CrawlerArmBuild"

    action {
      name     = "CrawlerArmBuild"
      category = "Build"
      owner    = "AWS"
      provider = "CodeBuild"
      version  = "1"
      input_artifacts = ["SourceZip"]

      configuration = {
        ProjectName = var.crawler_arm_build_project
      }
    }
  }

  # ── Stage 3 – run crawler job ──────────────────────────────────────────
  stage {
    name = "CrawlerRunner"

    action {
      name     = "CrawlerRunner"
      category = "Build"
      owner    = "AWS"
      provider = "CodeBuild"
      version  = "1"
      input_artifacts = ["SourceZip"]

      configuration = {
        ProjectName = var.crawler_runner_project
      }
    }
  }

  # ── Stage 4 – destroy clusters ─────────────────────────────────────────
  stage {
    name = "ClusterDestroy"

    action {
      name     = "ClusterManagerDestroy"
      category = "Build"
      owner    = "AWS"
      provider = "CodeBuild"
      version  = "1"
      input_artifacts = ["SourceZip"]

      configuration = {
        ProjectName = var.cluster_manager_project
        EnvironmentVariables = jsonencode([
          { name = "ACTION", value = "destroy", type = "PLAINTEXT" }
        ])
      }
    }
  }
}
