resource "aws_lb" "main" {
  name                       = local.name
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = aws_subnet.main[*].id
  enable_deletion_protection = false
  tags                       = local.tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.alb.certificate_arn
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}

resource "aws_lb_target_group" "main" {
  for_each    = var.container_port
  name        = "${each.key}-${var.environment}"
  port        = each.value
  protocol    = var.container_protocol
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path     = lookup(var.container_health, each.key, "/index.html")
    protocol = var.container_protocol
  }
}

# Priority 10+: unauthenticated paths (themes, logout page, favicon)
resource "aws_lb_listener_rule" "public" {
  for_each     = var.container_route_public
  listener_arn = aws_lb_listener.https.arn
  priority     = 10 + index(keys(var.container_route_public), each.key)

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main[each.key].arn
  }
  condition {
    host_header {
      values = [local.dns]
    }
  }
  condition {
    path_pattern {
      values = each.value
    }
  }
}

# Priority 20+: API access with 'x-api-key' header and 'api-user' query parameter
resource "aws_lb_listener_rule" "public_header" {
  for_each     = var.container_route_header
  listener_arn = aws_lb_listener.https.arn
  priority     = 20 + index(keys(var.container_route_header), each.key)

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main[each.key].arn
  }
  condition {
    host_header {
      values = [local.dns]
    }
  }

  condition {
    http_header {
      http_header_name = split(":", each.value)[0]
      values           = [split(":", each.value)[1]]
    }
  }
}

# Priority 30+: API access with 'api-key' and 'api-user' query parameters
resource "aws_lb_listener_rule" "public_query" {
  for_each     = var.container_route_query
  listener_arn = aws_lb_listener.https.arn
  priority     = 30 + index(keys(var.container_route_query), each.key)

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main[each.key].arn
  }
  condition {
    host_header {
      values = [local.dns]
    }
  }

  condition {
    query_string {
      key   = split(":", each.value)[0]
      value = split(":", each.value)[1]
    }
  }

  condition {
    query_string {
      key   = "api-user"
      value = "*"
    }
  }
}

# Priority 50+: everything else requires a Cognito authentication
resource "aws_lb_listener_rule" "private" {
  for_each     = var.container_route_private
  listener_arn = aws_lb_listener.https.arn
  priority     = 50 + index(keys(var.container_route_private), each.key)

  action {
    type = "authenticate-cognito"
    authenticate_cognito {
      user_pool_arn       = aws_cognito_user_pool.main.arn
      user_pool_client_id = aws_cognito_user_pool_client.main.id
      user_pool_domain    = aws_cognito_user_pool_domain.main.domain
    }
  }
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main[each.key].arn
  }
  condition {
    host_header {
      values = [local.dns]
    }
  }
  condition {
    path_pattern {
      values = [each.value]
    }
  }
}

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Security Group pour ALB"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.tags, { "Name" = "${local.name}-alb" })
}

resource "aws_security_group_rule" "alb_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "alb_http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "alb_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = -1
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = aws_security_group.alb.id
}
