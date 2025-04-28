terraform {
  backend "s3" {
    bucket         = "linxact-terraform-state"
    key            = "cicd/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}