resource "aws_secretsmanager_secret" "ligoj_lambda" {
  name                    = "${local.name}-sign_up"
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "ligoj_lambda" {
  secret_id      = aws_secretsmanager_secret.ligoj_lambda.id
  secret_string  = jsonencode({ username = local.ligoj_lambda_api_user, key = local.ligoj_lambda_api_token })
  version_stages = ["AWSCURRENT"]
}

# Signup user role assumed by a lambda
resource "random_id" "ligoj_lambda_api_token_name" {
  keepers = {
    id = aws_cognito_user_pool.main.name
  }
  byte_length = 6
}
resource "random_password" "ligoj_lambda_api_token" {
  length      = 32
  special     = false
  min_numeric = 1
  min_upper   = 1
}

# The user bootstrap is a RESOURCE, not a data source: it must only run during
# apply, after the ECS service is steady (Ligoj creates the schema and seeds the
# roles at boot). A data source would execute at plan time, deadlocking any run
# where the application is not up yet. The API tokens do not need to be read
# back: the script stores exactly the '_plain_' + random_password value it is
# given (see locals below).
resource "terraform_data" "ligoj_lambda" {
  count      = var.enabled ? 1 : 0
  depends_on = [aws_lambda_function.data_api, aws_rds_cluster_instance.main, aws_ecs_service.main]

  # Re-run when the user pool or the database is recreated (the script is idempotent)
  triggers_replace = [aws_cognito_user_pool.main.id, one(aws_rds_cluster.main[*].id)]

  provisioner "local-exec" {
    # Same stdin JSON contract as the historical external data source; passed
    # through the environment so secrets never appear in the command line, and
    # stdout is discarded so the returned token never reaches the logs
    command = "echo \"$BOOTSTRAP_INPUT\" | bash '${path.root}/ligoj_new_user.sh' >/dev/null"
    environment = {
      BOOTSTRAP_INPUT = jsonencode({
        rds_arn        = aws_rds_cluster.main[0].arn
        rds_secret_arn = aws_secretsmanager_secret.rds_master.arn
        rds_secret_64  = base64encode(aws_secretsmanager_secret_version.rds_master.secret_string)
        function_name  = local.lambda_data_api_name
        profile        = var.profile == null ? "" : var.profile
        region         = var.region
        username       = local.ligoj_lambda_api_user
        user_pool      = aws_cognito_user_pool.main.id
        database       = "ligoj"
        api_token_name = "init_${random_id.ligoj_lambda_api_token_name.hex}"
        api_token      = local.ligoj_lambda_api_token
      })
    }
  }
}

# Admin user
resource "random_id" "ligoj_admin_api_token_name" {
  keepers = {
    id = aws_cognito_user_pool.main.name
  }
  byte_length = 6
}
resource "random_password" "ligoj_admin_api_token" {
  length  = 32
  special = false
}

resource "terraform_data" "ligoj_admin" {
  count      = var.enabled ? 1 : 0
  depends_on = [terraform_data.ligoj_lambda]

  triggers_replace = [aws_cognito_user_pool.main.id, one(aws_rds_cluster.main[*].id), aws_cognito_user.admin.sub]

  provisioner "local-exec" {
    command = "echo \"$BOOTSTRAP_INPUT\" | bash '${path.root}/ligoj_new_user.sh' >/dev/null"
    environment = {
      BOOTSTRAP_INPUT = jsonencode({
        rds_arn        = aws_rds_cluster.main[0].arn
        rds_secret_arn = aws_secretsmanager_secret.rds_master.arn
        rds_secret_64  = base64encode(aws_secretsmanager_secret_version.rds_master.secret_string)
        function_name  = local.lambda_data_api_name
        profile        = var.profile == null ? "" : var.profile
        region         = var.region
        username       = local.cognito_admin_sub
        user_pool      = aws_cognito_user_pool.main.id
        database       = "ligoj"
        api_token_name = "init_${random_id.ligoj_admin_api_token_name.hex}"
        api_token      = local.ligoj_admin_api_token
      })
    }
  }
}

locals {
  ligoj_lambda_secret_arn = aws_secretsmanager_secret.ligoj_lambda.arn
  ligoj_lambda_api_user   = "cognito_sign_up"
  # The script stores these values verbatim ('_plain_' hash marker): no read-back needed
  ligoj_lambda_api_token = "_plain_${random_password.ligoj_lambda_api_token.result}"
  ligoj_admin_api_token  = "_plain_${random_password.ligoj_admin_api_token.result}"
}
