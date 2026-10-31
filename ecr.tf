# Private repositories for the Ligoj images, fed by the image pipeline of
# pipeline/docker.tf. They start EMPTY: run that pipeline once before the first apply
# of this stack, the default empty 'ligoj_version' reads the latest pushed digest and
# fails on an empty repository. 'docker_repository' only applies to a forced
# 'ligoj_version'. Repository names match the image paths built in local.image below.
resource "aws_ecr_repository" "main" {
  for_each             = toset(["ligoj-ui", "ligoj-api"])
  name                 = "ligoj/${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  tags                 = local.tags

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "main" {
  for_each   = aws_ecr_repository.main
  repository = each.value.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 14 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last 20 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = { type = "expire" }
      }
    ]
  })
}

# Most recently pushed image of each repository, used when no tag is forced
data "aws_ecr_image" "latest" {
  for_each        = var.ligoj_version == "" ? aws_ecr_repository.main : {}
  repository_name = each.value.name
  most_recent     = true
}

locals {
  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/"
  # Forced tag when provided, otherwise the digest of the latest pushed ECR image
  image = { for name in ["ligoj-ui", "ligoj-api"] :
    name => var.ligoj_version == "" ? "${local.ecr_registry}ligoj/${name}@${data.aws_ecr_image.latest[name].image_digest}" : "${var.docker_repository}ligoj/${name}:${var.ligoj_version}"
  }
}
