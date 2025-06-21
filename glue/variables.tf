########################################################
# variables.tf – tweak these or wire them through TF Cloud
########################################################
variable "s3_bucket" { default = "linxact" }
# existing bucket
variable "s3_prefix" { default = "glue-scripts" }

variable "delta_upsert_job_name" { default = "delta-upsert" }
variable "delta_upsert_script_path" { default = "scripts/delta_upsert.py" }
variable "delta_upsert_coalesce" { default = 10 }
variable "delta_upsert_stage" { default = "1" }
variable "delta_upsert_target_file_size" { default = 500 }