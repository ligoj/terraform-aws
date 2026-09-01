# AWS managed policies: static assets are cached on the URL only, everything else is
# passed through uncached. 'AllViewer' forwards the Host header, required both by the
# ALB host/Cognito listener rules and by the origin TLS validation (the internal ALB
# serves the certificate of local.dns, not of its *.elb.amazonaws.com name).
data "aws_cloudfront_cache_policy" "assets" {
  name = "Managed-CachingOptimized"
}
data "aws_cloudfront_cache_policy" "no_cache" {
  name = "Managed-CachingDisabled"
}
data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

# Private path from CloudFront to the internal ALB, no public exposure of the origin
resource "aws_cloudfront_vpc_origin" "alb" {
  vpc_origin_endpoint_config {
    name                   = local.name
    arn                    = aws_lb.main.arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "https-only"

    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
  tags = local.tags
}

resource "aws_cloudfront_distribution" "main" {
  enabled         = true
  comment         = local.name
  aliases         = [local.dns]
  web_acl_id      = local.web_acl_arn
  is_ipv6_enabled = true
  http_version    = "http2and3"
  price_class     = "PriceClass_100"
  tags            = local.tags

  origin {
    domain_name = aws_lb.main.dns_name
    origin_id   = "alb"

    vpc_origin_config {
      vpc_origin_id = aws_cloudfront_vpc_origin.alb.id
    }
  }

  # API: never cached, all methods
  ordered_cache_behavior {
    path_pattern             = "${var.context_path}/rest*"
    target_origin_id         = "alb"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.no_cache.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
    viewer_protocol_policy   = "redirect-to-https"
    compress                 = true
  }

  # Static assets: cached on the URL only
  ordered_cache_behavior {
    path_pattern             = "${var.context_path}/themes/*"
    target_origin_id         = "alb"
    allowed_methods          = ["GET", "HEAD"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.assets.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
    viewer_protocol_policy   = "redirect-to-https"
    compress                 = true
  }
  ordered_cache_behavior {
    path_pattern             = "${var.context_path}/favicon.ico"
    target_origin_id         = "alb"
    allowed_methods          = ["GET", "HEAD"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.assets.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
    viewer_protocol_policy   = "redirect-to-https"
    compress                 = true
  }

  # Everything else (authenticated application, Cognito OAuth callback): pass-through.
  # Cookies (AWSELBAuthSessionCookie) and query strings must reach the ALB untouched
  default_cache_behavior {
    target_origin_id         = "alb"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.no_cache.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
    viewer_protocol_policy   = "redirect-to-https"
    compress                 = true
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cloudfront.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = length(var.cloudfront_allowed_countries) == 0 ? "none" : "whitelist"
      locations        = var.cloudfront_allowed_countries
    }
  }
}
