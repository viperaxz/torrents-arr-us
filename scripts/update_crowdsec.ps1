# update_crowdsec.ps1
# Per-app update script: CrowdSec engine (Chocolatey).
# Config lives in C:\ProgramData\CrowdSec and is untouched by choco upgrades.
# Health check: the crowdsec service must be Running and config.yaml present.
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

$AppName     = "CrowdSec"
$ServiceName = "crowdsec"

$installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $AppName

if ($WhatIf) {
    return [PSCustomObject]@{ App = $AppName; Status = "DRYRUN"; Installed = $installed; Target = $Version; Detail = "choco upgrade crowdsec" }
}
if (-not $installed -or $installed -ieq "unknown") {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "not installed or installed version unknown" }
}

try {
    Invoke-ChocoUpgrade -Package "crowdsec" -Version $Version

    Restart-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10
    $svcAfter = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svcAfter -or $svcAfter.Status -ne "Running") { throw "crowdsec service not Running after upgrade" }
    if (-not (Test-Path "C:\ProgramData\CrowdSec\config\config.yaml")) {
        throw "config.yaml missing after upgrade -- CrowdSec config may be damaged"
    }

    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $Version
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = "" }
} catch {
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}
