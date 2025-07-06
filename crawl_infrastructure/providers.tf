provider "aws" {
  region = "us-east-1"
  alias  = "n_virginia"
}

provider "aws" {
  region = local.env[terraform.workspace]["region"]
}

# Static provider alias pointing at the state/lock region
provider "aws" {
  alias  = "state"
  region = "us-east-1"
}

provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster_ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", local.env[terraform.workspace]["region"]]
  }
}

provider "kubectl" {
  apply_retry_count      = 5
  host                   = local.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster_ca_certificate)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", local.env[terraform.workspace]["region"]]
  }
}

provider "helm" {
  kubernetes {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = base64decode(local.cluster_ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", local.env[terraform.workspace]["region"]]
    }
  }
}
