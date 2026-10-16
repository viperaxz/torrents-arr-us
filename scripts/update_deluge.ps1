# update_deluge.ps1
# Per-app update script: Deluge (Chocolatey, restart daemon + web services).
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [Parameter(Mandatory = $true)][string]$BinDir,
    [object]$Config,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "update_common.ps1")
$Config = Initialize-UpdateScript -Config $Config

$AppName     = "Deluge"
$ServiceList = @("DelugeDaemon", "DelugeWeb")

$installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $AppName

if ($WhatIf) {
    return [PSCustomObject]@{ App = $AppName; Status = "DRYRUN"; Installed = $installed; Target = $Version; Detail = "choco upgrade deluge + restart DelugeDaemon/DelugeWeb" }
}
if (-not $installed -or $installed -ieq "unknown") {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "not installed or installed version unknown" }
}

try {
    Invoke-ChocoUpgrade -Package "deluge" -Version $Version

    foreach ($svcName in $ServiceList) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) { Restart-Service -Name $svcName -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Seconds 15
    foreach ($svcName in $ServiceList) {
        $svcAfter = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if (-not $svcAfter -or $svcAfter.Status -ne "Running") { throw "$svcName not Running after upgrade" }
    }

    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $Version
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = "" }
} catch {
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}
