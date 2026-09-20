# Optional AWS price list cache: copies the public AWS offers (OnDemand/RI, every Savings
# Plans offer, EC2 and Fargate spot) into an EXISTING bucket served as the catalog source of
# plugin-prov-aws (https://aws.ligoj.io). Disabled unless var.prices_cache_bucket is set.
#
# The Step Functions workflow invokes the Lambda up to 3 times until it succeeds. A run can
# fail on a transient download error or on the 15 minutes Lambda limit; the function skips
# the files already copied today, so each retry resumes where the previous one stopped.
locals {
  prices_cache_enabled = var.prices_cache_bucket != ""
  prices_cache_name    = "${local.name}-cache-prices"
}

data "archive_file" "cache_prices" {
  count       = local.prices_cache_enabled ? 1 : 0
  type        = "zip"
  output_path = "${path.module}/.build/lambda_cache_prices.zip"
  source {
    content  = file("${path.module}/lambda_cache_prices.py")
    filename = "index.py"
  }
}

resource "aws_lambda_function" "cache_prices" {
  count            = local.prices_cache_enabled ? 1 : 0
  filename         = data.archive_file.cache_prices[0].output_path
  function_name    = local.prices_cache_name
  role             = aws_iam_role.cache_prices[0].arn
  handler          = "index.lambda_handler"
  source_code_hash = data.archive_file.cache_prices[0].output_base64sha256
  runtime          = "python3.13"
  architectures    = ["arm64"]
  timeout          = 900
  memory_size      = 1024
  tags             = local.tags

  # The largest offer files (EC2 regional JSON) are several hundred MB, staged in /tmp
  ephemeral_storage {
    size = 4096
  }

  environment {
    variables = {
      BUCKET_NAME = var.prices_cache_bucket
    }
  }

  depends_on = [aws_cloudwatch_log_group.cache_prices]
}

resource "aws_cloudwatch_log_group" "cache_prices" {
  count             = local.prices_cache_enabled ? 1 : 0
  name              = "/aws/lambda/${local.prices_cache_name}"
  retention_in_days = var.expiration
  tags              = local.tags
}

resource "aws_iam_role" "cache_prices" {
  count = local.prices_cache_enabled ? 1 : 0
  name  = local.prices_cache_name
  tags  = local.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "cache_prices" {
  count = local.prices_cache_enabled ? 1 : 0
  name  = local.prices_cache_name
  role  = aws_iam_role.cache_prices[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.cache_prices[0].arn}:*"
      },
      {
        # ListBucket makes a missing key answer 404 instead of 403 on the freshness check
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.prices_cache_bucket}"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "arn:aws:s3:::${var.prices_cache_bucket}/*"
      }
    ]
  })
}

# --- Orchestration: up to 3 invocations until one succeeds ---
resource "aws_sfn_state_machine" "cache_prices" {
  count    = local.prices_cache_enabled ? 1 : 0
  name     = local.prices_cache_name
  role_arn = aws_iam_role.cache_prices_sfn[0].arn
  tags     = local.tags

  definition = jsonencode({
    Comment = "Cache the AWS price lists: the Lambda is invoked up to 3 times until it succeeds"
    StartAt = "CachePrices"
    States = {
      CachePrices = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.cache_prices[0].arn
          "Payload.$"  = "$"
        }
        ResultSelector = { "result.$" = "$.Payload" }
        # Above the Lambda limit, so a function timeout surfaces as a task failure, not a hang
        TimeoutSeconds = 960
        # 1 attempt + 2 retries = 3 invocations. States.ALL covers the function errors (failed
        # copies raise), the Lambda timeout and the service errors
        Retry = [{
          ErrorEquals     = ["States.ALL"]
          IntervalSeconds = 30
          MaxAttempts     = 2
          BackoffRate     = 1
        }]
        End = true
      }
    }
  })
}

resource "aws_iam_role" "cache_prices_sfn" {
  count = local.prices_cache_enabled ? 1 : 0
  name  = "${local.prices_cache_name}-sfn"
  tags  = local.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "states.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "cache_prices_sfn" {
  count = local.prices_cache_enabled ? 1 : 0
  name  = "${local.prices_cache_name}-sfn"
  role  = aws_iam_role.cache_prices_sfn[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = [aws_lambda_function.cache_prices[0].arn]
    }]
  })
}
