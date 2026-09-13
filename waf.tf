# Optional WAF in front of CloudFront (CLOUDFRONT-scope WAFv2 resources only exist in us-east-1).
# - var.web_acl_arn: attach an existing Web ACL as-is, nothing is generated.
# - otherwise a Web ACL is generated when at least one of these is set:
#   * var.web_acl_allowed_paths: only the known application routes get through
#     (URI path allowlist as regexes), whoever sends the request;
#   * var.web_acl_allowed_ipset_arns: only these IP sets (or a request carrying the
#     secret cookie) get through.
# Cost: WAF bills every rule, so the whole policy is ONE allow rule
#   known route AND (IP set 1 OR IP set 2 ... OR secret cookie)
# with a BLOCK default action. Nested and/or statements are free.
locals {
  waf_ip_restricted    = length(var.web_acl_allowed_ipset_arns) > 0
  waf_route_restricted = length(var.web_acl_allowed_paths) > 0
  waf_generated        = var.web_acl_arn == "" && (local.waf_ip_restricted || local.waf_route_restricted)

  # Allowed sources: the IP sets, plus the cookie bypass when IPs are restricted
  # ("cookie" is the marker of the byte-match statement below)
  waf_sources      = local.waf_ip_restricted ? concat(var.web_acl_allowed_ipset_arns, var.web_acl_secret_cookie == "" ? [] : ["cookie"]) : []
  waf_source_count = length(local.waf_sources)
  # or_statement / and_statement need at least two operands: pick the statement shape
  waf_shape = (local.waf_route_restricted && local.waf_source_count > 0 ? "route_and_sources" :
  local.waf_route_restricted ? "route_only" : local.waf_source_count > 1 ? "sources_or" : "source_single")

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

  default_action {
    block {}
  }

  rule {
    name     = "allow-known-routes-from-allowed-sources"
    priority = 0

    action {
      allow {}
    }

    statement {
      # --- route AND sources ---
      dynamic "and_statement" {
        for_each = local.waf_shape == "route_and_sources" ? [1] : []
        content {
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
          statement {
            dynamic "or_statement" {
              for_each = local.waf_source_count > 1 ? [1] : []
              content {
                dynamic "statement" {
                  for_each = local.waf_sources
                  content {
                    dynamic "ip_set_reference_statement" {
                      for_each = statement.value == "cookie" ? [] : [statement.value]
                      content {
                        arn = ip_set_reference_statement.value
                      }
                    }
                    dynamic "byte_match_statement" {
                      for_each = statement.value == "cookie" ? [1] : []
                      content {
                        search_string         = var.web_acl_secret_cookie
                        positional_constraint = "EXACTLY"
                        # Browsers split the Cookie header into one field per cookie over
                        # HTTP/2 and single_header only inspects the first: the parsed
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
                  }
                }
              }
            }
            # a single IP set and no cookie: no OR needed
            dynamic "ip_set_reference_statement" {
              for_each = local.waf_source_count == 1 ? [local.waf_sources[0]] : []
              content {
                arn = ip_set_reference_statement.value
              }
            }
          }
        }
      }

      # --- route only ---
      dynamic "regex_pattern_set_reference_statement" {
        for_each = local.waf_shape == "route_only" ? [1] : []
        content {
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

      # --- sources only (no route restriction) ---
      dynamic "or_statement" {
        for_each = local.waf_shape == "sources_or" ? [1] : []
        content {
          dynamic "statement" {
            for_each = local.waf_sources
            content {
              dynamic "ip_set_reference_statement" {
                for_each = statement.value == "cookie" ? [] : [statement.value]
                content {
                  arn = ip_set_reference_statement.value
                }
              }
              dynamic "byte_match_statement" {
                for_each = statement.value == "cookie" ? [1] : []
                content {
                  search_string         = var.web_acl_secret_cookie
                  positional_constraint = "EXACTLY"
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
            }
          }
        }
      }
      dynamic "ip_set_reference_statement" {
        for_each = local.waf_shape == "source_single" ? [local.waf_sources[0]] : []
        content {
          arn = ip_set_reference_statement.value
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name}-allow"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-waf"
    sampled_requests_enabled   = true
  }
}
