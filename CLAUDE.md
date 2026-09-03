# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-root Terraform configuration (no modules) that deploys [Ligoj](https://github.com/ligoj/ligoj)
(4.x, PostgreSQL-based) on AWS: Fargate behind an ALB with Cognito authentication, Aurora PostgreSQL
Serverless v2, EFS, and three Lambdas. Everything lives in the repo root — one `.tf` file per AWS concern.
Requires Terraform >= 1.5 and AWS provider ~> 6.0 (declared in `provider.tf` along with `random`,
`archive`, `external`).

## Commands

There is no test suite. Validation is `fmt` / `validate` / `plan`.

```bash
# Backend is only partially configured in provider.tf; bucket/key/profile must be supplied at init.
aws sso login --profile <profile>            # if the profile uses SSO
terraform init -upgrade -reconfigure \
    -backend-config="bucket=terraform.ligoj.io" \
    -backend-config="key=ligoj-saas.tfstate" \
    -backend-config="region=eu-west-3" \
    -backend-config="profile=<profile>"

terraform init -backend=false                 # enough for validate, no AWS credentials needed
terraform fmt -recursive
terraform validate
terraform plan  -var-file="main.sample.tfvars"
terraform apply -var-file="main-private.saas.tfvars" -auto-approve

# Iterate on one piece without touching the rest
terraform apply -var-file="..." -target=aws_lambda_function.post_confirmation
```

`main.sample.tfvars` is the tracked template. `main-private.*.tfvars` are gitignored per-tenant files
(two exist locally: `saas`, `enedis`) — never commit them.

`pipeline/` is a **standalone sub-project** (own state key, own `terraform init`) provisioning a
CodePipeline V2 + CodeBuild pair that plans/applies the root stack on `main` branch pushes — see
`pipeline/README.md` for setup (GitHub connection handshake, CI tfvars uploaded to S3 without
`profile`). Its buildspecs (`pipeline/buildspec-*.yml`) are read from the source artifact at build
time. The root stack treats a null/empty `var.profile` as "ambient credentials" so it runs both
locally (profile) and in CodeBuild (role) — keep it that way when touching `local-exec`/`external`
commands.

Required on the machine running Terraform, because of `local-exec` and `external` data sources:
`aws` CLI (with the named profile), `jq`, `bash`, `npm`.

## Architecture

