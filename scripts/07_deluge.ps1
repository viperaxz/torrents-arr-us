param (
    [Parameter(Mandatory=$true)]
    [object]$Config
)

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "07_deluge.ps1 started"

$AppName       = "Deluge"
$AppLower      = "deluge"
$DaemonPort    = $Config.Ports.Deluge
$WebPort       = $Config.Ports.DelugeWeb
# BitTorrent peer port -- must be forwarded on your router.
# Default 56881 avoids ISP throttling on well-known ports like 6881.
$BTPort        = if ($Config.Ports.PSObject.Properties['DelugeBT'] -and $Config.Ports.DelugeBT) {
    [int]$Config.Ports.DelugeBT
} else {
    Write-DebugLog "WARN" "Ports.DelugeBT not set in config.json. Using default 56881."
    56881
}
$InstallDir    = $Config.General.InstallDir
$DataDir       = Join-Path $InstallDir "Deluge-data"
$LockFile      = Join-Path $InstallDir ".locks\.$AppLower.lock"
$SvcUser       = "seedbox-svc"
$SvcPass       = $Config.General.ServiceAccountPassword
$SecretsDir    = Join-Path $InstallDir "secrets"
$AuthFile      = Join-Path $DataDir "auth"
$CoreConf      = Join-Path $DataDir "core.conf"
$WebConf       = Join-Path $DataDir "web.conf"
$DaemonLog     = Join-Path $DataDir "deluged.log"
$WebLog        = Join-Path $DataDir "deluge-web.log"
$dlPath        = $Config.Paths.Downloads

Write-DebugLog "VAR AppName=$AppName DaemonPort=$DaemonPort WebPort=$WebPort BTPort=$BTPort"
Write-DebugLog "VAR InstallDir=$InstallDir DataDir=$DataDir"
Write-DebugLog "VAR LockFile=$LockFile (exists=$(Test-Path $LockFile))"
Write-DebugLog "VAR SecretsDir=$SecretsDir AuthFile=$AuthFile"
Write-DebugLog "VAR SvcUser=$SvcUser SvcPass=[REDACTED]"

if (-not (Get-Command Grant-SeedboxDirAccess -ErrorAction SilentlyContinue)) {
    Write-DebugLog "INFO" "Loading ACL helpers..."
    . (Join-Path $PSScriptRoot "00_service_account.ps1") -Config $Config
}

if ($Config.Apps.Deluge -ne $true) {
    Write-Host "[$AppName] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "$AppName skipped (Apps.Deluge != true)"
    return
}
if (Test-Path $LockFile) {
    Write-Host "[$AppName] Already installed. Skipping." -ForegroundColor Green
    Write-DebugLog "INFO" "$AppName already installed (lock file present)"
    return
}

Write-Host "[$AppName] Installing..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== Installing $AppName ==="

# -- 1. Install Deluge via Chocolatey (version-pinned when versions.json present) -
$PinnedVersion = if ($Config._Versions -and $Config._Versions.Apps.Deluge) { $Config._Versions.Apps.Deluge.version } else { $null }
Write-DebugLog "VAR PinnedVersion=$PinnedVersion"

$installed = choco list --exact deluge -r 2>$null
Write-DebugLog "VAR choco deluge output=$installed"
if ([string]::IsNullOrWhiteSpace($installed)) {
    $displayVer = if ($PinnedVersion) { " $PinnedVersion" } else { "" }
    Write-Host "  -> Installing Deluge$displayVer via Chocolatey..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Installing Deluge via choco..."
    $savedEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        if ($PinnedVersion) {
            choco install deluge --version $PinnedVersion -y --no-progress | Out-Null
        } else {
            choco install deluge -y --no-progress | Out-Null
        }
    } finally {
        $ErrorActionPreference = $savedEAP
    }
    Write-DebugLog "INFO" "choco install deluge exit=$LASTEXITCODE"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "[$AppName] choco install deluge returned exit code $LASTEXITCODE. Attempting to continue..."
        Write-DebugLog "WARN" "choco install deluge non-zero exit: $LASTEXITCODE"
    }
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    Write-DebugLog "INFO" "PATH refreshed after deluge install"
} else {
    Write-Host "  -> Deluge already installed via Chocolatey." -ForegroundColor Green
    Write-DebugLog "INFO" "Deluge already installed: $installed"
}

