locals {
  repo_name = "my-codecommit-repo"   # or GitHub HTTPS URL
}

resource "aws_iam_role" "cb_role" {
  name               = "codebuild-cluster-manager"
  assume_role_policy = data.aws_iam_policy_document.cb_assume.json
}

data "aws_iam_policy_document" "cb_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { type = "Service" identifiers = ["codebuild.amazonaws.com"] }
  }
}

# permissions shortened for clarity
resource "aws_iam_role_policy_attachment" "cb_admin" {
  role       = aws_iam_role.cb_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_codebuild_project" "cluster_manager" {
  name         = "cluster-manager"
  service_role = aws_iam_role.cb_role.arn

  source {
    type      = "CODECOMMIT"
    location  = "https://git-codecommit.eu-central-1.amazonaws.com/v1/repos/${local.repo_name}"
    buildspec = "buildspec.yml"          # at repo root
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:7.0"
    type         = "LINUX_CONTAINER"

    environment_variable { name = "TF_STATE_BUCKET" value = "my-tfstate-bucket" }
    environment_variable { name = "TF_STATE_KEY"    value = "prod/terraform.tfstate" }
    environment_variable { name = "TF_LOCK_TABLE"   value = "tf-lock" }
    environment_variable { name = "ACTION"          value = "plan" }
    environment_variable { name = "CLUSTERS"        value = "nc" }
  }

  artifacts { type = "NO_ARTIFACTS" }
}
