<# LAB_TIME_MODE=sync: set the guest clock to the host's UTC time (passed by the host). #>
param([Parameter(Mandatory)][string]$UtcIso)
$styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
$t = [DateTime]::Parse($UtcIso, [Globalization.CultureInfo]::InvariantCulture, $styles)
Set-Date -Date $t.ToLocalTime() | Out-Null
w32tm.exe /resync /nowait 2>$null | Out-Null
exit 0
