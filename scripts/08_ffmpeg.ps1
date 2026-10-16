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
# "latest"/"unknown" are manifest sentinels, not package versions: choco rejects
# them, so install the current release instead of failing the step
# (scripts\14_grafana.ps1 skips the pin the same way).
if ($PinnedVersion -and ($PinnedVersion -ieq "latest" -or $PinnedVersion -ieq "unknown")) {
    Write-DebugLog "WARN" "Ignoring non-version manifest pin for ffmpeg: '$PinnedVersion'"
    $PinnedVersion = $null
}

function Get-InstalledChocoVersion {
    # Reads what Chocolatey reports for a package.
    # Returns: "<version>" | "unknown" (listed but unparseable) | $null (absent)
    param([Parameter(Mandatory=$true)][string]$Package)
    $savedEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $listOutput = choco list --exact $Package -r 2>$null
    } finally {
        $ErrorActionPreference = $savedEAP
    }
    Write-DebugLog "VAR choco list --exact $Package -r => $listOutput"
    if ([string]::IsNullOrWhiteSpace($listOutput)) { return $null }
    $parts = ([string]($listOutput | Select-Object -First 1)) -split '\|'
    if ($parts.Count -ge 2 -and $parts[1].Trim()) { return $parts[1].Trim() }
    return "unknown"
}

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

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Warning "[ffmpeg] Chocolatey is not available (00_prerequisites.ps1 installs it). Cannot install ffmpeg."
    Write-DebugLog "ERROR" "choco not found in PATH; aborting ffmpeg install"
    exit 1
}

Write-Host "[ffmpeg] Installing..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== Installing ffmpeg ==="

$installedVersion = Get-InstalledChocoVersion -Package "ffmpeg"
if (-not $installedVersion) {
    $displayVer = if ($PinnedVersion) { " $PinnedVersion" } else { "" }
    Write-Host "  -> Installing ffmpeg$displayVer via Chocolatey..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Installing ffmpeg via choco..."
    # EAP is "Stop" here (inherited from master_install.ps1) and choco writes
    # warnings (pending reboot, deprecation notices) to stderr on otherwise
    # successful installs -- which would abort this FATAL script.
    $savedEAP = $ErrorActionPreference
    $global:LASTEXITCODE = 0
    try {
        $ErrorActionPreference = "Continue"
        if ($PinnedVersion) {
            choco install ffmpeg --version $PinnedVersion -y --no-progress | Out-Null
        } else {
            choco install ffmpeg -y --no-progress | Out-Null
        }
    } catch {
        Write-DebugLog "WARN" "choco install ffmpeg could not run: $_"
    } finally {
        $ErrorActionPreference = $savedEAP
    }
    Write-DebugLog "INFO" "choco install ffmpeg exit=$LASTEXITCODE"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "[ffmpeg] choco install ffmpeg returned exit code $LASTEXITCODE. Checking whether the package landed anyway..."
        Write-DebugLog "WARN" "choco install ffmpeg non-zero exit: $LASTEXITCODE"
    }
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    Write-DebugLog "INFO" "PATH refreshed after ffmpeg install"
    # The exit code alone is not authoritative (choco returns non-zero for
    # warnings such as a pending reboot): ask Chocolatey what is installed now.
    $installedVersion = Get-InstalledChocoVersion -Package "ffmpeg"
} else {
    Write-Host "  -> ffmpeg already installed via Chocolatey (version $installedVersion)." -ForegroundColor Green
    Write-DebugLog "INFO" "ffmpeg already installed: $installedVersion"
}

if (-not $installedVersion) {
    # Writing the lock file and the ledger entry after a failed install would make
    # every later run report "Already installed. Skipping." and would tell the
    # updater that the pinned version is installed, so a transient choco/network
    # failure could never be retried. Leave both untouched and fail the step so
    # master_install.ps1 logs ffmpeg as failed and a re-run installs it.
    Write-Warning "[ffmpeg] No ffmpeg Chocolatey package is present after the install attempt. Not writing the lock file so a re-run retries."
    Write-DebugLog "ERROR" "ffmpeg package absent after install attempt; lock file not written"
    exit 1
}

# Jellyfin (and its hardware transcoding) runs as a Windows service, so it only
# sees the machine-wide PATH. Resolve ffmpeg.exe there instead of relying on this
# process' PATH, which can contain per-user entries the service never receives.
$machinePath = [System.Environment]::GetEnvironmentVariable("Path","Machine")
$ffmpegExe = $null
foreach ($pathEntry in ($machinePath -split ';')) {
    $dir = [System.Environment]::ExpandEnvironmentVariables($pathEntry.Trim())
    if ($dir -eq "") { continue }
    $candidate = Join-Path $dir "ffmpeg.exe"
    if (Test-Path -LiteralPath $candidate) { $ffmpegExe = $candidate; break }
}
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
    Write-Warning "  -> ffmpeg.exe is not on the machine PATH. Jellyfin transcoding will not find it - set the FFmpeg path in Jellyfin's dashboard or add its directory to the system PATH."
    Write-DebugLog "WARN" "ffmpeg.exe not found on machine PATH after install"
}

# Record what Chocolatey reports as installed, not the manifest pin: a machine
# that already carried a different ffmpeg build must show up as "update
# available" in the updater instead of being reported as current.
$LockVersion = $installedVersion
[System.IO.File]::WriteAllText($LockFile, $LockVersion, [System.Text.Encoding]::UTF8)
Write-DebugLog "INFO" "Lock file written: $LockFile (version=$LockVersion)"

# Ledger entry for the updater (single source of truth for installed versions)
if (-not (Get-Command Set-InstalledVersion -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "update_common.ps1")
}
Set-InstalledVersion -InstallDir $InstallDir -AppName "ffmpeg" -Version $LockVersion

Write-Host "[ffmpeg] Done." -ForegroundColor Cyan
Write-DebugLog "INFO" "08_ffmpeg.ps1 complete"
