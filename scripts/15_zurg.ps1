param (
    [Parameter(Mandatory=$true)]
    [object]$Config
)

# -- Debug logging ---------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "15_zurg.ps1 started"

$AppName    = "Zurg"
$AppLower   = "zurg"
$InstallDir = $Config.General.InstallDir
$AppBinDir  = Join-Path $InstallDir $AppName
$LockFile   = Join-Path $InstallDir ".locks\.$AppLower.lock"
$SvcUser    = "seedbox-svc"
$SvcPass    = $Config.General.ServiceAccountPassword

Write-DebugLog "VAR AppName=$AppName InstallDir=$InstallDir AppBinDir=$AppBinDir"
Write-DebugLog "VAR LockFile=$LockFile (exists=$(Test-Path $LockFile))"

if (-not (Get-Command Grant-SeedboxDirAccess -ErrorAction SilentlyContinue)) {
    Write-DebugLog "INFO" "Loading ACL helpers..."
    . (Join-Path $PSScriptRoot "00_service_account.ps1") -Config $Config
}

if ($Config.Apps.RealDebrid -ne $true) {
    Write-Host "[$AppName] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "$AppName skipped (Apps.RealDebrid != true)"
    return
}

$RdApiKey = if ($Config.PSObject.Properties['RealDebrid'] -and $Config.RealDebrid.ApiKey) {
    $Config.RealDebrid.ApiKey
} else { "" }

Write-DebugLog "VAR RdApiKey configured=$((-not [string]::IsNullOrEmpty($RdApiKey)))"

if ([string]::IsNullOrEmpty($RdApiKey)) {
    Write-Warning "[$AppName] RealDebrid.ApiKey is empty in config.json. Skipping."
    Write-DebugLog "WARN" "RealDebrid.ApiKey is empty -- skipping Zurg install"
    return
}

if (Test-Path $LockFile) {
    Write-Host "[$AppName] Already installed. Skipping." -ForegroundColor Green
    Write-DebugLog "INFO" "$AppName already installed (lock file present)"
    return
}

Write-Host "[$AppName] Installing..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== Installing $AppName ==="

# -- 1. Create app directory ----------------------------------------------------
if (-not (Test-Path $AppBinDir)) {
    New-Item -ItemType Directory -Path $AppBinDir -Force | Out-Null
    Write-DebugLog "INFO" "Created $AppBinDir"
}

# -- 2. Download zurg binary from GitHub ----------------------------------------
$BinDir = Join-Path $PSScriptRoot "..\bin"
if (-not (Test-Path $BinDir)) { New-Item -Path $BinDir -ItemType Directory -Force | Out-Null }

$ZurgExe = Join-Path $AppBinDir "zurg.exe"
Write-DebugLog "VAR ZurgExe=$ZurgExe (exists=$(Test-Path $ZurgExe))"

