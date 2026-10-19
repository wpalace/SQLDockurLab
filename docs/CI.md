# Continuous integration and code checks

This page describes the automatic checks that run on every pull request, and how to run the same
checks on your own computer before you push.

There are two levels of checks:

| Level | Where it runs | What it needs | Command |
| --- | --- | --- | --- |
| Formatters and linters | GitHub Actions and locally | Docker, or the tools installed | `tests/standards-check.sh` |
| Static validation (TC1) | Locally (and as TC1 of the lab tests) | Docker, or the tools installed | `tests/validate.sh` |

`tests/validate.sh` runs `tests/standards-check.sh` first, then the extra static checks. Neither
needs a running lab, cloud credentials or a network connection to Google Cloud.

The style rules that the checks enforce are described per language in [docs/style/](style/).

## The GitHub Actions workflow

File: [`.github/workflows/standards-check.yml`](../.github/workflows/standards-check.yml)
(workflow name **Standards check**).

- **Triggers:** every pull request, every push to `main`, and manual runs (`workflow_dispatch`).
- **Permissions:** `contents: read` only. Checkout does not keep the token (`persist-credentials: false`).
- **Concurrency:** a new push to the same branch cancels the run that is still in progress.
- **Tool versions are pinned** (actions, shfmt, ShellCheck, PSScriptAnalyzer, Terraform, tflint,
  hadolint, yamllint, ruff), so a new tool release cannot break the build by surprise.
  `tests/standards-check.sh` and `.pre-commit-config.yaml` use the same versions.
  The lab's own container images (the installer image is pinned by digest) are listed in
  [IMAGES.md](IMAGES.md), with the procedure to change a pin.

The workflow has five jobs. They run in parallel, and each must pass.

### `python`: ruff

| Step | Tool | Enforces |
| --- | --- | --- |
| `ruff format --check` | ruff 0.17.1 | Formatting (line length 100, double quotes) |
| `ruff check` | ruff 0.17.1 | Lint rules E, F, I (import order), B, UP, SIM, N |

Settings: `ruff.toml` and `runtime/ruff.toml` (`runtime/qmp.py` targets Python 3.13 and is
excluded while the runtime image is frozen, see below).

### `bash`: shfmt and ShellCheck

| Step | Tool | Enforces |
| --- | --- | --- |
| `shfmt -d -i 2 -ci -bn` | shfmt v3.14.1 | 2-space indent, indented `case` items, binary operators at the start of a line |
| `shellcheck -x` | ShellCheck 0.11.0 | All ShellCheck rules, following sourced files (`lib/*.sh`) |

Files: every tracked `*.sh` and `*.bash` file plus the extensionless scripts `lab` and
`deploy/gcp/lab-gcp`. There are no global ShellCheck exclusions (`.shellcheckrc` only enables
`external-sources`); a rule is disabled only inline, with a reason.

### `powershell`: Invoke-Formatter and PSScriptAnalyzer

The job installs PSScriptAnalyzer 1.25.0 and runs
[`tests/Test-PowerShellFile.ps1`](../tests/Test-PowerShellFile.ps1). For every tracked `*.ps1`,
`*.psm1` and `*.psd1` file it checks:

- **Formatting:** the file must be identical to the output of `Invoke-Formatter` (OTBS braces,
  4-space indent, consistent whitespace and casing).
- **Analysis:** `Invoke-ScriptAnalyzer` must report no findings at Error, Warning or Information
  severity (approved verbs, no aliases, no positional parameters, lines of at most 115 characters,
  and so on).

Both use `PSScriptAnalyzerSettings.psd1`. A finding that is intended (for example `Write-Host` in
the console front end) is suppressed in the file with `SuppressMessageAttribute` and a
justification, never in the settings file.

**The PSScriptAnalyzer crash retry.** PSScriptAnalyzer 1.25 on PowerShell 7.6 sometimes crashes in
the `UseCorrectCasing` rule with `Object reference not set to an instance of an object`
(a race in `CommandInfo.Parameters`). It is random: about one run in three hits it on some files.
After such a crash, PSScriptAnalyzer's command lookup can also fail with
`The term 'Get-Command' is not recognized`. The script therefore checks one file at a time and
retries a file **only** for these two errors, at most 10 runs. A run that crashed is never counted as a pass; a file that crashes 10 times fails the job.
In the log, a retry looks like this and is harmless:

```text
PSScriptAnalyzer crashed on tests/validate.ps1 (known 1.25 UseCorrectCasing race); retry 1
```

### `terraform`: terraform fmt and tflint

| Step | Tool | Enforces |
| --- | --- | --- |
| `terraform fmt -check -recursive -diff` | Terraform 1.16 | Canonical HCL formatting |
| `tflint --recursive` | tflint v0.64.0 | Naming (snake_case), typed and documented variables and outputs, pinned providers, standard file layout |

tflint fails at `notice` severity, so naming and documentation findings fail the job too. Settings:
`.tflint.hcl`. The root modules are `deploy/gcp/terraform/shared` and `deploy/gcp/terraform/vms`.
`terraform validate` needs a provider download and runs locally (see below).

### `docker`: hadolint, yamllint and compose config

| Step | Tool | Enforces |
| --- | --- | --- |
| hadolint | hadolint 2.x | Dockerfile best practices (pinned bases, clean apt layers), failure threshold `warning` |
| yamllint | yamllint 1.38.0 | YAML style for compose files and workflows (2-space indent, lines up to 120 characters) |
| `docker compose config --quiet` | Docker Compose | `compose.yml` + `compose.vhost.yml` and `build/base/compose.yml` are valid with the committed `lab.env` |

