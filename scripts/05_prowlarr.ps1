param (
    [Parameter(Mandatory=$true)]
    [object]$Config
)

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "05_prowlarr.ps1 started"

$AppName     = "Prowlarr"
$AppLower    = "prowlarr"
$AppPort     = $Config.Ports.Prowlarr
$InstallDir  = $Config.General.InstallDir
$AppBinDir   = Join-Path $InstallDir $AppName
$DataDir     = "C:\ProgramData\$AppName"
$LockFile    = Join-Path $InstallDir ".locks\.$AppLower.lock"
$DomainMode  = $Config.General.DomainMode
$SvcUser     = "seedbox-svc"
$SvcPass     = $Config.General.ServiceAccountPassword

Write-DebugLog "VAR AppName=$AppName AppPort=$AppPort"
Write-DebugLog "VAR InstallDir=$InstallDir AppBinDir=$AppBinDir DataDir=$DataDir"
Write-DebugLog "VAR LockFile=$LockFile (exists=$(Test-Path $LockFile))"
Write-DebugLog "VAR DomainMode=$DomainMode SvcUser=$SvcUser"

if (-not (Get-Command Grant-SeedboxDirAccess -ErrorAction SilentlyContinue)) {
    Write-DebugLog "INFO" "Loading ACL helpers..."
    . (Join-Path $PSScriptRoot "00_service_account.ps1") -Config $Config
}

if ($Config.Apps.Prowlarr -ne $true) {
    Write-Host "[$AppName] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "$AppName skipped (Apps.Prowlarr != true)"
    return
}
if (Test-Path $LockFile) {
    Write-Host "[$AppName] Already installed. Skipping." -ForegroundColor Green
    Write-DebugLog "INFO" "$AppName already installed (lock file present)"
    return
}

Write-Host "[$AppName] Installing..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== Installing $AppName ==="

$BinDir = Join-Path $PSScriptRoot "..\bin"
Write-DebugLog "VAR BinDir=$BinDir"
if (-not (Test-Path $BinDir)) { New-Item -Path $BinDir -ItemType Directory -Force | Out-Null }

$PinnedVersion = if ($Config._Versions -and $Config._Versions.Apps.Prowlarr) { $Config._Versions.Apps.Prowlarr.version } else { $null }
$AssetPattern  = if ($Config._Versions -and $Config._Versions.Apps.Prowlarr) { $Config._Versions.Apps.Prowlarr.asset } else { "*windows-core-x64*.zip" }
Write-DebugLog "VAR PinnedVersion=$PinnedVersion AssetPattern=$AssetPattern"

$VersionNumeric = if ($PinnedVersion) { $PinnedVersion.TrimStart('v') } else { $null }
$CachedZip = if ($VersionNumeric) {
    Get-ChildItem $BinDir -Filter "$AppName*$VersionNumeric*.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
} else {
    Get-ChildItem $BinDir -Filter "$AppName.*.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
}
Write-DebugLog "VAR cached zip found=$($null -ne $CachedZip) name=$($CachedZip.Name)"

