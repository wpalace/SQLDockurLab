#!/usr/bin/env bash
# Static validation (TC1): house coding standards checks, PowerShell parse, Pester, compose config,
# terraform validate, password rules, XML, python.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
DOCKER=${DOCKER:-docker}
rc=0
step() { printf '== %s\n' "$*"; }
# Use a host tool when installed; otherwise run it from a container image so no host install is needed.
tool() { # tool NAME IMAGE ENTRYPOINT ARGS...
  local name=$1 image=$2 ep=$3; shift 3
  if type -P "$name" >/dev/null; then command "$name" "$@"
  else $DOCKER run --rm -v "$PWD:$PWD" -w "$PWD" --entrypoint "$ep" "$image" "$@"; fi
}
pwsh() { tool pwsh mcr.microsoft.com/dotnet/sdk:10.0 pwsh "$@"; }
terraform() { tool terraform docker.io/hashicorp/terraform:1.13 terraform "$@"; }
step "house coding standards (tests/standards-check.sh: every Formatting-section check)"
tests/standards-check.sh || rc=1
step "pwsh parse (guest and base image scripts)"
for f in guest/*.ps1 build/base/oem/lab/*.ps1; do
  pwsh -NoProfile -Command "\$e=\$null;[void][Management.Automation.Language.Parser]::ParseFile('$PWD/$f',[ref]\$null,[ref]\$e);if(\$e){\$e|%{'$f:'+\$_.Extent.StartLineNumber+' '+\$_.Message};exit 1}" || rc=1
done
step "operator front end (tests/validate.ps1: parse, PSScriptAnalyzer with the house settings, Pester)"
pwsh -NoProfile -File tests/validate.ps1 || rc=1
step "compose config"
"$DOCKER" compose -f compose.yml -f compose.vhost.yml --env-file lab.env config -q || rc=1
LAB_PASSWORD=x "$DOCKER" compose -f build/base/compose.yml --env-file lab.env config -q || rc=1
step "terraform validate (no credentials, no backend)"
for d in deploy/gcp/terraform/shared deploy/gcp/terraform/vms; do
  { terraform -chdir="$d" init -backend=false -input=false >/dev/null && terraform -chdir="$d" validate -no-color; } || rc=1
done
step "LAB_PASSWORD rules (lib/password.sh)"
bash -c 'source lib/password.sh; bad=0
  for p in "" "<change me>" "Ab1!" "abcdefgh1" "Abc def1!" "Abcdef1'"'"'x" "Abcd\$ef12" "MyAdministrator1!"; do password_problem "$p" >/dev/null && { echo "accepted bad: $p"; bad=1; }; done
  for p in Lab-Passw0rd "abcdefg1!" "ABCDEFG1!" "Pa#ssw0rd!2026"; do password_problem "$p" >/dev/null || { echo "refused good: $p"; bad=1; }; done
  exit $bad' || rc=1
step xml; python3 -c "import xml.dom.minidom as m;m.parse('build/base/oem/lab/unattend-clone.xml')" || rc=1
step python; python3 -m py_compile runtime/qmp.py && rm -rf runtime/__pycache__ || rc=1
((rc==0)) && echo "ALL STATIC CHECKS PASSED" || echo "STATIC CHECKS FAILED"
exit $rc
