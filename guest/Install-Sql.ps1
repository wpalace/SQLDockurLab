<# Unattended SQL Server 2025 (Enterprise Developer) default instance from the attached ISO.
   Run via RunAs.ps1 (needs domain credentials for the domain service account). #>
. "$PSScriptRoot\Common.ps1"
$c = Get-LabConfig
if (Get-Service MSSQLSERVER -ErrorAction SilentlyContinue) {
    Write-Ok 'SQL Server already installed'
    Set-Service MSSQLSERVER -StartupType Automatic
    Start-Service MSSQLSERVER -ErrorAction SilentlyContinue
    exit 0
}
$drive = Get-Volume | Where-Object { $_.DriveType -eq 'CD-ROM' -and $_.DriveLetter } |
    ForEach-Object { "$($_.DriveLetter):" } | Where-Object { Test-Path "$_\setup.exe" } | Select-Object -First 1
if (-not $drive) { throw 'SQL Server media (setup.exe) not found on any CD-ROM drive. Is LAB_SQL_ISO in ./media?' }
Write-Step "Installing SQL Server from $drive"
$svc = "$($c.netbios)\$($c.sqlServiceUser)"
$argList = @(
    '/Q', '/ACTION=Install', '/IACCEPTSQLSERVERLICENSETERMS', '/ENU', '/UpdateEnabled=False',
    '/FEATURES=SQLENGINE', '/INSTANCENAME=MSSQLSERVER',
    "/PID=$($c.sqlPid)",
    "/SQLSVCACCOUNT=`"$svc`"", "/SQLSVCPASSWORD=`"$($c.password)`"", '/SQLSVCSTARTUPTYPE=Automatic',
    "/AGTSVCACCOUNT=`"$svc`"", "/AGTSVCPASSWORD=`"$($c.password)`"", '/AGTSVCSTARTUPTYPE=Automatic',
    '/SQLSVCINSTANTFILEINIT=True',
    "/SQLSYSADMINACCOUNTS=`"$($c.netbios)\Domain Admins`" `"BUILTIN\Administrators`"",
    '/SECURITYMODE=SQL', "/SAPWD=`"$($c.password)`"",
    '/TCPENABLED=1', '/NPENABLED=0',
    "/SQLMAXMEMORY=$($c.sqlMaxMemoryMb)", "/SQLMINMEMORY=$($c.sqlMinMemoryMb)",
    '/SQLTEMPDBFILECOUNT=2', '/SQLMAXDOP=2', '/INDICATEPROGRESS'
)
$p = Start-Process -FilePath "$drive\setup.exe" -ArgumentList $argList -Wait -PassThru -NoNewWindow
$summaryPath = 'C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log\Summary.txt'
$summary = Get-ChildItem -Path $summaryPath -ErrorAction SilentlyContinue | Select-Object -Last 1
if ($p.ExitCode -notin 0, 3010) {
    if ($summary) {
        Get-Content -Path $summary.FullName | Select-Object -First 60 | ForEach-Object { "    [summary] $_" } |
            Write-LabLine
    }
    throw "SQL setup failed with exit code $($p.ExitCode)"
}
Write-Ok "setup exit $($p.ExitCode)"
# CEIP/telemetry off: quieter VMs after every restore.
Get-Service -Name 'SQLTELEMETRY*' -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-Service -InputObject $_ -Force
    Set-Service -Name $_.Name -StartupType Disabled
}
if ($p.ExitCode -eq 3010) { exit 3010 }
Wait-LabSql
$versionQuery = "SELECT @@SERVERNAME AS n, CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64)) AS v, " +
"CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS e"
$version = (Invoke-LabSql -Query $versionQuery).Rows[0]
Write-Ok "$($version.n) $($version.v) $($version.e)"
exit 0
