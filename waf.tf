# Optional WAF in front of CloudFront. Two mutually exclusive inputs:
# - var.web_acl_arn: attach an existing CLOUDFRONT-scope Web ACL as-is
# - var.web_acl_allowed_ipset_arn: build an IP allowlist Web ACL around an
#   existing WAFv2 IP set (allow the listed IPs, block everything else)
# CLOUDFRONT-scope WAFv2 resources only exist in us-east-1.
resource "aws_wafv2_web_acl" "ip_allowlist" {
  count  = var.web_acl_allowed_ipset_arn == "" ? 0 : 1
  region = "us-east-1"
  name   = "${local.name}-ip-allowlist"
  scope  = "CLOUDFRONT"
  tags   = local.tags

  default_action {
    block {}
  }

  rule {
    name     = "allow-listed-ips"
    priority = 1

    action {
      allow {}
    }

    statement {
      ip_set_reference_statement {
        arn = var.web_acl_allowed_ipset_arn
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name}-allow-listed-ips"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-waf"
    sampled_requests_enabled   = true
  }
}

locals {
  # Existing Web ACL wins; else the generated allowlist one; else no WAF
  web_acl_arn = var.web_acl_arn != "" ? var.web_acl_arn : one(aws_wafv2_web_acl.ip_allowlist[*].arn)
}
