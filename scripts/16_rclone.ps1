param (
    [Parameter(Mandatory=$true)]
    [object]$Config
)

# -- Debug logging ---------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "16_rclone.ps1 started"

$AppName    = "rclone-rd"
$AppLower   = "rclone-rd"
$InstallDir = $Config.General.InstallDir
$AppBinDir  = Join-Path $InstallDir "rclone"
$LockFile   = Join-Path $InstallDir ".locks\.$AppLower.lock"

Write-DebugLog "VAR AppName=$AppName InstallDir=$InstallDir AppBinDir=$AppBinDir"
Write-DebugLog "VAR LockFile=$LockFile (exists=$(Test-Path $LockFile))"

if ($Config.Apps.RealDebrid -ne $true) {
    Write-Host "[$AppName] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "$AppName skipped (Apps.RealDebrid != true)"
    return
}

$RdApiKey = if ($Config.PSObject.Properties['RealDebrid'] -and $Config.RealDebrid.ApiKey) {
    $Config.RealDebrid.ApiKey
} else { "" }

if ([string]::IsNullOrEmpty($RdApiKey)) {
    Write-Warning "[$AppName] RealDebrid.ApiKey is empty in config.json. Skipping."
    Write-DebugLog "WARN" "RealDebrid.ApiKey is empty -- skipping rclone install"
    return
}

$MountLetter = if ($Config.PSObject.Properties['RealDebrid'] -and $Config.RealDebrid.MountLetter) {
    $Config.RealDebrid.MountLetter.ToString().ToUpper().TrimEnd(':')
} else { "R" }

# Movies on MountLetter (e.g. R:\).
if ($MountLetter -notmatch '^[A-Y]$') {
    Write-Warning "[$AppName] MountLetter '$MountLetter' is not A-Y. Falling back to 'R'."
    Write-DebugLog "WARN" "Invalid MountLetter '$MountLetter'. Using default R."
    $MountLetter = "R"
}
$MovieLetter = $MountLetter

Write-DebugLog "VAR MountLetter=$MountLetter MovieLetter=$MovieLetter"

if (Test-Path $LockFile) {
    Write-Host "[$AppName] Already installed. Skipping." -ForegroundColor Green
    Write-DebugLog "INFO" "$AppName already installed (lock file present)"
    return
}

Write-Host "[$AppName] Installing..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== Installing $AppName ==="

# -- 1. Install WinFsp (required for rclone mount on Windows) -------------------
Write-Host "  -> Checking WinFsp..." -ForegroundColor Gray
$winfspInstalled = Get-Package -Name "WinFsp*" -ErrorAction SilentlyContinue
$winfspDir       = "C:\Program Files (x86)\WinFsp"
$winfspPresent   = $winfspInstalled -or (Test-Path $winfspDir)
Write-DebugLog "VAR WinFsp present=$winfspPresent"

if (-not $winfspPresent) {
    Write-Host "  -> Installing WinFsp via Chocolatey..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Installing WinFsp via choco..."
    # choco writes warnings to stderr on successful installs; EAP="Stop" is inherited.
    $savedEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        choco install winfsp -y --no-progress 2>&1 | Out-Null
    } finally {
        $ErrorActionPreference = $savedEAP
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Host "     OK WinFsp installed." -ForegroundColor Green
        Write-DebugLog "INFO" "WinFsp installed successfully"
    } else {
        Write-Warning "     WinFsp install may have failed (exit $LASTEXITCODE). rclone mount may not work."
        Write-DebugLog "WARN" "WinFsp choco install exit=$LASTEXITCODE"
    }
} else {
    Write-Host "     WinFsp already present." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "WinFsp already installed"
}

# -- 1b. EnableLinkedConnections: share drive letters across service sessions ---
# Without this, Jellyfin (running as seedbox-svc) cannot see the rclone mount.
$regPath  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
$regName  = "EnableLinkedConnections"
$regValue = (Get-ItemProperty -Path $regPath -Name $regName -ErrorAction SilentlyContinue).$regName
Write-DebugLog "VAR $regName current=$regValue"
if ($regValue -ne 1) {
    Set-ItemProperty -Path $regPath -Name $regName -Value 1 -Type DWord -Force
    Write-Host "     OK EnableLinkedConnections set to 1 (reboot required)." -ForegroundColor Green
    Write-DebugLog "INFO" "EnableLinkedConnections set to 1"
} else {
    Write-Host "     EnableLinkedConnections already set." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "EnableLinkedConnections already 1"
}

