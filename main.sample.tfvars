dns_zone = "corp.com"
dns      = "ligoj.corp.com"
profile  = "my-profile"

# Force an image tag; empty (default) deploys the latest image pushed to ECR
#ligoj_version = "4.1.0"

# For steady phase
cpu = 2
ram = 8192

# For import phase
#cpu=4
#ram=8192
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
