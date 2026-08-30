resource "aws_acm_certificate" "alb" {
  domain_name       = local.dns
  validation_method = "DNS"
  tags              = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

# Cognito custom domains are fronted by CloudFront: the certificate must live in us-east-1
resource "aws_acm_certificate" "cognito" {
  region            = "us-east-1"
  domain_name       = local.cognito_dns
  validation_method = "DNS"
  tags              = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "alb" {
  certificate_arn         = aws_acm_certificate.alb.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_alb : record.fqdn]
}

resource "aws_acm_certificate_validation" "cognito" {
  region                  = "us-east-1"
  certificate_arn         = aws_acm_certificate.cognito.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_cognito : record.fqdn]
}
