# Sending domain identity used by Cognito (invitation, verification emails).
# Verifying the zone covers every 'From' address of the zone and its subdomains.
# NOTE: a fresh AWS account is in the SES SANDBOX (delivery only to verified
# addresses); request production access in the SES console for real traffic.
resource "aws_sesv2_email_identity" "main" {
  email_identity = var.dns_zone
  tags           = local.tags
}

# Easy DKIM: the three CNAME records also act as the domain verification
resource "aws_route53_record" "ses_dkim" {
  count           = 3
  allow_overwrite = true
  zone_id         = data.aws_route53_zone.main.zone_id
  name            = "${aws_sesv2_email_identity.main.dkim_signing_attributes[0].tokens[count.index]}._domainkey.${var.dns_zone}"
  type            = "CNAME"
  ttl             = 600
  records         = ["${aws_sesv2_email_identity.main.dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"]
}

# Custom MAIL FROM domain, for SPF/DMARC alignment
resource "aws_sesv2_email_identity_mail_from_attributes" "main" {
  email_identity         = aws_sesv2_email_identity.main.email_identity
  mail_from_domain       = "mail.${var.dns_zone}"
  behavior_on_mx_failure = "USE_DEFAULT_VALUE"
}

resource "aws_route53_record" "ses_mail_from_mx" {
  allow_overwrite = true
  zone_id         = data.aws_route53_zone.main.zone_id
  name            = "mail.${var.dns_zone}"
  type            = "MX"
  ttl             = 600
  records         = ["10 feedback-smtp.${var.region}.amazonses.com"]
}

resource "aws_route53_record" "ses_mail_from_spf" {
  allow_overwrite = true
  zone_id         = data.aws_route53_zone.main.zone_id
  name            = "mail.${var.dns_zone}"
  type            = "TXT"
  ttl             = 600
  records         = ["v=spf1 include:amazonses.com ~all"]
}

# Cognito refuses an unverified SES identity at user pool creation: wait for the
# DKIM-based verification to complete (usually a few minutes with Route53)
resource "terraform_data" "ses_verified" {
  depends_on       = [aws_route53_record.ses_dkim]
  triggers_replace = [aws_sesv2_email_identity.main.arn]

  provisioner "local-exec" {
    command = <<-CMD
      for i in $(seq 1 30); do
        status="$(aws sesv2 get-email-identity --email-identity "${var.dns_zone}" --region "${var.region}" ${local.aws_cli_profile} --query VerifiedForSendingStatus --output text)"
        [ "$status" = "True" ] && exit 0
        echo "Waiting for SES identity verification (status=$status)..."
        sleep 20
      done
      echo "SES identity ${var.dns_zone} not verified in time" >&2
      exit 1
    CMD
  }
}
