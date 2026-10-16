# update_rclone.ps1
# Per-app update script: rclone (GitHub zip, single-exe swap).
# The rclone directory also holds rclone.conf, so only rclone.exe is replaced.
# After the swap the movies mount must be visible at the configured drive
# letter, otherwise the swap is rolled back.
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

$AppName     = "rclone"
$ServiceName = "rclone-rd-movies"
$ExePath     = Join-Path $InstallDir "rclone\rclone.exe"

$mountLetter = "R"
if ($Config.PSObject.Properties["RealDebrid"] -and $Config.RealDebrid.MountLetter) {
    $mountLetter = $Config.RealDebrid.MountLetter.ToString().ToUpper().TrimEnd(':')
}

$installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $AppName

if ($WhatIf) {
    return [PSCustomObject]@{ App = $AppName; Status = "DRYRUN"; Installed = $installed; Target = $Version; Detail = "single-exe swap (service: $ServiceName, mount: ${mountLetter}:\)" }
}
if (-not $installed -or $installed -ieq "unknown") {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "not installed or installed version unknown" }
}
if (-not (Test-Path $ExePath)) {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "rclone.exe not found at $ExePath" }
}

try {
    $entry   = $Config._Versions.Apps.$AppName
    $zipPath = Join-Path $BinDir "rclone-$Version-win.zip"
    Invoke-GitHubReleaseDownload -Repo $entry.repo -Tag $Version -AssetPattern $entry.asset -ZipPath $zipPath

    $tmpDir = Join-Path $env:TEMP "rclone-update-$Version"
    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
    New-Item -Path $tmpDir -ItemType Directory -Force | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $tmpDir -Force
    $newExe = Get-ChildItem $tmpDir -Recurse -Filter "rclone.exe" | Select-Object -First 1
    if (-not $newExe) { throw "rclone.exe not found in archive" }

    $mountCheck = { param() (Test-Path "${mountLetter}:\") }
    $swap = Swap-SingleExeWithRollback -AppName $AppName -ExePath $ExePath `
                -NewExePath $newExe.FullName -ServiceNames @($ServiceName) -HealthSeconds 15 -PostHealthCheck $mountCheck
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $swap.Ok) { throw "exe swap failed: $($swap.Detail)" }

    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $Version
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = "" }
} catch {
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}
