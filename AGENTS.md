# AGENTS.md

Instructions for every AI coding agent working in this repository (Cursor, Claude Code, Copilot, Codex, Grok, and others).

## Coding conventions

Each language used here has a style guide in `docs/style/`:

- Bash: `docs/style/bash.md`
- PowerShell: `docs/style/powershell.md`
- Python: `docs/style/python.md`
- Docker and Compose: `docs/style/docker.md`
- Terraform: `docs/style/terraform.md`

The checks and the CI pipeline are described in `docs/CI.md`.

## Rules

1. **Read the matching style guide before editing.** Before you create or change a file in one of these languages, read its guide above and follow it. If a file mixes languages (for example a Dockerfile that runs a shell script), follow each guide involved.
2. **Run the checks before declaring done.** Run `tests/standards-check.sh` (or `tests/standards-check.sh --fix`, or `pre-commit run --all-files`) and fix every finding. Never say a task is complete while a check fails. If a check cannot run here, say so explicitly.
3. **Keep reformatting and logic changes in separate commits.** Commit formatter-only changes on their own first, then the behavior change.
4. **Change linter settings only on purpose.** The settings files (`ruff.toml`, `.tflint.hcl`, `.hadolint.yaml`, `.yamllint.yaml`, `.shellcheckrc`, `PSScriptAnalyzerSettings.psd1`, `.editorconfig`) apply to the whole repository. Change one only in its own commit, with the reason, and update the matching guide in `docs/style/`. Prefer an inline suppression with a justification for a single finding.
5. **Project notes win on conflict.** Anything in the project-specific section below overrides the general guidance in `docs/style/`.

## Running the project

`MAKE.md` is the entry point for building, testing, and running this project. Read it before running commands, and use the commands it documents rather than guessing.

## Project-specific notes

- **Entry point:** `MAKE.md` (build, test, operate; Local and GCP targets). Static checks: `tests/validate.sh` (TC1), which runs `tests/standards-check.sh` (every formatter and linter; containers when a tool is missing). CI: `docs/CI.md`.
- **Bash files** include the extensionless scripts `lab` and `deploy/gcp/lab-gcp` (bash shebang).
- **Frozen runtime image inputs:** `runtime/Dockerfile`, `runtime/launcher.sh`, `runtime/router.sh`, `runtime/qmp.py`. The image ID is part of the checkpoint fingerprint (`vm_fingerprint` in `lib/common.sh`): changing any of these files changes the image, and every checkpoint, published artifact and golden snapshot stops restoring. They are excluded from shfmt and ruff (`.editorconfig`, `runtime/ruff.toml`, CI). Change them only together with a planned image and checkpoint rebuild, and reformat them then.
- **Guest scripts** (`guest/*.ps1`, `build/base/oem/lab/*.ps1`) run in **Windows PowerShell 5.1** inside the lab VMs (Server Core). Keep them 5.1-compatible: no `??`, `?:`, `&&`/`||` pipeline chains, `-Parallel`, `Join-Path` with several child paths, or `$PSNativeCommandUseErrorActionPreference`. `guest/Common.ps1` sets strict mode for the guest scripts that dot-source it. `build/base/oem/lab/*.ps1` are baked into the base image at build time: a change there takes effect only after `./lab build-base --force`.
- **Write-Host** is the console UI of the operator front end (`lab.ps1`, `lib/LabHost.psm1`, `deploy/gcp/lab-gcp.ps1`) and the progress log of the guest scripts (read over SSH). Its PSScriptAnalyzer finding is suppressed per file with a justification.
- **Secrets:** the lab password is `LAB_PASSWORD` in the gitignored `lab.local.env` (never in `lab.env`, `TRANSCRIPT.md` or logs). The lab SSH key is in Secret Manager (`sqlag-lab-ssh-key`), never in the bucket or Terraform state.
- **Transcript:** record long operations in `TRANSCRIPT.md` and `logs/progress.log` (`./lab log`), Pacific Time (MAKE.md section 0).
