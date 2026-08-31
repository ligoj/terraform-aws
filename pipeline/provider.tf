terraform {
  backend "s3" {
    region = "eu-west-1"
    acl    = "bucket-owner-full-control"
  }
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.profile
}
