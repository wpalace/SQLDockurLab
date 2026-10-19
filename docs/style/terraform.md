# Terraform style guide

> **Before calling work done:** run the formatter and linter checks in the Formatting section (`terraform fmt -check -recursive && tflint --recursive`) and fix every finding. Configuration: `.tflint.hcl` at the repository root. `tests/standards-check.sh` runs every check; see [CI.md](../CI.md).

**Targets:** Terraform 1.16.x (1.16.6, Oct 2026). Set `required_version = "~> 1.16"`, and adopt 1.17 after it reaches GA. OpenTofu (1.13) is largely HCL-compatible, but the two have diverged (Terraform actions and `query`, OpenTofu state encryption), so pick one engine per repo.

## Version Pinning

- Pin Terraform with `required_version`, and pin every provider with a pessimistic `~>` constraint in `versions.tf`.
- **Commit `.terraform.lock.hcl`.** Upgrade deliberately with `terraform init -upgrade` in its own PR.
- Pin modules to an exact registry version or git tag (`?ref=v2.3.1`). Never use a branch.

```hcl
terraform {
  required_version = "~> 1.16"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
```

## Layout

- Every module has `versions.tf`, `main.tf`, `variables.tf`, `outputs.tf`, and `locals.tf`, plus `providers.tf` in root modules only. Split `main.tf` by concern once it gets large.
- Keep one root module per environment (`envs/prod`, `envs/staging`) calling shared modules in `modules/`.

## Naming

- Use `snake_case` for resources, variables, outputs, and locals.
- Don't repeat the resource type in its name. Use `main` or `this` for singletons.

```hcl
resource "aws_s3_bucket" "logs" {}   # not "logs_s3_bucket" or "s3_bucket_logs"
```

## Variables & Outputs

- Every variable has `type` and `description`, and `validation` where input can be wrong. Mark secrets `sensitive = true`.
- Prefer one `object({...})` with `optional()` defaults over many loose variables.
- Use `deprecated = "..."` (1.15+) to retire inputs and outputs gracefully.

```hcl
variable "environment" {
  type        = string
  description = "Deployment environment."

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging, or prod."
  }
}
```

## State

- Shared infrastructure always uses **remote state with locking and encryption**. For S3, use `use_lockfile = true` (native locking). DynamoDB locking is deprecated.
- Use one state per environment and per blast radius, with separate backends or keys. Use separate root modules for environments rather than workspaces.
- `sensitive` hides values in output, not in state. Restrict state access with IAM.

```hcl
backend "s3" {
  bucket       = "acme-tfstate-prod"
  key          = "network/terraform.tfstate"
  region       = "us-west-2"
  encrypt      = true
  use_lockfile = true
}
```

## Modules

- Keep modules small and focused on one concern. Version them and publish to a registry or tag them in git.
- **No `provider` blocks inside modules.** The caller passes providers (`providers = { aws = aws.west }`).
- Expose only the outputs consumers need, documented with `terraform-docs`.

## Iteration & Refactoring

- Use `for_each` with stable keys rather than `count`. Use `count` only for an on/off toggle (`count = var.enabled ? 1 : 0`).
- Refactor without destroying resources by using `moved` blocks. Adopt existing resources with `import` blocks, which can live in child modules as of 1.16. Use `removed` blocks to stop managing a resource without deleting it.

```hcl
moved {
  from = aws_instance.web[0]
  to   = aws_instance.web["primary"]
}

removed {
  from = aws_s3_bucket.legacy
  lifecycle { destroy = false }
}
```

## Modern Features

- Use **ephemeral resources and variables** (1.10+) and **write-only arguments** (`*_wo`, 1.11+) to keep secrets out of plan and state.
- Use **`terraform test`** with `.tftest.hcl` files and `mock_provider` for module unit tests.
- Use **`check` blocks** for post-apply health assertions that warn without blocking.
- Use **`terraform query`** with `.tfquery.hcl` files (1.14+) to discover existing resources and generate import configuration.
- Use provider **actions** (1.14+, with destroy triggers in 1.16) instead of `local-exec` side effects.

```hcl
ephemeral "random_password" "db" {
  length = 32
}

resource "aws_db_instance" "main" {
  password_wo         = ephemeral.random_password.db.result
  password_wo_version = 1
}
```

## Formatting

Code is formatted for human readability and review.

- Run **`terraform fmt`**, which is canonical and has no config. CI runs `terraform fmt -check -recursive`.
- Put one argument per line, and let `fmt` align the `=` signs. Leave a blank line between argument groups, then nested blocks, then `lifecycle` and `depends_on` last.
- Put meta-arguments (`for_each`, `count`, `provider`) first, followed by a blank line.
- Break long lists and maps one element per line, with trailing commas, so each change is a one-line diff.
- Sort variables and outputs alphabetically, or group them by concern. Keep lines under about 100 characters.
- Write comments that explain *why* (constraints, tickets), not *what*. Never mix reformatting and logic changes in one PR.

```hcl
# Before
resource "aws_subnet" "this" {
  vpc_id = aws_vpc.main.id
  for_each = local.subnets
  cidr_block = each.value
  tags = { Name = each.key, Tier = "private" }
}

# After
resource "aws_subnet" "this" {
  for_each = local.subnets

  vpc_id     = aws_vpc.main.id
  cidr_block = each.value

  tags = {
    Name = each.key
    Tier = "private"
  }
}
```

## CI

Every PR runs these checks. A human reviews the saved plan, and CI applies only that plan file.

```bash
terraform fmt -check -recursive && terraform init -backend=false && terraform validate
tflint --recursive && trivy config . && checkov -d .
terraform test && terraform plan -out=tfplan
```

## Avoid

- Hardcoded secrets in `.tf` or `.tfvars` files. Use ephemeral values, write-only arguments, or a secrets manager.
- Unpinned providers or modules, and a missing `.terraform.lock.hcl`.
- Local state for shared infrastructure.
- Building on `count` indexes. Reordering a list destroys and recreates resources.
- Provisioners (`local-exec`, `remote-exec`). Use cloud-init, images, or actions instead.

## In this project

- Root modules: `deploy/gcp/terraform/shared` and `deploy/gcp/terraform/vms`.
- `required_version = ">= 1.5"`, not `~> 1.16`: operators and the lab hosts run Terraform 1.5 or
  later. The Google provider is pinned with `~> 7.0`; commit `.terraform.lock.hcl`.
- State is local by default (a single-operator lab). `backend.tf.example` shows a GCS backend for
  teams.

## Sources

- HashiCorp, "New in Terraform 1.15: Dynamic sources, variable deprecation, and more" (May 13, 2026)
- HashiCorp, "Terraform 1.16 completes Actions lifecycles and brings imports into child modules" (Sep 28, 2026)
- OTTO Tech, "Terraform Tips: Securing Infrastructure-as-Code with Terratest, Part 3" (Medium, Mar 2026)
