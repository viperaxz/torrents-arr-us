# update_zurg.ps1
# Per-app update script: Zurg (GitHub release, single-exe swap).
# zurg.exe lives next to config.yml, so only the executable is replaced.
# NOTE: Zurg versions historically shipped mount-path regressions (the
# compilePattern panic in v0.9.3).  After every Zurg update, verify that the
# rclone movies mount is still readable.
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

$AppName     = "Zurg"
$ServiceName = "Zurg"
$ExePath     = Join-Path $InstallDir "Zurg\zurg.exe"

$installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $AppName

if ($WhatIf) {
    return [PSCustomObject]@{ App = $AppName; Status = "DRYRUN"; Installed = $installed; Target = $Version; Detail = "single-exe swap (service: $ServiceName)" }
}
if (-not $installed -or $installed -ieq "unknown") {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "not installed or installed version unknown" }
}
if (-not (Test-Path $ExePath)) {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "zurg.exe not found at $ExePath" }
}

try {
    $repo    = $Config._Versions.Apps.$AppName.repo
    $headers = @{ "User-Agent" = "win-seedbox-installer" }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/tags/$Version" -Headers $headers -UseBasicParsing
    $asset = $release.assets | Where-Object {
        $_.name -match "windows" -and ($_.name -match "amd64" -or $_.name -match "x64")
    } | Select-Object -First 1
    if (-not $asset) { throw "No Windows amd64/x64 asset found in Zurg release $Version" }

    $tmpDir = Join-Path $env:TEMP "zurg-update-$Version"
    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
    New-Item -Path $tmpDir -ItemType Directory -Force | Out-Null
    $newExe = $null

    if ($asset.name -like "*.zip") {
        $dlZip = Join-Path $tmpDir "zurg.zip"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dlZip -UseBasicParsing
        $exDir = Join-Path $tmpDir "ex"
        New-Item -Path $exDir -ItemType Directory -Force | Out-Null
        Expand-Archive -Path $dlZip -DestinationPath $exDir -Force
        $newExe = Get-ChildItem $exDir -Recurse -Filter "*.exe" | Select-Object -First 1
    } else {
        $newExe = Join-Path $tmpDir "zurg-new.exe"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $newExe -UseBasicParsing
    }
    if (-not $newExe) { throw "Could not extract a Zurg executable from the release asset" }

    $swap = Swap-SingleExeWithRollback -AppName $AppName -ExePath $ExePath `
                -NewExePath $newExe.FullName -ServiceNames @($ServiceName) -HealthSeconds 10
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $swap.Ok) { throw "exe swap failed: $($swap.Detail)" }

    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $Version
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = "verify rclone movies mount after Zurg updates" }
} catch {
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}
