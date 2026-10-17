param (
    [Parameter(Mandatory=$true)]
    [object]$Config
)

# -- Debug logging ---------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")

# Bounded service control: nssm services wedge in Stop/Start Pending and the
# built-in cmdlets wait indefinitely. See service_helpers.ps1.
if (-not (Get-Command Start-ServiceBounded -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "service_helpers.ps1")
}
Initialize-DebugLog -Config $Config
# Shared choco plumbing: PATH-safe resolution plus retry-on-transient-feed-failure.
. (Join-Path $PSScriptRoot "choco_helpers.ps1")
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

# Movies on MountLetter (e.g. R:\).  TV shows are NOT split onto a second
# drive: zurg serves one flat __all__ tree and the WebDAV layer has no reliable
# movies/shows split, which is why only a Movies library is provisioned.
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
    # Invoke-Choco captures choco's stderr chatter instead of letting it abort
    # this script under EAP="Stop", and retries transient feed failures.
    $winfspInstall = Invoke-Choco -Arguments @('install', 'winfsp', '-y', '--no-progress')
    $winfspTail = $winfspInstall.Output
    if ($winfspTail -and $winfspTail.Length -gt 800) { $winfspTail = $winfspTail.Substring($winfspTail.Length - 800) }
    # Trust the installed files, not the exit code: an MSI that needs a reboot
    # reports 3010, which is a success for our purposes.
    $winfspPresent = Test-Path $winfspDir
    if ($winfspPresent) {
        Write-Host "     OK WinFsp installed." -ForegroundColor Green
        Write-DebugLog "INFO" "WinFsp installed successfully (choco exit=$($winfspInstall.ExitCode), attempts=$($winfspInstall.Attempts))"
    } else {
        Write-DebugLog "ERROR" "WinFsp missing after choco install (exit $($winfspInstall.ExitCode), ran=$($winfspInstall.Ran), transient=$($winfspInstall.Transient)): $winfspTail"
        Write-Warning "     WinFsp install failed (exit $($winfspInstall.ExitCode)). Not writing the lock file so a re-run retries."
        Write-Error "[$AppName] WinFsp is required for the rclone mount and is not installed."
        exit 1
    }
} else {
    Write-Host "     WinFsp already present." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "WinFsp already installed"
}

# -- 1b. EnableLinkedConnections: share drive mappings across the linked token --
# Kept for the interactive side: a drive mapping made with the standard token
# then stays visible to that user's elevated token.
# It has no effect on the rclone mount -- WinFsp drive letters are per Windows
# session, so rclone-rd-movies and Jellyfin see the same letter by both running
# as services in session 0, while an interactive desktop session (1+) does not.
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

[System.IO.File]::WriteAllText($RcloneConf, $rcloneIni, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "     OK rclone config written." -ForegroundColor Green
Write-DebugLog "INFO" "rclone config written to $RcloneConf (Zurg WebDAV port=$ZurgPort)"

$LogDir = Join-Path $InstallDir "logs"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }

$CommonFlags = "--skip-links --read-only --vfs-cache-mode off --dir-cache-time 5m --no-modtime --buffer-size 64M --transfers 4 --log-level ERROR --config `"$RcloneConf`""

$MoviesSvc  = "rclone-rd-movies"
$MoviesMountArgs = "mount zurg:__all__ ${MovieLetter}:\ $CommonFlags"

Write-DebugLog "VAR MoviesSvc=$MoviesSvc MoviesMountArgs=$MoviesMountArgs"

# A letter that is already a local volume or network mapping makes the mount
# fail; surface it here rather than as a warning after the service is registered.
$letterOwner = Get-PSDrive -Name $MovieLetter -PSProvider FileSystem -ErrorAction SilentlyContinue
if ($letterOwner) {
    Write-Warning "     Drive ${MovieLetter}: is already in use (root: $($letterOwner.Root)). rclone cannot mount over an existing drive -- set a free RealDebrid.MountLetter in config.json."
    Write-DebugLog "WARN" "MountLetter ${MovieLetter}: already in use by $($letterOwner.Root)"
}

# -- 6. Register rclone-rd-movies NSSM service ----------------------------------
Write-Host "  -> Registering $MoviesSvc service (${MovieLetter}:\)..." -ForegroundColor Gray

$svcExists = Get-Service -Name $MoviesSvc -ErrorAction SilentlyContinue
if ($svcExists) {
    $null = Stop-ServiceBounded -Name $MoviesSvc
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
$zurgStart = Get-Date
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
            Start-Sleep -Seconds 3
        }
    }
}
$zurgWaited = [int]((Get-Date) - $zurgStart).TotalSeconds
Write-DebugLog "VAR Zurg WebDAV ready=$zurgReady waited=${zurgWaited}s"
if (-not $zurgReady) {
    Write-Warning "     Zurg WebDAV not responding after ${zurgWaited}s. rclone mount will fail."
    Write-Warning "     A service that is Running but never opens port $ZurgPort usually means an invalid RealDebrid.ApiKey in config.json (Zurg loops in its network test) -- see $InstallDir\logs\zurg.log."
    Write-DebugLog "WARN" "Zurg WebDAV at $zurgDavUrl not ready after ${zurgWaited}s"
}

# -- 8. Start service -----------------------------------------------------------
Write-Host "  -> Starting $MoviesSvc..." -ForegroundColor Gray
$null = Start-ServiceBounded -Name $MoviesSvc

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

$mSvcRunning = [bool]($mSvc -and $mSvc.Status -eq "Running")

if ($mSvcRunning -and $mountOk) {
    Write-Host "     OK $MoviesSvc running (${MovieLetter}:\)" -ForegroundColor Green
    Write-DebugLog "INFO" "$MoviesSvc running, mount at ${MovieLetter}:\"
} elseif ($mSvcRunning -and -not $mountOk) {
    Write-Warning "     $MoviesSvc running but ${MovieLetter}:\ not visible from this session. Mount may need more time."
    Write-Warning "     Note: a WinFsp drive letter belongs to the session that created it. The mount is created by the $MoviesSvc service in session 0, so it is visible to other services (Jellyfin) but not to an interactive desktop session."
    Write-DebugLog "WARN" "$MoviesSvc running but drive ${MovieLetter}:\ not found"
} else {
    Write-Warning "     $MoviesSvc not running (status: $mSvcStatus). Check $LogDir\rclone-rd-movies-error.log."
    Write-DebugLog "WARN" "$MoviesSvc status=$mSvcStatus"
}

# -- 9. Write lock file ---------------------------------------------------------
# Only a running mount service counts as installed.  Writing the lock file (and
# the ledger entry) after a failed start would make every later run report
# "Already installed. Skipping." and would tell the updater that the version is
# in place, so a transient failure could never be retried.  The drive-letter
# check above is deliberately not part of this decision: WinFsp mount points are
# per session, so an installer running in an interactive session may not see a
# perfectly healthy mount.
if (-not $mSvcRunning) {
    Write-Warning "[$AppName] Install incomplete: service '$MoviesSvc' is $mSvcStatus. Not writing the lock file so a re-run retries."
    Write-DebugLog "ERROR" "$MoviesSvc not running ($mSvcStatus); lock file and ledger entry not written"
    exit 1
}

[System.IO.File]::WriteAllText($LockFile, (Get-Date -Format "o"), (New-Object System.Text.UTF8Encoding($false)))
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
