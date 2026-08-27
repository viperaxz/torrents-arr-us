param (
    [Parameter(Mandatory=$true)]
    [object]$Config
)

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "02_jellyfin.ps1 started"

$DomainMode = $Config.General.DomainMode
$InstallDir = $Config.General.InstallDir
$LockFile   = Join-Path $InstallDir ".locks\.jellyfin.lock"
$SvcUser    = "seedbox-svc"
$SvcPass    = $Config.General.ServiceAccountPassword

Write-DebugLog "VAR DomainMode=$DomainMode InstallDir=$InstallDir"
Write-DebugLog "VAR LockFile=$LockFile (exists=$(Test-Path $LockFile))"
Write-DebugLog "VAR SvcUser=$SvcUser SvcPass=[REDACTED]"
Write-DebugLog "VAR JellyfinPort=$($Config.Ports.Jellyfin)"

if (-not (Get-Command Grant-SeedboxDirAccess -ErrorAction SilentlyContinue)) {
    Write-DebugLog "INFO" "Loading ACL helpers..."
    . (Join-Path $PSScriptRoot "00_service_account.ps1") -Config $Config
}

if ($Config.Apps.Jellyfin -ne $true) {
    Write-Host "[Jellyfin] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "Jellyfin skipped (Apps.Jellyfin != true)"
    return
}
if (Test-Path $LockFile) {
    Write-Host "[Jellyfin] Already installed. Skipping." -ForegroundColor Green
    Write-DebugLog "INFO" "Jellyfin already installed (lock file exists). Skipping."
    return
}

Write-Host "[Jellyfin] Installing..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== Installing Jellyfin ==="

# 1. Install via Chocolatey (version-pinned when versions.json is present)
$PinnedVersion = if ($Config._Versions -and $Config._Versions.Apps.Jellyfin) { $Config._Versions.Apps.Jellyfin.version } else { $null }
Write-DebugLog "VAR PinnedVersion=$PinnedVersion"
Write-Host "  -> Installing Jellyfin via Chocolatey$(if ($PinnedVersion) { " $PinnedVersion" })..." -ForegroundColor Yellow
$installed = choco list --exact jellyfin -r 2>$null
Write-DebugLog "VAR choco jellyfin output=$installed"
if ([string]::IsNullOrWhiteSpace($installed)) {
    Write-DebugLog "INFO" "Jellyfin not installed. Running choco install..."
    # EAP is "Stop" here (inherited from master_install.ps1) and choco writes
    # warnings (pending reboot, deprecation notices) to stderr on otherwise
    # successful installs -- which would abort this FATAL script.
    $savedEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        if ($PinnedVersion) {
            choco install jellyfin --version $PinnedVersion -y --no-progress | Out-Null
        } else {
            choco install jellyfin -y --no-progress | Out-Null
        }
    } finally {
        $ErrorActionPreference = $savedEAP
    }
    Write-DebugLog "INFO" "choco install jellyfin exit=$LASTEXITCODE"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "[Jellyfin] choco install jellyfin returned exit code $LASTEXITCODE. Attempting to continue..."
        Write-DebugLog "WARN" "choco install jellyfin non-zero exit: $LASTEXITCODE"
    }
} else {
    Write-Host "  -> Jellyfin already installed via Chocolatey." -ForegroundColor Green
    Write-DebugLog "INFO" "Jellyfin already installed: $installed"
    # Service may have been deleted without uninstalling the package; force reinstall to re-register it
    $hasService = $false
    foreach ($c in @("JellyfinServer","jellyfin","Jellyfin")) {
        if (Get-Service -Name $c -ErrorAction SilentlyContinue) { $hasService = $true; break }
    }
    Write-DebugLog "VAR Jellyfin service registered=$hasService"
    if (-not $hasService) {
        Write-Host "  -> Service not registered; forcing reinstall to re-register..." -ForegroundColor Yellow
        Write-DebugLog "WARN" "Jellyfin service not found after install. Force-reinstalling..."
        # EAP is "Stop" here; choco stderr warnings must not abort this.
        $savedEAP = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            if ($PinnedVersion) {
                choco install jellyfin --version $PinnedVersion -y --no-progress --force | Out-Null
            } else {
                choco install jellyfin -y --no-progress --force | Out-Null
            }
        } finally {
            $ErrorActionPreference = $savedEAP
        }
        Write-DebugLog "INFO" "choco force reinstall jellyfin exit=$LASTEXITCODE"
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "[Jellyfin] choco force reinstall jellyfin returned exit code $LASTEXITCODE."
            Write-DebugLog "WARN" "choco force reinstall jellyfin non-zero exit: $LASTEXITCODE"
        }
    }
}

