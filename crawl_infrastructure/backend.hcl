bucket         = "linxact-terraform-state"
key            = "${var.backend_prefix}/${terraform.workspace}/terraform.tfstate"
region         = "us-east-1"
dynamodb_table = "terraform-locks"
encrypt        = true