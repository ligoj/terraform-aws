# GitHub connection. Created in PENDING state: a one-time manual handshake in the
# console is required (Developer Tools > Connections > Update pending connection)
resource "aws_codeconnections_connection" "github" {
  name          = local.name
  provider_type = "GitHub"
  tags          = local.tags
}

# --- Artifact store --------------------------------------------------------
resource "aws_s3_bucket" "artifacts" {
  bucket_prefix = "${local.name}-artifacts-"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = var.log_retention_days
    }
  }
}

# --- Pipeline --------------------------------------------------------------
resource "aws_codepipeline" "main" {
  name          = local.name
  role_arn      = aws_iam_role.pipeline.arn
  pipeline_type = "V2"
  tags          = local.tags

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  # Only pushes on the deployment branch start an execution
  trigger {
    provider_type = "CodeStarSourceConnection"
    git_configuration {
      source_action_name = "Source"
      push {
        branches {
          includes = [var.branch]
        }
      }
    }
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source"]
      configuration = {
        ConnectionArn    = aws_codeconnections_connection.github.arn
        FullRepositoryId = var.repository
        BranchName       = var.branch
      }
    }
  }

  stage {
    name = "Plan"
    action {
      name             = "Plan"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source"]
      output_artifacts = ["plan"]
      configuration = {
        ProjectName = aws_codebuild_project.plan.name
      }
    }
  }

  dynamic "stage" {
    for_each = var.require_approval ? [1] : []
    content {
      name = "Approve"
      action {
        name     = "Approve"
        category = "Approval"
        owner    = "AWS"
        provider = "Manual"
        version  = "1"
      }
    }
  }

  stage {
    name = "Apply"
    action {
      name            = "Apply"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["plan"]
      configuration = {
        ProjectName = aws_codebuild_project.apply.name
      }
    }
  }
}

output "connection_arn" {
  description = "Complete the GitHub handshake on this connection in the console"
  value       = aws_codeconnections_connection.github.arn
}
output "connection_status" {
  value = aws_codeconnections_connection.github.connection_status
}
output "pipeline_name" {
  value = aws_codepipeline.main.name
}
