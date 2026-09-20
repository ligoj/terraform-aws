# Variables
variable "application" {
  description = "Application name for tags and prefix resource naming"
  type        = string
  default     = "ligoj"
}
variable "environment" {
  description = "The name of the service. Used to compute the resource naming"
  type        = string
  default     = "prod"
}
variable "region" {
  type    = string
  default = "eu-west-3"
}
variable "profile" {
  type    = string
  default = null
}

variable "account" {
  description = "AWS account id. Unused, kept for tfvars compatibility"
  type        = string
  default     = null
}

variable "expiration" {
  description = "CloudWatch log retention, in days"
  type        = number
  default     = 14
}

variable "container_protocol" {
  type    = string
  default = "HTTP"
}
variable "dns" {
  description = "Public DNS name of the application. When empty, computed from the application name and the DNS zone"
  type        = string
  default     = ""
}
variable "dns_zone" {
  description = "Route53 public zone name hosting all the DNS records"
  type        = string
}
variable "cognito_dns" {
  description = "Cognito custom domain. When empty, computed from the Cognito DNS prefix and the application DNS"
  type        = string
  default     = ""
}
variable "desired_count" {
  type    = number
  default = 1
}
variable "cpu" {
  description = "vCPU count of the Fargate task. Multiplied by 1024 for the task definition"
  type        = number
  default     = 2
}
variable "ram" {
  description = "Memory of the Fargate task, in MiB"
  type        = number
  default     = 8192
}
variable "container_route_private" {
  description = "Cognito authenticated route (path pattern), by container name"
  type        = map(string)
  default = {
    "ligoj-ui" = "*"
  }
}
variable "container_route_public" {
  description = "Unauthenticated routes (path patterns), by container name. Matches the Ligoj 5.x pre-auth whitelist"
  type        = map(list(string))
  default = {
    "ligoj-ui" = ["/themes/*", "/lib/*", "/dist/*", "/assets/*", "/main/public/*", "/logout.html", "/favicon.ico"]
  }
}
variable "container_port" {
  description = "Exposed port, by container name"
  type        = map(number)
  default = {
    "ligoj-ui" = 8080
  }
}
variable "container_health" {
  description = "Health check path, by container name"
  type        = map(string)
  default = {
    # A pre-auth whitelisted static: '/' itself answers 401 to anonymous checks
    "ligoj-ui" = "/favicon.ico"
  }
}
variable "container_route_query" {
  description = "API access 'key:value' query string, by container name"
  type        = map(string)
  default = {
    "ligoj-ui" = "api-key:*"
  }
}
variable "container_route_header" {
  description = "API access 'name:value' HTTP header, by container name"
  type        = map(string)
  default = {
    "ligoj-ui" = "x-api-key:*"
  }
}

variable "context_path" {
  type    = string
  default = ""
}
variable "cidr" {
  type    = string
  default = "10.0.0.0/16"
}
variable "nb_subnets" {
  type    = number
  default = 3
}
variable "cidr_newbits" {
  type    = number
  default = 8
}

variable "cognito_email_verification_subject" {
  type    = string
  default = "[LIGOJ] Verification code"
}
variable "cognito_email_verification_message" {
  type    = string
  default = "Your verification code is {####}"
}
variable "cognito_reply" {
  type    = string
  default = ""
}
variable "cognito_source_arn" {
  description = "SES identity ARN used by Cognito to send emails. When empty, the Terraform-managed identity of the DNS zone is used"
  type        = string
  default     = ""
}
variable "cognito_from" {
  type    = string
  default = ""
}
variable "cognito_admin" {
  type    = string
  default = ""
}
variable "cognito_dns_prefix" {
  type    = string
  default = "login"
}
variable "ligoj_plugins" {
  type    = string
  default = "plugin-id,plugin-id-cognito,plugin-iam-node"
}
variable "ligoj_sign_up_role" {
  type    = string
  default = "USER"
}
variable "ligoj_sign_up_project" {
  type    = string
  default = "true"
}
variable "engine_version" {
  # SELECT AURORA_VERSION();
  # aws rds describe-db-clusters --db-cluster-identifier ligoj-prod
  # aws rds describe-orderable-db-instance-options --engine aurora-postgresql --db-instance-class db.serverless \
  #     --region eu-west-3 --query 'OrderableDBInstanceOptions[].[EngineVersion]' --output text --profile kloudy-website
  description = "Aurora PostgreSQL engine version, compatible with Serverless v2"
  type        = string
  default     = "17.4"
}