# Find deluged.exe and deluge-web.exe
$delugedExe = Get-Command deluged.exe -ErrorAction SilentlyContinue
if (-not $delugedExe) {
    $chocoBin    = "C:\ProgramData\chocolatey\bin"
    $delugedExe  = Get-ChildItem $chocoBin -Filter "deluged.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $delugedExe) {
        $delugeDir = Get-ChildItem "C:\Program Files" -Directory -Filter "Deluge*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($delugeDir) {
            $delugedExe = Get-ChildItem $delugeDir.FullName -Filter "deluged.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        }
    }
}
$delugedPath = if ($delugedExe -is [System.Management.Automation.CommandInfo]) { $delugedExe.Source } else { $delugedExe.FullName }
Write-DebugLog "VAR delugedPath=$delugedPath"
if (-not $delugedPath) {
    Write-Error "[$AppName] deluged.exe not found. Chocolatey install may have failed."
    Write-DebugLog "ERROR" "deluged.exe not found in PATH or chocolatey bin"
    exit 1
}

$delugeWebExe = Get-Command deluge-web.exe -ErrorAction SilentlyContinue
if (-not $delugeWebExe) {
    $delugeWebExe = Get-ChildItem (Split-Path $delugedPath) -Filter "deluge-web.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
}
$delugeWebPath = if ($delugeWebExe -is [System.Management.Automation.CommandInfo]) { $delugeWebExe.Source } else { $delugeWebExe.FullName }
Write-DebugLog "VAR delugeWebPath=$delugeWebPath"
if (-not $delugeWebPath) {
    Write-Warning "[$AppName] deluge-web.exe not found. Web UI will not be available."
    Write-DebugLog "WARN" "deluge-web.exe not found. Web UI skipped."
}

# -- 2. Data directory + ACLs --------------------------------------------------
Write-DebugLog "VAR DataDir exists=$(Test-Path $DataDir)"
if (-not (Test-Path $DataDir)) {
    New-Item -Path $DataDir -ItemType Directory -Force | Out-Null
    Write-DebugLog "INFO" "Created $DataDir"
}
Grant-SeedboxDirAccess -Path $DataDir -Username $SvcUser

# -- 2b. Restore Deluge state from previous install ---------------------------
$DelugeBackupDir = Join-Path $env:LOCALAPPDATA "win-seedbox\deluge-state-backup"
$DelugeBackupStateDir = Join-Path $DelugeBackupDir "state"
Write-DebugLog "VAR DelugeBackupDir=$DelugeBackupDir (exists=$(Test-Path $DelugeBackupDir))"
Write-DebugLog "VAR DelugeBackupStateDir=$DelugeBackupStateDir (exists=$(Test-Path $DelugeBackupStateDir))"
if ((Test-Path $DelugeBackupStateDir) -and -not (Test-Path (Join-Path $DataDir "state"))) {
    Write-Host "  -> Restoring Deluge torrent state from previous install..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Restoring Deluge state from $DelugeBackupStateDir to $DataDir\state"
    Copy-Item -Recurse -Force $DelugeBackupStateDir "$DataDir\state" -ErrorAction SilentlyContinue
    Write-DebugLog "INFO" "Deluge state restored successfully"
    # Clean up backup to avoid stale restores on future reinstalls
    Remove-Item -Recurse -Force $DelugeBackupDir -ErrorAction SilentlyContinue
    Write-DebugLog "INFO" "Deluge backup cleaned up after successful restore"
} elseif (Test-Path $DelugeBackupDir) {
    Write-DebugLog "INFO" "Deluge backup found but DataDir\state already exists -- skip restore"
} else {
    Write-DebugLog "INFO" "No Deluge state backup found"
}

# -- 3. Generate auth file -----------------------------------------------------
Set-SecretsDirAcl -Path $SecretsDir -SvcUsername $SvcUser
$DelugeAuthFile = Join-Path $SecretsDir "deluge_auth.txt"
$delugeAuthExists = Test-Path $DelugeAuthFile
Write-DebugLog "VAR DelugeAuthFile exists=$delugeAuthExists"

