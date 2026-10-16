# update_jellyfin.ps1
# Per-app update script: Jellyfin (Chocolatey, service account re-applied).
# choco upgrade can reset the service to LocalSystem; this script re-applies the
# seedbox-svc account afterwards and health-checks the service.
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

$AppName = "Jellyfin"

$installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $AppName

if ($WhatIf) {
    return [PSCustomObject]@{ App = $AppName; Status = "DRYRUN"; Installed = $installed; Target = $Version; Detail = "choco upgrade jellyfin + service account re-apply" }
}
if (-not $installed -or $installed -ieq "unknown") {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "not installed or installed version unknown" }
}

try {
    Invoke-ChocoUpgrade -Package "jellyfin" -Version $Version

    # Resolve the service name among known variants.
    $svcName = $null
    foreach ($candidate in @("Jellyfin", "JellyfinServer", "jellyfin")) {
        $svc = Get-Service -Name $candidate -ErrorAction SilentlyContinue
        if ($svc) { $svcName = $candidate; break }
    }
    if (-not $svcName) { throw "Jellyfin service not found after upgrade" }

    # Re-apply the seedbox service account (choco upgrade may reset it).
    $svcUser = "seedbox-svc"
    $svcPass = $Config.General.ServiceAccountPassword
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        sc.exe config $svcName obj= ".\$svcUser" password= $svcPass | Out-Null
        $scExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldEap
    }
    if ($scExit -ne 0) { Write-Warning "sc.exe config failed (exit $scExit). Jellyfin may run under the wrong account." }

    Restart-Service -Name $svcName -Force
    Start-Sleep -Seconds 15
    $svcAfter = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svcAfter -or $svcAfter.Status -ne "Running") { throw "Jellyfin service not Running after restart" }

    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $Version
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = "" }
} catch {
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}