if ($CachedZip) {
    Write-Host "  -> Using cached $($CachedZip.Name)..." -ForegroundColor Gray
    $ZipPath = $CachedZip.FullName
    Write-DebugLog "INFO" "Using cached zip: $ZipPath"
} else {
    $ApiUri = if ($PinnedVersion) {
        "https://api.github.com/repos/Prowlarr/Prowlarr/releases/tags/$PinnedVersion"
    } else {
        "https://api.github.com/repos/Prowlarr/Prowlarr/releases/latest"
    }
    $displayVer = if ($PinnedVersion) { $PinnedVersion } else { "latest" }
    Write-Host "  -> Fetching $AppName release $displayVer..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Querying GitHub API: $ApiUri"
    try {
        $Release = Invoke-RestMethod -Uri $ApiUri -UseBasicParsing
        Write-DebugLog "VAR GitHub release tag=$($Release.tag_name) assets=$($Release.assets.Count)"
    } catch {
        Write-Error "[$AppName] Failed to query GitHub releases: $_"
        Write-DebugLog "ERROR" "GitHub API query failed: $_"
        exit 1
    }
    $Asset = $Release.assets | Where-Object { $_.name -like $AssetPattern } | Select-Object -First 1
    Write-DebugLog "VAR selected asset=$($Asset.name) url=$($Asset.browser_download_url)"
    if (-not $Asset) {
        Write-Error "[$AppName] No asset matching '$AssetPattern' in release $($Release.tag_name)."
        Write-DebugLog "ERROR" "No asset matching '$AssetPattern' in release $($Release.tag_name)"
        exit 1
    }
    $ZipPath = Join-Path $BinDir $Asset.name
    Write-Host "  -> Downloading $AppName $($Release.tag_name)..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Downloading $($Asset.browser_download_url) -> $ZipPath"
    Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $ZipPath -UseBasicParsing
    $zipSize = (Get-Item $ZipPath).Length
    Write-DebugLog "INFO" "Download complete. File=$ZipPath size=$zipSize bytes"
    if (-not $PinnedVersion) { $PinnedVersion = $Release.tag_name }
}

if (-not (Test-Path $AppBinDir)) {
    New-Item -Path $AppBinDir -ItemType Directory -Force | Out-Null
    Write-DebugLog "INFO" "Created AppBinDir: $AppBinDir"
}
Write-Host "  -> Extracting..." -ForegroundColor Gray
Write-DebugLog "INFO" "Extracting $ZipPath -> $AppBinDir"
Expand-Archive -Path $ZipPath -DestinationPath $AppBinDir -Force
Write-DebugLog "INFO" "Extraction complete"

$AppExe = Get-ChildItem -Path $AppBinDir -Recurse -Filter "$AppName.exe" | Select-Object -First 1
Write-DebugLog "VAR AppExe=$($AppExe.FullName)"
if (-not $AppExe) {
    Write-Error "[$AppName] $AppName.exe not found after extraction."
    Write-DebugLog "ERROR" "$AppName.exe not found in $AppBinDir"
    exit 1
}

Write-DebugLog "VAR DataDir=$DataDir (exists=$(Test-Path $DataDir))"
if (-not (Test-Path $DataDir)) { New-Item -Path $DataDir -ItemType Directory -Force | Out-Null }
Grant-SeedboxDirAccess -Path $DataDir -Username $SvcUser

Write-Host "  -> Creating Windows service..." -ForegroundColor Gray
$ExistingService = Get-Service -Name $AppName -ErrorAction SilentlyContinue
Write-DebugLog "VAR $AppName service exists=$($null -ne $ExistingService)"
if (-not $ExistingService) {
    Write-DebugLog "INFO" "Creating NSSM service '$AppName' exe=$($AppExe.FullName)"
    nssm install $AppName "`"$($AppExe.FullName)`"" | Out-Null
    nssm set $AppName AppParameters "-nobrowser -data=`"$DataDir`"" | Out-Null
    nssm set $AppName Description "$AppName Indexer Manager Service" | Out-Null
    nssm set $AppName AppDirectory "$($AppExe.DirectoryName)" | Out-Null
    nssm set $AppName Start SERVICE_AUTO_START | Out-Null
    nssm set $AppName AppStdout (Join-Path $DataDir "$AppLower.log") | Out-Null
    nssm set $AppName AppStderr (Join-Path $DataDir "$AppLower.log") | Out-Null
    nssm set $AppName ObjectName ".\$SvcUser" $SvcPass | Out-Null
    nssm set $AppName AppExit Default Restart | Out-Null
    nssm set $AppName AppRestartDelay 5000 | Out-Null
    Write-DebugLog "INFO" "NSSM service '$AppName' created"
} else {
    Write-DebugLog "INFO" "NSSM service '$AppName' already exists"
}