# -- 2. Create app directory ----------------------------------------------------
if (-not (Test-Path $AppBinDir)) {
    New-Item -ItemType Directory -Path $AppBinDir -Force | Out-Null
    Write-DebugLog "INFO" "Created $AppBinDir"
}

# -- 3. Download rclone ---------------------------------------------------------
$RcloneExe = Join-Path $AppBinDir "rclone.exe"
Write-DebugLog "VAR RcloneExe=$RcloneExe (exists=$(Test-Path $RcloneExe))"

if (-not (Test-Path $RcloneExe)) {
    Write-Host "  -> Fetching rclone release from GitHub..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Querying GitHub API for rclone latest release..."
    try {
        $ghHeaders = @{ "User-Agent" = "win-seedbox-installer" }
        $release   = Invoke-RestMethod "https://api.github.com/repos/rclone/rclone/releases/latest" `
                         -Headers $ghHeaders -UseBasicParsing -ErrorAction Stop
        Write-DebugLog "VAR release tag=$($release.tag_name) assets=$($release.assets.Count)"

        $asset = $release.assets | Where-Object { $_.name -like "*windows-amd64.zip" } | Select-Object -First 1
        if (-not $asset) {
            Write-Error "[$AppName] No windows-amd64 zip found in rclone release $($release.tag_name)."
            Write-DebugLog "ERROR" "No windows-amd64 asset in rclone release"
            exit 1
        }

        Write-DebugLog "VAR asset=$($asset.name)"
        $zipPath = Join-Path $env:TEMP "rclone-windows-amd64.zip"
        Write-Host "  -> Downloading $($asset.name)..." -ForegroundColor Gray
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing -ErrorAction Stop

        $extractDir = Join-Path $env:TEMP "rclone-extract"
        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

        $extractedExe = Get-ChildItem $extractDir -Recurse -Filter "rclone.exe" | Select-Object -First 1
        if (-not $extractedExe) {
            Write-Error "[$AppName] rclone.exe not found in extracted archive."
            Write-DebugLog "ERROR" "rclone.exe not found in extracted zip"
            exit 1
        }
        Copy-Item $extractedExe.FullName $RcloneExe -Force
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue

        Write-Host "     OK rclone $($release.tag_name) downloaded." -ForegroundColor Green
        Write-DebugLog "INFO" "rclone $($release.tag_name) ready at $RcloneExe"
    } catch {
        Write-Error "[$AppName] rclone download failed: $_"
        Write-DebugLog "ERROR" "rclone download failed: $_"
        exit 1
    }
}

if (-not (Test-Path $RcloneExe)) {
    Write-Error "[$AppName] rclone.exe not found at '$RcloneExe' after download."
    Write-DebugLog "ERROR" "rclone.exe missing after download"
    exit 1
}

# -- 4. Write rclone config -----------------------------------------------------
$RcloneConf = Join-Path $AppBinDir "rclone.conf"
Write-DebugLog "VAR RcloneConf=$RcloneConf"

$ZurgPort  = 9999
$rcloneIni = @"
[zurg]
type = webdav
url = http://127.0.0.1:$ZurgPort/dav/
vendor = other
pacer_min_sleep = 0
"@

[System.IO.File]::WriteAllText($RcloneConf, $rcloneIni, [System.Text.Encoding]::UTF8)
Write-Host "     OK rclone config written." -ForegroundColor Green
Write-DebugLog "INFO" "rclone config written to $RcloneConf (Zurg WebDAV port=$ZurgPort)"

$LogDir = Join-Path $InstallDir "logs"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }

$CommonFlags = "--skip-links --read-only --vfs-cache-mode off --dir-cache-time 5m --no-modtime --buffer-size 64M --transfers 4 --log-level ERROR --config `"$RcloneConf`""

$MoviesSvc  = "rclone-rd-movies"
$MoviesMountArgs = "mount zurg:__all__ ${MovieLetter}:\ $CommonFlags"

Write-DebugLog "VAR MoviesSvc=$MoviesSvc MoviesMountArgs=$MoviesMountArgs"

# -- 6. Register rclone-rd-movies NSSM service ----------------------------------
Write-Host "  -> Registering $MoviesSvc service (${MovieLetter}:\)..." -ForegroundColor Gray

$svcExists = Get-Service -Name $MoviesSvc -ErrorAction SilentlyContinue
if ($svcExists) {
    Stop-Service -Name $MoviesSvc -Force -ErrorAction SilentlyContinue
    $waited = 0
    while ((Get-Service -Name $MoviesSvc -ErrorAction SilentlyContinue).Status -eq 'StopPending' -and $waited -lt 30) {
        Start-Sleep -Seconds 2; $waited += 2
    }
    nssm remove $MoviesSvc confirm | Out-Null
    $waited = 0
    while ($null -ne (Get-Service -Name $MoviesSvc -ErrorAction SilentlyContinue) -and $waited -lt 10) {
        Start-Sleep -Seconds 1; $waited += 1
    }
}

nssm install $MoviesSvc $RcloneExe | Out-Null
nssm set $MoviesSvc AppDirectory $AppBinDir | Out-Null
nssm set $MoviesSvc AppParameters $MoviesMountArgs | Out-Null
nssm set $MoviesSvc AppStdout (Join-Path $LogDir "rclone-rd-movies.log") | Out-Null
nssm set $MoviesSvc AppStderr (Join-Path $LogDir "rclone-rd-movies-error.log") | Out-Null
nssm set $MoviesSvc AppRotateFiles 1 | Out-Null
nssm set $MoviesSvc AppRotateBytes 5242880 | Out-Null
# Delayed auto-start: Zurg needs 15-30s after boot to load its torrent cache
# and open the WebDAV port.  With SERVICE_AUTO_START rclone races Zurg every
# boot, exits with CRITICAL "connection refused" and relies on the AppExit
# restart loop to recover.  Delayed start (~120s after boot) lets Zurg come up
# first while keeping the services decoupled.
nssm set $MoviesSvc Start SERVICE_DELAYED_AUTO_START | Out-Null
nssm set $MoviesSvc ObjectName "LocalSystem" | Out-Null
# rclone mount is resilient to backend unavailability -- it will recover
# automatically when Zurg comes back.  Do NOT add a DependOnService here
# because SCM stops dependents when a dependency restarts, which would
# kill the rclone process before NSSM AppExit has a chance to restart it.
# Instead, rely on:
#   1. rclone's built-in retry (keeps mount alive during transient outages)
#   2. NSSM AppExit Default Restart (restarts the process if it does crash)
#   3. SERVICE_DELAYED_AUTO_START (Zurg is listening before rclone mounts)
nssm set $MoviesSvc AppExit Default Restart | Out-Null
nssm set $MoviesSvc AppRestartDelay 5000 | Out-Null
nssm set $MoviesSvc AppThrottle 30000 | Out-Null
Write-DebugLog "INFO" "NSSM service '$MoviesSvc' registered (auto-restart on exit)"

# -- 7. Wait for Zurg WebDAV before starting rclone -----------------------------
# Zurg starts its HTTP server asynchronously after network tests. rclone connects
# to Zurg's WebDAV on port 9999 at mount time. If we start rclone before Zurg is
# listening, rclone enters a Paused state and the mount never materialises.
Write-Host "  -> Waiting for Zurg WebDAV on port $ZurgPort..." -ForegroundColor Gray
$zurgDavUrl = "http://127.0.0.1:$ZurgPort/dav/"
$zurgReady = $false
$zurgDeadline = (Get-Date).AddSeconds(120)
$zurgWaited = 0
while (-not $zurgReady -and (Get-Date) -lt $zurgDeadline) {
    try {
        # Zurg v1.0.0+ may respond with 401, 207, or 200 to a GET on /dav/
        # Accept any HTTP response (2xx/3xx/4xx) as proof the server is listening.
        $zurgTest = Invoke-WebRequest -Uri $zurgDavUrl -Method Get `
            -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        $zurgReady = $true
    } catch {
        # The server may respond with a status that Invoke-WebRequest treats as
        # an error (e.g. 401), but that still means it is alive and listening.
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $zurgReady = $true
        } else {
            Start-Sleep -Seconds 3; $zurgWaited += 3
        }
    }
}
Write-DebugLog "VAR Zurg WebDAV ready=$zurgReady waited=${zurgWaited}s"
if (-not $zurgReady) {
    Write-Warning "     Zurg WebDAV not responding after 120s. rclone mount will fail."
    Write-DebugLog "WARN" "Zurg WebDAV at $zurgDavUrl not ready after 120s"
}

# -- 8. Start service -----------------------------------------------------------
Write-Host "  -> Starting $MoviesSvc..." -ForegroundColor Gray
Start-Service -Name $MoviesSvc -ErrorAction SilentlyContinue

$mSvc = $null
$pollDeadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $pollDeadline) {
    $mSvc = Get-Service -Name $MoviesSvc -ErrorAction SilentlyContinue
    if ($mSvc -and $mSvc.Status -eq "Running") { break }
    if ($mSvc -and $mSvc.Status -ne "StartPending") { break }
    Start-Sleep -Seconds 2
}
if (-not $mSvc) { $mSvc = Get-Service -Name $MoviesSvc -ErrorAction SilentlyContinue }

$mSvcStatus = if ($mSvc) { $mSvc.Status } else { "NOT FOUND" }
Write-DebugLog "VAR $MoviesSvc status=$mSvcStatus"

# Verify the mount actually works by listing its root.
# Test-Path alone succeeds even while the WebDAV backend is still failing to
# serve directory listings (e.g. Zurg still building __all__ right after its
# network tests). That race made Jellyfin see an empty library during Layer 2.
# A real readdir that does not throw is the reliable readiness signal.
$mountOk       = $false
$mountDeadline = (Get-Date).AddSeconds(60)
$listingOk     = $false
while (-not $listingOk -and (Get-Date) -lt $mountDeadline) {
    try {
        $null = Get-ChildItem -Path "${MovieLetter}:\" -ErrorAction Stop
        $listingOk = $true
    } catch {
        Start-Sleep -Seconds 2
    }
}
if ($listingOk) {
    $mountOk = (Test-Path "${MovieLetter}:\")
}
Write-DebugLog "VAR $MoviesSvc mount at ${MovieLetter}:\ ok=$mountOk"

if ($mSvc -and $mSvc.Status -eq "Running" -and $mountOk) {
    Write-Host "     OK $MoviesSvc running (${MovieLetter}:\)" -ForegroundColor Green
    Write-DebugLog "INFO" "$MoviesSvc running, mount at ${MovieLetter}:\"
} elseif ($mSvc -and $mSvc.Status -eq "Running" -and -not $mountOk) {
    Write-Warning "     $MoviesSvc running but ${MovieLetter}:\ not visible. Mount may need more time."
    Write-DebugLog "WARN" "$MoviesSvc running but drive ${MovieLetter}:\ not found"
} else {
    Write-Warning "     $MoviesSvc not running (status: $mSvcStatus). Check $LogDir\rclone-rd-movies-error.log."
    Write-DebugLog "WARN" "$MoviesSvc status=$mSvcStatus"
}

# -- 9. Write lock file ---------------------------------------------------------
[System.IO.File]::WriteAllText($LockFile, (Get-Date -Format "o"), [System.Text.Encoding]::UTF8)
# Ledger entry for the updater (single source of truth for versions)
if (-not (Get-Command Set-InstalledVersion -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "update_common.ps1")
}
$rcloneVer = $null
if (Get-Variable -Name release -ErrorAction SilentlyContinue) { $rcloneVer = $release.tag_name }
if (-not $rcloneVer) {
    $rcloneEntry = if ($Config._Versions -and $Config._Versions.Apps.rclone) { $Config._Versions.Apps.rclone } else { $null }
    $rcloneVer = Detect-InstalledVersion -AppName "rclone" -Entry $rcloneEntry -InstallDir $InstallDir
}
if ($rcloneVer) { Set-InstalledVersion -InstallDir $InstallDir -AppName "rclone" -Version $rcloneVer }
Write-Host "  OK $AppName installed (movies: ${MovieLetter}:\)." -ForegroundColor Green
Write-DebugLog "INFO" "16_rclone.ps1 complete. Lock file written: $LockFile"