# 2. Find service  --  Chocolatey may register it as "JellyfinServer" or "jellyfin"
$ServiceName = $null
foreach ($candidate in @("JellyfinServer","jellyfin","Jellyfin")) {
    if (Get-Service -Name $candidate -ErrorAction SilentlyContinue) {
        $ServiceName = $candidate
        Write-DebugLog "VAR Jellyfin service name=$ServiceName"
        break
    }
}
if (-not $ServiceName) {
    Write-Warning "[Jellyfin] Service not found. Chocolatey install may have failed."
    Write-DebugLog "ERROR" "Jellyfin service not found after install (tried JellyfinServer, jellyfin, Jellyfin)"
    exit 1
}

# 3a. Grant seedbox-svc access to Jellyfin data dir and media paths (filesystem only  --  service
#     account is changed later, after network.xml has been generated as LocalSystem)
$JellyfinDataDir = "C:\ProgramData\Jellyfin"
Write-DebugLog "VAR JellyfinDataDir=$JellyfinDataDir Movies=$($Config.Paths.Movies) TV=$($Config.Paths.TV)"
Grant-SeedboxDirAccess -Path $JellyfinDataDir           -Username $SvcUser
Grant-SeedboxDirAccess -Path $Config.Paths.Movies       -Username $SvcUser -Rights "ReadAndExecute"
Grant-SeedboxDirAccess -Path $Config.Paths.TV           -Username $SvcUser -Rights "ReadAndExecute"

# 3. Stop service to edit config
$jfSvc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
$svcStatus = if ($jfSvc) { $jfSvc.Status } else { "NOT FOUND" }
Write-DebugLog "VAR $ServiceName status before stop=$svcStatus"
if ($svcStatus -eq "Running") {
    Write-Host "  -> Stopping service to configure..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Stopping $ServiceName to write network.xml..."
    Stop-Service -Name $ServiceName -Force
    Start-Sleep -Seconds 3
    Write-DebugLog "INFO" "$ServiceName stopped"
}

# 4. Ensure network.xml exists  --  run as LocalSystem (current account) so Jellyfin has
#    full access to create C:\ProgramData\Jellyfin\Server\config\ on first run.
#    Service account is changed to seedbox-svc only after this file exists.
$ConfigDir     = "C:\ProgramData\Jellyfin\Server\config"
$NetworkConfig = Join-Path $ConfigDir "network.xml"
Write-DebugLog "VAR NetworkConfig=$NetworkConfig (exists=$(Test-Path $NetworkConfig))"
if (-not (Test-Path $NetworkConfig)) {
    Write-Host "  -> Writing network.xml (pre-configuring for first run)..." -ForegroundColor Gray
    $targetBase = if ($DomainMode -eq "duckdns") { "/jellyfin" } else { "" }
    $JfPort     = $Config.Ports.Jellyfin
    Write-DebugLog "VAR network.xml targetBase='$targetBase' JfPort=$JfPort"
    New-Item -Path $ConfigDir -ItemType Directory -Force | Out-Null
    $networkXmlContent = @"
<?xml version="1.0" encoding="utf-8"?>
<NetworkConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <RequireHttps>false</RequireHttps>
  <BaseUrl>$targetBase</BaseUrl>
  <InternalHttpPort>$JfPort</InternalHttpPort>
  <InternalHttpsPort>8920</InternalHttpsPort>
  <PublicHttpPort>80</PublicHttpPort>
  <PublicHttpsPort>443</PublicHttpsPort>
  <AutoDiscovery>true</AutoDiscovery>
  <EnableUPnP>false</EnableUPnP>
  <EnableIPV6>false</EnableIPV6>
  <EnableRemoteAccess>true</EnableRemoteAccess>
</NetworkConfiguration>
"@
    # BOM-free: Jellyfin's .NET XML parser handles BOM, but this is consistent
    # with the project-wide convention of never emitting EF BB BF.
    [System.IO.File]::WriteAllText($NetworkConfig, $networkXmlContent, (New-Object System.Text.UTF8Encoding($false)))
    Remove-Variable networkXmlContent -ErrorAction SilentlyContinue
    Write-Host "  -> network.xml written (BaseUrl='$targetBase')." -ForegroundColor Green
    Write-DebugLog "INFO" "network.xml written. BaseUrl='$targetBase' port=$JfPort"
}

