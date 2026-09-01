dns_zone      = "corp.com"
dns           = "ligoj.corp.com"
ligoj_version = "4.1.0"
profile       = "my-profile"

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

# Subscribe this address to the CloudWatch alarm notifications
#alarm_email = "ligoj-admin@corp.com"
