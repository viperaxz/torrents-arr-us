param (
    [Parameter(Mandatory=$true)]
    [object]$Config
)

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "01_webserver.ps1 started"

$DomainMode    = $Config.General.DomainMode
$TlsMode       = $Config.General.TlsMode
$InstallDir    = $Config.General.InstallDir
$CaddyDir      = Join-Path $InstallDir "Caddy"
$CaddyDataDir  = Join-Path $InstallDir "caddy-data"
$CertCacheDir  = Join-Path $PSScriptRoot "..\cert-cache"
$CertCacheFile = Join-Path $CertCacheDir "caddy-data.enc"
$SvcUser       = "seedbox-svc"
$SvcPass       = $Config.General.ServiceAccountPassword
$SecretsDir    = Join-Path $InstallDir "secrets"

Write-DebugLog "VAR DomainMode=$DomainMode TlsMode=$TlsMode"
Write-DebugLog "VAR InstallDir=$InstallDir"
Write-DebugLog "VAR CaddyDir=$CaddyDir"
Write-DebugLog "VAR CaddyDataDir=$CaddyDataDir"
Write-DebugLog "VAR CertCacheFile=$CertCacheFile (exists=$(Test-Path $CertCacheFile))"
Write-DebugLog "VAR SecretsDir=$SecretsDir"
Write-DebugLog "VAR SvcUser=$SvcUser SvcPass=[REDACTED]"

# Load ACL helpers from 00_service_account.ps1 if not already loaded
if (-not (Get-Command Grant-SeedboxDirAccess -ErrorAction SilentlyContinue)) {
    Write-DebugLog "INFO" "Loading ACL helpers from 00_service_account.ps1..."
    . (Join-Path $PSScriptRoot "00_service_account.ps1") -Config $Config
}

# PS 5.1-safe repeating scheduled task via XML import (CimInstance Repetition props are not settable on all builds)
# Runs as seedbox-svc (Password logon)  --  not SYSTEM.
function Register-RepeatingTask {
    param([string]$TaskName, [string]$ScriptPath, [string]$Description)
    $FullSvcUser = "$env:COMPUTERNAME\$SvcUser"
    # Escape XML special characters to avoid malformed task XML if the
    # description or computer name contains &, <, >, or " characters.
    $escapedDesc = [System.Security.SecurityElement]::Escape($Description)
    $escapedUser = [System.Security.SecurityElement]::Escape($FullSvcUser)
    Write-DebugLog "INFO" "Registering scheduled task '$TaskName' for user=$FullSvcUser scriptPath=$ScriptPath"
    $XmlString = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>$escapedDesc</Description></RegistrationInfo>
  <Triggers>
    <TimeTrigger>
      <Repetition>
        <Interval>PT5M</Interval>
        <Duration>P9999D</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>2000-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$escapedUser</UserId>
      <LogonType>Password</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <ExecutionTimeLimit>PT30M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$ScriptPath"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    Register-ScheduledTask -TaskName $TaskName -Xml $XmlString -User $FullSvcUser -Password $SvcPass -Force | Out-Null
    Write-Host "  -> Scheduled task '$TaskName' created (every 5 min, $SvcUser)." -ForegroundColor Green
    Write-DebugLog "INFO" "Scheduled task '$TaskName' registered successfully"
}

