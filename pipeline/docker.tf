# Second pipeline: build the Ligoj Docker images from the application repository
# and push them to the ECR repositories managed by the main stack.
# aarch64 build host: the Fargate tasks run on ARM64, images are built natively.

locals {
  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

resource "aws_codebuild_project" "docker" {
  name          = "${local.name}-docker"
  description   = "Docker build and ECR push of ${var.app_repository}"
  service_role  = aws_iam_role.docker.arn
  build_timeout = 60
  tags          = local.tags

  artifacts {
    type = "CODEPIPELINE"
  }

  source {
    type = "CODEPIPELINE"
    # The application repository carries no buildspec for this pipeline: inline
    buildspec = <<-EOT
      version: 0.2
      phases:
        pre_build:
          commands:
            - aws ecr get-login-password --region "$${AWS_REGION}" | docker login --username AWS --password-stdin "$${ECR_REGISTRY}"
            - |
              VERSION=$(python3 - <<'PY'
              import xml.etree.ElementTree as ET
              ns = {'m': 'http://maven.apache.org/POM/4.0.0'}
              v = ET.parse('pom.xml').getroot().find('m:version', ns)
              print(v.text if v is not None else 'master')
              PY
              )
            - echo "Building version $${VERSION} (commit $${CODEBUILD_RESOLVED_SOURCE_VERSION})"
            # Zstd layers need a BuildKit builder of its own: the default one only exports gzip
            - docker buildx create --name zstd --driver docker-container --use
            # A single image manifest, no attestation: the main stack deploys the most recently
            # pushed manifest of the repository (data.aws_ecr_image), which must be the image
            - COMMON_ARGS="--provenance=false --sbom=false --build-arg BUILDPLATFORM=linux/arm64 --build-arg TARGETPLATFORM=linux/arm64 --build-arg GIT_COMMIT=$${CODEBUILD_RESOLVED_SOURCE_VERSION} --build-arg GIT_BRANCH=$${APP_BRANCH} --build-arg FLAT_CLASSPATH=true"
            # Level 3: higher levels only shrink the image further at the cost of a slower pull.
            # force-compression also converts the gzip layers of the base images
            - ZSTD_OUTPUT="type=image,push=true,oci-mediatypes=true,compression=zstd,compression-level=3,force-compression=true"
        build:
          commands:
            # Activate the build preparation script: sourced by the Dockerfile builder stage, it
            # imports app-api/plugin-vendors/*.cer into the bundled plugin-vendors-default.p12
            # truststore, installed as <ligoj.home>/plugin-vendors.p12 at first startup. Without
            # it, signed plugins show as UNTRUSTED instead of VERIFIED.
            - cp app-api/prepare-build-sample.sh app-api/prepare-build.sh
            # Loaded into the local daemon for the check below, the push comes later
            - docker buildx build $${COMMON_ARGS} --load -t "$${ECR_REGISTRY}/ligoj/ligoj-api:$${VERSION}" -f app-api/Dockerfile app-api/
            # Fail early if the vendors truststore did not make it into the image
            - docker run --rm --entrypoint ls "$${ECR_REGISTRY}/ligoj/ligoj-api:$${VERSION}" /usr/local/ligoj/plugin-vendors-default.p12
            - docker buildx build $${COMMON_ARGS} --output type=cacheonly -f app-ui/Dockerfile app-ui/
            # Both images are built and the checks passed: push them, recompressed from the cache.
            # Not in post_build: it also runs after a failed build, and these commands would then
            # build and push the failed image.
            - docker buildx build $${COMMON_ARGS} --output "$${ZSTD_OUTPUT}" -t "$${ECR_REGISTRY}/ligoj/ligoj-api:$${VERSION}" -t "$${ECR_REGISTRY}/ligoj/ligoj-api:$${APP_BRANCH}" -f app-api/Dockerfile app-api/
            - docker buildx build $${COMMON_ARGS} --output "$${ZSTD_OUTPUT}" -t "$${ECR_REGISTRY}/ligoj/ligoj-ui:$${VERSION}" -t "$${ECR_REGISTRY}/ligoj/ligoj-ui:$${APP_BRANCH}" -f app-ui/Dockerfile app-ui/
    EOT
  }

  environment {
    compute_type = "BUILD_GENERAL1_MEDIUM"
    image        = "aws/codebuild/amazonlinux-aarch64-standard:4.0"
    type         = "ARM_CONTAINER"
    host_kernel  = "LINUX_KERNEL_6"
    # Docker daemon for the image builds
    privileged_mode = true

    environment_variable {
      name  = "ECR_REGISTRY"
      value = local.ecr_registry
    }
    environment_variable {
      name  = "APP_BRANCH"
      value = var.app_branch
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.build.name
      stream_name = "docker"
    }
  }
}

# Least privilege: unlike the Terraform projects, this one only pushes images
resource "aws_iam_role" "docker" {
  name = "${local.name}-docker"
  tags = local.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "codebuild.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "docker" {
  name = "${local.name}-docker"
  role = aws_iam_role.docker.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.build.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/ligoj/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = "${aws_s3_bucket.artifacts.arn}/*"
      }
    ]
  })
}

resource "aws_codepipeline" "docker" {
  name          = "${local.name}-docker"
  role_arn      = aws_iam_role.pipeline.arn
  pipeline_type = "V2"
  tags          = local.tags

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  trigger {
    provider_type = "CodeStarSourceConnection"
    git_configuration {
      source_action_name = "Source"
      push {
        branches {
          includes = [var.app_branch]
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
        FullRepositoryId = var.app_repository
        BranchName       = var.app_branch
      }
    }
  }

  stage {
    name = "Build"
    action {
      name            = "Build"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source"]
      configuration = {
        ProjectName = aws_codebuild_project.docker.name
      }
    }
  }
}

output "docker_pipeline_name" {
  value = aws_codepipeline.docker.name
}
