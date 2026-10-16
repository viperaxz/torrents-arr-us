param (
    [Parameter(Mandatory=$true)]
    [object]$Config
)

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "08_ffmpeg.ps1 started"

$InstallDir    = $Config.General.InstallDir
$LockFile      = Join-Path $InstallDir ".locks\.ffmpeg.lock"
$PinnedVersion = if ($Config._Versions -and $Config._Versions.Apps.ffmpeg) { $Config._Versions.Apps.ffmpeg.version } else { $null }
Write-DebugLog "VAR InstallDir=$InstallDir LockFile=$LockFile PinnedVersion=$PinnedVersion"

if ($Config.Apps.Ffmpeg -ne $true) {
    Write-Host "[ffmpeg] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "ffmpeg skipped (Apps.Ffmpeg != true)"
    return
}
if (Test-Path $LockFile) {
    Write-Host "[ffmpeg] Already installed. Skipping." -ForegroundColor Green
    Write-DebugLog "INFO" "ffmpeg already installed (lock file present)"
    return
}

Write-Host "[ffmpeg] Installing..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== Installing ffmpeg ==="

$installed = choco list --exact ffmpeg -r 2>$null
Write-DebugLog "VAR choco ffmpeg output=$installed"
if ([string]::IsNullOrWhiteSpace($installed)) {
    $displayVer = if ($PinnedVersion) { " $PinnedVersion" } else { "" }
    Write-Host "  -> Installing ffmpeg$displayVer via Chocolatey..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Installing ffmpeg via choco..."
    # EAP is "Stop" here (inherited from master_install.ps1) and choco writes
    # warnings (pending reboot, deprecation notices) to stderr on otherwise
    # successful installs -- which would abort this FATAL script.
    $savedEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        if ($PinnedVersion) {
            choco install ffmpeg --version $PinnedVersion -y --no-progress | Out-Null
        } else {
            choco install ffmpeg -y --no-progress | Out-Null
        }
    } finally {
        $ErrorActionPreference = $savedEAP
    }
    Write-DebugLog "INFO" "choco install ffmpeg exit=$LASTEXITCODE"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "[ffmpeg] choco install ffmpeg returned exit code $LASTEXITCODE. Attempting to continue..."
        Write-DebugLog "WARN" "choco install ffmpeg non-zero exit: $LASTEXITCODE"
    }
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    Write-DebugLog "INFO" "PATH refreshed after ffmpeg install"
} else {
    Write-Host "  -> ffmpeg already installed ($installed)." -ForegroundColor Green
    Write-DebugLog "INFO" "ffmpeg already installed: $installed"
}

$ffmpegExe = (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue).Source
Write-DebugLog "VAR ffmpegExe=$ffmpegExe"
if ($ffmpegExe) {
    Write-DebugLog "INFO" "Running ffmpeg -version to verify installation..."
    # ffmpeg writes its banner to stderr; with the inherited EAP="Stop" that would
    # turn a purely informational version check into a failed install step.
    $savedEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $versionOutput = & $ffmpegExe -version 2>&1
    } catch {
        $versionOutput = $null
    } finally {
        $ErrorActionPreference = $savedEAP
    }
    $version = if ($versionOutput) { "$($versionOutput[0])" } else { "(unknown)" }
    Write-Host "  -> $version" -ForegroundColor Green
    Write-DebugLog "VAR ffmpeg version output=$version"
} else {
    Write-Warning "  -> ffmpeg.exe not found in PATH after install. You may need to restart your shell."
    Write-DebugLog "WARN" "ffmpeg.exe not found in PATH after install"
}

$LockVersion = if ($PinnedVersion) { $PinnedVersion } else { "unknown" }
[System.IO.File]::WriteAllText($LockFile, $LockVersion, [System.Text.Encoding]::UTF8)
Write-DebugLog "INFO" "Lock file written: $LockFile (version=$LockVersion)"

# Ledger entry for the updater (single source of truth for installed versions)
if (-not (Get-Command Set-InstalledVersion -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "update_common.ps1")
}
Set-InstalledVersion -InstallDir $InstallDir -AppName "ffmpeg" -Version $LockVersion

Write-Host "[ffmpeg] Done." -ForegroundColor Cyan
Write-DebugLog "INFO" "08_ffmpeg.ps1 complete"
