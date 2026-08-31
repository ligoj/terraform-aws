resource "aws_ecs_service" "main" {
  name             = local.name
  cluster          = aws_ecs_cluster.main.id
  task_definition  = aws_ecs_task_definition.main.arn
  desired_count    = var.desired_count
  launch_type      = "FARGATE"
  platform_version = "1.4.0"
  tags             = local.tags

  # Let Ligoj boot (plugin install, schema update) before the ALB health checks count
  health_check_grace_period_seconds = 120

  # Stop and roll back a deployment whose tasks fail to stabilize, instead of retrying forever
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    security_groups  = [aws_security_group.ecs.id]
    subnets          = aws_subnet.main[*].id
    assign_public_ip = true
  }

  dynamic "load_balancer" {
    iterator = container
    for_each = var.container_port
    content {
      target_group_arn = aws_lb_target_group.main[container.key].arn
      container_name   = container.key
      container_port   = container.value
    }
  }
}

resource "aws_cloudwatch_log_group" "app_ui" {
  name              = "/ecs/ligoj-ui-${var.environment}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}
resource "aws_cloudwatch_log_group" "app_api" {
  name              = "/ecs/ligoj-api-${var.environment}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}
