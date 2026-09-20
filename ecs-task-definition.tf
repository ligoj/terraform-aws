resource "aws_ecs_task_definition" "main" {
  family                   = var.application
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = local.sizing.task.cpu
  memory                   = local.sizing.task.memory
  execution_role_arn       = aws_iam_role.task.arn
  # Task role = the identity of the RUNNING containers. Without it ECS injects no
  # AWS_CONTAINER_CREDENTIALS_RELATIVE_URI, and the Cognito plugin (which signs its
  # own requests with the host role credentials) has no credentials at all
  task_role_arn = aws_iam_role.app.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([
    jsondecode(templatefile("${path.module}/task-definition/ligoj-ui.json", merge(local.container_definition, {
      image              = local.image["ligoj-ui"]
      context_path       = var.context_path
      cpu                = local.sizing.ui.cpu
      memory             = local.sizing.ui.memory
      memory_reservation = local.sizing.ui.memory_reservation
      java_memory        = local.sizing.ui.java_memory
    }))),
    jsondecode(templatefile("${path.module}/task-definition/ligoj-api.json", merge(local.container_definition, {
      image              = local.image["ligoj-api"]
      cpu                = local.sizing.api.cpu
      memory             = local.sizing.api.memory
      memory_reservation = local.sizing.api.memory_reservation
      java_memory        = local.sizing.api.java_memory
      nb_cpu             = local.sizing.api.active_processor_count
      db_tdp_arn         = local.db_tdp_arn
      db_user            = local.db_user
      db_password_arn    = local.db_password_arn
      db_host            = local.db_host
      ligoj_plugins      = var.ligoj_plugins
    })))
  ])
  volume {
    name = "efs"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.main.id
      root_directory     = "/"
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.ligoj.id
      }
    }
  }
}

resource "aws_iam_role" "task" {
  name               = "${local.name}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
  tags               = local.tags
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "task" {
  role       = aws_iam_role.task.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_policy" "task_secret" {
  name        = "${local.name}-ecs-secret"
  description = "Ligoj ECS Task policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [local.db_password_arn, local.db_tdp_arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "task_secret" {
  role       = aws_iam_role.task.name
  policy_arn = aws_iam_policy.task_secret.arn
}

# --- Task role: what the application itself may call (distinct from the execution
# role, which only pulls the image and reads the secrets at task start) ---
resource "aws_iam_role" "app" {
  name               = "${local.name}-ecs-app"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
  tags               = local.tags
}

# plugin-id-cognito (UserCognitoRepository): DescribeUserPool, ListUsers, AdminGetUser
# on the pool of this stack; the group operations cover the next plugin versions
resource "aws_iam_policy" "app_cognito" {
  name        = "${local.name}-ecs-app-cognito"
  description = "Ligoj Cognito identity plugin, read-only on the user pool"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:DescribeUserPool",
          "cognito-idp:ListUsers",
          "cognito-idp:AdminGetUser",
          "cognito-idp:GetGroup",
          "cognito-idp:ListGroups",
          "cognito-idp:AdminListGroupsForUser",
          "cognito-idp:ListUsersInGroup"
        ]
        Resource = aws_cognito_user_pool.main.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "app_cognito" {
  role       = aws_iam_role.app.name
  policy_arn = aws_iam_policy.app_cognito.arn
}
