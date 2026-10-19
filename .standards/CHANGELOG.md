# Changelog

All notable changes to the coding standards are recorded here. This project uses [Semantic Versioning](https://semver.org/):

- **MAJOR:** a rule change that makes existing compliant code fail checks (new lint rule at error level, a formatter setting change, a stricter version target).
- **MINOR:** new guidance, a new language skill, or new optional checks that don't break compliant code.
- **PATCH:** wording fixes, examples, and documentation.

## [1.0.0] - 2026-10-17

### Added

- Skills for Python 3.14+, C# 14 / .NET 10, Bash 5.x, PowerShell 7.6, Docker and Compose v5, and Terraform 1.16.
- Reference configs: `ruff.toml`, `.editorconfig` fragments, `PSScriptAnalyzerSettings.psd1`, `.tflint.hcl`, `.hadolint.yaml`, `.yamllint.yaml`.
- `scripts/sync-standards.sh`, agent pointer templates, CI workflow templates, and a pre-commit template.
