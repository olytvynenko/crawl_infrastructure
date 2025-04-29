# ─────────────────────────────────────────────────────────────────────────────
# 1. Existing remote-state bucket (read-only)
# ─────────────────────────────────────────────────────────────────────────────
data "aws_s3_bucket" "tf_state" {
  bucket = var.state_bucket_name
}

# If you still want Terraform to manage versioning / encryption / lifecycle
# **comment these blocks back in only after** you’ve run `terraform import`
# for the bucket.  Otherwise, just rely on whatever settings the bucket
# already has.

# ─────────────────────────────────────────────────────────────────────────────
# 2. Existing DynamoDB lock table (read-only)
# ─────────────────────────────────────────────────────────────────────────────
data "aws_dynamodb_table" "tf_locks" {
  name = var.lock_table_name
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Backend configuration (unchanged)
# ─────────────────────────────────────────────────────────────────────────────
terraform {
  backend "s3" {
    bucket         = "linxact-terraform-state"
    key            = "terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
