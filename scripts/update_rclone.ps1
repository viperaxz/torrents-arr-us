# update_rclone.ps1
# Per-app update script: rclone (GitHub zip, single-exe swap).
# The rclone directory also holds rclone.conf, so only rclone.exe is replaced.
# Every mount service (movies, shows, and the optional anime mount) is stopped and
# restarted, and every drive letter must answer a real readdir, otherwise the swap
# is rolled back.
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [Parameter(Mandatory = $true)][string]$BinDir,
    [object]$Config,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "update_common.ps1")
# Anime split helpers: the anime mount letter lives in the Anime block.
. (Join-Path $PSScriptRoot "anime_helpers.ps1")
$Config = Initialize-UpdateScript -Config $Config

$AppName     = "rclone"
$ExePath     = Join-Path $InstallDir "rclone\rclone.exe"

$mountLetter = "R"
if ($Config.PSObject.Properties["RealDebrid"] -and $Config.RealDebrid.MountLetter) {
    $mountLetter = $Config.RealDebrid.MountLetter.ToString().ToUpper().TrimEnd(':')
}
if ($mountLetter -notmatch '^[A-Y]$') { $mountLetter = "R" }   # same fallback as scripts/16_rclone.ps1

$tvMountLetter = "S"
if ($Config.PSObject.Properties["RealDebrid"] -and $Config.RealDebrid.PSObject.Properties["TvMountLetter"] -and $Config.RealDebrid.TvMountLetter) {
    $tvMountLetter = $Config.RealDebrid.TvMountLetter.ToString().ToUpper().TrimEnd(':')
}
if ($tvMountLetter -notmatch '^[A-Y]$' -or $tvMountLetter -eq $mountLetter) {
    $tvMountLetter = if ($mountLetter -ne 'S') { 'S' } else { 'T' }
}

$animeCfg      = Get-AnimeConfig -Config $Config
$animeEnabled  = [bool]($animeCfg.Enabled -and $animeCfg.Sources.Count -gt 0)
$animeLetter   = $animeCfg.MountLetter

# Every mount service holds rclone.exe open, so all of them must stop for the exe
# swap.  Older installs only have the movies service (no anime mount); only the
# services that exist are passed to the swap helper (a missing one would fail its
# health gate).
$serviceCandidates = @("rclone-rd-movies", "rclone-rd-shows")
if ($animeEnabled) { $serviceCandidates += "rclone-rd-anime" }
$ServiceNames = @($serviceCandidates | Where-Object { Get-Service -Name $_ -ErrorAction SilentlyContinue })
if ($ServiceNames.Count -eq 0) { $ServiceNames = @("rclone-rd-movies") }

$checkLetters = @($mountLetter)
if ($ServiceNames -contains "rclone-rd-shows") { $checkLetters += $tvMountLetter }
if ($ServiceNames -contains "rclone-rd-anime") { $checkLetters += $animeLetter }

$installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $AppName

if ($WhatIf) {
    return [PSCustomObject]@{ App = $AppName; Status = "DRYRUN"; Installed = $installed; Target = $Version; Detail = "single-exe swap (services: $($ServiceNames -join ', '), mounts: $(($checkLetters | ForEach-Object { "$_`:" }) -join ', '))" }
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

    # Test-Path alone passes while the mount root still cannot serve directory
    # listings (Zurg rebuilding its trees right after a restart), which is exactly
    # the state a bad swap leaves behind.  A real readdir is the reliable signal.
    # Every mounted drive must answer: a stale shows mount is still a failed update.
    $mountCheck = {
        param()
        foreach ($l in $checkLetters) {
            try { $null = Get-ChildItem "${l}:\" -ErrorAction Stop } catch { return $false }
        }
        return $true
    }
    $swap = Swap-SingleExeWithRollback -AppName $AppName -ExePath $ExePath `
                -NewExePath $newExe.FullName -ServiceNames $ServiceNames -HealthSeconds 15 -PostHealthCheck $mountCheck
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $swap.Ok) { throw "exe swap failed: $($swap.Detail)" }

    # The anime view is a set of symlinks into the mount that just restarted, so
    # refresh it while we know the drives are healthy (cheap and idempotent).
    if ($animeEnabled) {
        $animeSync  = Join-Path $InstallDir "scripts\sync_anime_library.ps1"
        $animeConfig = Join-Path (Split-Path $PSScriptRoot -Parent) "config.json"
        if (Test-Path $animeSync) {
            try {
                & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $animeSync -ConfigPath $animeConfig -Quiet | Out-Null
                Write-UcLog "INFO" "Anime library view refreshed after rclone update"
            } catch {
                Write-UcLog "WARN" "Anime sync after rclone update failed: $_"
            }
        }
    }

    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $Version
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = "" }
} catch {
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}
