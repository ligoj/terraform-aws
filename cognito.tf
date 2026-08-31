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
  depends_on      = [aws_route53_record.app]
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
  attributes = {
    email          = local.cognito_admin
    email_verified = true
  }
}

# Hosted UI branding: Ligoj logo and color scheme (blue #4589ca, navy #034b80, orange #ff6900).
# Cognito only accepts PNG/JPEG (max 100KB) for the logo, hence the PNG copy of the SVG logo.
resource "aws_cognito_user_pool_ui_customization" "main" {
  # Reference the domain to make sure it exists before the customization is applied
  user_pool_id = aws_cognito_user_pool_domain.main.user_pool_id
  image_file   = filebase64("${path.module}/assets/logo.png")
  css          = <<-CSS
    .logo-customizable {
      max-width: 130px;
      max-height: 130px;
    }
    .banner-customizable {
      padding: 25px 0px 25px 0px;
      background-color: #ffffff;
    }
    .background-customizable {
      background-color: #f2f6fa;
    }
    .label-customizable {
      font-weight: 400;
    }
    .textDescription-customizable {
      padding-top: 10px;
      padding-bottom: 10px;
      display: block;
      font-size: 16px;
    }
    .legalText-customizable {
      color: #747474;
      font-size: 11px;
    }
    .submitButton-customizable {
      font-size: 14px;
      font-weight: bold;
      margin: 20px 0px 10px 0px;
      height: 40px;
      width: 100%;
      color: #ffffff;
      background-color: #ff6900;
    }
    .submitButton-customizable:hover {
      color: #ffffff;
      background-color: #e05e00;
    }
    .errorMessage-customizable {
      padding: 5px;
      font-size: 14px;
      width: 100%;
      background: #f5f5f5;
      border: 2px solid #d64958;
      color: #d64958;
    }
    .inputField-customizable {
      width: 100%;
      height: 34px;
      color: #034b80;
      background-color: #ffffff;
      border: 1px solid #cccccc;
    }
    .inputField-customizable:focus {
      border-color: #4589ca;
      outline: 0;
    }
    .redirect-customizable {
      text-align: center;
    }
    .passwordCheck-notValid-customizable {
      color: #d64958;
    }
    .passwordCheck-valid-customizable {
      color: #19bf00;
    }
  CSS
}

locals {
  cognito_admin_sub = aws_cognito_user.admin.sub
}
