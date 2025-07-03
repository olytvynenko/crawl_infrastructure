terraform {

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.96"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.7.2"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0.6"
    }

    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3.5"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35.1"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17.0"
    }

    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19.0"
    }

  }

  required_version = "~> 1.12"
}

