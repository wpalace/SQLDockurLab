# Managed by coding-standards (scripts/sync-standards.sh). Do not edit in projects; change it upstream.
# Terraform standard: snake_case, typed and documented variables, pinned versions, standard layout.
config {
  call_module_type = "local"
  # CI runs with --minimum-failure-severity=notice so naming and docs findings fail too.
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Add the provider ruleset your project uses, pinned to a version, for example:
# plugin "aws" {
#   enabled = true
#   version = "0.49.0"
#   source  = "github.com/terraform-linters/tflint-ruleset-aws"
# }

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_module_pinned_source" {
  enabled = true
  style   = "semver"
}

rule "terraform_module_version" {
  enabled = true
  exact   = false
}

rule "terraform_typed_variables" {
  enabled = true
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_standard_module_structure" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_unused_required_providers" {
  enabled = true
}

rule "terraform_deprecated_index" {
  enabled = true
}

rule "terraform_comment_syntax" {
  enabled = true
}
