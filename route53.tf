data "aws_route53_zone" "main" {
  name         = var.dns_zone
  private_zone = false
}

resource "aws_route53_record" "acm_alb" {
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
resource "aws_route53_record" "acm_cognito" {
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

# The public entry point is the CloudFront distribution; the ALB is internal
resource "aws_route53_record" "app" {
  allow_overwrite = true
  name            = local.dns
  type            = "A"
  zone_id         = data.aws_route53_zone.main.zone_id

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}
resource "aws_route53_record" "app_ipv6" {
  allow_overwrite = true
  name            = local.dns
  type            = "AAAA"
  zone_id         = data.aws_route53_zone.main.zone_id

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "cognito" {
  allow_overwrite = true
  name            = local.cognito_dns
  type            = "A"
  zone_id         = data.aws_route53_zone.main.zone_id

  alias {
    name                   = aws_cognito_user_pool_domain.main.cloudfront_distribution
    zone_id                = aws_cognito_user_pool_domain.main.cloudfront_distribution_zone_id
    evaluate_target_health = false
  }
}