# LAN-scoped: Caddy proxies over loopback, so exposing this port to the internet
# would only bypass basic-auth and CrowdSec detection. See 03_sonarr.ps1.
New-NetFirewallRule -DisplayName "$AppName" -Direction Inbound -LocalPort $AppPort -Protocol TCP -Action Allow -RemoteAddress LocalSubnet -ErrorAction SilentlyContinue | Out-Null
Write-DebugLog "INFO" "Firewall rule added for $AppName port=$AppPort"

Write-Host "  -> Starting $AppName (waiting for first-run config)..." -ForegroundColor Gray
Write-DebugLog "INFO" "Starting $AppName. Waiting up to 90s for config.xml..."
Start-Service -Name $AppName -ErrorAction SilentlyContinue
$ConfigXml = Join-Path $DataDir "config.xml"
$deadline  = (Get-Date).AddSeconds(90)
$waited    = 0
while (-not (Test-Path $ConfigXml) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3; $waited += 3 }
Write-DebugLog "VAR config.xml created=$(Test-Path $ConfigXml) waited=${waited}s"

if ($DomainMode -eq "duckdns" -and (Test-Path $ConfigXml)) {
    Write-DebugLog "INFO" "DuckDNS mode: setting UrlBase=/$AppLower in $ConfigXml"
    Stop-Service -Name $AppName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    try {
        [xml]$xml = Get-Content -Path $ConfigXml -Encoding UTF8
        $beforeUrlBase = $xml.Config.UrlBase
        Write-DebugLog "VAR config.xml UrlBase before='$beforeUrlBase'"
        if ($null -ne $xml.Config.UrlBase) { $xml.Config.UrlBase = "/$AppLower" }
        else {
            $node = $xml.CreateElement("UrlBase"); $node.InnerText = "/$AppLower"
            $xml.Config.AppendChild($node) | Out-Null
        }
        $xml.Save($ConfigXml)
        Write-Host "  -> UrlBase set to /$AppLower (DuckDNS mode)." -ForegroundColor Green
        Write-DebugLog "INFO" "config.xml UrlBase updated: '$beforeUrlBase' -> '/$AppLower'"
    } catch {
        Write-Warning "  -> Could not set UrlBase: $_"
        Write-DebugLog "ERROR" "config.xml UrlBase update failed: $_"
    }
    Start-Service -Name $AppName -ErrorAction SilentlyContinue
    Write-DebugLog "INFO" "$AppName restarted after UrlBase change"
} elseif (-not (Test-Path $ConfigXml)) {
    Write-Warning "  -> config.xml not found after 90s."
    Write-DebugLog "WARN" "config.xml not generated within 90s"
} else {
    Write-DebugLog "INFO" "Cloudflare mode: UrlBase not needed"
}

Start-Sleep -Seconds 3
$svc = Get-Service -Name $AppName -ErrorAction SilentlyContinue
Write-DebugLog "VAR $AppName final status=$(if ($svc) { $svc.Status } else { 'NOT FOUND' })"
if ($svc -and $svc.Status -eq "Running") {
    Write-Host "  -> $AppName running on port $AppPort." -ForegroundColor Green
    Write-DebugLog "INFO" "$AppName is Running on port $AppPort"
} else {
    Write-Warning "  -> $AppName may not have started. Check $DataDir\$AppLower.log"
    Write-DebugLog "WARN" "$AppName may not be running. Check $DataDir\$AppLower.log"
}

$LockVersion = if ($PinnedVersion) { $PinnedVersion } else { "unknown" }
[System.IO.File]::WriteAllText($LockFile, $LockVersion, [System.Text.Encoding]::UTF8)
Write-DebugLog "INFO" "Lock file written: $LockFile (version=$LockVersion)"
Write-Host "[$AppName] Done." -ForegroundColor Cyan
Write-DebugLog "INFO" "05_prowlarr.ps1 complete"
