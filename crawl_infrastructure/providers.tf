provider "aws" {
  region = "us-east-1"
  alias  = "n_virginia"
}

provider "aws" {
  region = "us-east-2"
  alias  = "ohio"
}

provider "aws" {
  region = "us-west-2"
  alias  = "oregon"
}

provider "aws" {
  region = "us-west-1"
  alias  = "n_california"
}

provider "kubernetes" {
  config_path    = "C:\\Users\\olexi\\.kube\\config"
  config_context = "linxact-nv-us-east-1"
  alias          = "n_virginia"
}

provider "kubernetes" {
  config_path    = "C:\\Users\\olexi\\.kube\\config"
  config_context = "linxact-oh-us-east-2"
  alias          = "ohio"
}

provider "kubernetes" {
  config_path    = "C:\\Users\\olexi\\.kube\\config"
  config_context = "linxact-or-us-west-2"
  alias          = "oregon"
}

provider "kubernetes" {
  config_path    = "C:\\Users\\olexi\\.kube\\config"
  config_context = "linxact-nc-us-west-1"
  alias          = "n_california"
}

#provider "kubectl" {
#  apply_retry_count      = 5
#  host                   = module.eks_n_virginia.cluster_endpoint
#  cluster_ca_certificate = base64decode(module.eks_n_virginia.cluster_certificate_authority_data)
#  load_config_file       = false
#  exec {
#    api_version = "client.authentication.k8s.io/v1beta1"
#    command     = "aws"
#    args = ["eks", "get-token", "--cluster-name", module.eks_n_virginia.cluster_endpoint]
#  }
#  alias = "n_virginia"
#}

#provider "helm" {
#  kubernetes {
#    config_path     = "C:\\Users\\olexi\\.kube\\config"
#    config_context  = "linxact-nv-us-east-1"
#  }
#  alias             = "n_virginia"
#}

provider "helm" {
  kubernetes {
    host                   = module.eks_n_virginia.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_n_virginia.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks_n_virginia.cluster_name]
    }
  }
  alias = "n_virginia"
}

provider "helm" {
  kubernetes {
    config_path    = "C:\\Users\\olexi\\.kube\\config"
    config_context = "kub-linxact-oh-us-east-2"
  }
  alias = "ohio"
}

provider "helm" {
  kubernetes {
    config_path    = "C:\\Users\\olexi\\.kube\\config"
    config_context = "linxact-or-us-west-2"
  }
  alias = "oregon"
}

provider "helm" {
  kubernetes {
    config_path    = "C:\\Users\\olexi\\.kube\\config"
    config_context = "linxact-nc-us-west-1"
  }
  alias = "n_california"
}
