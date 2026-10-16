# update_ffmpeg.ps1
# Per-app update script: ffmpeg (jellyfin-ffmpeg portable win64, CLI only, no service).
#
# ffmpeg no longer comes from Chocolatey: that package ships gyan.dev's
# "essentials" build, which has neither OpenCL nor libplacebo, so tonemap_opencl
# (EnableTonemapping in every profiles\gpu\*.json) cannot work.  The download,
# verification and swap logic is shared with scripts\08_ffmpeg.ps1, so install and
# update can never disagree about what a valid build is.
# No service needs restarting: Jellyfin spawns ffmpeg per transcode and resolves
# it from the machine PATH, which keeps pointing at the same file.
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

# Reuse the installer's helpers (release resolution, download, verification,
# binary swap, machine PATH handling).  They are loaded inside a child scope:
# dot-sourcing 08_ffmpeg.ps1 at this level would overwrite this script's
# parameters ($Version, $InstallDir, ...).  The helpers are declared "global:",
# so they survive that scope.
& {
    . (Join-Path $PSScriptRoot "08_ffmpeg.ps1") -Config $Config -FunctionsOnly
}

$ManifestEntry = if ($Config -and $Config.PSObject.Properties["_Versions"] -and $Config._Versions.apps) {
                     $Config._Versions.apps.PSObject.Properties[$AppName]
                 } else { $null }
$ManifestEntry = if ($ManifestEntry) { $ManifestEntry.Value } else { $null }
$Repo          = if ($ManifestEntry -and $ManifestEntry.repo) { $ManifestEntry.repo } else { "jellyfin/jellyfin-ffmpeg" }
$AssetPattern  = if ($ManifestEntry -and $ManifestEntry.asset) { $ManifestEntry.asset } else { $null }
$DisplayTarget = if ($Version) { $Version } else { "latest" }

$installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $AppName

if ($WhatIf) {
    return [PSCustomObject]@{ App = $AppName; Status = "DRYRUN"; Installed = $installed; Target = $Version; Detail = "download + swap jellyfin-ffmpeg $DisplayTarget" }
}
if (-not $installed -or $installed -ieq "unknown") {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "not installed or installed version unknown (re-run the installer)" }
}

try {
    $install = Install-FfmpegBuild -InstallDir $InstallDir -BinDir $BinDir -Repo $Repo `
                  -AssetPattern $AssetPattern -Tag $Version
    if (-not $install.Ok) { throw $install.Detail }

    # Record the release that was actually installed and verified (its binary
    # reported the matching version), never the requested target: a pin that fell
    # back to the latest release, or a swap that did not land, must not leave the
    # ledger claiming a version that is not on disk.  The lock file is refreshed
    # alongside the ledger so both agree on what is installed.
    $actual  = $install.Tag
    $lockDir = Join-Path $InstallDir ".locks"
    if (-not (Test-Path $lockDir)) { New-Item -Path $lockDir -ItemType Directory -Force | Out-Null }
    [System.IO.File]::WriteAllText((Join-Path $lockDir ".ffmpeg.lock"), $actual, [System.Text.Encoding]::UTF8)
    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $actual

    $detail = ""
    if ($actual -and $Version -and ($actual -ne $Version)) {
        $detail = "installed $actual (requested $Version)"
    }
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = $detail }
} catch {
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}