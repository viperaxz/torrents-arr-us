# update_loki.ps1
# Per-app update script: Loki (GitHub zip, single-exe swap).
# The Loki directory also holds loki-config.yml, so only the executable is
# replaced -- never the surrounding config.
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

$AppName     = "Loki"
$ServiceName = "Loki"
$ExePath     = Join-Path $InstallDir "Loki\loki.exe"

$installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $AppName

if ($WhatIf) {
    return [PSCustomObject]@{ App = $AppName; Status = "DRYRUN"; Installed = $installed; Target = $Version; Detail = "single-exe swap (service: $ServiceName)" }
}
if (-not $installed -or $installed -ieq "unknown") {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "not installed or installed version unknown" }
}
if (-not (Test-Path $ExePath)) {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "loki.exe not found at $ExePath" }
}

try {
    $entry   = $Config._Versions.Apps.$AppName
    $zipPath = Join-Path $BinDir "loki-$Version-win.zip"
    Invoke-GitHubReleaseDownload -Repo $entry.repo -Tag $Version -AssetPattern $entry.asset -ZipPath $zipPath

    $tmpDir = Join-Path $env:TEMP "loki-update-$Version"
    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
    New-Item -Path $tmpDir -ItemType Directory -Force | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $tmpDir -Force
    $newExe = Get-ChildItem $tmpDir -Filter "loki-windows-amd64.exe" | Select-Object -First 1
    if (-not $newExe) { throw "loki-windows-amd64.exe not found in archive" }

    $swap = Swap-SingleExeWithRollback -AppName $AppName -ExePath $ExePath `
                -NewExePath $newExe.FullName -ServiceNames @($ServiceName) -HealthSeconds 10
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $swap.Ok) { throw "exe swap failed: $($swap.Detail)" }

    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $Version
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = "" }
} catch {
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}
