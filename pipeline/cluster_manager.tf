###############################################################################
# IAM ROLE
###############################################################################

data "aws_iam_policy_document" "cb_assume" {
  statement {
    effect = "Allow"

    principals {
      type = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "cb_role" {
  name               = "codebuild-cluster-manager"
  assume_role_policy = data.aws_iam_policy_document.cb_assume.json
}

resource "aws_iam_role_policy_attachment" "cb_cluster_manager" {
  role       = aws_iam_role.cb_role.name
  policy_arn = aws_iam_policy.codebuild_cluster_manager.arn
}

resource "aws_iam_role_policy_attachment" "cb_source_access" {
  role       = aws_iam_role.cb_role.name
  policy_arn = aws_iam_policy.codebuild_source_access.arn
}

###############################################################################
# CODEBUILD PROJECT
###############################################################################

resource "aws_codebuild_project" "cluster_manager" {
  name         = "cluster-manager"
  description = "Creates EKS clusters to run crawler jobs"
  service_role = aws_iam_role.cb_role.arn

  # ────────────── source (update “type” & “location” if you use Bitbucket) ─────
  source {
    type      = "CODECOMMIT"
    location  = "https://git-codecommit.us-east-1.amazonaws.com/v1/repos/crawl-infrastructure"
    buildspec = "buildspec.yml"
  }

  # ────────────── build environment ────────────────────────────────────────────
  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:7.0"
    type         = "LINUX_CONTAINER"

    environment_variable {
      name  = "TF_STATE_BUCKET"
      value = "linxact-terraform-state"
    }
    environment_variable {
      name  = "TF_STATE_KEY"
      value = "cicd/terraform.tfstate"
    }
    environment_variable {
      name  = "TF_LOCK_TABLE"
      value = "terraform-locks"
    }
    environment_variable {
      name  = "ACTION"
      value = "plan"
    }
    environment_variable {
      name  = "CLUSTERS"
      value = "nv"
    }
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }
}
