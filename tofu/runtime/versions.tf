# Per-session stack (ADR-0031): everything that costs money by the hour.
# `tofu apply` at the start of a session, `tofu destroy` at the end. Reads the
# permanent foundation stack (VPC, subnets, route table) from its state.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }

  #   tofu init -backend-config="bucket=rokusec-tofu-state-<account id>"
  backend "s3" {
    key          = "runtime/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project = "rokusec"
      Stack   = "runtime"
    }
  }
}

# The cluster is created in this same apply, so the providers authenticate
# with a short-lived token from the AWS CLI rather than a kubeconfig file.
locals {
  exec_auth = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = local.exec_auth.api_version
    command     = local.exec_auth.command
    args        = local.exec_auth.args
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec = {
      api_version = local.exec_auth.api_version
      command     = local.exec_auth.command
      args        = local.exec_auth.args
    }
  }
}
