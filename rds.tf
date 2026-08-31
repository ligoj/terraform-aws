resource "aws_rds_cluster_parameter_group" "main" {
  # Family derived from the engine major version: '17.4' -> 'aurora-postgresql17'
  name        = "${local.name}-cluster"
  family      = "aurora-postgresql${split(".", var.engine_version)[0]}"
  description = local.name
}

resource "aws_rds_cluster_instance" "main" {
  count              = var.enabled ? 1 : 0
  cluster_identifier = aws_rds_cluster.main[count.index].id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.main[count.index].engine
  engine_version     = aws_rds_cluster.main[count.index].engine_version

  # 7 days retention is within the Performance Insights free tier
  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  provisioner "local-exec" {
    when    = create
    command = local.rds_data_commands[0]
  }
  provisioner "local-exec" {
    when    = create
    command = local.rds_data_commands[1]
  }
  provisioner "local-exec" {
    when    = create
    command = local.rds_data_commands[2]
  }
}

# Owns the log group RDS would otherwise auto-create with unlimited retention
resource "aws_cloudwatch_log_group" "rds" {
  count             = var.enabled ? 1 : 0
  name              = "/aws/rds/cluster/${local.name}/postgresql"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_rds_cluster" "main" {
  count                           = var.enabled ? 1 : 0
  cluster_identifier              = local.name
  depends_on                      = [aws_cloudwatch_log_group.rds]
  apply_immediately               = true
  engine                          = "aurora-postgresql"
  engine_mode                     = "provisioned"
  engine_version                  = var.engine_version
  enable_http_endpoint            = true
  master_username                 = var.db_master_user
  master_password                 = random_password.rds_master.result
  skip_final_snapshot             = true
  copy_tags_to_snapshot           = true
  backup_retention_period         = 7
  port                            = 5432
  db_subnet_group_name            = aws_db_subnet_group.main.name
  vpc_security_group_ids          = [aws_security_group.aurora.id]
  storage_encrypted               = var.storage_encrypted
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.main.id
  enabled_cloudwatch_logs_exports = ["postgresql"]
  tags                            = local.tags

  serverlessv2_scaling_configuration {
    max_capacity = var.aurora_max_capacity
    min_capacity = var.aurora_min_capacity
  }
}

// DB Subnet Group creation
resource "aws_db_subnet_group" "main" {
  name        = local.name
  description = "Group of DB subnets"
  subnet_ids  = aws_subnet.main[*].id
  tags        = local.tags
}

resource "random_password" "rds_master" {
  length           = 16
  special          = true
  override_special = "_+.-"
  min_numeric      = 1
  min_special      = 1
  min_upper        = 1
}

resource "random_password" "rds_app" {
  length           = 12
  special          = true
  override_special = "_+.-"
  min_numeric      = 1
  min_special      = 1
  min_upper        = 1
}

resource "random_password" "rds_tdp" {
  length           = 12
  special          = true
  override_special = "_+.-"
  min_numeric      = 1
  min_special      = 1
  min_upper        = 1
}

resource "aws_secretsmanager_secret" "rds_master" {
  name                    = "${local.name}-master"
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "rds_master" {
  secret_id      = aws_secretsmanager_secret.rds_master.id
  secret_string  = jsonencode({ username = var.db_master_user, password = random_password.rds_master.result })
  version_stages = ["AWSCURRENT"]
}

resource "aws_secretsmanager_secret" "rds_tdp" {
  name                    = "${local.name}-tdp"
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "rds_tdp" {
  secret_id      = aws_secretsmanager_secret.rds_tdp.id
  secret_string  = local.db_tdp
  version_stages = ["AWSCURRENT"]
}

resource "aws_secretsmanager_secret" "rds_app" {
  name                    = "${local.name}-db"
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "rds_app" {
  secret_id      = aws_secretsmanager_secret.rds_app.id
  secret_string  = local.db_password
  version_stages = ["AWSCURRENT"]
}

locals {
  # Seed the database through the data API Lambda: Terraform cannot reach the private Aurora cluster
  rds_data_commands = [for script in ["00-create-database.sql", "01-create-user.sql", "02-grant.sql"] : <<-CMD
    aws lambda invoke \
    --function-name "${local.lambda_data_api_name}" \
    --region "${var.region}" \
    ${local.aws_cli_profile} \
    --payload '${base64encode(<<-JSON
{
  "database": null,
  "query":   "${base64encode(templatefile("${path.module}/sql/${script}", { db_user = local.db_user, db_password = local.db_password }))}", 
  "secret":  "${base64encode(aws_secretsmanager_secret_version.rds_master.secret_string)}"
}
JSON
)}' \
    "rds-${script}.log"
CMD
]
# Empty when no profile is set (e.g. CodeBuild, where the role provides credentials)
aws_cli_profile = var.profile == null || var.profile == "" ? "" : "--profile ${var.profile}"
db_user         = var.db_user
db_password     = random_password.rds_app.result
db_password_arn = aws_secretsmanager_secret_version.rds_app.secret_arn
db_tdp          = random_password.rds_tdp.result
db_tdp_arn      = aws_secretsmanager_secret_version.rds_tdp.secret_arn
db_host         = var.enabled ? aws_rds_cluster.main[0].endpoint : "localhost"
}

resource "aws_security_group" "aurora" {
  name        = "${local.name}-aurora"
  description = "Security Group pour Aurora"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.tags, { "Name" = "${local.name}-aurora" })
}
resource "aws_security_group_rule" "aurora_from_ecs" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ecs.id
  security_group_id        = aws_security_group.aurora.id
}
resource "aws_security_group_rule" "aurora_from_data_api" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.data_api.id
  security_group_id        = aws_security_group.aurora.id
}

resource "aws_security_group_rule" "aurora_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = -1
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = aws_security_group.aurora.id
}