# -- 0. Cert cache restore -----------------------------------------------------
. (Join-Path $PSScriptRoot "cert_cache_helpers.ps1")
$caddyDataExists = Test-Path $CaddyDataDir
$caddyDataEmpty  = $true
if ($caddyDataExists) {
    try {
        $caddyDataEmpty = (Get-ChildItem $CaddyDataDir -ErrorAction Stop | Measure-Object).Count -eq 0
    } catch {
        Write-DebugLog "WARN" "Cannot read $CaddyDataDir (permission error?). Treating as non-empty to avoid overwrite."
        $caddyDataEmpty = $false
    }
}
Write-DebugLog "VAR CaddyDataDir exists=$caddyDataExists isEmpty=$caddyDataEmpty"
Write-DebugLog "VAR CertCacheFile exists=$(Test-Path $CertCacheFile)"
if ((Test-Path $CertCacheFile) -and $caddyDataEmpty) {
    Write-Host "[WebServer] Restoring cert cache..." -ForegroundColor Yellow
    Write-DebugLog "INFO" "Restoring cert cache from $CertCacheFile to $CaddyDataDir"
    try {
        Restore-CaddyData -SourceFile $CertCacheFile -DestDir $CaddyDataDir `
                          -Password $Config.General.AdminPassword
        $restoredFiles = (Get-ChildItem $CaddyDataDir -Recurse -ErrorAction SilentlyContinue).Count
        Write-DebugLog "INFO" "Cert cache restored. Files in CaddyDataDir=$restoredFiles"

        # Check which certs are already cached vs. still needed.
        # We NEVER discard the restored data  --  the ACME account info must survive
        # across reinstalls so Caddy reuses the same LE account. Discarding it
        # causes a new account + new order on every install, burning the LE rate limit
        # even when all challenges fail (e.g. DNS not yet propagated).
        # Caddy will request whatever certs are missing on its own first start.
        if ($TlsMode -ne "internal") {
            $certStoreBase = Join-Path $CaddyDataDir "certificates"
            $expectedDomains = if ($DomainMode -eq "cloudflare") {
                $d = $Config.General.Domain
                @($d) + (
                    @("Jellyfin","Sonarr","Radarr","Prowlarr","Deluge","Bazarr","Jellyseerr","Grafana") |
                    Where-Object { $Config.Apps.$_ -eq $true } |
                    ForEach-Object { "$($_.ToLower()).$d" }
                )
            } else {
                @($Config.General.DuckDnsDomain)
            }
            Write-DebugLog "VAR cert check expectedDomains=$($expectedDomains -join ', ')"

            $missingDomains = @($expectedDomains | Where-Object {
                -not (Test-Path (Join-Path $certStoreBase "*\$_"))
            })
            Write-DebugLog "VAR cert check missingDomains=$($missingDomains -join ', ')"

            if ($missingDomains.Count -gt 0) {
                Write-Host "  -> Cert cache restored (ACME account preserved)." -ForegroundColor Green
                Write-Host "  -> Certs not yet in cache: $($missingDomains -join ', ')." -ForegroundColor Yellow
                Write-Host "  -> Caddy will request them on first start (port 80/443 must be reachable)." -ForegroundColor Yellow
                Write-DebugLog "WARN" "Cert cache: ACME account present, certs missing=$($missingDomains -join ', '). Caddy will obtain them."
            } else {
                Write-Host "  -> Cert cache valid: all $($expectedDomains.Count) domain(s) cached." -ForegroundColor Green
                Write-DebugLog "INFO" "Cert cache valid: $($expectedDomains -join ', ')"
            }
        } else {
            Write-Host "  -> Cert cache restored to $CaddyDataDir" -ForegroundColor Green
        }
    } catch {
        Write-Warning "  -> Cert cache restore failed (wrong password or corrupt): $_"
        Write-DebugLog "ERROR" "Cert cache restore FAILED: $_"
        Write-Host "  -> Caddy will request new certificates from Let's Encrypt." -ForegroundColor Yellow
    }
} else {
    Write-DebugLog "INFO" "Cert cache restore skipped (cacheFile=$(Test-Path $CertCacheFile) dataEmpty=$caddyDataEmpty)"
}

Write-Host "[WebServer] Starting ($DomainMode mode, TLS=$TlsMode)..." -ForegroundColor Cyan

if (-not (Test-Path $InstallDir)) {
    New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
    Write-DebugLog "INFO" "Created InstallDir: $InstallDir"
}

# -- 1. Install Caddy ----------------------------------------------------------
$CaddyPinnedVersion = if ($Config._Versions -and $Config._Versions.Apps.Caddy) { $Config._Versions.Apps.Caddy.version } else { $null }
Write-DebugLog "VAR CaddyPinnedVersion=$CaddyPinnedVersion"
Write-Host "[WebServer] Installing Caddy$(if ($CaddyPinnedVersion) { " $CaddyPinnedVersion" })..." -ForegroundColor Yellow
Write-DebugLog "INFO" "=== Checking Caddy installation ==="
$caddyInstalled = choco list --exact caddy -r 2>$null
Write-DebugLog "VAR choco caddy output=$caddyInstalled"
if ([string]::IsNullOrWhiteSpace($caddyInstalled)) {
    Write-DebugLog "INFO" "Caddy not installed. Installing via choco..."
    # EAP is "Stop" here (inherited from master_install.ps1) and choco writes
    # warnings (pending reboot, deprecation notices) to stderr on otherwise
    # successful installs -- which would abort this FATAL script.
    $savedEAP = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        if ($CaddyPinnedVersion) {
            choco install caddy --version $CaddyPinnedVersion -y --no-progress | Out-Null
        } else {
            choco install caddy -y --no-progress | Out-Null
        }
    } finally {
        $ErrorActionPreference = $savedEAP
    }
    Write-DebugLog "INFO" "choco install caddy complete. Exit code=$LASTEXITCODE"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "[WebServer] choco install caddy failed (exit $LASTEXITCODE)."
        Write-DebugLog "ERROR" "choco install caddy returned non-zero exit code: $LASTEXITCODE"
        exit 1
    }
} else {
    Write-Host "  -> Caddy already installed." -ForegroundColor Green
    Write-DebugLog "INFO" "Caddy already installed: $caddyInstalled"
}
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
Write-DebugLog "INFO" "PATH refreshed after Caddy check"

$caddyExe = (Get-Command caddy.exe -ErrorAction SilentlyContinue).Source
Write-DebugLog "VAR caddyExe=$caddyExe"
if (-not $caddyExe) {
    Write-Error "[WebServer] caddy.exe not found in PATH after install. Aborting."
    Write-DebugLog "ERROR" "caddy.exe not found in PATH. PATH=$env:Path"
    exit 1
}

# -- 2. DNS updater ------------------------------------------------------------
Write-DebugLog "INFO" "=== DNS updater setup (mode=$DomainMode) ==="
if ($DomainMode -eq "cloudflare") {
    $CloudflareApiToken = $Config.General.CloudflareApiToken
    $Domain             = $Config.General.Domain

    Write-DebugLog "VAR Domain=$Domain"
    Write-DebugLog "VAR CloudflareApiToken=[REDACTED] (isBlank=$([string]::IsNullOrWhiteSpace($CloudflareApiToken)) isDefault=$($CloudflareApiToken -eq 'your-cloudflare-api-token'))"

    if ([string]::IsNullOrWhiteSpace($CloudflareApiToken) -or $CloudflareApiToken -eq "your-cloudflare-api-token") {
        Write-Warning "[WebServer] Cloudflare API token not set. Skipping DNS updater."
        Write-DebugLog "WARN" "Cloudflare DNS updater skipped: token not configured"
    } else {
        Write-Host "[WebServer] Configuring Cloudflare DNS updater..." -ForegroundColor Yellow

        # Store token in ACL-protected credential file (not embedded in the script)
        Set-SecretsDirAcl -Path $SecretsDir -SvcUsername $SvcUser
        $TokenFile = Join-Path $SecretsDir "cloudflare_token.txt"
        Set-Content -Path $TokenFile -Value $CloudflareApiToken -Encoding UTF8
        Write-DebugLog "VAR Cloudflare token file=$TokenFile"

        # Build subdomain list from enabled apps (Flaresolverr is internal-only)
        $cfSubdomains = @('""')
        foreach ($k in @("Jellyfin","Sonarr","Radarr","Prowlarr","Deluge","Bazarr","Jellyseerr")) {
            if ($Config.Apps.$k -eq $true) { $cfSubdomains += "`"$($k.ToLower())`"" }
        }
        $CfSubdomainLiteral = $cfSubdomains -join ","
        Write-DebugLog "VAR Cloudflare updater subdomains: $CfSubdomainLiteral"

        $UpdaterPath = Join-Path $InstallDir "Update-CloudflareDNS.ps1"
        Write-DebugLog "VAR UpdaterPath=$UpdaterPath"
        $UpdaterContent = @"
`$ApiToken   = (Get-Content -Path "$TokenFile" -Raw -ErrorAction Stop).Trim()
`$Domain     = "$Domain"
`$Subdomains = @($CfSubdomainLiteral)
`$Headers    = @{ "Authorization" = "Bearer `$ApiToken"; "Content-Type" = "application/json" }
try {
    `$PublicIp = (Invoke-RestMethod -Uri "https://api.ipify.org" -UseBasicParsing).Trim()
    `$ZoneResp = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones?name=`$Domain" -Headers `$Headers -UseBasicParsing
    if (-not `$ZoneResp.success -or `$ZoneResp.result.Count -eq 0) { throw "Zone not found for `$Domain" }
    `$ZoneId = `$ZoneResp.result[0].id
    foreach (`$sub in `$Subdomains) {
        `$fqdn    = if (`$sub -eq "") { `$Domain } else { "`$sub.`$Domain" }
        `$dnsResp = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/`$ZoneId/dns_records?name=`$fqdn&type=A" -Headers `$Headers -UseBasicParsing
        `$body    = @{ type="A"; name=`$fqdn; content=`$PublicIp; proxied=`$false; ttl=1 } | ConvertTo-Json
        if (`$dnsResp.success -and `$dnsResp.result.Count -gt 0) {
            `$rid = `$dnsResp.result[0].id
            if (`$dnsResp.result[0].content -ne `$PublicIp) {
                Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/`$ZoneId/dns_records/`$rid" -Headers `$Headers -Method Put -Body `$body -UseBasicParsing | Out-Null
                Write-Output "Updated `$fqdn -> `$PublicIp"
            } else { Write-Output "`$fqdn already correct." }
        } else {
            Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/`$ZoneId/dns_records" -Headers `$Headers -Method Post -Body `$body -UseBasicParsing | Out-Null
            Write-Output "Created `$fqdn -> `$PublicIp"
        }
    }
} catch { Write-Error "Cloudflare update failed: `$_"; exit 1 }
"@
        Set-Content -Path $UpdaterPath -Value $UpdaterContent -Encoding UTF8
        Write-DebugLog "INFO" "Cloudflare updater script written to $UpdaterPath"

        Write-Host "  -> Running initial DNS update..." -ForegroundColor Gray
        Write-DebugLog "INFO" "Running initial Cloudflare DNS update..."
        # Wrap in try/catch: master_install sets $ErrorActionPreference="Stop", so
        # a subprocess stderr line becomes a terminating NativeCommandError otherwise.
        $dnsOutput = $null
        try {
            $dnsOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $UpdaterPath 2>&1
        } catch {
            $dnsOutput = "ERROR: $_"
            Write-Warning "[WebServer] Initial Cloudflare DNS update failed (non-fatal  --  scheduled task will retry): $_"
            Write-DebugLog "WARN" "Initial Cloudflare DNS update failed (non-fatal): $_"
        }
        Write-DebugLog "VAR Cloudflare DNS update output=$dnsOutput"

        $TaskName = "Seedbox_Cloudflare_Updater"
        $taskExists = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Write-DebugLog "VAR scheduled task '$TaskName' exists=$($null -ne $taskExists)"
        if (-not $taskExists) {
            Register-RepeatingTask -TaskName $TaskName -ScriptPath $UpdaterPath -Description "Updates Cloudflare A records with current IP every 5 minutes"
        } else {
            Write-Host "  -> Cloudflare scheduled task already exists." -ForegroundColor Green
            Write-DebugLog "INFO" "Scheduled task '$TaskName' already registered"
        }
    }
} else {
    # DuckDNS updater
    $DuckDnsDomain = $Config.General.DuckDnsDomain
    $DuckDnsToken  = $Config.General.DuckDnsToken

    Write-DebugLog "VAR DuckDnsDomain=$DuckDnsDomain"
    Write-DebugLog "VAR DuckDnsToken=[REDACTED] (isBlank=$([string]::IsNullOrWhiteSpace($DuckDnsToken)) isDefault=$($DuckDnsToken -eq 'your-duckdns-token'))"

    if ([string]::IsNullOrWhiteSpace($DuckDnsToken) -or $DuckDnsToken -eq "your-duckdns-token") {
        Write-Warning "[WebServer] DuckDNS token not set. Skipping DNS updater."
        Write-DebugLog "WARN" "DuckDNS updater skipped: token not configured"
    } else {
        Write-Host "[WebServer] Configuring DuckDNS updater..." -ForegroundColor Yellow

        # Store token in ACL-protected credential file (not embedded in the script)
        Set-SecretsDirAcl -Path $SecretsDir -SvcUsername $SvcUser
        $TokenFile = Join-Path $SecretsDir "duckdns_token.txt"
        Set-Content -Path $TokenFile -Value $DuckDnsToken -Encoding UTF8
        Write-DebugLog "VAR DuckDNS token file=$TokenFile"

        $UpdaterPath = Join-Path $InstallDir "Update-DuckDNS.ps1"
        Write-DebugLog "VAR UpdaterPath=$UpdaterPath"
        $UpdaterContent = @"
`$token  = (Get-Content -Path "$TokenFile" -Raw -ErrorAction Stop).Trim()
`$domain = "$DuckDnsDomain"
try {
    `$ip  = (Invoke-WebRequest -Uri "https://api.ipify.org" -UseBasicParsing).Content.Trim()
    `$url = "https://www.duckdns.org/update?domains=`$domain&token=`$token&ip=`$ip"
    `$raw = (Invoke-WebRequest -Uri `$url -UseBasicParsing).Content
    `$res = if (`$raw -is [byte[]]) { [Text.Encoding]::UTF8.GetString(`$raw).Trim() } else { ([string]`$raw).Trim() }
    if (`$res -eq "OK") { Write-Output "DuckDNS updated: `$domain -> `$ip" }
    else { Write-Error "DuckDNS returned: `$res" }
} catch { Write-Error "DuckDNS update failed: `$_"; exit 1 }
"@
        Set-Content -Path $UpdaterPath -Value $UpdaterContent -Encoding UTF8
        Write-DebugLog "INFO" "DuckDNS updater script written to $UpdaterPath"

        Write-Host "  -> Running initial DuckDNS update..." -ForegroundColor Gray
        Write-DebugLog "INFO" "Running initial DuckDNS update..."
        # Wrap in try/catch: master_install sets $ErrorActionPreference="Stop", so
        # a subprocess stderr line becomes a terminating NativeCommandError otherwise.
        $dnsOutput = $null
        try {
            $dnsOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $UpdaterPath 2>&1
        } catch {
            $dnsOutput = "ERROR: $_"
            Write-Warning "[WebServer] Initial DuckDNS update failed (non-fatal  --  scheduled task will retry): $_"
            Write-DebugLog "WARN" "Initial DuckDNS update failed (non-fatal): $_"
        }
        Write-DebugLog "VAR DuckDNS update output=$dnsOutput"

        $TaskName = "Seedbox_DuckDNS_Updater"
        $taskExists = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Write-DebugLog "VAR scheduled task '$TaskName' exists=$($null -ne $taskExists)"
        if (-not $taskExists) {
            Register-RepeatingTask -TaskName $TaskName -ScriptPath $UpdaterPath -Description "Updates DuckDNS record with current IP every 5 minutes"
        } else {
            Write-Host "  -> DuckDNS scheduled task already exists." -ForegroundColor Green
            Write-DebugLog "INFO" "Scheduled task '$TaskName' already registered"
        }
    }
}

