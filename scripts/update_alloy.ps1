# update_alloy.ps1
# Per-app update script: Alloy (GitHub zip, single-exe swap).
# Falls back to the latest release when the pinned version is not found
# (same policy as the installer).
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

$AppName     = "Alloy"
$ServiceName = "Alloy"
$ExePath     = Join-Path $InstallDir "Alloy\alloy.exe"

$installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $AppName

if ($WhatIf) {
    return [PSCustomObject]@{ App = $AppName; Status = "DRYRUN"; Installed = $installed; Target = $Version; Detail = "single-exe swap (service: $ServiceName)" }
}
if (-not $installed -or $installed -ieq "unknown") {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "not installed or installed version unknown" }
}
if (-not (Test-Path $ExePath)) {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "alloy.exe not found at $ExePath" }
}

try {
    $entry    = $Config._Versions.Apps.$AppName
    $repo     = $entry.repo
    $applied  = $Version
    $zipPath  = Join-Path $BinDir "alloy-$Version-win.zip"

    try {
        Invoke-GitHubReleaseDownload -Repo $repo -Tag $Version -AssetPattern $entry.asset -ZipPath $zipPath
    } catch {
        Write-Warning "Pinned Alloy version $Version not found; falling back to latest release."
        $headers  = @{ "User-Agent" = "win-seedbox-installer" }
        $release  = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers $headers -UseBasicParsing
        $applied  = $release.tag_name
        $zipPath  = Join-Path $BinDir "alloy-$applied-win.zip"
        Invoke-GitHubReleaseDownload -Repo $repo -Tag $applied -AssetPattern $entry.asset -ZipPath $zipPath
    }

    $tmpDir = Join-Path $env:TEMP "alloy-update-$applied"
    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
    New-Item -Path $tmpDir -ItemType Directory -Force | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $tmpDir -Force
    $newExe = Get-ChildItem $tmpDir -Filter "alloy-windows-amd64.exe" | Select-Object -First 1
    if (-not $newExe) { throw "alloy-windows-amd64.exe not found in archive" }

    $swap = Swap-SingleExeWithRollback -AppName $AppName -ExePath $ExePath `
                -NewExePath $newExe.FullName -ServiceNames @($ServiceName) -HealthSeconds 10
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $swap.Ok) { throw "exe swap failed: $($swap.Detail)" }

    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $applied
    $detail = if ($applied -ne $Version) { "applied latest $applied (pinned $Version not found)" } else { "" }
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $applied; Detail = $detail }
} catch {
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}
