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
  description = "Unauthenticated routes (path patterns), by container name"
  type        = map(list(string))
  default = {
    "ligoj-ui" = ["/themes/*", "/logout.html", "/favicon.ico"]
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
  default = "plugin-id,plugin-id-cognito"
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
  type    = number
  default = 0.5
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
  description = "Existing WAFv2 Web ACL ARN (CLOUDFRONT scope, us-east-1) attached to the distribution. Empty means no WAF, unless an IP set is given below"
  type        = string
  default     = ""
}
variable "web_acl_allowed_ipset_arn" {
  description = "Existing WAFv2 IP set ARN (CLOUDFRONT scope, us-east-1): when set, a Web ACL is created allowing only these IPs and attached to the distribution"
  type        = string
  default     = ""
}