# -- 3. Compute bcrypt hash of admin password for Caddy basicauth -------------
$AdminUsername   = $Config.General.AdminUsername
$AdminPassword   = $Config.General.AdminPassword
Write-DebugLog "INFO" "=== Computing bcrypt hash for AdminUser=$AdminUsername ==="
Write-DebugLog "VAR AdminPassword=[REDACTED]"
# EAP is "Stop" here (inherited from master_install.ps1). Any stderr line from caddy
# would become a terminating NativeCommandError and abort this FATAL script before the
# explicit validation below can produce a useful message. Drop to Continue for the call.
$savedEAP = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    $AdminBcryptHash = (& $caddyExe hash-password --plaintext $AdminPassword 2>&1 | Out-String).Trim()
} finally {
    $ErrorActionPreference = $savedEAP
}
Write-DebugLog "VAR AdminBcryptHash starts with '$($AdminBcryptHash.Substring(0,[Math]::Min(4,$AdminBcryptHash.Length)))...' (full hash [REDACTED for security])"
if ([string]::IsNullOrWhiteSpace($AdminBcryptHash) -or -not $AdminBcryptHash.StartsWith('$2')) {
    Write-Error "[WebServer] Failed to generate bcrypt hash via 'caddy hash-password'. Output: $AdminBcryptHash"
    Write-DebugLog "ERROR" "bcrypt hash generation FAILED. caddy output=$AdminBcryptHash"
    exit 1
}
Write-DebugLog "INFO" "bcrypt hash generated successfully (starts with `$2b)"

