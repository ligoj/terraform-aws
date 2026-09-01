variable "application" {
  description = "Application name for tags and prefix resource naming"
  type        = string
  default     = "ligoj"
}
variable "environment" {
  type    = string
  default = "prod"
}
variable "region" {
  type    = string
  default = "eu-west-3"
}
variable "profile" {
  description = "AWS profile used to run THIS sub-project locally, never used by the pipeline itself"
  type        = string
  default     = null
}

variable "repository" {
  description = "GitHub repository (owner/name) hosting the main Terraform stack"
  type        = string
  default     = "ligoj/terraform-aws"
}
variable "branch" {
  description = "Branch whose pushes trigger a deployment"
  type        = string
  default     = "main"
}

variable "state_bucket" {
  description = "S3 bucket holding the MAIN stack Terraform state"
  type        = string
}
variable "state_key" {
  description = "S3 key of the MAIN stack Terraform state"
  type        = string
  default     = "ligoj.tfstate"
}
variable "state_region" {
  description = "Region of the state bucket. Defaults to the deployment region"
  type        = string
  default     = ""
}

variable "tfvars_s3_uri" {
  description = "Optional s3://bucket/key URI of the tfvars applied by the pipeline (must NOT set 'profile'). When empty, only variable defaults are used"
  type        = string
  default     = ""
}

variable "terraform_version" {
  description = "Terraform CLI version installed in CodeBuild"
  type        = string
  default     = "1.16.0"
}

variable "require_approval" {
  description = "When true, a manual approval stage is inserted between plan and apply"
  type        = bool
  default     = false
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "app_repository" {
  description = "GitHub repository (owner/name) of the Ligoj application"
  type        = string
  default     = "ligoj/ligoj"
}
variable "app_branch" {
  description = "Application branch whose pushes trigger an image build"
  type        = string
  default     = "master"
}