variable "ligoj_version" {
  description = "Forced image tag. Empty means the most recently pushed image of the managed ECR repositories (by digest)"
  type        = string
  default     = ""
}
variable "cpu_architecture" {
  description = "Fargate CPU architecture, matching the pushed images"
  type        = string
  default     = "ARM64"
}
variable "enabled" {
  description = "When false, the RDS cluster and the Ligoj user bootstrap are not created"
  type        = bool
  default     = true
}
variable "db_user" {
  type    = string
  default = "ligoj"
}
variable "db_master_user" {
  # Note: 'admin' is a reserved word rejected by RDS for PostgreSQL
  type    = string
  default = "postgres"
}
variable "storage_encrypted" {
  type    = bool
  default = true
}

variable "cognito_email_filter" {
  description = "Regular expression validating the email of a new user at sign-up"
  type        = string
  default     = "(.*@kloudy.io)"
}

variable "cognito_email_filter_message" {
  type    = string
  default = "You are not allowed to use this service"
}

variable "ligoj_sign_up_subscription" {
  description = "Subscriptions created within the welcome project of a new user"
  type = list(object({
    node       = string
    mode       = string
    parameters = optional(list(any), [])
  }))
  default = [{ node = "service:prov:aws:sandbox", mode = "create", parameters = [] }]
}

variable "aurora_min_capacity" {
  description = "Minimum Aurora capacity (ACU). 0 enables scale-to-zero: the instance pauses after 'aurora_auto_pause_seconds' without connections and resumes (~15s) on the next one"
  type        = number
  default     = 0
}
variable "aurora_auto_pause_seconds" {
  description = "Idle time before Aurora pauses, 300 to 86400 seconds. Only used when aurora_min_capacity is 0"
  type        = number
  default     = 300
  validation {
    condition     = var.aurora_auto_pause_seconds >= 300 && var.aurora_auto_pause_seconds <= 86400
    error_message = "aurora_auto_pause_seconds must be between 300 and 86400."
  }
}
variable "aurora_max_capacity" {
  type    = number
  default = 128
}
variable "docker_repository" {
  description = "Image registry prefix, with trailing slash. Empty for Docker Hub; set to the 'ecr_registry' output (after pushing the images) for the Terraform-managed ECR repositories"
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "CloudWatch retention for application and database logs, in days"
  type        = number
  default     = 30
}
variable "alarm_email" {
  description = "Email receiving the CloudWatch alarm notifications. When empty, no subscription is created"
  type        = string
  default     = ""
}

variable "cloudfront_allowed_countries" {
  description = "ISO 3166-1 alpha-2 country codes allowed to access the CloudFront distribution. Empty means no geo restriction"
  type        = list(string)
  default     = []
}

variable "web_acl_arn" {
  description = "Existing WAFv2 Web ACL ARN (CLOUDFRONT scope, us-east-1) attached to the distribution as-is. Empty: a Web ACL is generated from the two variables below when at least one is set"
  type        = string
  default     = ""
}
variable "web_acl_allowed_ipset_arns" {
  description = "Existing WAFv2 IP set ARNs (CLOUDFRONT scope, us-east-1): when non-empty, only these IPs (or the secret cookie) get through. Empty: no IP restriction"
  type        = list(string)
  default     = []
}
variable "web_acl_allowed_paths" {
  description = "Regexes (WAFv2 syntax, at most 10) of the URI paths the application serves: anything else is blocked at the edge, for everybody. Empty: no route restriction. Default: the Ligoj UI pages, the ALB Cognito callback, the REST API, the plugin resources under /main, the static bundles and /manage/health; the rest of /manage (actuator) is deliberately absent"
  type        = list(string)
  default = [
    "^/$",
    "^/(index|login|login-by-api-key|logout|mfa|400|401|403|404|405|500|503)\\.html$",
    "^/(login(/mfa(/passkey)?|-by-api-key)?|logout)$",
    "^/oauth2/idpresponse$",
    "^/favicon\\.ico$",
    "^/rest(/|$)",
    "^/manage/health$",
    "^/main/[A-Za-z0-9._/-]+\\.(html|css|js|json|map|png|jpe?g|gif|svg|webp|ico|woff2?|ttf|eot)$",
    "^/(dist|lib|assets|themes)/[A-Za-z0-9._/-]+$",
  ]
}

variable "web_acl_secret_cookie" {
  description = "Secret value: any request whose Cookie header contains it bypasses the IP allowlist of the generated Web ACL. Empty disables the bypass"
  type        = string
  sensitive   = true
  default     = ""
}

variable "ecs_stop_schedule" {
  description = "Optional Application Auto Scaling cron stopping the ECS tasks (scale to 0), e.g. 'cron(0 20 ? * MON-FRI *)'. Empty = never"
  type        = string
  default     = ""
}
variable "ecs_start_schedule" {
  description = "Optional Application Auto Scaling cron starting the ECS tasks (scale to desired_count), e.g. 'cron(0 7 ? * MON-FRI *)'. Empty = never"
  type        = string
  default     = ""
}
variable "ecs_schedule_timezone" {
  description = "IANA time zone of the ECS start/stop schedules"
  type        = string
  default     = "UTC"
}
