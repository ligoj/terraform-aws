# Optional off-hours shutdown of the Fargate tasks through Application Auto
# Scaling scheduled actions (no Lambda, no cost): 'stop' scales the service to
# 0, 'start' back to var.desired_count. Either schedule can be set alone.
# NOTE: a 'terraform apply' during the stopped window restarts the tasks
# (desired_count / capacities converge back to the configuration) until the
# next 'stop' fires; deploy during business hours or accept the blip.
locals {
  ecs_schedule_enabled = var.ecs_stop_schedule != "" || var.ecs_start_schedule != ""
}

resource "aws_appautoscaling_target" "ecs" {
  count              = local.ecs_schedule_enabled ? 1 : 0
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.main.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.desired_count
  max_capacity       = var.desired_count
  tags               = local.tags
}

resource "aws_appautoscaling_scheduled_action" "ecs_stop" {
  count              = var.ecs_stop_schedule == "" ? 0 : 1
  name               = "${local.name}-stop"
  service_namespace  = aws_appautoscaling_target.ecs[0].service_namespace
  resource_id        = aws_appautoscaling_target.ecs[0].resource_id
  scalable_dimension = aws_appautoscaling_target.ecs[0].scalable_dimension
  schedule           = var.ecs_stop_schedule
  timezone           = var.ecs_schedule_timezone

  scalable_target_action {
    min_capacity = 0
    max_capacity = 0
  }
}

resource "aws_appautoscaling_scheduled_action" "ecs_start" {
  count              = var.ecs_start_schedule == "" ? 0 : 1
  name               = "${local.name}-start"
  service_namespace  = aws_appautoscaling_target.ecs[0].service_namespace
  resource_id        = aws_appautoscaling_target.ecs[0].resource_id
  scalable_dimension = aws_appautoscaling_target.ecs[0].scalable_dimension
  schedule           = var.ecs_start_schedule
  timezone           = var.ecs_schedule_timezone

  scalable_target_action {
    min_capacity = var.desired_count
    max_capacity = var.desired_count
  }
}
