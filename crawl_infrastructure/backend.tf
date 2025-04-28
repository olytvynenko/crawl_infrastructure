# ─────────────────────────────────────────────────────────────────────────────
# 2. State Bucket
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "tf_state" {
  bucket = var.state_bucket_name
}

# 2) Versioning as its own resource
resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# 3) Server-side encryption via its own resource
resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 4) Lifecycle rules via its own resource
resource "aws_s3_bucket_lifecycle_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  rule {
    id     = "keep-latest-5-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      days = 30
    }

    noncurrent_version_transition {
      days          = 7
      storage_class = "GLACIER"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. DynamoDB Lock Table
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_dynamodb_table" "tf_locks" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Terraform Backend Configuration
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

