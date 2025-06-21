##############################################################################
# 2. CodeBuild project names
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
# Glue Jobs Variables
########################################################
variable "s3_bucket" { default = "linxact" }
variable "s3_prefix" { default = "glue-scripts" }

########################################################
# Delta Upsert Job Configuration
########################################################
variable "delta_upsert" {
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
# Sitemap Seed Generator Job Configuration
########################################################
variable "sitemap_generator" {
  type = object({
    job_name          = string
    script_path       = string
    glue_version      = string
    worker_type       = string
    number_of_workers = number
  })

  default = {
    job_name          = "sitemap-seed-generator"
    script_path       = "scripts/sitemap_seed_generator.py"
    glue_version      = "5.0"
    worker_type       = "G.1X"
    number_of_workers = 5
  }
}


