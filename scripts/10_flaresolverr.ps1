param (
    [Parameter(Mandatory=$true)]
    [object]$Config
)

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "10_flaresolverr.ps1 started"

$AppName    = "Flaresolverr"
$AppLower   = "flaresolverr"
$AppPort    = if ($Config.Ports.PSObject.Properties["Flaresolverr"]) { $Config.Ports.Flaresolverr } else { 8191 }
$InstallDir = $Config.General.InstallDir
$AppBinDir  = Join-Path $InstallDir $AppName
$DataDir    = "C:\ProgramData\$AppName"
$LockFile   = Join-Path $InstallDir ".locks\.$AppLower.lock"
$SvcUser    = "seedbox-svc"
$SvcPass    = $Config.General.ServiceAccountPassword

Write-DebugLog "VAR AppName=$AppName AppPort=$AppPort"
Write-DebugLog "VAR InstallDir=$InstallDir AppBinDir=$AppBinDir DataDir=$DataDir"
Write-DebugLog "VAR LockFile=$LockFile (exists=$(Test-Path $LockFile))"
Write-DebugLog "VAR SvcUser=$SvcUser SvcPass=[REDACTED]"

if (-not (Get-Command Grant-SeedboxDirAccess -ErrorAction SilentlyContinue)) {
    Write-DebugLog "INFO" "Loading ACL helpers..."
    . (Join-Path $PSScriptRoot "00_service_account.ps1") -Config $Config
}

if ($Config.Apps.Flaresolverr -ne $true) {
    Write-Host "[$AppName] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "$AppName skipped (Apps.Flaresolverr != true)"
    return
}
if (Test-Path $LockFile) {
    Write-Host "[$AppName] Already installed. Skipping." -ForegroundColor Green
    Write-DebugLog "INFO" "$AppName already installed (lock file present)"
    return
}

Write-Host "[$AppName] Installing..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== Installing $AppName ==="

# -- 1. Download from GitHub ---------------------------------------------------
$BinDir = Join-Path $PSScriptRoot "..\bin"
Write-DebugLog "VAR BinDir=$BinDir"
if (-not (Test-Path $BinDir)) { New-Item -Path $BinDir -ItemType Directory -Force | Out-Null }

$PinnedVersion = if ($Config._Versions -and $Config._Versions.Apps.Flaresolverr) { $Config._Versions.Apps.Flaresolverr.version } else { $null }
$AssetName     = if ($Config._Versions -and $Config._Versions.Apps.Flaresolverr) { $Config._Versions.Apps.Flaresolverr.asset } else { "flaresolverr_windows_x64.zip" }
Write-DebugLog "VAR PinnedVersion=$PinnedVersion AssetName=$AssetName"

$CacheFile = if ($PinnedVersion) { Join-Path $BinDir "flaresolverr-$PinnedVersion.zip" } else { $null }
$CachedZip = if ($CacheFile -and (Test-Path $CacheFile)) {
    Get-Item $CacheFile
} else {
    Get-ChildItem $BinDir -Filter "flaresolverr-*.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
}
Write-DebugLog "VAR cached zip found=$($null -ne $CachedZip) name=$($CachedZip.Name)"

