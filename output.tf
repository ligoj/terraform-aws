output "db_secret_master_arn" {
  value = aws_secretsmanager_secret.rds_master.arn
}
output "db_secret_tdp_arn" {
  value = aws_secretsmanager_secret.rds_tdp.arn
}
output "db_arn" {
  value = one(aws_rds_cluster.main[*].arn)
}
output "cognito_client_id" {
  value = aws_cognito_user_pool_client.main.id
}
output "cognito_pool_id" {
  value = aws_cognito_user_pool.main.id
}
output "cognito_client_secret" {
  sensitive = true
  value     = aws_cognito_user_pool_client.main.client_secret
}
output "cognito_ligoj_admin_id" {
  value = local.cognito_admin_sub
}
output "ligoj_admin" {
  value = local.cognito_admin
}
output "ligoj_admin_api_token" {
  sensitive = true
  value     = local.ligoj_admin_api_token
}
output "ligoj_url" {
  value = local.dns
}
output "cloudfront_domain" {
  value = aws_cloudfront_distribution.main.domain_name
}
output "ecr_registry" {
  description = "Value for 'docker_repository' to pull from the managed ECR repositories"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/"
}
output "ses_identity_arn" {
  value = aws_sesv2_email_identity.main.arn
}
