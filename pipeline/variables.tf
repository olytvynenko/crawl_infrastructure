variable "base_aws_region" { default = "us-east-1" }

##############################################################################
#  ✨  CodeBuild project names
##############################################################################
variable "cluster_manager_project" { default = "cluster-manager" }
variable "crawler_arm_build_project" { default = "crawler-arm-build" }
variable "crawler_runner_project" { default = "crawler-runner" }
variable "exit_code_monitor_build_project" { default = "exit-code-monitor-build" }

variable "dataset_base" { default = "links/delta/dataset-2409/" }

# Data path configuration - can be overridden for testing
variable "data_path_prefix" {
  description = "Prefix for data paths (e.g., 'update' for production, 'test' for testing)"
  type        = string
  default     = "update"
}


variable "checkpoint_table" {
  description = "DynamoDB table for storing execution checkpoints"
  type        = string
  default     = "crawl-execution-checkpoints"
}


########################################################
#  ✨  Glue Jobs Variables
########################################################
variable "s3_bucket" { default = "linxact" }
variable "s3_prefix" { default = "glue-scripts" }

########################################################
#  ✨  Delta Upsert Job Configuration
########################################################
variable "wpapi_delta_upsert" {
  type = object({
    job_name          = string
    script_path       = string
    coalesce          = number
    stage             = string
    target_file_size  = number
    glue_version      = string
    worker_type       = string
    number_of_workers = number
  })

  default = {
    job_name          = "delta-upsert"
    script_path       = "spark/delta_upsert.py"
    coalesce          = 10
    stage             = "1"
    target_file_size  = 500
    glue_version      = "5.0"
    worker_type       = "G.8X"
    number_of_workers = 10
  }
}

########################################################
#  ✨  Sitemap Seed Generator Job Configuration
########################################################
variable "sitemap_generator" {
  type = object({
    job_name          = string
    script_path       = string
    stage = string
    glue_version      = string
    worker_type       = string
    number_of_workers = number
  })

  default = {
    job_name          = "sitemap-seed-generator"
    script_path       = "spark/sitemap_seed_generator.py"
    stage = "sm"
    glue_version      = "5.0"
    worker_type       = "G.1X"
    number_of_workers = 5
  }
}

###############################################################################
#  ✨  Parameters passed to kube_job.py
###############################################################################
variable "kube_jobs" {
  type = object({
    aws_region = string
    repo_name  = string
    branch     = string
  })
  default = {
    aws_region = "us-east-1"
    repo_name  = "kube-jobs"
    branch     = "master"
  }
}

###############################################################################
#  ✨  Input for the messanger
###############################################################################
variable "messenger_webhook_url" {
  description = "Incoming webhook URL for Slack/Teams/etc. Leave blank to disable."
  type        = string
  default     = ""
}


variable "tag_keys" {
  description = "Tag keys that the Lambda should look for on EC2 instances"
  type = list(string)
  default = ["eks:cluster-name", "karpenter.sh/discovery"]     # add or override in *.tfvars as needed
}

# S3 deletion scheduling variables

variable "s3_deletion_delay_seconds" {
  type = number
  description = "Seconds to wait before deleting S3 folders after cluster destruction"
  default = 259200  # 72 hours in seconds
}

variable "s3_deletion_check_delay_seconds" {
  type = number
  description = "Seconds to wait after scheduled deletion before checking if folders were deleted"
  default = 28800  # 8 hours in seconds
}





