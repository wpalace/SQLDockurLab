#!/usr/bin/env bash
# Static validation: shellcheck, terraform, PowerShell parse (pwsh), YAML lint, compose config, XML, python.
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
shellcheck() { tool shellcheck docker.io/koalaman/shellcheck:stable shellcheck "$@"; }
yamllint() { tool yamllint docker.io/cytopia/yamllint:latest yamllint "$@"; }
pwsh() { tool pwsh mcr.microsoft.com/powershell:latest pwsh "$@"; }
step shellcheck; shellcheck -x lab lib/*.sh runtime/*.sh tests/*.sh tests/fakeguest/build.sh deploy/gcp/lab-gcp deploy/gcp/*.sh deploy/gcp/terraform/vms/startup.sh || rc=1
step "pwsh parse"
for f in guest/*.ps1 build/base/oem/lab/*.ps1; do
  pwsh -NoProfile -Command "\$e=\$null;[void][Management.Automation.Language.Parser]::ParseFile('$PWD/$f',[ref]\$null,[ref]\$e);if(\$e){\$e|%{'$f:'+\$_.Extent.StartLineNumber+' '+\$_.Message};exit 1}" || rc=1
done
if pwsh -NoProfile -Command 'exit [int](-not (Get-Module -ListAvailable PSScriptAnalyzer))'; then
  step PSScriptAnalyzer
  pwsh -NoProfile -Command "\$r=@(Invoke-ScriptAnalyzer -Path guest -Severity Error -ExcludeRule PSAvoidUsingConvertToSecureStringWithPlainText)+@(Invoke-ScriptAnalyzer -Path build/base/oem/lab -Severity Error -ExcludeRule PSAvoidUsingConvertToSecureStringWithPlainText); \$r|ft -auto|Out-String|Write-Host; exit \$r.Count" || rc=1
fi
step yamllint; yamllint -d '{extends: relaxed, rules: {line-length: disable}}' compose.yml compose.vhost.yml build/base/compose.yml ci/*.yml || rc=1
step "compose config"
$DOCKER compose -f compose.yml -f compose.vhost.yml --env-file lab.env config -q || rc=1
LAB_PASSWORD=x $DOCKER compose -f build/base/compose.yml --env-file lab.env config -q || rc=1
terraform() { tool terraform docker.io/hashicorp/terraform:1.13 terraform "$@"; }
step "terraform fmt + validate (no credentials, no backend)"
for d in deploy/gcp/terraform/shared deploy/gcp/terraform/vms; do
  terraform -chdir="$d" fmt -check -diff || rc=1
  { terraform -chdir="$d" init -backend=false -input=false >/dev/null && terraform -chdir="$d" validate -no-color; } || rc=1
done
step xml; python3 -c "import xml.dom.minidom as m;m.parse('build/base/oem/lab/unattend-clone.xml')" || rc=1
step python; python3 -m py_compile runtime/qmp.py && rm -rf runtime/__pycache__ || rc=1
((rc==0)) && echo "ALL STATIC CHECKS PASSED" || echo "STATIC CHECKS FAILED"
exit $rc
