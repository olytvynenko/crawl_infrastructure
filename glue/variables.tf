########################################################
# variables.tf – tweak these or wire them through TF Cloud
########################################################
variable "job_name" { default = "delta-upsert" }
variable "script_path" { default = "scripts/delta_upsert.py" }
variable "s3_bucket" { default = "linxact" }
# existing bucket
variable "s3_prefix" { default = "glue-scripts" }
variable "coalesce" { default = 10 }
variable "stage" { default = "1" }
variable "target_file_size" { default = 500 }