if (-not (Test-Path $ZurgExe)) {
    Write-Host "  -> Fetching Zurg release from GitHub..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Querying GitHub API for zurg-testing latest release..."
    try {
        $ghHeaders = @{ "User-Agent" = "win-seedbox-installer" }
        $release   = Invoke-RestMethod "https://api.github.com/repos/debridmediamanager/zurg-public/releases/latest" `
                         -Headers $ghHeaders -UseBasicParsing -ErrorAction Stop
        Write-DebugLog "VAR release tag=$($release.tag_name) assets=$($release.assets.Count)"

        $asset = $release.assets | Where-Object {
            $_.name -match "windows" -and ($_.name -match "amd64" -or $_.name -match "x64")
        } | Select-Object -First 1

        if (-not $asset) {
            Write-Error "[$AppName] No Windows x64 asset found in Zurg release $($release.tag_name)."
            Write-DebugLog "ERROR" "No Windows amd64 asset in Zurg release $($release.tag_name)"
            exit 1
        }

        Write-DebugLog "VAR asset=$($asset.name) url=$($asset.browser_download_url)"
        $zipPath = Join-Path $env:TEMP "zurg-windows-amd64.zip"

        if ($asset.name -like "*.zip") {
            Write-Host "  -> Downloading $($asset.name)..." -ForegroundColor Gray
            Write-DebugLog "INFO" "Downloading $($asset.browser_download_url) -> $zipPath"
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
            Expand-Archive -Path $zipPath -DestinationPath $AppBinDir -Force
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            # Rename extracted exe if needed
            $extracted = Get-ChildItem $AppBinDir -Filter "*.exe" | Select-Object -First 1
            if ($extracted -and $extracted.Name -ne "zurg.exe") {
                Rename-Item $extracted.FullName "zurg.exe" -Force
                Write-DebugLog "INFO" "Renamed $($extracted.Name) -> zurg.exe"
            }
        } else {
            # Single exe asset
            Write-Host "  -> Downloading $($asset.name)..." -ForegroundColor Gray
            Write-DebugLog "INFO" "Downloading $($asset.browser_download_url) -> $ZurgExe"
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $ZurgExe -UseBasicParsing -ErrorAction Stop
        }

        Write-Host "     OK Zurg $($release.tag_name) downloaded." -ForegroundColor Green
        Write-DebugLog "INFO" "Zurg $($release.tag_name) ready at $ZurgExe"
    } catch {
        Write-Error "[$AppName] Download failed: $_"
        Write-DebugLog "ERROR" "Zurg download failed: $_"
        exit 1
    }
}

if (-not (Test-Path $ZurgExe)) {
    Write-Error "[$AppName] zurg.exe not found at '$ZurgExe' after download."
    Write-DebugLog "ERROR" "zurg.exe missing after download"
    exit 1
}

# -- 3. Generate zurg config ----------------------------------------------------
$ZurgConfig = Join-Path $AppBinDir "config.yml"
Write-DebugLog "VAR ZurgConfig=$ZurgConfig"

$ZurgPort = 9999
# v1.0.0+ uses the zurg-public stable release channel.
# __all__ is the built-in directory that exposes all torrents at the WebDAV root.
# rclone mounts zurg:__all__ so torrent folders appear directly at the drive root.
$configYml = @"
zurg: v1
token: $RdApiKey
port: $ZurgPort
concurrent_workers: 32
check_for_changes_every_secs: 15
enable_repair: true
enable_thorough_hash_check: false
cache_network_test_results: true
"@

[System.IO.File]::WriteAllText($ZurgConfig, $configYml, [System.Text.Encoding]::UTF8)
Write-Host "     OK Zurg config written." -ForegroundColor Green
Write-DebugLog "INFO" "Zurg config written to $ZurgConfig (port=$ZurgPort)"

# -- 4. Set ACLs ----------------------------------------------------------------
Grant-SeedboxDirAccess -Path $AppBinDir
Write-DebugLog "INFO" "ACLs set on $AppBinDir"

# -- 5. Register NSSM service ---------------------------------------------------
Write-Host "  -> Registering Zurg service..." -ForegroundColor Gray
Write-DebugLog "INFO" "Registering NSSM service '$AppName'..."

$svcExists = Get-Service -Name $AppName -ErrorAction SilentlyContinue
if ($svcExists) {
    Write-DebugLog "INFO" "Service '$AppName' already exists -- removing for clean registration"
    Stop-Service -Name $AppName -Force -ErrorAction SilentlyContinue
    # Wait up to 30 s for the process to exit before asking NSSM to remove it.
    # Without this, nssm remove blocks until the process dies (can take minutes).
    $waited = 0
    while ((Get-Service -Name $AppName -ErrorAction SilentlyContinue).Status -eq 'StopPending' -and $waited -lt 30) {
        Start-Sleep -Seconds 2; $waited += 2
    }
    nssm remove $AppName confirm | Out-Null
    # Wait for SCM to fully unregister before calling nssm install.
    $waited = 0
    while ($null -ne (Get-Service -Name $AppName -ErrorAction SilentlyContinue) -and $waited -lt 10) {
        Start-Sleep -Seconds 1; $waited += 1
    }
}

nssm install $AppName $ZurgExe | Out-Null
nssm set $AppName AppDirectory $AppBinDir | Out-Null

$LogDir = Join-Path $InstallDir "logs"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
nssm set $AppName AppStdout (Join-Path $LogDir "zurg.log") | Out-Null
nssm set $AppName AppStderr (Join-Path $LogDir "zurg-error.log") | Out-Null
nssm set $AppName AppRotateFiles 1 | Out-Null
nssm set $AppName AppRotateBytes 5242880 | Out-Null
nssm set $AppName Start SERVICE_AUTO_START | Out-Null
nssm set $AppName ObjectName ".\$SvcUser" $SvcPass | Out-Null
nssm set $AppName AppEnvironmentExtra "LOG_LEVEL=info" | Out-Null
nssm set $AppName AppExit Default Restart | Out-Null
nssm set $AppName AppRestartDelay 5000 | Out-Null

Write-DebugLog "INFO" "NSSM service '$AppName' registered"

# -- 6. Start service -----------------------------------------------------------
Write-Host "  -> Starting Zurg service..." -ForegroundColor Gray
Write-DebugLog "INFO" "Starting service '$AppName'..."
Start-Service -Name $AppName -ErrorAction SilentlyContinue

$svc = $null
$pollDeadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $pollDeadline) {
    $svc = Get-Service -Name $AppName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") { break }
    if ($svc -and $svc.Status -ne "StartPending") { break }
    Start-Sleep -Seconds 2
}
if (-not $svc) { $svc = Get-Service -Name $AppName -ErrorAction SilentlyContinue }

$svcStatus = if ($svc) { $svc.Status } else { "NOT FOUND" }
Write-DebugLog "VAR service status=$svcStatus"
if ($svc -and $svc.Status -eq "Running") {
    Write-Host "     OK Zurg service running (WebDAV on port $ZurgPort)." -ForegroundColor Green
    Write-DebugLog "INFO" "Zurg service running on port $ZurgPort"
} else {
    Write-Warning "     Zurg service not running (status: $svcStatus). Check logs at $LogDir\zurg-error.log."
    Write-DebugLog "WARN" "Zurg service status=$svcStatus after start"
}

# -- 7. Write lock file ---------------------------------------------------------
[System.IO.File]::WriteAllText($LockFile, (Get-Date -Format "o"), [System.Text.Encoding]::UTF8)

# Ledger entry for the updater (single source of truth for versions)
if (-not (Get-Command Set-InstalledVersion -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "update_common.ps1")
}
$zurgVer = $null
if (Get-Variable -Name release -ErrorAction SilentlyContinue) { $zurgVer = $release.tag_name }
if (-not $zurgVer) {
    $zurgEntry = if ($Config._Versions -and $Config._Versions.Apps.Zurg) { $Config._Versions.Apps.Zurg } else { $null }
    $zurgVer = Detect-InstalledVersion -AppName "Zurg" -Entry $zurgEntry -InstallDir $InstallDir
}
if ($zurgVer) { Set-InstalledVersion -InstallDir $InstallDir -AppName "Zurg" -Version $zurgVer }

Write-Host "  OK $AppName installed." -ForegroundColor Green
Write-DebugLog "INFO" "15_zurg.ps1 complete. Lock file written: $LockFile"
