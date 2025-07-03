terraform {

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.96"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6.2"
      #       version = "~> 3.5.1"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0.5"
    }

    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3.4"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31.0"
      #       version = "~> 2.25.2"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14.0"
      #       version = "~> 2.12.1"
    }

    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14.0"
    }

  }

  required_version = "~> 1.12"
}