# 4b. Now switch to seedbox-svc  --  data dir already exists and has correct permissions
Write-Host "  -> Changing Jellyfin service account to '$SvcUser'..." -ForegroundColor Gray
Write-DebugLog "INFO" "Changing $ServiceName service account to $SvcUser..."
sc.exe config $ServiceName obj= ".\$SvcUser" password= $SvcPass | Out-Null
Write-DebugLog "INFO" "sc.exe config $ServiceName exit=$LASTEXITCODE"
if ($LASTEXITCODE -ne 0) {
    Write-Warning "[Jellyfin] sc.exe config failed (exit $LASTEXITCODE). Service may be running under the wrong account."
    Write-DebugLog "ERROR" "sc.exe config $ServiceName returned non-zero exit code: $LASTEXITCODE"
}

# 5. Edit network.xml
Write-DebugLog "VAR network.xml exists=$(Test-Path $NetworkConfig)"
if (Test-Path $NetworkConfig) {
    try {
        [xml]$xml = Get-Content -Path $NetworkConfig -Encoding UTF8

        # RequireHttps  --  always false so Caddy handles TLS
        $beforeHttps = $xml.NetworkConfiguration.RequireHttps
        if ($null -ne $xml.NetworkConfiguration.RequireHttps) {
            $xml.NetworkConfiguration.RequireHttps = "false"
        }

        # BaseUrl  --  empty for Cloudflare (subdomain), /jellyfin for DuckDNS (path)
        $targetBase = if ($DomainMode -eq "duckdns") { "/jellyfin" } else { "" }
        $beforeBase = $xml.NetworkConfiguration.BaseUrl
        Write-DebugLog "VAR network.xml before: RequireHttps=$beforeHttps BaseUrl='$beforeBase'"
        if ($null -ne $xml.NetworkConfiguration.BaseUrl) {
            $xml.NetworkConfiguration.BaseUrl = $targetBase
        } else {
            $node = $xml.CreateElement("BaseUrl")
            $node.InnerText = $targetBase
            $xml.NetworkConfiguration.AppendChild($node) | Out-Null
        }

        $xml.Save($NetworkConfig)
        Write-Host "  -> BaseUrl='$targetBase', RequireHttps=false set." -ForegroundColor Green
        Write-DebugLog "INFO" "network.xml updated. BaseUrl='$targetBase' RequireHttps=false"
    } catch {
        Write-Warning "  -> Could not edit network.xml: $_"
        Write-DebugLog "ERROR" "network.xml edit failed: $_"
    }
} else {
    Write-Warning "  -> network.xml not found. Set BaseUrl manually in Jellyfin dashboard."
    Write-DebugLog "WARN" "network.xml not found for editing"
}

# 5b. Firewall  --  LAN-scoped so Caddy (loopback) is the only internet-facing path.
# A world-open rule would expose Jellyfin's own login page on :$AppPort, bypassing
# Caddy's basic-auth and CrowdSec detection. See 03_sonarr.ps1 for rationale.
$JfPort = $Config.Ports.Jellyfin
New-NetFirewallRule -DisplayName "Jellyfin" -Direction Inbound -LocalPort $JfPort -Protocol TCP -Action Allow -RemoteAddress LocalSubnet -ErrorAction SilentlyContinue | Out-Null
Write-DebugLog "INFO" "Firewall rule added for Jellyfin port=$JfPort"

# 6. Start service
Write-Host "  -> Starting Jellyfin..." -ForegroundColor Yellow
Write-DebugLog "INFO" "Starting $ServiceName..."
Start-Service -Name $ServiceName
Start-Sleep -Seconds 3
$svc = Get-Service -Name $ServiceName
Write-DebugLog "VAR $ServiceName status after start=$($svc.Status)"
if ($svc.Status -eq "Running") {
    Write-Host "  -> Jellyfin running on port $($Config.Ports.Jellyfin)." -ForegroundColor Green
    Write-DebugLog "INFO" "Jellyfin is Running on port $($Config.Ports.Jellyfin)"
} else {
    Write-Warning "  -> Jellyfin may not have started. Status: $($svc.Status)"
    Write-DebugLog "WARN" "Jellyfin status=$($svc.Status)  --  may not have started"
}

$LockVersion = if ($PinnedVersion) { $PinnedVersion } else { "unknown" }
[System.IO.File]::WriteAllText($LockFile, $LockVersion, [System.Text.Encoding]::UTF8)
Write-DebugLog "INFO" "Lock file written: $LockFile (version=$LockVersion)"

# Ledger entry for the updater (single source of truth for installed versions)
if (-not (Get-Command Set-InstalledVersion -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "update_common.ps1")
}
Set-InstalledVersion -InstallDir $InstallDir -AppName "Jellyfin" -Version $LockVersion

Write-Host "[Jellyfin] Done." -ForegroundColor Cyan
Write-DebugLog "INFO" "02_jellyfin.ps1 complete"