if ($CachedZip) {
    Write-Host "  -> Using cached $($CachedZip.Name)..." -ForegroundColor Gray
    $ZipPath = $CachedZip.FullName
    Write-DebugLog "INFO" "Using cached zip: $ZipPath"
} else {
    $ApiUri = if ($PinnedVersion) {
        "https://api.github.com/repos/FlareSolverr/FlareSolverr/releases/tags/$PinnedVersion"
    } else {
        "https://api.github.com/repos/FlareSolverr/FlareSolverr/releases/latest"
    }
    $displayVer = if ($PinnedVersion) { $PinnedVersion } else { "latest" }
    Write-Host "  -> Fetching FlareSolverr release $displayVer..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Querying GitHub API: $ApiUri"
    try {
        $Release = Invoke-RestMethod -Uri $ApiUri -UseBasicParsing
        Write-DebugLog "VAR GitHub release tag=$($Release.tag_name) assets=$($Release.assets.Count)"
    } catch {
        Write-Error "[$AppName] Failed to query GitHub releases: $_"
        Write-DebugLog "ERROR" "GitHub API query failed: $_"
        exit 1
    }
    $Version = $Release.tag_name
    $Asset   = $Release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
    Write-DebugLog "VAR selected asset=$($Asset.name) url=$($Asset.browser_download_url)"
    if (-not $Asset) {
        Write-Error "[$AppName] Asset '$AssetName' not found in release $Version."
        Write-DebugLog "ERROR" "Asset '$AssetName' not found in release $Version"
        exit 1
    }
    $ZipPath = Join-Path $BinDir "flaresolverr-$Version.zip"
    Write-Host "  -> Downloading FlareSolverr $Version..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Downloading $($Asset.browser_download_url) -> $ZipPath"
    Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $ZipPath -UseBasicParsing
    $zipSize = (Get-Item $ZipPath).Length
    Write-DebugLog "INFO" "Download complete. ZipPath=$ZipPath size=$zipSize bytes"
    if (-not $PinnedVersion) { $PinnedVersion = $Version }
}

# -- 2. Extract ----------------------------------------------------------------
Write-Host "  -> Extracting..." -ForegroundColor Gray
$existingSvc = Get-Service -Name $AppName -ErrorAction SilentlyContinue
Write-DebugLog "VAR existing $AppName service=$(if ($existingSvc) { $existingSvc.Status } else { 'NOT FOUND' })"
if ($existingSvc) {
    Write-DebugLog "INFO" "Stopping existing $AppName service before extraction..."
    Stop-Service -Name $AppName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}
$appBinExists = Test-Path $AppBinDir
Write-DebugLog "VAR AppBinDir exists=$appBinExists  --  will be removed"
if ($appBinExists) { Remove-Item $AppBinDir -Recurse -Force }
New-Item -Path $AppBinDir -ItemType Directory -Force | Out-Null
Write-DebugLog "INFO" "Extracting $ZipPath -> $AppBinDir"
Expand-Archive -Path $ZipPath -DestinationPath $AppBinDir -Force

# Flatten single-directory zips (e.g. flaresolverr-v3.x.x/ wrapping the files)
$children = Get-ChildItem $AppBinDir
Write-DebugLog "VAR top-level items after extract=$($children.Count) first=$($children[0].Name)"
if ($children.Count -eq 1 -and $children[0].PSIsContainer) {
    $sub = $children[0].FullName
    Write-DebugLog "INFO" "Flattening single-directory zip from $sub"
    Get-ChildItem $sub | Move-Item -Destination $AppBinDir
    Remove-Item $sub -Recurse -Force
    Write-DebugLog "INFO" "Flatten complete"
}

$ExePath = Join-Path $AppBinDir "flaresolverr.exe"
Write-DebugLog "VAR ExePath=$ExePath (exists=$(Test-Path $ExePath))"
if (-not (Test-Path $ExePath)) {
    Write-Error "[$AppName] flaresolverr.exe not found after extraction."
    Write-DebugLog "ERROR" "flaresolverr.exe not found in $AppBinDir"
    exit 1
}

# -- 3. Directories + permissions ----------------------------------------------
New-Item -Path $DataDir -ItemType Directory -Force | Out-Null
Grant-SeedboxDirAccess -Path $AppBinDir -Username $SvcUser
Grant-SeedboxDirAccess -Path $DataDir   -Username $SvcUser
Write-DebugLog "INFO" "Directories and ACLs set for $AppName"