# -- 4. Static dashboard -------------------------------------------------------
Write-Host "[WebServer] Generating dashboard..." -ForegroundColor Yellow
$DashboardDir  = Join-Path $InstallDir "dashboard"
$DashboardHtml = Join-Path $DashboardDir "index.html"
Write-DebugLog "VAR DashboardDir=$DashboardDir"
Write-DebugLog "VAR DashboardHtml=$DashboardHtml"
if (-not (Test-Path $DashboardDir)) {
    New-Item -Path $DashboardDir -ItemType Directory -Force | Out-Null
    Write-DebugLog "INFO" "Created dashboard directory: $DashboardDir"
}

$DashTemplatePath = Join-Path $PSScriptRoot "..\templates\dashboard.html.template"
Write-DebugLog "VAR DashTemplatePath=$DashTemplatePath (exists=$(Test-Path $DashTemplatePath))"
if (-not (Test-Path $DashTemplatePath)) {
    Write-Warning "  -> dashboard.html.template not found. Skipping."
    Write-DebugLog "WARN" "Dashboard template not found at $DashTemplatePath"
} else {
    $cfgDomain = $Config.General.Domain
    $cfgDuck   = $Config.General.DuckDnsDomain
    $Hostname  = if ($DomainMode -eq "cloudflare") { $cfgDomain } else { $cfgDuck }
    Write-DebugLog "VAR dashboard Hostname=$Hostname (mode=$DomainMode)"

    $AppDefs = @(
        @{ Key="Jellyfin";   Name="Jellyfin";   Slug="jellyfin";   Initials="JF";  Color="#00a4dc" },
        @{ Key="Sonarr";     Name="Sonarr";     Slug="sonarr";     Initials="SNR"; Color="#35c5f4" },
        @{ Key="Radarr";     Name="Radarr";     Slug="radarr";     Initials="RDR"; Color="#ffc230" },
        @{ Key="Prowlarr";   Name="Prowlarr";   Slug="prowlarr";   Initials="PRL"; Color="#ff6b35" },
        @{ Key="Deluge";     Name="Deluge";     Slug="deluge";     Initials="DL";  Color="#4a90d9" },
        @{ Key="Bazarr";     Name="Bazarr";     Slug="bazarr";     Initials="BZR"; Color="#9b59b6" },
        @{ Key="Jellyseerr"; Name="Jellyseerr"; Slug="jellyseerr"; Initials="JS";  Color="#ff7e4e" },
        @{ Key="Grafana";    Name="Grafana";    Slug="grafana";    Initials="GRF"; Color="#f46800"; Suffix="/dashboards" }
    )

    $cards = @()
    $enabledApps = @()
    foreach ($a in $AppDefs) {
        if ($Config.Apps.$($a.Key) -ne $true) { continue }
        $enabledApps += $a.Key
        $suffix = if ($a.Suffix) { $a.Suffix } else { "" }
        $url = if ($DomainMode -eq "cloudflare") {
            "https://$($a.Slug).$cfgDomain$suffix"
        } else {
            "https://$cfgDuck/$($a.Slug)$suffix"
        }
        $bg = "$($a.Color)33"
        $cards += "    <a href=`"$url`" class=`"card`" target=`"_blank`">"
        $cards += "      <div class=`"badge`" style=`"background:$bg;color:$($a.Color)`">$($a.Initials)</div>"
        $cards += "      <div class=`"app-name`">$($a.Name)</div>"
        $cards += "    </a>"
    }
    Write-DebugLog "VAR dashboard enabled apps=$($enabledApps -join ',') cards=$($cards.Count) lines"

    $DashHtml = Get-Content -Raw -Path $DashTemplatePath -Encoding UTF8
    $DashHtml = $DashHtml.Replace('{HOSTNAME}',  $Hostname)
    $DashHtml = $DashHtml.Replace('{APP_CARDS}', ($cards -join "`n"))
    Set-Content -Path $DashboardHtml -Value $DashHtml -Encoding UTF8
    Write-Host "  -> Dashboard written to $DashboardHtml" -ForegroundColor Green
    Write-DebugLog "INFO" "Dashboard HTML written to $DashboardHtml (size=$($DashHtml.Length) chars)"
}

# -- 5. Generate Caddyfile -----------------------------------------------------
Write-Host "[WebServer] Generating Caddyfile..." -ForegroundColor Yellow
if (-not (Test-Path $CaddyDir)) {
    New-Item -Path $CaddyDir -ItemType Directory -Force | Out-Null
    Write-DebugLog "INFO" "Created CaddyDir: $CaddyDir"
}

$TemplateName = if ($DomainMode -eq "cloudflare") { "Caddyfile_cloudflare.template" } else { "Caddyfile_duckdns.template" }
$TemplatePath = Join-Path $PSScriptRoot "..\templates\$TemplateName"
Write-DebugLog "VAR Caddyfile templateName=$TemplateName path=$TemplatePath (exists=$(Test-Path $TemplatePath))"

if (-not (Test-Path $TemplatePath)) {
    Write-Error "[WebServer] Template not found: $TemplatePath"
    Write-DebugLog "ERROR" "Caddyfile template not found: $TemplatePath"
    exit 1
}

# Build TLS block
$TlsBlock = switch ($TlsMode) {
    "internal"       { "tls internal" }
    "letsencrypt"    { "tls $($Config.General.TlsEmail)" }
    "letsencrypt-staging" {
        "tls $($Config.General.TlsEmail) {`n        ca https://acme-staging-v02.api.letsencrypt.org/directory`n    }"
    }
    default { "tls internal" }
}
Write-DebugLog "VAR TlsBlock=$TlsBlock"

$SafeInstallDir   = $InstallDir.Replace('\', '/')
$SafeCaddyDataDir = $CaddyDataDir.Replace('\', '/')
Write-DebugLog "VAR SafeInstallDir=$SafeInstallDir"
Write-DebugLog "VAR SafeCaddyDataDir=$SafeCaddyDataDir"
Write-DebugLog "VAR Ports: Jellyfin=$($Config.Ports.Jellyfin) Sonarr=$($Config.Ports.Sonarr) Radarr=$($Config.Ports.Radarr) Prowlarr=$($Config.Ports.Prowlarr) Deluge=$($Config.Ports.Deluge) DelugeWeb=$($Config.Ports.DelugeWeb) Bazarr=$($Config.Ports.Bazarr)"

$Content = Get-Content -Raw -Path $TemplatePath -Encoding UTF8
Write-DebugLog "VAR template raw size=$($Content.Length) chars"

# Common substitutions
$Content = $Content.Replace('{$CADDY_DATA_DIR}',  $SafeCaddyDataDir)
$Content = $Content.Replace('{$TLS_BLOCK}',         $TlsBlock)
$Content = $Content.Replace('{$INSTALL_DIR}',        $SafeInstallDir)
$Content = $Content.Replace('{$JELLYFIN_PORT}',      [string]$Config.Ports.Jellyfin)
$Content = $Content.Replace('{$SONARR_PORT}',        [string]$Config.Ports.Sonarr)
$Content = $Content.Replace('{$RADARR_PORT}',        [string]$Config.Ports.Radarr)
$Content = $Content.Replace('{$PROWLARR_PORT}',      [string]$Config.Ports.Prowlarr)
$Content = $Content.Replace('{$DELUGE_WEB_PORT}',      [string]$Config.Ports.DelugeWeb)
$Content = $Content.Replace('{$BAZARR_PORT}',        [string]$Config.Ports.Bazarr)
$JellyseerrPort = if ($Config.Ports.PSObject.Properties["Jellyseerr"]) { $Config.Ports.Jellyseerr } else { 5055 }
$Content = $Content.Replace('{$JELLYSEERR_PORT}',    [string]$JellyseerrPort)
$Content = $Content.Replace('{$ADMIN_USER}',         $AdminUsername)
$Content = $Content.Replace('{$ADMIN_HASH_BCRYPT}',  $AdminBcryptHash)

if ($DomainMode -eq "cloudflare") {
    $Content = $Content.Replace('{$DOMAIN}', $Config.General.Domain)
    Write-DebugLog "VAR substituted DOMAIN=$($Config.General.Domain)"
} else {
    $DuckHost = $Config.General.DuckDnsDomain
    $Content  = $Content.Replace('{$DUCKDNS_HOST}', $DuckHost)
    Write-DebugLog "VAR substituted DUCKDNS_HOST=$DuckHost"
}

$CaddyfilePath = Join-Path $CaddyDir "Caddyfile"
# BOM-free: the Caddyfile is parsed by Caddy (Go), not PowerShell. Set-Content
# -Encoding UTF8 on PS 5.1 prepends EF BB BF ahead of the global-options '{'.
[System.IO.File]::WriteAllText($CaddyfilePath, $Content, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "  -> Caddyfile written to $CaddyfilePath" -ForegroundColor Green
Write-DebugLog "INFO" "Caddyfile written to $CaddyfilePath (size=$($Content.Length) chars)"

# Normalize formatting so Caddy's startup warning ("not formatted") is suppressed.
caddy fmt --overwrite $CaddyfilePath 2>$null
Write-DebugLog "INFO" "Caddyfile formatted (caddy fmt)"

# -- 5. Caddy service ----------------------------------------------------------
Write-Host "[WebServer] Configuring Caddy service..." -ForegroundColor Yellow
$CaddyService = Get-Service -Name "Caddy" -ErrorAction SilentlyContinue
Write-DebugLog "VAR Caddy service exists=$($null -ne $CaddyService) status=$(if ($CaddyService) { $CaddyService.Status } else { 'N/A' })"
if (-not $CaddyService) {
    Write-DebugLog "INFO" "Creating Caddy NSSM service under $SvcUser..."
    Grant-SeedboxDirAccess -Path $CaddyDir     -Username $SvcUser
    Grant-SeedboxDirAccess -Path $CaddyDataDir -Username $SvcUser
    nssm install Caddy "$caddyExe" "run --config `"$CaddyfilePath`"" | Out-Null
    Write-DebugLog "INFO" "nssm install Caddy exit=$LASTEXITCODE"
    nssm set Caddy Description "Caddy Reverse Proxy" | Out-Null
    nssm set Caddy AppDirectory "$CaddyDir" | Out-Null
    nssm set Caddy Start SERVICE_AUTO_START | Out-Null
    nssm set Caddy AppStdout (Join-Path $CaddyDir "caddy.log") | Out-Null
    nssm set Caddy AppStderr (Join-Path $CaddyDir "caddy.log") | Out-Null
    nssm set Caddy ObjectName ".\$SvcUser" $SvcPass | Out-Null
    nssm set Caddy AppExit Default Restart | Out-Null
    nssm set Caddy AppRestartDelay 5000 | Out-Null
    Write-DebugLog "VAR Caddy service log=$(Join-Path $CaddyDir 'caddy.log')"

    New-NetFirewallRule -DisplayName "Caddy HTTP"  -Direction Inbound -LocalPort 80  -Protocol TCP -Action Allow -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "Caddy HTTPS" -Direction Inbound -LocalPort 443 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue | Out-Null
    Write-DebugLog "INFO" "Firewall rules added: ports 80 and 443"

    Write-DebugLog "INFO" "Starting Caddy service..."
    Start-Service -Name "Caddy"
    Start-Sleep -Seconds 3
    $svc = Get-Service -Name "Caddy"
    Write-DebugLog "VAR Caddy service status after start=$($svc.Status)"
    if ($svc.Status -eq "Running") {
        Write-Host "  -> Caddy service started." -ForegroundColor Green
        Write-DebugLog "INFO" "Caddy service is Running"
    } else {
        Write-Error "[WebServer] Caddy failed to start. Check $CaddyDir\caddy.log"
        Write-DebugLog "ERROR" "Caddy failed to start. Status=$($svc.Status) logFile=$(Join-Path $CaddyDir 'caddy.log')"
        exit 1
    }
} else {
    Write-Host "  -> Caddy already exists. Reloading config..." -ForegroundColor Green
    Write-DebugLog "INFO" "Caddy service exists. Reloading config from $CaddyfilePath..."
    # Caddy writes JSON logs to stderr even on success; PS 5.1 with $ErrorActionPreference="Stop"
    # turns any stderr output from a native command into a terminating NativeCommandError before
    # the pipeline can suppress it. Wrap in try/catch so $LASTEXITCODE is still checkable.
    try { & $caddyExe reload --config $CaddyfilePath 2>&1 | Out-Null } catch {}
    Write-DebugLog "VAR caddy reload exit=$LASTEXITCODE"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "  -> caddy reload failed; restarting service instead."
        Write-DebugLog "WARN" "caddy reload failed (exit=$LASTEXITCODE). Restarting service..."
        Restart-Service -Name "Caddy"
        Write-DebugLog "INFO" "Caddy service restarted"
    } else {
        Write-DebugLog "INFO" "Caddy config reloaded successfully"
    }
}

if ($TlsMode -eq "internal") {
    Write-Host ""
    Write-Host "  [TIP] To trust the local Caddy CA (removes browser warnings):" -ForegroundColor Yellow
    Write-Host "        Run once as admin: caddy trust" -ForegroundColor Yellow
    Write-DebugLog "INFO" "TlsMode=internal: user must run 'caddy trust' manually"
}

$CaddyLockFile = Join-Path $Config.General.InstallDir ".locks\.caddy.lock"
$CaddyLockVer  = if ($CaddyPinnedVersion) { $CaddyPinnedVersion } else { "unknown" }
[System.IO.File]::WriteAllText($CaddyLockFile, $CaddyLockVer, [System.Text.Encoding]::UTF8)
Write-DebugLog "INFO" "Caddy lock file written: $CaddyLockFile (version=$CaddyLockVer)"

Write-Host "[WebServer] Done." -ForegroundColor Cyan
Write-DebugLog "INFO" "01_webserver.ps1 complete"
