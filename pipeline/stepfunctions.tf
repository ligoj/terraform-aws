# Release workflow: build the images, deploy the stack, confirm the ECS rollout.
# Pure AWS SDK integrations (no Lambda). Driven by pipeline/release.py, which
# adds the client-side checks (ECR, container logs, HTTP readiness); it can also
# be started from the console or EventBridge with the input {"build": true|false}.

locals {
  app_name = "${var.application}-${var.environment}"

  release_definition = {
    Comment        = "Ligoj release: docker images -> terraform deploy -> ECS rollout"
    StartAt        = "ShouldBuild"
    TimeoutSeconds = 5400
    States = {
      ShouldBuild = {
        Type = "Choice"
        Choices = [{
          Variable      = "$.build"
          BooleanEquals = false
          Next          = "StartDeploy"
        }]
        Default = "StartBuild"
      }

      # ---- docker images ----
      StartBuild = {
        Type           = "Task"
        Resource       = "arn:aws:states:::aws-sdk:codepipeline:startPipelineExecution"
        Parameters     = { Name = aws_codepipeline.docker.name }
        ResultSelector = { "PipelineExecutionId.$" = "$.PipelineExecutionId" }
        ResultPath     = "$.build_execution"
        Next           = "WaitBuild"
      }
      WaitBuild = { Type = "Wait", Seconds = 30, Next = "GetBuild" }
      GetBuild = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:codepipeline:getPipelineExecution"
        Parameters = {
          PipelineName            = aws_codepipeline.docker.name
          "PipelineExecutionId.$" = "$.build_execution.PipelineExecutionId"
        }
        ResultSelector = { "Status.$" = "$.PipelineExecution.Status" }
        ResultPath     = "$.build_status"
        Next           = "BuildDone"
      }
      BuildDone = {
        Type = "Choice"
        Choices = [
          { Variable = "$.build_status.Status", StringEquals = "Succeeded", Next = "StartDeploy" },
          { Variable = "$.build_status.Status", StringEquals = "InProgress", Next = "WaitBuild" },
        ]
        Default = "BuildFailed"
      }
      BuildFailed = { Type = "Fail", Error = "ImageBuildFailed", CausePath = "$.build_status.Status" }

      # ---- terraform deploy ----
      StartDeploy = {
        Type           = "Task"
        Resource       = "arn:aws:states:::aws-sdk:codepipeline:startPipelineExecution"
        Parameters     = { Name = aws_codepipeline.main.name }
        ResultSelector = { "PipelineExecutionId.$" = "$.PipelineExecutionId" }
        ResultPath     = "$.deploy_execution"
        Next           = "WaitDeploy"
      }
      WaitDeploy = { Type = "Wait", Seconds = 30, Next = "GetDeploy" }
      GetDeploy = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:codepipeline:getPipelineExecution"
        Parameters = {
          PipelineName            = aws_codepipeline.main.name
          "PipelineExecutionId.$" = "$.deploy_execution.PipelineExecutionId"
        }
        ResultSelector = { "Status.$" = "$.PipelineExecution.Status" }
        ResultPath     = "$.deploy_status"
        Next           = "DeployDone"
      }
      DeployDone = {
        Type = "Choice"
        Choices = [
          { Variable = "$.deploy_status.Status", StringEquals = "Succeeded", Next = "CheckService" },
          { Variable = "$.deploy_status.Status", StringEquals = "InProgress", Next = "WaitDeploy" },
        ]
        Default = "DeployFailed"
      }
      DeployFailed = { Type = "Fail", Error = "DeployFailed", CausePath = "$.deploy_status.Status" }

      # ---- ECS rollout (the apply already waits for steady state; this is the proof) ----
      CheckService = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:ecs:describeServices"
        Parameters = {
          Cluster  = local.app_name
          Services = [local.app_name]
        }
        ResultSelector = {
          "RolloutState.$" = "$.Services[0].Deployments[0].RolloutState"
          "Deployments.$"  = "States.ArrayLength($.Services[0].Deployments)"
          "Running.$"      = "$.Services[0].RunningCount"
          "Desired.$"      = "$.Services[0].DesiredCount"
        }
        ResultPath = "$.service"
        Next       = "ServiceStable"
      }
      ServiceStable = {
        Type = "Choice"
        Choices = [
          {
            And = [
              { Variable = "$.service.RolloutState", StringEquals = "COMPLETED" },
              { Variable = "$.service.Deployments", NumericEquals = 1 },
            ]
            Next = "Released"
          },
          { Variable = "$.service.RolloutState", StringEquals = "FAILED", Next = "RolloutFailed" },
        ]
        Default = "WaitService"
      }
      WaitService   = { Type = "Wait", Seconds = 20, Next = "CheckService" }
      RolloutFailed = { Type = "Fail", Error = "RolloutFailed", Cause = "ECS deployment rolled back (circuit breaker)" }
      Released      = { Type = "Succeed" }
    }
  }
}

resource "aws_iam_role" "release" {
  name = "${local.name}-release"
  tags = local.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "states.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "release" {
  name = "${local.name}-release"
  role = aws_iam_role.release.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["codepipeline:StartPipelineExecution", "codepipeline:GetPipelineExecution"]
        Resource = [aws_codepipeline.docker.arn, aws_codepipeline.main.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["ecs:DescribeServices"]
        Resource = ["arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:service/${local.app_name}/${local.app_name}"]
      }
    ]
  })
}

resource "aws_sfn_state_machine" "release" {
  name       = "${local.name}-release"
  role_arn   = aws_iam_role.release.arn
  definition = jsonencode(local.release_definition)
  tags       = local.tags
}

output "release_state_machine_arn" {
  value = aws_sfn_state_machine.release.arn
}
