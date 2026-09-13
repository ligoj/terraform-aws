# Optional WAF in front of CloudFront (CLOUDFRONT-scope WAFv2 resources only exist in us-east-1).
# - var.web_acl_arn: attach an existing Web ACL as-is, nothing is generated.
# - otherwise a Web ACL is generated when at least one of these is set:
#   * var.web_acl_allowed_paths: only the known application routes get through
#     (URI path allowlist as regexes), evaluated FIRST so it applies to everybody;
#   * var.web_acl_allowed_ipset_arns: only these IP sets (or a request carrying the
#     secret cookie) get through; the default action is then BLOCK, otherwise ALLOW.
locals {
  waf_ip_restricted    = length(var.web_acl_allowed_ipset_arns) > 0
  waf_route_restricted = length(var.web_acl_allowed_paths) > 0
  waf_generated        = var.web_acl_arn == "" && (local.waf_ip_restricted || local.waf_route_restricted)

  # Existing Web ACL wins; else the generated one; else no WAF
  web_acl_arn = var.web_acl_arn != "" ? var.web_acl_arn : one(aws_wafv2_web_acl.main[*].arn)
}

# Known application routes (a regex pattern set holds at most 10 expressions)
resource "aws_wafv2_regex_pattern_set" "routes" {
  count  = local.waf_generated && local.waf_route_restricted ? 1 : 0
  region = "us-east-1"
  name   = "${local.name}-routes"
  scope  = "CLOUDFRONT"
  tags   = local.tags

  dynamic "regular_expression" {
    for_each = var.web_acl_allowed_paths
    content {
      regex_string = regular_expression.value
    }
  }
}

resource "aws_wafv2_web_acl" "main" {
  count  = local.waf_generated ? 1 : 0
  region = "us-east-1"
  name   = "${local.name}-edge"
  scope  = "CLOUDFRONT"
  tags   = local.tags

  # IP restriction: block unless allowed below. Routes only: allow what survived rule 0
  default_action {
    dynamic "block" {
      for_each = local.waf_ip_restricted ? [1] : []
      content {}
    }
    dynamic "allow" {
      for_each = local.waf_ip_restricted ? [] : [1]
      content {}
    }
  }

  # 0. Anything outside the known routes is blocked, whoever sends it (cookie or IP
  #    allowlist do not help): reduces the surface to what the application serves.
  #    The path is URL-decoded then normalized ('/dist/../rest' is judged as '/rest').
  dynamic "rule" {
    for_each = local.waf_route_restricted ? [1] : []
    content {
      name     = "block-unknown-routes"
      priority = 0

      action {
        block {}
      }

      statement {
        not_statement {
          statement {
            regex_pattern_set_reference_statement {
              arn = aws_wafv2_regex_pattern_set.routes[0].arn

              field_to_match {
                uri_path {}
              }

              text_transformation {
                priority = 0
                type     = "URL_DECODE"
              }
              text_transformation {
                priority = 1
                type     = "NORMALIZE_PATH"
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.name}-block-unknown-routes"
        sampled_requests_enabled   = true
      }
    }
  }

  # 1. Optional bypass of the IP allowlist: a request carrying the secret cookie is
  #    allowed regardless of its source IP (roaming outside the allowlisted networks)
  dynamic "rule" {
    for_each = local.waf_ip_restricted && var.web_acl_secret_cookie != "" ? [1] : []
    content {
      name     = "allow-secret-cookie"
      priority = 1

      action {
        allow {}
      }

      statement {
        byte_match_statement {
          search_string         = var.web_acl_secret_cookie
          positional_constraint = "EXACTLY"

          # Browsers split the Cookie header into one field per cookie over
          # HTTP/2, and single_header only inspects the first: the parsed
          # 'cookies' match is the only reliable way. The cookie NAME is fixed.
          field_to_match {
            cookies {
              match_scope       = "VALUE"
              oversize_handling = "NO_MATCH"
              match_pattern {
                included_cookies = ["waf_bypass"]
              }
            }
          }

          text_transformation {
            priority = 0
            type     = "NONE"
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.name}-allow-secret-cookie"
        sampled_requests_enabled   = true
      }
    }
  }

  # 2. Allowlisted source IPs: one IP set directly, several through an OR
  dynamic "rule" {
    for_each = local.waf_ip_restricted ? [1] : []
    content {
      name     = "allow-listed-ips"
      priority = 2

      action {
        allow {}
      }

      statement {
        dynamic "ip_set_reference_statement" {
          for_each = length(var.web_acl_allowed_ipset_arns) == 1 ? var.web_acl_allowed_ipset_arns : []
          content {
            arn = ip_set_reference_statement.value
          }
        }
        dynamic "or_statement" {
          for_each = length(var.web_acl_allowed_ipset_arns) > 1 ? [1] : []
          content {
            dynamic "statement" {
              for_each = var.web_acl_allowed_ipset_arns
              content {
                ip_set_reference_statement {
                  arn = statement.value
                }
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.name}-allow-listed-ips"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-waf"
    sampled_requests_enabled   = true
  }
}
