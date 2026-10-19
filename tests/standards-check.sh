#!/usr/bin/env bash
# Runs the Formatting-section checks of every coding-standards skill used here
# (.standards/skills/*).
# A host tool is used when it is installed, otherwise its pinned container image.
# Exit 0 only when every check passes. Usage: tests/standards-check.sh [--fix]
#   --fix  run the formatters (shfmt -w, Invoke-Formatter, terraform fmt, ruff format) first
set -Eeuo pipefail
shopt -s inherit_errexit

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly DOCKER="${DOCKER:-docker}"
readonly SHFMT_IMAGE="docker.io/mvdan/shfmt:v3.14.1"
readonly SHELLCHECK_IMAGE="docker.io/koalaman/shellcheck:v0.11.0"
readonly HADOLINT_IMAGE="docker.io/hadolint/hadolint:v2.14.0"
readonly YAMLLINT_IMAGE="docker.io/cytopia/yamllint:latest"
readonly TFLINT_IMAGE="ghcr.io/terraform-linters/tflint:v0.64.0"
readonly TERRAFORM_IMAGE="docker.io/hashicorp/terraform:1.13"
readonly RUFF_IMAGE="ghcr.io/astral-sh/ruff:0.17.1"
# pwsh 7.6 with PSScriptAnalyzer 1.25 (the mcr.microsoft.com/powershell images stopped at 7.4.2).
readonly PWSH_IMAGE="mcr.microsoft.com/dotnet/sdk:10.0"
# Runtime image inputs are frozen (see AGENTS.md): changing them changes the image ID, which is
# part of the checkpoint fingerprint. They are excluded from shfmt and ruff (shellcheck and
# hadolint still check them).
declare -rA ENTRYPOINTS=([ruff]=/ruff)
readonly FROZEN_SHELL=(runtime/launcher.sh runtime/router.sh)

fix=0
rc=0

step() { printf '== %s\n' "$*"; }

fail() {
  printf 'FAIL %s\n' "$*"
  rc=1
}

# tool NAME IMAGE [docker args --] ARGS...: host binary when installed, otherwise the image.
tool() {
  local name="$1" image="$2"
  shift 2
  if type -P "$name" >/dev/null; then
    command "$name" "$@"
  else
    "$DOCKER" run --rm -u "$(id -u):$(id -g)" -v "$REPO_ROOT:$REPO_ROOT" -w "$REPO_ROOT" \
      --entrypoint "${ENTRYPOINTS[$name]:-$name}" "$image" "$@"
  fi
}

bash_files() {
  local f
  while IFS= read -r f; do
    [[ " ${FROZEN_SHELL[*]} " == *" $f "* ]] && continue
    printf '%s\n' "$f"
  done < <(git ls-files -- '*.sh' '*.bash' lab deploy/gcp/lab-gcp ':!:.standards/**')
}

check_bash() {
  local files
  mapfile -t files < <(bash_files)
  step "bash: shfmt -d -i 2 -ci -bn (${#files[@]} files)"
  if ((fix)); then
    tool shfmt "$SHFMT_IMAGE" -w -i 2 -ci -bn "${files[@]}"
  fi
  tool shfmt "$SHFMT_IMAGE" -d -i 2 -ci -bn "${files[@]}" || fail shfmt
  step "bash: shellcheck"
  mapfile -t files < <(git ls-files -- '*.sh' '*.bash' lab deploy/gcp/lab-gcp ':!:.standards/**')
  tool shellcheck "$SHELLCHECK_IMAGE" -x "${files[@]}" || fail shellcheck
}

check_powershell() {
  step "powershell: Invoke-Formatter + Invoke-ScriptAnalyzer (PSScriptAnalyzerSettings.psd1)"
  local args=(-NoProfile -File tests/Test-PowerShellFile.ps1)
  ((fix)) && args+=(-Fix)
  if type -P pwsh >/dev/null; then
    pwsh "${args[@]}" || fail PSScriptAnalyzer
  else
    # shellcheck disable=SC2016 # $PWD and $@ expand in the container's bash, not here.
    local cmd='git config --global --add safe.directory "$PWD" && exec pwsh "$@"'
    "$DOCKER" run --rm -e HOME=/tmp -u "$(id -u):$(id -g)" \
      -v "$REPO_ROOT:$REPO_ROOT" -w "$REPO_ROOT" "$PWSH_IMAGE" \
      bash -c "$cmd" pwsh "${args[@]}" \
      || fail PSScriptAnalyzer
  fi
}

check_docker() {
  step "docker: hadolint"
  local files
  mapfile -t files < <(git ls-files -- '*Dockerfile*' '*.dockerfile' ':!:.standards/**')
  tool hadolint "$HADOLINT_IMAGE" -c .hadolint.yaml "${files[@]}" || fail hadolint
  step "docker: yamllint -c .yamllint.yaml"
  mapfile -t files < <(git ls-files -- '*.yml' '*.yaml' ':!:.standards/**')
  tool yamllint "$YAMLLINT_IMAGE" -c .yamllint.yaml "${files[@]}" || fail yamllint
  step "docker: docker compose config --quiet"
  "$DOCKER" compose -f compose.yml -f compose.vhost.yml --env-file lab.env config --quiet \
    || fail "compose config (compose.yml)"
  "$DOCKER" compose -f build/base/compose.yml --env-file lab.env config --quiet \
    || fail "compose config (build/base/compose.yml)"
}

check_terraform() {
  step "terraform: terraform fmt -check -recursive"
  if ((fix)); then
    tool terraform "$TERRAFORM_IMAGE" fmt -recursive deploy/gcp/terraform
  fi
  tool terraform "$TERRAFORM_IMAGE" fmt -check -recursive -diff deploy/gcp/terraform \
    || fail "terraform fmt"
  step "terraform: tflint --recursive (minimum failure severity notice)"
  "$DOCKER" run --rm -v "$REPO_ROOT:/data" -w /data "$TFLINT_IMAGE" \
    --recursive --config /data/.tflint.hcl --format compact --minimum-failure-severity=notice \
    || fail tflint
}

check_python() {
  step "python: ruff format --check && ruff check"
  if ((fix)); then
    tool ruff "$RUFF_IMAGE" format --no-cache .
  fi
  tool ruff "$RUFF_IMAGE" format --no-cache --check . || fail "ruff format"
  tool ruff "$RUFF_IMAGE" check --no-cache . || fail "ruff check"
}

main() {
  case "${1:-}" in
    --fix) fix=1 ;;
    "") ;;
    *)
      printf 'usage: %s [--fix]\n' "$0" >&2
      exit 2
      ;;
  esac
  cd -- "$REPO_ROOT"
  check_bash
  check_powershell
  check_docker
  check_terraform
  check_python
  if ((rc == 0)); then
    printf 'ALL STANDARDS CHECKS PASSED\n'
  else
    printf 'STANDARDS CHECKS FAILED\n'
  fi
  return "$rc"
}

main "$@"
