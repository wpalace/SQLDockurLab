<# Host entry point: run another guest script as LAB\Administrator. Usage: RunAs.ps1 <Script.ps1> [args...] #>
param([Parameter(Mandatory, Position = 0)][string]$Script, [Parameter(ValueFromRemainingArguments)][string[]]$Rest = @())
. "$PSScriptRoot\Common.ps1"
$rc = Invoke-AsDomainAdmin -Script $Script -Arguments $Rest
exit $rc
