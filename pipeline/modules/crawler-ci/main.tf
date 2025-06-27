########################################
# Helpers
########################################
data "aws_region" "current" {}
data "aws_partition" "this" {}
data "aws_caller_identity" "current" {}

locals {
  project_name = var.codebuild_project
}

########################################
# CodeBuild service role
########################################
data "aws_iam_policy_document" "assume_codebuild" {
  statement {
    effect = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cb_role" {
  name               = "${local.project_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume_codebuild.json
}

# Broad permissions for first run – tighten later if desired
resource "aws_iam_role_policy_attachment" "cb_admin" {
  role       = aws_iam_role.cb_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

########################################
# CodeBuild project
########################################
resource "aws_codebuild_project" "crawler_run" {
  name         = local.project_name
  description  = "Runs kube_job.py to launch crawler jobs on EKS clusters"
  service_role = aws_iam_role.cb_role.arn

  source {
    type            = "CODECOMMIT"
    location        = "https://git-codecommit.${data.aws_region.current.id}.amazonaws.com/v1/repos/${var.repo_name}"
    git_clone_depth = 1
  }

  environment {
    type         = "LINUX_CONTAINER"
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:7.0"
  }

  artifacts { type = "NO_ARTIFACTS" }
}
