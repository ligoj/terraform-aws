dns_zone = "corp.com"
dns      = "ligoj.corp.com"
profile  = "my-profile"

# Force an image tag; empty (default) deploys the latest image pushed to ECR
#ligoj_version = "4.1.0"

# Sizing: vCPU only (2, 4, 8, 16, 32); memory and JVM settings derive from it (ecs-sizing.tf)
cpu = 2

# For import phase (bulk imports), then revert
#cpu=4
#aurora_min_capacity=16

# Emails are sent through the Terraform-managed SES identity of the DNS zone
# (From/Reply-To and the Cognito domain 'login.<dns>' default from 'dns')
cognito_admin                = "ligoj-admin@corp.com"
cognito_email_filter         = "(any_pattern|.*@corp.com)"
cognito_email_filter_message = "Only corporate staff can sign up to this application"

# Empty (default) pulls from Docker Hub; set to the 'ecr_registry' output to
# pull from the Terraform-managed ECR repositories (push the images first)
#docker_repository = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/"

# Restrict CloudFront to these countries (ISO 3166-1 alpha-2); empty = worldwide
#cloudfront_allowed_countries = ["FR"]

# Subscribe this address to the CloudWatch alarm notifications
#alarm_email = "ligoj-admin@corp.com"

# Optional off-hours shutdown of the Fargate tasks (Application Auto Scaling cron, 6 fields)
#ecs_stop_schedule     = "cron(0 20 ? * MON-FRI *)"
#ecs_start_schedule    = "cron(0 7 ? * MON-FRI *)"
#ecs_schedule_timezone = "Europe/Paris"

# Edge Web ACL (us-east-1 WAFv2). The known application routes are always enforced
# (web_acl_allowed_paths default, set [] to disable); IP sets restrict the sources
#web_acl_allowed_ipset_arns = ["arn:aws:wafv2:us-east-1:123456789012:global/ipset/office/..."]
#web_acl_secret_cookie      = "some-random-uuid" # 'waf_bypass' cookie value bypassing the IP allowlist