**Request path.** Client → Route53 alias → **CloudFront** (`cloudfront.tf`, viewer cert in us-east-1,
`PriceClass_100`) → **VPC origin** → internal ALB (443, in-region ACM cert). CloudFront cache behaviors:
`/rest*` and the default (authenticated app, OAuth callback) use `CachingDisabled`; `/themes/*` and
`/favicon.ico` use `CachingOptimized`. Every behavior uses the `AllViewer` origin-request policy — the
forwarded `Host` header is what makes the ALB host/Cognito rules match AND what lets CloudFront validate
the origin TLS cert (the internal ALB serves the `local.dns` cert, not its `*.elb.amazonaws.com` name);
never drop it. The ALB SG only admits the `CloudFront-VPCOrigins-Service-SG` (VPC-origin traffic does NOT source
from the ENI's in-VPC IP — a VPC-CIDR rule silently drops it). The CloudFront and
ALB certs cover the same domain, so the CloudFront cert validation reuses the ALB validation records.
Optional edge controls: `cloudfront_allowed_countries` (geo allowlist) and `web_acl_arn` /
`web_acl_allowed_ipset_arn` (`waf.tf` — the latter generates an IP-allowlist Web ACL around an
existing us-east-1 CLOUDFRONT-scope IP set; CloudFront only accepts Web ACL ARNs, never IP set ARNs).
The ALB HTTPS listener defaults to a 403 fixed response; traffic is only forwarded by listener rules,
keyed by container name (`for_each` over the `container_*` maps) in priority bands defined in `alb.tf`:

- 10+ `public` — path allowlist (`/themes/*`, `/logout.html`, …), no auth
- 20+ `public_header` — API access via `x-api-key` header
- 30+ `public_query` — API access via `api-key` + `api-user` query parameters
- 50+ `private` — `authenticate-cognito` action, then forward (everything else, `*`)

Authenticated requests reach the `ligoj-ui` container with `X-Amzn-Oidc-Identity` / `X-Amzn-Oidc-Accesstoken`
headers; `task-definition/ligoj-ui.json` wires those into Ligoj's `security.pre-auth-*` options. **The Ligoj
login is the Cognito `sub` (UUID), not the email.**

**One task, two containers.** `ecs-task-definition.tf` renders both `task-definition/*.json` templates
(`jsonencode(jsondecode(templatefile(...)))`) into a single Fargate task. Only `ligoj-ui` is exposed (8080,
ALB target group); it calls `ligoj-api` over `http://localhost:8081/ligoj-api`. `ligoj-api` mounts EFS at
`/home/ligoj` **through an access point forcing uid/gid 1001** (the non-root user of the 4.x/5.x
images) and pulls DB/crypto secrets from Secrets Manager. Both containers need a **writable root
filesystem** (Jetty temp dirs in `/tmp`, the UI's startup `sed` of the SPA context placeholder) —
do not set `readonlyRootFilesystem`, and never mount a Fargate ephemeral volume over `/tmp`
(Fargate mounts them root-owned 0755, unwritable for uid 1001). Ligoj 4.x defaults to PostgreSQL
(`jdbc.vendor=postgresql`, port 5432, bundled `org.postgresql` driver), so the task definition only
overrides `jdbc.host` / `jdbc.username` (plus `JDBC_PASSWORD` via Spring relaxed env binding). The
`container_*` variables are maps keyed by container name — only `ligoj-ui` has entries.

**Bootstrap chain (the fragile part).** Terraform cannot reach the private Aurora cluster, so DB seeding is
done by proxy through a Lambda, in this order:

1. `lambda_data_api` — a VPC Lambda (`lambda_data_api/index.js`, `pg` driver) that executes an arbitrary
   base64 SQL string against Aurora using a base64 master-credentials JSON passed in the event; a `null`
   database in the event targets the `postgres` maintenance DB (needed for `CREATE DATABASE`). SELECTs come
   back as `{records: [...]}` and writes as `{affectedRows: n}` — `ligoj_new_user.sh` parses that contract.
   `node_modules` are installed by `terraform_data.lambda_data_api` (`npm ci`), re-triggered only when
   `package.json`/`package-lock.json`/`index.js` change.
2. `aws_rds_cluster_instance.main` `local-exec` provisioners (`when = create`) invoke it once per file in
   `sql/` (create database → create user → make the user own the database).
3. `aws_cognito_user.admin` creates the admin account (invitation email + temporary password); its `sub`
   attribute feeds the next step.
4. `ligoj_new_user.sh` (run twice, via `terraform_data` **resources** — NEVER convert these back to
   data sources: they must execute at apply time only, after `aws_ecs_service.main` reaches steady
   state (`wait_for_steady_state`), because Ligoj creates the schema and seeds `s_role` at first boot)
   INSERTs into `s_user` / `s_role_assignment` / `s_api_token` via the same Lambda, drawing ids from the
   native `<table>_seq` PostgreSQL sequences (`nextval()`). The `user` column is a PG reserved word and
   stays double-quoted. Tokens are stored with a literal `_plain_` hash marker — the stored value IS
   `_plain_` + the `random_password`, so Terraform never needs to read anything back.
5. `lambda_pre_signup` (regex email allowlist) and `lambda_post_confirmation` (calls the Ligoj REST API with
   the `cognito_sign_up` API token to create the user, grant a role, and optionally create a welcome project +
   subscription; uses native `fetch`) are attached to the Cognito user pool. All Lambdas run `nodejs22.x`.

Steps 2 and 4 are ordered by explicit `depends_on` (the Lambda is referenced only by NAME — Terraform
sees no implicit dependency; keep the `depends_on` when refactoring). `ligoj_new_user.sh` retries up to
~7 minutes per statement and waits up to 10 minutes for the `ADMIN` role to be seeded. A from-scratch
deployment MUST go through `apply` (the pipeline default): a standalone `plan` of a bootstrapped-but-
unhealthy stack has nothing to defer and nothing to fix. A partial failure usually means re-running
`apply` rather than tainting.

## Conventions and gotchas

- **Naming/tagging:** every resource is `${var.application}-${var.environment}` via `local.name`, tagged from
  `local.tags`. `local.*` in `main.tf` derives `dns` and all `cognito_*` fallbacks when the variables are left
  empty — resources reference the `local.` values, never the `var.cognito_*` ones directly.
- **us-east-1:** the Cognito custom-domain certificate uses the provider v6 per-resource `region = "us-east-1"`
  (no provider alias) — ACM for CloudFront-fronted Cognito domains is us-east-1 only.
- **Aurora:** `var.engine_version` (e.g. `17.4`) drives the cluster and the parameter-group family
  (`aurora-postgresql17` is derived from its major). `var.db_master_user` defaults to `postgres` — `admin`
  is a reserved word on RDS for PostgreSQL.
- `var.cpu` is a vCPU **count** (multiplied by 1024 for Fargate and passed as `-XX:ActiveProcessorCount`);
  `var.ram` is MiB. tfvars files carry commented "import phase" values (higher cpu/ram, `aurora_min_capacity=16`)
  used for bulk imports, then reverted.
- **ECR** (`ecr.tf`): managed repositories `ligoj/ligoj-ui|api` (scan-on-push, lifecycle expiry), fed by
  the `pipeline/docker.tf` image pipeline (ligoj/ligoj@master, native arm64 build, inline buildspec).
  Image selection: empty `var.ligoj_version` (default) deploys the **digest of the most recently pushed
  ECR image** (`data.aws_ecr_image` `most_recent`); a non-empty value forces `docker_repository` + tag.
  Fresh accounts must run the docker pipeline once before the first main apply (empty repo fails the
  data source). Fargate tasks run on **ARM64** (`var.cpu_architecture`) — images must match.
  The docker buildspec activates `app-api/prepare-build.sh` (copied from the `-sample`) so the
  image bundles `plugin-vendors-default.p12` built from `app-api/plugin-vendors/*.cer`; that is what
  makes signed plugins show as VERIFIED (defaults: `${ligoj.home}/plugin-vendors.p12`, `changeit`).
  The container installs it into `LIGOJ_HOME` (EFS) **only when absent** — after a vendor cert
  rotation, delete `/home/ligoj/plugin-vendors.p12` on EFS so the next boot reinstalls it.
- **SES** (`ses.tf`): SESv2 domain identity on `var.dns_zone` (Easy DKIM + custom MAIL FROM records in
  Route53), used as the default `cognito_source_arn`. A `terraform_data` waits for DKIM verification
  because Cognito validates the identity at pool creation. Fresh AWS accounts are in the SES sandbox
  (delivery only to verified addresses) — production access is a manual SES console request. tfvars
  overriding `cognito_source_arn` (external identities, e.g. kloudy.io) bypass all of this.
- The Cognito login page uses **Managed Login v2** (`managed_login_version = 2` on the domain) branded by
  `aws_cognito_managed_login_branding`: `assets/managed-login.json` is the FULL settings document (exported
  from Cognito's defaults, palette blue `#4589ca` / navy `#034b80` / orange `#ff6900` applied, colors as
  RRGGBBAA) and `assets/logo.svg` is both the form logo and the SVG favicon (v2 accepts SVG, the classic
  UI did not). To add a setting, export the defaults again (`create-managed-login-branding
  --use-cognito-provided-values` + `describe-managed-login-branding --return-merged-resources`, then
  delete) rather than guessing keys. The palette source of truth is `ligoj/app-ui/.../assets/logo.svg`.
- **Off-hours schedules** (`ecs-schedule.tf`): `ecs_stop_schedule` / `ecs_start_schedule` (Application Auto
  Scaling 6-field crons, `ecs_schedule_timezone`) scale the ECS service to 0 and back to `desired_count`
  through a scalable target — no Lambda. An apply during the stopped window restarts the tasks until the
  next stop; the ECS alarms use `notBreaching` on missing data so a stopped service does not flap them.
- **Observability** (`observability.tf`): ALB access logs to an S3 bucket expiring after
  `var.log_retention_days` (also the CloudWatch retention for ECS/RDS logs), ECS Container Insights,
  Aurora Performance Insights (7-day free tier), and CloudWatch alarms (ALB 5xx, unhealthy targets,
  ECS CPU/memory, Aurora ACU, CloudFront 5xx rate) publishing to an SNS topic — set `var.alarm_email`
  to subscribe.
- The helper script writes `*.log` files into the repo root (`ligoj_new_user-<user>.log`,
  `rds-*.sql.log`). These are gitignored.
- `.terraform.lock.hcl` is gitignored (the `**.hcl` pattern), so provider pinning is local-only; `~>`
  constraints in `provider.tf` are the real bound.
- Lambda zips are built into `.build/` (gitignored), NOT `.terraform/`: the pipeline's plan artifact
  excludes `.terraform/` but must carry the zips to the apply stage. Keep archive `output_path`s there.
- Both backends use S3 native locking (`use_lockfile = true`, hence Terraform >= 1.10). Never run a
  local apply/destroy while the pipeline may run — and vice versa; the lock now enforces this.