Settings: `.hadolint.yaml` and `.yamllint.yaml`.

## Run the checks locally

You do not have to install the linters. When a tool is not on your `PATH`,
`tests/standards-check.sh` runs it from a pinned container image, so Docker is enough.

```bash
tests/standards-check.sh          # every CI check; exit code 0 only when all pass
tests/standards-check.sh --fix    # run the formatters first (shfmt, Invoke-Formatter, terraform fmt, ruff format)
tests/validate.sh                 # the checks above plus the static validation below
```

Only the PowerShell checks, or only some files (PowerShell 7.4 or later):

```powershell
pwsh -NoProfile -File tests/Test-PowerShellFile.ps1                 # all PowerShell files
pwsh -NoProfile -File tests/Test-PowerShellFile.ps1 -Fix            # format, then check
pwsh -NoProfile -File tests/Test-PowerShellFile.ps1 lab.ps1 lib/LabHost.psm1
pwsh -NoProfile -File tests/validate.ps1                            # parse, 5.1 syntax, Pester
```

Optional git hooks with the same tools and versions:

```bash
pre-commit install
pre-commit run --all-files
```

### Static validation (`tests/validate.sh`)

After the formatter and linter checks, `tests/validate.sh` also runs:

- **`tests/validate.ps1`:**
  - parses the operator scripts (`lab.ps1`, `lib/LabHost.psm1`, `deploy/gcp/lab-gcp.ps1`);
  - runs PSScriptAnalyzer on them (same settings, same crash retry);
  - checks that the guest scripts (`guest/*.ps1`, `build/base/oem/lab/*.ps1`) use only Windows
    PowerShell 5.1 syntax (`PSUseCompatibleSyntax`), because they run in 5.1 inside the lab VMs;
  - runs the **Pester** tests in `tests/LabGcp.Tests.ps1` (Pester 5.5 or later). They test the
    PowerShell front end without a cloud account: VM name mapping, remote command encoding,
    command-line parsing (apply flags, console and tunnel options), the spawned-VM registry and
    destroy guard, the watch-terminal script, LF line endings, the lab password rules and the
    `key` command.
- **`docker compose config`** for both compose projects.
- **`terraform init -backend=false` and `terraform validate`** for both root modules (no
  credentials and no state are used). `./lab gcp tf-check` (or `./lab.ps1 gcp tf-check`) runs
  `terraform fmt -check` and `terraform validate` for both roots in the same way.
- **The `LAB_PASSWORD` rules** in `lib/password.sh`, against known good and bad passwords.
- **XML** well-formedness of `build/base/oem/lab/unattend-clone.xml`, and **Python** byte
  compilation of `runtime/qmp.py`.

It prints `ALL STATIC CHECKS PASSED` when everything passes. The lab test suite (`MAKE.md`,
TC1-TC9) runs it as TC1.

## Fix common failures

| Failure | Fix |
| --- | --- |
| `shfmt -d` shows a diff | `tests/standards-check.sh --fix`, or `shfmt -w -i 2 -ci -bn FILE` |
| ShellCheck finding | Fix the code. If the finding is wrong for that line, add `# shellcheck disable=SCnnnn # reason` on the line above |
| `Not formatted: FILE` (PowerShell) | `pwsh -NoProfile -File tests/Test-PowerShellFile.ps1 -Fix` |
| `PSAvoidLongLines` | Break the line (115 characters at most); use splatting for long commands |
| `PSUseApprovedVerbs` | Rename the function with a verb from `Get-Verb` |
| `PSAvoidUsingWriteHost` in a new file | Use `Write-Output`, `Write-Verbose` or `Write-Information`. In console UI code only, suppress it with a justification |
| `PSUseCompatibleSyntax` (guest scripts) | Replace PowerShell 7 syntax (`??`, `?:`, `&&`, `\|\|`, `-Parallel`) with 5.1 syntax |
| PSScriptAnalyzer crashed 10 times | Rerun the job; if it repeats, report it with the log |
| `terraform fmt` diff | `terraform fmt -recursive deploy/gcp/terraform` |
| tflint `terraform_documented_variables` / `_outputs` | Add a `description` to the variable or output |
| tflint `terraform_naming_convention` | Use snake_case names |
| `ruff format` diff | `ruff format .` (or `tests/standards-check.sh --fix`) |
| yamllint line length or indentation | Wrap at 120 characters; indent with 2 spaces |
| `docker compose config` error | Fix the compose file; the committed `lab.env` must keep every variable that compose files use |

## Frozen files

The runtime image inputs (`runtime/Dockerfile`, `runtime/launcher.sh`, `runtime/router.sh`,
`runtime/qmp.py`) are part of the checkpoint fingerprint: changing any byte changes the image, and
every saved checkpoint, published artifact and golden snapshot stops restoring. shfmt and ruff
therefore skip `runtime/launcher.sh`, `runtime/router.sh` and `runtime/qmp.py`
(`.editorconfig`, `runtime/ruff.toml`, the workflow and `.pre-commit-config.yaml`). ShellCheck and
hadolint still check them. Reformat them only together with a planned image and checkpoint
rebuild.

## Not part of CI

[`ci/github-actions-example.yml`](../ci/github-actions-example.yml) is an example only. It shows how
to run your own SQL Server tests against the lab on a self-hosted runner on the lab host (reset to
`golden`, health check, test suite). It is not in `.github/workflows/` and does not run in this
repository.
