# Deployment pipeline

A standalone Terraform sub-project provisioning a CodePipeline (V2) that deploys the **main
Terraform stack** (repository root) whenever the `main` branch changes:

```
GitHub push (main) ──> Source ──> Apply (CodeBuild: terraform apply -auto-approve)
```

With `-var require_approval=true`, plan and manual approval stages precede the apply
(`terraform plan -out=tfplan`, then `terraform apply tfplan`). **Approval mode only works on an
already bootstrapped stack**: the plan executes the external data sources of the bootstrap chain,
which need the Ligoj application running — a from-scratch deployment must use the default direct
apply, where Terraform defers those reads until after the ECS service converges.

The CodeBuild role holds `AdministratorAccess`: a full-stack Terraform deployer (VPC, IAM, RDS,
Cognito, …) cannot meaningfully be least-privileged.

## Setup

```bash
aws sso login --profile kloudy-website
cd pipeline

# 1. Own state, in the same bucket as the main stack but under another key
terraform init \
    -backend-config="bucket=terraform.ligoj.io" \
    -backend-config="key=ligoj-pipeline.tfstate" \
    -backend-config="region=eu-west-3" \
    -backend-config="profile=kloudy-website"

# 2. Deployment values of the MAIN stack, stored outside the repository.
#    Copy from main-private.*.tfvars, and REMOVE the 'profile' line: CodeBuild
#    authenticates through its role, not through a local AWS profile.
aws s3 cp ../main-private.saas.tfvars s3://terraform.ligoj.io/ligoj-saas-ci.tfvars --profile kloudy-website

# 3. Provision the pipeline
terraform apply \
    -var profile=kloudy-website \
    -var state_bucket=terraform.ligoj.io \
    -var state_key=ligoj-saas.tfstate \
    -var state_region=eu-west-3 \
    -var tfvars_s3_uri=s3://terraform.ligoj.io/ligoj-saas-ci.tfvars
```

## One-time GitHub handshake

The `aws_codeconnections_connection` is created in `PENDING` state and cannot be activated by
Terraform. In the AWS console: *Developer Tools > Settings > Connections*, select the pending
connection, **Update pending connection**, and authorize the GitHub app on the repository.
Until then, the Source stage fails with a connection error.

## Variables

| Variable             | Default              | Purpose                                            |
|----------------------|----------------------|----------------------------------------------------|
| `repository`         | `ligoj/terraform-aws`| GitHub `owner/name` of the main stack              |
| `branch`             | `main`               | Branch triggering a deployment (push filter)       |
| `state_bucket`       | *(required)*         | S3 bucket of the main stack state                  |
| `state_key`          | `ligoj.tfstate`      | S3 key of the main stack state                     |
| `state_region`       | `region`             | Region of the state bucket                         |
| `tfvars_s3_uri`      | *(empty)*            | `s3://…` tfvars applied by the pipeline            |
| `terraform_version`  | `1.16.0`             | Terraform CLI version used in CodeBuild            |
| `require_approval`   | `false`              | Plan + manual approval before apply (bootstrapped stacks only) |
| `profile`            | `null`               | AWS profile to run THIS sub-project locally        |

## Notes

- The buildspecs live in this directory (`buildspec-plan.yml`, `buildspec-apply.yml`) and are
  read from the source artifact, so pipeline behavior changes are versioned with the code.
- The tfvars file fetched from `tfvars_s3_uri` is loaded as `pipeline.auto.tfvars` and must
  not set `profile` (the main stack treats a null/empty profile as "use the ambient
  credentials", which is the CodeBuild role).
- Build logs land in `/codebuild/<name>-deploy` (CloudWatch, retention `log_retention_days`);
  pipeline artifacts expire from S3 after the same number of days.
- Cost: one small CodeBuild instance per push (~2 builds × a few minutes), S3 artifacts, and
  the pipeline itself (V2 pipelines bill per action-execution minute) — cents per deployment.
