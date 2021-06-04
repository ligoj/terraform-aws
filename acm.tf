resource aws_acm_certificate alb {
  domain_name               = local.dns
  validation_method         = "DNS"
  tags                      = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource aws_acm_certificate cognito {
  domain_name       = var.cognito_dns
  validation_method = "DNS"
  tags              = local.tags
  provider          = aws.use1

  lifecycle {
    create_before_destroy = true
  }
}

resource aws_acm_certificate_validation alb {
  certificate_arn         = aws_acm_certificate.alb.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_alb : record.fqdn]
}

resource aws_acm_certificate_validation cognito {
  certificate_arn         = aws_acm_certificate.cognito.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_cognito : record.fqdn]
  provider          = aws.use1
}
