# update_ffmpeg.ps1
# Per-app update script: ffmpeg (Chocolatey, CLI only, no service).
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

$AppName = "ffmpeg"

$installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $AppName

if ($WhatIf) {
    return [PSCustomObject]@{ App = $AppName; Status = "DRYRUN"; Installed = $installed; Target = $Version; Detail = "choco upgrade ffmpeg" }
}
if (-not $installed -or $installed -ieq "unknown") {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "not installed or installed version unknown" }
}

try {
    Invoke-ChocoUpgrade -Package "ffmpeg" -Version $Version

    # Record what Chocolatey actually installed instead of assuming the requested
    # version landed (same "detect, then write" pattern master_update.ps1 uses for
    # ledger migration).  Writing a version that is not on disk would leave the
    # ledger permanently wrong, so the app would look "update available" on every
    # run - or worse, "current" while an older build is installed.
    $entry  = if ($Config -and $Config.PSObject.Properties["_Versions"] -and $Config._Versions.apps) {
                  $Config._Versions.apps.PSObject.Properties["ffmpeg"]
              } else { $null }
    $entry  = if ($entry) { $entry.Value } else { $null }
    $actual = Detect-InstalledVersion -AppName $AppName -Entry $entry -InstallDir $InstallDir
    # "unknown" means choco's output could not be parsed: fall back to the
    # version the upgrade was asked for.
    if (-not $actual -or $actual -ieq "unknown") { $actual = $Version }
    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $actual

    $detail = ""
    if ($actual -and $Version -and ($actual -ne $Version)) {
        $detail = "installed $actual (requested $Version)"
    }
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = $detail }
} catch {
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}
