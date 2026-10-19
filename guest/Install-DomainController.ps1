<# Promote DC1 to the forest root DC of the lab domain. Exit 3010 when a reboot is needed. #>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'The lab password is plain text in lab-config.json by design (disposable lab).')]
param()
. "$PSScriptRoot\Common.ps1"
$c = Get-LabConfig
$role = (Get-CimInstance Win32_ComputerSystem).DomainRole   # 4/5 = DC
if ($role -ge 4) {
    Write-Ok "Already a domain controller of $((Get-CimInstance Win32_ComputerSystem).Domain)"
    exit 0
}

Write-Step "Promoting to forest root DC for $($c.domain)"
Install-WindowsFeature AD-Domain-Services, DNS -IncludeManagementTools | Out-Null
Import-Module ADDSDeployment
$sec = ConvertTo-SecureString -String $c.password -AsPlainText -Force
# The local Administrator becomes LAB\Administrator with the same password.
Install-ADDSForest -DomainName $c.domain -DomainNetbiosName $c.netbios -InstallDns `
    -SafeModeAdministratorPassword $sec -DomainMode WinThreshold -ForestMode WinThreshold `
    -NoRebootOnCompletion -Force -WarningAction SilentlyContinue | Out-Null
Write-Ok 'Promotion staged; reboot required'
exit 3010
