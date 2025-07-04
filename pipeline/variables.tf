variable "base_aws_region" { default = "us-east-1" }

##############################################################################
#  ✨  CodeBuild project names
##############################################################################
variable "cluster_manager_project" { default = "cluster-manager" }
variable "crawler_arm_build_project" { default = "crawler-arm-build" }
variable "crawler_runner_project" { default = "crawler-runner" }

variable "dataset_base" { default = "links/delta/dataset-2409/" }
variable "seed_base" { default = "update/seed/" }
variable "results_base" { default = "update/results/" }

variable "checkpoint_table" {
  description = "DynamoDB table for storing execution checkpoints"
  type        = string
  default     = "crawl-execution-checkpoints"
}

variable "sitemap_seed_generator_project" {
  description = "Name of the sitemap seed generator Glue job"
  type        = string
  default     = "sitemap-seed-generator"
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
    script_path       = "scripts/delta_upsert.py"
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
    script_path       = "scripts/sitemap_seed_generator.py"
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

variable "ec2_tag_key" {
  description = "Optional tag key to mark instances that are subject to auto-deletion"
  type        = string
  default     = "AutoDelete"
}

variable "ec2_tag_value" {
  description = "Optional tag value to mark instances that are subject to auto-deletion"
  type        = string
  default     = "true"
}

variable "tag_keys" {
  description = "Tag keys that the Lambda should look for on EC2 instances"
  type = list(string)
  default = ["eks:cluster-name", "karpenter.sh/discovery"]     # add or override in *.tfvars as needed
}

###############################################################################
#  Crawler Credentials (to be stored in Parameter Store)
###############################################################################
variable "crawler_aws_access_key_id" {
  description = "AWS Access Key ID for crawler (stored in Parameter Store)"
  type        = string
  sensitive   = true
}

variable "crawler_aws_secret_access_key" {
  description = "AWS Secret Access Key for crawler (stored in Parameter Store)"
  type        = string
  sensitive   = true
}

variable "crawler_ip_abuse_check_key" {
  description = "IP Abuse Check API Key for crawler (stored in Parameter Store)"
  type        = string
  sensitive   = true
}




