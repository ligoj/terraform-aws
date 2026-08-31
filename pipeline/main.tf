locals {
  name         = "${var.application}-${var.environment}-deploy"
  state_region = var.state_region == "" ? var.region : var.state_region

  tags = {
    "Name" : local.name
    "APPLICATION" : var.application
    "ENVIRONMENT" : var.environment
    "MANAGED_BY" : "terraform"
  }
}

data "aws_caller_identity" "current" {}
