###############################################################################
# 0. Terraform settings
###############################################################################
terraform {
  required_version = ">= 1.4"
}

###############################################################################
# Call the crawler-ci sub-module
###############################################################################
module "crawler_ci" {
  source = "./modules/crawler-ci"   # local path
  repo_name = var.kube_jobs.repo_name
  branch    = var.kube_jobs.branch
}

resource "aws_codecommit_repository" "kube_jobs" {
  repository_name = var.kube_jobs.repo_name
  description     = "Kubernetes job runner scripts"
}

locals {
  # Get all files but exclude .git and .idea directories
  all_files = fileset("${path.module}/kube-jobs", "**")
  filtered_files = [
    for f in local.all_files : f
    if !startswith(f, ".git/") && !startswith(f, ".idea/")
  ]
}

resource "null_resource" "sync_kube_jobs" {
  triggers = {
    files_hash = md5(join("", [
      for f in local.filtered_files :
      filemd5("${path.module}/kube-jobs/${f}")
    ]))
  }

  provisioner "local-exec" {
    command = "echo 'Step 1: Git init' && cd kube-jobs && git init"
  }

  provisioner "local-exec" {
    command = "echo 'Step 2: Configure user' && cd kube-jobs && git config user.email terraform@pipeline.local"
  }

  provisioner "local-exec" {
    command = "echo 'Step 3: Configure name' && cd kube-jobs && git config user.name Terraform-Pipeline"
  }

  provisioner "local-exec" {
    command = "echo 'Step 4: Add files' && cd kube-jobs && git add ."
  }

  provisioner "local-exec" {
    command = "echo 'Step 5: Check status' && cd kube-jobs && git status"
  }

  provisioner "local-exec" {
    command = "echo 'Step 6: Force commit' && cd kube-jobs && (git commit -m 'Sync-from-pipeline' || git commit --allow-empty -m 'Initial-commit')"
  }

  provisioner "local-exec" {
    command = "echo 'Step 7: Add remote' && cd kube-jobs && (git remote add origin https://git-codecommit.us-east-1.amazonaws.com/v1/repos/${var.kube_jobs.repo_name} || echo 'Remote exists')"
  }

  provisioner "local-exec" {
    command = "echo 'Step 8: Check AWS creds' && aws sts get-caller-identity"
  }

  provisioner "local-exec" {
    command = "echo 'Step 9: Force push to ${var.kube_jobs.branch}' && cd kube-jobs && git push --force-with-lease origin ${var.kube_jobs.branch}"
  }

  depends_on = [aws_codecommit_repository.kube_jobs]
}

###############################################################################
# Outputs
###############################################################################
output "codebuild_project_name" {
  description = "Name of the CodeBuild project that runs the crawler"
  value       = module.crawler_ci.codebuild_project_name
}

# output "debug_files_found" {
#   value = local.filtered_files
# }
#
# output "debug_current_hash" {
#   value = md5(join("", [
#     for f in local.filtered_files :
#       filemd5("${path.module}/kube-jobs/${f}")
#   ]))
# }
