# --- CodeBuild role --------------------------------------------------------
# The apply project provisions the WHOLE main stack (VPC, IAM, RDS, Cognito, ...):
# a least-privilege policy is impractical for a full-stack Terraform deployer, so
# the standard trade-off of an administrator deploy role is used. The plan project
# shares it because 'terraform plan' also executes the external data sources
# (Lambda invocations) of the bootstrap chain.
resource "aws_iam_role" "build" {
  name = "${local.name}-build"
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

resource "aws_iam_role_policy_attachment" "build_admin" {
  role       = aws_iam_role.build.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# --- CodePipeline role -----------------------------------------------------
resource "aws_iam_role" "pipeline" {
  name = "${local.name}-pipeline"
  tags = local.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "codepipeline.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "pipeline" {
  name = local.name
  role = aws_iam_role.pipeline.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketVersioning", "s3:GetBucketLocation"]
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
        Resource = [aws_codebuild_project.plan.arn, aws_codebuild_project.apply.arn, aws_codebuild_project.docker.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["codeconnections:UseConnection", "codestar-connections:UseConnection"]
        Resource = [aws_codeconnections_connection.github.arn]
      }
    ]
  })
}