if (-not $delugeAuthExists) {
    # Use the admin password from config.json so users only need one credential.
    # The same password protects the dashboard (Caddy basic_auth) and Deluge Web UI.
    $DelugePassword = $Config.General.AdminPassword
    # BOM-free: this file is read as a credential -- no stray BOM allowed
    [System.IO.File]::WriteAllText($DelugeAuthFile, $DelugePassword, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  -> Saved Deluge auth password -> $DelugeAuthFile" -ForegroundColor Gray
    Write-DebugLog "INFO" "Using admin password for Deluge. Saved to $DelugeAuthFile"
} else {
    $DelugePassword = (Get-Content -Path $DelugeAuthFile -Raw -Encoding UTF8).TrimStart([char]0xFEFF).Trim()
    Write-DebugLog "INFO" "Using existing Deluge password from $DelugeAuthFile"
}

Write-DebugLog "VAR DelugePassword=[REDACTED] (length=$($DelugePassword.Length))"

# -- 4. Write Deluge config files ----------------------------------------------
if (-not (Test-Path $AuthFile)) {
    Write-Host "  -> Writing Deluge auth file..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Writing auth file to $AuthFile"
    # Format: username:password:auth_level (10 = admin)
    # localclient allows localhost connections without password check
    $authContent = "localclient:`$1`$localclient:10`r`nseedbox:${DelugePassword}:10`r`n"
    # BOM-free -- Deluge reads auth line-by-line
    [System.IO.File]::WriteAllText($AuthFile, $authContent, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  -> Deluge auth file written to $AuthFile" -ForegroundColor Green
    Write-DebugLog "INFO" "Auth file written with localclient + seedbox accounts"
} else {
    Write-DebugLog "INFO" "Auth file already exists at $AuthFile -- not overwritten"
}

# Write core.conf -- Deluge config JSON (two-line format: header + config)
if (-not (Test-Path $CoreConf)) {
    Write-Host "  -> Writing deluge core.conf..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Writing core.conf to $CoreConf"
    $safeDlPath = $dlPath -replace '\\', '/'
    # High port avoids ISP throttling on default 6881 (configurable via Ports.DelugeBT).
    # DHT/LSD enabled for public tracker peer discovery.
    # Private torrents ignore DHT via the private flag automatically.
    # Tuned for 1 Gbps symmetric: 15 active downloads, 50 seeding,
    # 1500 global connections, 8 upload slots per torrent.
    # Upload capped at 720 Mbps (90 MB/s) to leave headroom for TCP ACKs.
    # 2 GiB disk cache (131072 x 16 KiB blocks) reduces HDD random I/O.
    $coreJson = @"
{"file": 1, "format": 1}
{
    "download_location": "$safeDlPath",
    "listen_ports": [$BTPort, $BTPort],
    "random_port": false,
    "dht": true,
    "upnp": true,
    "natpmp": true,
    "lsd": true,
    "utpex": true,
    "max_connections_global": 1500,
    "max_connections_per_second": 200,
    "max_connections_per_torrent": 120,
    "max_half_open_connections": 500,
    "max_upload_slots_global": 100,
    "max_upload_slots_per_torrent": 8,
    "max_active_limit": 100,
    "max_active_seeding": 50,
    "max_active_downloading": 15,
    "max_upload_speed": 90000.0,
    "max_download_speed": -1.0,
    "enc_in_policy": 2,
    "enc_out_policy": 2,
    "enc_level": 2,
    "cache_size": 131072,
    "cache_expiry": 300,
    "stop_seed_at_ratio": false,
    "remove_seed_at_ratio": false,
    "add_paused": false,
    "auto_managed": true,
    "allow_remote": false,
    "daemon_port": $DaemonPort,
    "enabled_plugins": ["Label"]
}
"@
    [System.IO.File]::WriteAllText($CoreConf, $coreJson, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  -> core.conf written to $CoreConf" -ForegroundColor Green
    Write-DebugLog "INFO" "core.conf written. download_location=$safeDlPath daemon_port=$DaemonPort"
} else {
    Write-DebugLog "INFO" "core.conf already exists at $CoreConf -- not overwritten"
}

# Write web.conf -- pre-configure Web UI password to match admin password
if (-not (Test-Path $WebConf)) {
    Write-Host "  -> Writing deluge web.conf..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Writing web.conf to $WebConf"

    # Generate salt and compute SHA1(salt + adminPassword) so the Web UI
    # is immediately usable with the same password as the dashboard.
    $saltBytes = New-Object byte[] 20
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($saltBytes)
    $webSalt = [System.BitConverter]::ToString($saltBytes) -replace '-', '' -replace '([0-9A-F]{2})', '$1'
    $webSalt = $webSalt.Substring(0, 40).ToLower()

    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    $hashInput = [System.Text.Encoding]::UTF8.GetBytes($webSalt + $DelugePassword)
    $webHash = [System.BitConverter]::ToString($sha1.ComputeHash($hashInput)) -replace '-', ''
    $webHash = $webHash.ToLower()

    $webJson = @"
{"file": 1, "format": 1}
{
    "port": $WebPort,
    "enabled": true,
    "allow_remote": false,
    "first_login": false,
    "pwd_salt": "$webSalt",
    "pwd_sha1": "$webHash",
    "session_timeout": 3600,
    "sessions": {}
}
"@
    [System.IO.File]::WriteAllText($WebConf, $webJson, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  -> web.conf written (Web UI password pre-configured)" -ForegroundColor Green
    Write-DebugLog "INFO" "web.conf written. port=$WebPort, first_login=false, password pre-set"
} else {
    Write-DebugLog "INFO" "web.conf already exists at $WebConf -- not overwritten"
}

# -- 5. NSSM services ----------------------------------------------------------
# Daemon service
Write-Host "  -> Creating Windows services..." -ForegroundColor Gray
$existingDaemon = Get-Service -Name "DelugeDaemon" -ErrorAction SilentlyContinue
Write-DebugLog "VAR DelugeDaemon service exists=$($null -ne $existingDaemon)"
if (-not $existingDaemon) {
    Write-DebugLog "INFO" "Creating NSSM service 'DelugeDaemon' exe=$delugedPath"
    nssm install DelugeDaemon "`"$delugedPath`"" | Out-Null
    nssm set DelugeDaemon AppParameters "--config `"$DataDir`" --loglevel info --logfile `"$DaemonLog`"" | Out-Null
    nssm set DelugeDaemon Description "Deluge BitTorrent Daemon" | Out-Null
    nssm set DelugeDaemon AppDirectory (Split-Path $delugedPath) | Out-Null
    nssm set DelugeDaemon Start SERVICE_AUTO_START | Out-Null
    nssm set DelugeDaemon AppStdout $DaemonLog | Out-Null
    nssm set DelugeDaemon AppStderr $DaemonLog | Out-Null
    nssm set DelugeDaemon ObjectName ".\$SvcUser" $SvcPass | Out-Null
    nssm set DelugeDaemon AppExit Default Restart | Out-Null
    nssm set DelugeDaemon AppRestartDelay 5000 | Out-Null
    Write-Host "  -> Service 'DelugeDaemon' created under '$SvcUser'." -ForegroundColor Green
    Write-DebugLog "INFO" "NSSM service 'DelugeDaemon' created. config=$DataDir log=$DaemonLog"
} else {
    Write-Host "  -> Service 'DelugeDaemon' already exists." -ForegroundColor Green
    Write-DebugLog "INFO" "NSSM service 'DelugeDaemon' already exists"
}

# Web UI service
$existingWeb = Get-Service -Name "DelugeWeb" -ErrorAction SilentlyContinue
Write-DebugLog "VAR DelugeWeb service exists=$($null -ne $existingWeb)"
$DomainMode = $Config.General.DomainMode
if (-not $existingWeb -and $delugeWebPath) {
    Write-DebugLog "INFO" "Creating NSSM service 'DelugeWeb' exe=$delugeWebPath"
    nssm install DelugeWeb "`"$delugeWebPath`"" | Out-Null
    $webBaseArg = if ($DomainMode -eq 'duckdns') { '--base /deluge' } else { '' }
    nssm set DelugeWeb AppParameters "--config `"$DataDir`" $webBaseArg --loglevel info --logfile `"$WebLog`"" | Out-Null
    nssm set DelugeWeb Description "Deluge Web UI" | Out-Null
    nssm set DelugeWeb AppDirectory (Split-Path $delugeWebPath) | Out-Null
    nssm set DelugeWeb Start SERVICE_AUTO_START | Out-Null
    nssm set DelugeWeb AppStdout $WebLog | Out-Null
    nssm set DelugeWeb AppStderr $WebLog | Out-Null
    nssm set DelugeWeb ObjectName ".\$SvcUser" $SvcPass | Out-Null
    nssm set DelugeWeb AppExit Default Restart | Out-Null
    nssm set DelugeWeb AppRestartDelay 5000 | Out-Null
    Write-Host "  -> Service 'DelugeWeb' created under '$SvcUser'." -ForegroundColor Green
    Write-DebugLog "INFO" "NSSM service 'DelugeWeb' created. config=$DataDir log=$WebLog"
} elseif (-not $delugeWebPath) {
    Write-Host "  -> Skipping DelugeWeb service (deluge-web.exe not found)." -ForegroundColor Yellow
    Write-DebugLog "WARN" "DelugeWeb service skipped: deluge-web.exe not found"
} else {
    Write-Host "  -> Service 'DelugeWeb' already exists." -ForegroundColor Green
    Write-DebugLog "INFO" "NSSM service 'DelugeWeb' already exists"
}

# -- 6. Firewall ---------------------------------------------------------------
New-NetFirewallRule -DisplayName "Deluge BT"     -Direction Inbound -LocalPort $BTPort -Protocol TCP -Action Allow -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule -DisplayName "Deluge BT UDP" -Direction Inbound -LocalPort $BTPort -Protocol UDP -Action Allow -ErrorAction SilentlyContinue | Out-Null
Write-DebugLog "INFO" "Firewall rules added for BitTorrent port $BTPort (TCP+UDP). Daemon port $DaemonPort is NOT opened (localhost-only)"
Write-Host "   -> IMPORTANT: Forward TCP+UDP port $BTPort on your router for optimal speeds." -ForegroundColor Yellow

# -- Fix Web UI: Chocolatey Deluge package only ships deluge-all-debug.js,
#    causing the Web UI to start in debug mode and fail to display torrents.
$webJsDir = Join-Path (Split-Path $delugeWebPath) "deluge\ui\web\js"
$debugJs  = Join-Path $webJsDir "deluge-all-debug.js"
$normalJs = Join-Path $webJsDir "deluge-all.js"
if ((Test-Path $debugJs) -and -not (Test-Path $normalJs)) {
    Copy-Item $debugJs $normalJs -Force
    Write-DebugLog "INFO" "Deluge Web UI: copied deluge-all-debug.js -> deluge-all.js to fix debug mode"
}

# -- 7. Start + verify Daemon --------------------------------------------------
Write-Host "  -> Starting DelugeDaemon..." -ForegroundColor Gray
Write-DebugLog "INFO" "Starting DelugeDaemon service..."
Start-Service -Name "DelugeDaemon" -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5
$svcDaemon = Get-Service -Name "DelugeDaemon" -ErrorAction SilentlyContinue
Write-DebugLog "VAR DelugeDaemon status after start=$(if ($svcDaemon) { $svcDaemon.Status } else { 'NOT FOUND' })"
if ($svcDaemon -and $svcDaemon.Status -eq "Running") {
    Write-Host "  -> DelugeDaemon running on port $DaemonPort (localhost only)." -ForegroundColor Green
    Write-DebugLog "INFO" "DelugeDaemon is Running. Daemon port=$DaemonPort (localhost only)"
} else {
    Write-Warning "  -> DelugeDaemon may not have started. Check $DaemonLog"
    Write-DebugLog "WARN" "DelugeDaemon may not be running. Check $DaemonLog"
}

# -- 8. Start + verify Web UI --------------------------------------------------
if ($delugeWebPath) {
    Write-Host "  -> Starting DelugeWeb..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Starting DelugeWeb service..."
    Start-Service -Name "DelugeWeb" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    $svcWeb = Get-Service -Name "DelugeWeb" -ErrorAction SilentlyContinue
    Write-DebugLog "VAR DelugeWeb status after start=$(if ($svcWeb) { $svcWeb.Status } else { 'NOT FOUND' })"
    if ($svcWeb -and $svcWeb.Status -eq "Running") {
        Write-Host "  -> Deluge Web UI running on port $WebPort (localhost only)." -ForegroundColor Green
        Write-DebugLog "INFO" "DelugeWeb is Running. Web port=$WebPort (localhost only)"
    } else {
        Write-Warning "  -> DelugeWeb may not have started. Check $WebLog"
        Write-DebugLog "WARN" "DelugeWeb may not be running. Check $WebLog"
    }
}

$LockVersion = if ($PinnedVersion) { $PinnedVersion } else { "unknown" }
[System.IO.File]::WriteAllText($LockFile, $LockVersion, [System.Text.Encoding]::UTF8)
Write-DebugLog "INFO" "Lock file written: $LockFile (version=$LockVersion)"
Write-Host "[$AppName] Done." -ForegroundColor Cyan
Write-DebugLog "INFO" "07_deluge.ps1 complete"