# -- 4. Windows service via NSSM ----------------------------------------------
Write-Host "  -> Creating Windows service..." -ForegroundColor Gray
$svcExists = Get-Service -Name $AppName -ErrorAction SilentlyContinue
Write-DebugLog "VAR $AppName service exists=$($null -ne $svcExists)"
if (-not $svcExists) {
    Write-DebugLog "INFO" "Creating NSSM service '$AppName' exe=$ExePath port=$AppPort"
    nssm install $AppName "`"$ExePath`"" | Out-Null
    nssm set $AppName AppDirectory  $AppBinDir | Out-Null
    # Bind to localhost only  --  Prowlarr accesses FlareSolverr internally; no external exposure needed.
    nssm set $AppName AppEnvironmentExtra "LOG_LEVEL=info" "HOST=127.0.0.1" "PORT=$AppPort" | Out-Null
    nssm set $AppName Description   "FlareSolverr - Cloudflare and DDoS-Guard CAPTCHA solver proxy" | Out-Null
    nssm set $AppName Start         SERVICE_AUTO_START | Out-Null
    nssm set $AppName AppStdout     (Join-Path $DataDir "flaresolverr-stdout.log") | Out-Null
    nssm set $AppName AppStderr     (Join-Path $DataDir "flaresolverr-stderr.log") | Out-Null
    nssm set $AppName ObjectName    ".\$SvcUser" $SvcPass | Out-Null
    nssm set $AppName AppExit Default Restart | Out-Null
    nssm set $AppName AppRestartDelay 5000 | Out-Null
    Write-Host "  -> Service '$AppName' created under '$SvcUser'." -ForegroundColor Gray
    Write-DebugLog "INFO" "NSSM service '$AppName' created. HOST=127.0.0.1 PORT=$AppPort"
} else {
    Write-DebugLog "INFO" "NSSM service '$AppName' already exists"
}

# -- 5. Firewall ---------------------------------------------------------------
# Deliberately NO inbound rule. The service is started with HOST=127.0.0.1, so it
# only ever listens on loopback and is reached exclusively by Prowlarr on the same
# machine. Loopback traffic bypasses the firewall entirely, which makes an inbound
# allow rule for :$AppPort pure attack surface -- it exposes a headless Chromium
# that performs arbitrary fetches on request. Clean up the rule from older installs.
Get-NetFirewallRule -DisplayName "Flaresolverr" -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
Write-DebugLog "INFO" "No firewall rule for $AppName (loopback-only); legacy rule removed if present"

# -- 6. Start and validate -----------------------------------------------------
# FlareSolverr initialises a headless Chromium on first start  --  allow up to 60s.
Write-Host "  -> Starting $AppName (first startup initialises Chromium, may take ~30s)..." -ForegroundColor Gray
Write-DebugLog "INFO" "Starting $AppName service. Waiting up to 60s for API readiness..."
Start-Service -Name $AppName -ErrorAction SilentlyContinue

$deadline = (Get-Date).AddSeconds(60)
$started  = $false
$waited   = 0
while (-not $started -and (Get-Date) -lt $deadline) {
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$AppPort/" `
            -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop | Out-Null
        $started = $true
    } catch { Start-Sleep -Seconds 5; $waited += 5 }
}
Write-DebugLog "VAR FlareSolverr HTTP API responded=$started waited=${waited}s"

$svc = Get-Service -Name $AppName -ErrorAction SilentlyContinue
Write-DebugLog "VAR $AppName final status=$(if ($svc) { $svc.Status } else { 'NOT FOUND' })"
if ($svc -and $svc.Status -eq "Running") {
    Write-Host "  -> $AppName running on port $AppPort." -ForegroundColor Green
    Write-DebugLog "INFO" "$AppName is Running on port $AppPort"
} else {
    Write-Warning "  -> $AppName may not have started. Check $DataDir\flaresolverr-stderr.log"
    Write-DebugLog "WARN" "$AppName may not be running. Check $DataDir\flaresolverr-stderr.log"
}

$LockVersion = if ($PinnedVersion) { $PinnedVersion } else { "unknown" }
[System.IO.File]::WriteAllText($LockFile, $LockVersion, [System.Text.Encoding]::UTF8)
Write-DebugLog "INFO" "Lock file written: $LockFile (version=$LockVersion)"

# Ledger entry for the updater (single source of truth for installed versions)
if (-not (Get-Command Set-InstalledVersion -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "update_common.ps1")
}
Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $LockVersion

Write-Host "[$AppName] Done." -ForegroundColor Cyan
Write-DebugLog "INFO" "10_flaresolverr.ps1 complete"
