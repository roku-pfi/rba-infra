# Permanent stack (ADR-0031): everything that costs ~nothing while idle and
# whose identity must survive the runtime being destroyed — the VPC, image
# repositories, the CloudFront names, the CI role, the budget alert.

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
  }

  # Bucket name carries the account id; pass it at init:
  #   tofu init -backend-config="bucket=rokusec-tofu-state-<account id>"
  backend "s3" {
    key          = "foundation/terraform.tfstate"
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
      Stack   = "foundation"
    }
  }
}
