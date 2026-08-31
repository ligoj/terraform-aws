resource "aws_cloudwatch_log_group" "build" {
  name              = "/codebuild/${local.name}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

# Common CodeBuild settings for the plan and apply projects
locals {
  build_env = {
    TF_VERSION      = var.terraform_version
    TF_STATE_BUCKET = var.state_bucket
    TF_STATE_KEY    = var.state_key
    TF_STATE_REGION = local.state_region
    TFVARS_S3_URI   = var.tfvars_s3_uri
  }
}

resource "aws_codebuild_project" "plan" {
  name          = "${local.name}-plan"
  description   = "terraform plan of ${var.repository}"
  service_role  = aws_iam_role.build.arn
  build_timeout = 30
  tags          = local.tags

  artifacts {
    type = "CODEPIPELINE"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "pipeline/buildspec-plan.yml"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"

    dynamic "environment_variable" {
      for_each = local.build_env
      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.build.name
      stream_name = "plan"
    }
  }
}

resource "aws_codebuild_project" "apply" {
  name          = "${local.name}-apply"
  description   = "terraform apply of ${var.repository}"
  service_role  = aws_iam_role.build.arn
  build_timeout = 60
  tags          = local.tags

  artifacts {
    type = "CODEPIPELINE"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "pipeline/buildspec-apply.yml"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"

    dynamic "environment_variable" {
      for_each = local.build_env
      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.build.name
      stream_name = "apply"
    }
  }
}
