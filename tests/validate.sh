#!/usr/bin/env bash
# Static validation (TC1): house coding standards checks, PowerShell parse, Pester, compose config,
# terraform validate, password rules, XML, python.
set -uo pipefail # no -e on purpose: every check runs and all failures are reported
cd "$(dirname "$0")/.." || exit 1
DOCKER=${DOCKER:-docker}
rc=0
step() { printf '== %s\n' "$*"; }
# Use a host tool when installed; otherwise run it from a container image (no host install needed).
tool() { # tool NAME IMAGE ENTRYPOINT ARGS...
  local name=$1 image=$2 ep=$3
  shift 3
  if type -P "$name" >/dev/null; then
    command "$name" "$@"
  else $DOCKER run --rm -v "$PWD:$PWD" -w "$PWD" --entrypoint "$ep" "$image" "$@"; fi
}
pwsh() { tool pwsh mcr.microsoft.com/dotnet/sdk:10.0 pwsh "$@"; }
terraform() { tool terraform docker.io/hashicorp/terraform:1.13 terraform "$@"; }
step "house coding standards (tests/standards-check.sh: every Formatting-section check)"
tests/standards-check.sh || rc=1
step "PowerShell (tests/validate.ps1: parse, house PSScriptAnalyzer settings, 5.1 syntax, Pester)"
pwsh -NoProfile -File tests/validate.ps1 || rc=1
step "compose config"
"$DOCKER" compose -f compose.yml -f compose.vhost.yml --env-file lab.env config -q || rc=1
LAB_PASSWORD=x "$DOCKER" compose -f build/base/compose.yml --env-file lab.env config -q || rc=1
step "terraform validate (no credentials, no backend)"
for d in deploy/gcp/terraform/shared deploy/gcp/terraform/vms; do
  {
    terraform -chdir="$d" init -backend=false -input=false >/dev/null \
      && terraform -chdir="$d" validate -no-color
  } || rc=1
done
step "LAB_PASSWORD rules (lib/password.sh)"
bash -c 'source lib/password.sh; bad=0
  for p in "" "<change me>" "Ab1!" "abcdefgh1" "Abc def1!" \
    "Abcdef1'"'"'x" "Abcd\$ef12" "MyAdministrator1!"; do
    if password_problem "$p" >/dev/null; then echo "accepted bad: $p"; bad=1; fi
  done
  for p in Lab-Passw0rd "abcdefg1!" "ABCDEFG1!" "Pa#ssw0rd!2026"; do
    if ! password_problem "$p" >/dev/null; then echo "refused good: $p"; bad=1; fi
  done
  exit $bad' || rc=1
step xml
python3 -c "import xml.dom.minidom as m;m.parse('build/base/oem/lab/unattend-clone.xml')" || rc=1
step python
python3 -m py_compile runtime/qmp.py && rm -rf runtime/__pycache__ || rc=1
((rc == 0)) && echo "ALL STATIC CHECKS PASSED" || echo "STATIC CHECKS FAILED"
exit $rc
