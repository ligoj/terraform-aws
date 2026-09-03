resource "aws_cognito_user_pool" "main" {
  name                       = local.name
  auto_verified_attributes   = ["email"]
  username_attributes        = ["email"]
  mfa_configuration          = "OPTIONAL"
  email_verification_subject = var.cognito_email_verification_subject
  email_verification_message = var.cognito_email_verification_message

  email_configuration {
    from_email_address     = local.cognito_from
    reply_to_email_address = local.cognito_reply
    source_arn             = local.cognito_source_arn
    email_sending_account  = "DEVELOPER"
  }
  software_token_mfa_configuration {
    enabled = true
  }
  lambda_config {
    pre_sign_up       = aws_lambda_function.pre_sign_up.arn
    post_confirmation = aws_lambda_function.post_confirmation.arn
  }
  tags = local.tags

  # Cognito validates the SES identity at creation
  depends_on = [terraform_data.ses_verified]
}

resource "aws_lambda_permission" "post_confirmation" {
  statement_id  = "AllowExecutionFromCognito-post_confirmation"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.post_confirmation.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.main.arn
}
resource "aws_lambda_permission" "pre_sign_up" {
  statement_id  = "AllowExecutionFromCognito-pre_sign_up"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pre_sign_up.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.main.arn
  depends_on = [
    aws_lambda_permission.post_confirmation
  ]
}

resource "random_password" "cognito_admin" {
  length           = 12
  special          = true
  override_special = "_+.-"
  min_numeric      = 1
  min_special      = 1
  min_upper        = 1
}

resource "aws_cognito_user_pool_domain" "main" {
  domain          = local.cognito_dns
  certificate_arn = aws_acm_certificate_validation.cognito.certificate_arn
  user_pool_id    = aws_cognito_user_pool.main.id
  # 2 = Managed Login (branding designer); 1 = classic hosted UI
  managed_login_version = 2
  depends_on            = [aws_route53_record.app]
}

resource "aws_cognito_user_pool_client" "main" {
  name                                 = local.name
  generate_secret                      = true
  supported_identity_providers         = ["COGNITO"]
  user_pool_id                         = aws_cognito_user_pool.main.id
  explicit_auth_flows                  = ["ALLOW_ADMIN_USER_PASSWORD_AUTH", "ALLOW_USER_PASSWORD_AUTH", "ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "aws.cognito.signin.user.admin"]
  logout_urls                          = ["https://${local.dns}${var.context_path}/logout.html", "https://${local.dns}/", "https://${local.dns}/logout.html"]
  callback_urls                        = ["https://${local.dns}/oauth2/idpresponse"]
  default_redirect_uri                 = "https://${local.dns}/oauth2/idpresponse"
  read_attributes                      = ["name", "email"]
  write_attributes                     = ["name", "email"]
}

# Administrator account, invited by email with a temporary password
resource "aws_cognito_user" "admin" {
  user_pool_id       = aws_cognito_user_pool.main.id
  username           = local.cognito_admin
  temporary_password = random_password.cognito_admin.result
  # The invitation defaults to SMS: without this, no email is ever sent.
  # NOTE: delivery only happens while SES is out of the sandbox (or to
  # SES-verified addresses); the temporary password otherwise lives in the
  # Terraform state (random_password.cognito_admin)
  desired_delivery_mediums = ["EMAIL"]
  attributes = {
    email          = local.cognito_admin
    email_verified = true
  }
}

# Managed Login branding: Ligoj palette (blue #4589ca, navy #034b80, orange #ff6900)
# and SVG logo. assets/managed-login.json is the full settings document exported
# from Cognito's defaults with the palette applied (every key is API-valid).
resource "aws_cognito_managed_login_branding" "main" {
  user_pool_id = aws_cognito_user_pool.main.id
  client_id    = aws_cognito_user_pool_client.main.id
  settings     = jsonencode(jsondecode(file("${path.module}/assets/managed-login.json")))

  asset {
    category   = "FORM_LOGO"
    color_mode = "LIGHT"
    extension  = "SVG"
    bytes      = filebase64("${path.module}/assets/logo.svg")
  }

  asset {
    category   = "FAVICON_SVG"
    color_mode = "DYNAMIC"
    extension  = "SVG"
    bytes      = filebase64("${path.module}/assets/logo.svg")
  }

  # The branding style targets the Managed Login domain version
  depends_on = [aws_cognito_user_pool_domain.main]
}

locals {
  cognito_admin_sub = aws_cognito_user.admin.sub
}
