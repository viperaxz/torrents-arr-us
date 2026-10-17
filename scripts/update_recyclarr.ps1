# update_recyclarr.ps1
# Per-app update script: Recyclarr (CLI, exe replacement in the project dir).
# Recyclarr runs on demand (Layer 2 sync), so there is no service to restart.
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

$AppName = "Recyclarr"
$ExePath = Join-Path $PSScriptRoot "..\recyclarr\recyclarr.exe"

$installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $AppName

if ($WhatIf) {
    return [PSCustomObject]@{ App = $AppName; Status = "DRYRUN"; Installed = $installed; Target = $Version; Detail = "replace recyclarr.exe (CLI)" }
}
if (-not $installed -or $installed -ieq "unknown") {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "not installed or installed version unknown" }
}
if (-not (Test-Path $ExePath)) {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "recyclarr.exe not found at $ExePath" }
}

try {
    $entry   = $Config._Versions.Apps.$AppName
    $zipPath = Join-Path $BinDir "recyclarr-$Version-win.zip"
    Invoke-GitHubReleaseDownload -Repo $entry.repo -Tag $Version -AssetPattern $entry.asset -ZipPath $zipPath

    $tmpDir = Join-Path $env:TEMP "recyclarr-update-$Version"
    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
    New-Item -Path $tmpDir -ItemType Directory -Force | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $tmpDir -Force
    $newExe = Get-ChildItem $tmpDir -Recurse -Filter "recyclarr.exe" | Select-Object -First 1
    if (-not $newExe) { throw "recyclarr.exe not found in archive" }

    # A CLI has no service to probe, so verify the swapped binary itself: it must
    # be a complete executable (a truncated, blocked or quarantined file is
    # rejected) and its version resource must be the release we asked for. Without
    # this the swap always "succeeded" and a bad download was recorded in the
    # ledger as an installed version.
    $versionCheck = {
        param()
        try {
            $item = Get-Item -LiteralPath $ExePath -ErrorAction Stop
            if ($item.Length -lt 1MB) { return $false }
            # Compare only major.minor.patch so "8.8.0.0" (PE) matches "v8.8.0".
            $wantMatch = [regex]::Match([string]$Version, '(\d+)\.(\d+)\.(\d+)')
            if (-not $wantMatch.Success) { return $true }
            $want = "$($wantMatch.Groups[1].Value).$($wantMatch.Groups[2].Value).$($wantMatch.Groups[3].Value)"
            foreach ($v in @($item.VersionInfo.FileVersion, $item.VersionInfo.ProductVersion)) {
                if (-not $v) { continue }
                $m = [regex]::Match([string]$v, '(\d+)\.(\d+)\.(\d+)')
                if (-not $m.Success) { continue }
                $got = "$($m.Groups[1].Value).$($m.Groups[2].Value).$($m.Groups[3].Value)"
                if ($got -eq $want) { return $true }
            }
            # Version resource missing or unusable: ask the binary itself.
            $cli = (& $ExePath --version 2>$null | Select-Object -First 1)
            if ($cli) {
                $m = [regex]::Match([string]$cli, '(\d+)\.(\d+)\.(\d+)')
                if ($m.Success) {
                    $got = "$($m.Groups[1].Value).$($m.Groups[2].Value).$($m.Groups[3].Value)"
                    if ($got -eq $want) { return $true }
                }
            }
            return $false
        } catch { return $false }
    }
    $swap = Swap-SingleExeWithRollback -AppName $AppName -ExePath $ExePath `
                -NewExePath $newExe.FullName -ServiceNames @() -HealthSeconds 0 -PostHealthCheck $versionCheck
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $swap.Ok) { throw "exe swap failed: $($swap.Detail)" }

    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $Version
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = "" }
} catch {
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}
