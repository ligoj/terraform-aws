data aws_route53_zone main {
  name         = var.dns_zone
  private_zone = false
}

resource aws_route53_record acm_alb {
  for_each = {
    for dvo in aws_acm_certificate.alb.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.main.zone_id
}
resource aws_route53_record acm_cognito {
  for_each = {
    for dvo in aws_acm_certificate.cognito.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.main.zone_id
}

resource aws_route53_record alb {
  allow_overwrite = true
  name            = local.dns
  type            = "CNAME"
  ttl             = 300
  zone_id         = data.aws_route53_zone.main.zone_id
  records         = [aws_lb.main.dns_name]
}

resource aws_route53_record cognito {
  allow_overwrite = true
  name            = var.cognito_dns
  type            = "A"
  zone_id         = data.aws_route53_zone.main.zone_id

  alias {
    name                   = aws_cognito_user_pool_domain.main.cloudfront_distribution_arn
    zone_id                = "Z2FDTNDATAQYW2"
    evaluate_target_health = false
  }
}
