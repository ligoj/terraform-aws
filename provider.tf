terraform {
  backend "s3" {
    region       = "eu-west-3"
    acl          = "bucket-owner-full-control"
    use_lockfile = true
  }
  # use_lockfile (S3 native locking) requires Terraform >= 1.10
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.profile
}
