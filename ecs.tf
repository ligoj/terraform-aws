resource "aws_ecs_cluster" "main" {
  name = local.name
  tags = local.tags
}

resource "aws_security_group" "ecs" {
  name        = "${local.name}-ecs"
  description = "Security Group pour ECS/Fargate"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.tags, { "Name" = "${local.name}-ecs" })
}
resource "aws_security_group_rule" "ecs_web" {
  for_each                 = var.container_port
  type                     = "ingress"
  from_port                = each.value
  to_port                  = each.value
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.ecs.id
}

resource "aws_security_group_rule" "ecs_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = -1
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = aws_security_group.ecs.id
}
