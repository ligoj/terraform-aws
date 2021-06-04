terraform {
  backend "s3" {
    region  = "eu-west-1"
    profile = "ligoj"
  }
  required_version = "~>0.15"
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "3.40.0"
    }
    random = {
      version = "= 2.3.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.profile
}

provider "aws" {
  region  = "us-east-1"
  alias   = "use1"
  profile = var.profile
}
