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

**Request path.** Client → Route53 CNAME → ALB (443, ACM cert). The HTTPS listener defaults to a 403
fixed response; traffic is only forwarded by listener rules, keyed by container name (`for_each` over the
`container_*` maps) in priority bands defined in `alb.tf`:

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
`/home/ligoj` and pulls DB/crypto secrets from Secrets Manager. Ligoj 4.x defaults to PostgreSQL
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
4. `ligoj_new_user.sh` (`external`, run twice — for the `cognito_sign_up` service account and for the admin
   `sub`, both gated on `var.enabled`) INSERTs into `s_user` / `s_role_assignment` / `s_api_token` via the
   same Lambda, drawing ids from the native `<table>_seq` PostgreSQL sequences Hibernate creates
   (`nextval()`). The `user` column is a PG reserved word and stays double-quoted in SQL. Tokens are stored
   with a literal `_plain_` hash marker.
5. `lambda_pre_signup` (regex email allowlist) and `lambda_post_confirmation` (calls the Ligoj REST API with
   the `cognito_sign_up` API token to create the user, grant a role, and optionally create a welcome project +
   subscription; uses native `fetch`) are attached to the Cognito user pool. All Lambdas run `nodejs22.x`.

Because steps 3–5 depend on the DB being seeded and the app being reachable, a from-scratch `apply` is
order-sensitive and partial failures usually mean re-running `apply` rather than tainting.

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
- The Cognito hosted login page is branded by `aws_cognito_user_pool_ui_customization` with
  `assets/logo.png` (Cognito accepts only PNG/JPEG <= 100KB, not the SVG) and the Ligoj palette
  (blue `#4589ca`, navy `#034b80`, orange `#ff6900`) — the palette source of truth is
  `ligoj/app-ui/.../assets/logo.svg`.
- **Observability** (`observability.tf`): ALB access logs to an S3 bucket expiring after
  `var.log_retention_days` (also the CloudWatch retention for ECS/RDS logs), ECS Container Insights,
  Aurora Performance Insights (7-day free tier), and CloudWatch alarms (ALB 5xx, unhealthy targets,
  ECS CPU/memory, Aurora ACU) publishing to an SNS topic — set `var.alarm_email` to subscribe.
- The helper script writes `*.log` files into the repo root (`ligoj_new_user-<user>.log`,
  `rds-*.sql.log`). These are gitignored.
- `.terraform.lock.hcl` is gitignored (the `**.hcl` pattern), so provider pinning is local-only; `~>`
  constraints in `provider.tf` are the real bound.
