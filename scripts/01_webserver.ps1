param (
    [Parameter(Mandatory=$true)]
    [object]$Config
)

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")
Initialize-DebugLog -Config $Config
# Shared choco plumbing: PATH-safe resolution plus retry-on-transient-feed-failure.
. (Join-Path $PSScriptRoot "choco_helpers.ps1")
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

# -- LLM reverse proxy config (optional, externally managed backend) -----------
$LlmEnabled   = $false
$LlmSubdomain = "llm"
$LlmHost      = "127.0.0.1"
$LlmPort      = 8081
$LlmApiKey    = ""
$LlmExposeUi  = $true
# NB: the property can exist with a null/absent value ("LLM": null). Indexing into a
# null $lc.PSObject.Properties throws, so guard the value too.
if ($Config.PSObject.Properties["LLM"] -and $Config.LLM) {
    $lc = $Config.LLM
    if ($lc.PSObject.Properties["Enabled"] -and $lc.Enabled -eq $true) { $LlmEnabled = $true }
    if ($lc.PSObject.Properties["Subdomain"] -and $lc.Subdomain) { $LlmSubdomain = [string]$lc.Subdomain }
    if ($lc.PSObject.Properties["BackendHost"] -and $lc.BackendHost) { $LlmHost = [string]$lc.BackendHost }
    if ($lc.PSObject.Properties["BackendPort"] -and $lc.BackendPort) { $LlmPort = [int]$lc.BackendPort }
    if ($lc.PSObject.Properties["ApiKey"]) { $LlmApiKey = [string]$lc.ApiKey }
    if ($lc.PSObject.Properties["ExposeUi"]) { $LlmExposeUi = $lc.ExposeUi -eq $true }
}
Write-DebugLog "VAR LLM enabled=$LlmEnabled backend=${LlmHost}:${LlmPort} subdomain=$LlmSubdomain exposeUi=$LlmExposeUi apiKeySet=$(-not [string]::IsNullOrWhiteSpace($LlmApiKey))"
if ($LlmEnabled -and $LlmPort -eq 8080) {
    Write-Warning "[WebServer] LLM.BackendPort is 8080 -- that port belongs to CrowdSec LAPI. Use 8081 for the LLM backend."
    Write-DebugLog "WARN" "LLM.BackendPort=8080 conflicts with CrowdSec LAPI"
}
if ($LlmEnabled -and $DomainMode -ne "cloudflare" -and $LlmExposeUi) {
    # Path mode cannot host the LLM UI: like Jellyseerr, the backend UI requests its
    # own assets from absolute paths, which a /llm prefix cannot serve.
    Write-Warning "[WebServer] LLM.ExposeUi is ignored in $DomainMode mode -- only the /llm/v1 API is published."
    Write-DebugLog "WARN" "LLM.ExposeUi=true has no effect in $DomainMode mode (API-only)"
}

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
                $appDoms = @(
                    @("Jellyfin","Sonarr","Radarr","Prowlarr","Deluge","Bazarr","Jellyseerr","Grafana") |
                    Where-Object { $Config.Apps.$_ -eq $true } |
                    ForEach-Object { "$($_.ToLower()).$d" }
                )
                if ($LlmEnabled) { $appDoms += "$($LlmSubdomain.ToLower()).$d" }
                @($d) + $appDoms
            } else {
                @($Config.General.DuckDnsDomain)
            }
            Write-DebugLog "VAR cert check expectedDomains=$($expectedDomains -join ', ')"

            # A cached certificate is only reusable if it sits under the CA this
            # TlsMode will use -- staging and production are separate trees, so a
            # staging certificate does not satisfy a production run.
            $caInfo = Get-CaddyCaInfo -TlsMode $TlsMode
            if (-not $caInfo) {
                # An unrecognised TlsMode renders as 'tls internal', which involves no
                # ACME CA, so there is nothing meaningful to assert about the cache.
                Write-Host "  -> Cert cache restored to $CaddyDataDir (TlsMode '$TlsMode' uses no ACME CA)." -ForegroundColor DarkGray
                Write-DebugLog "WARN" "Cert cache: TlsMode='$TlsMode' maps to no ACME CA; cache validation skipped"
            } else {
                Write-DebugLog "VAR cert check caDir=$($caInfo.Dir) caUrl=$($caInfo.Url)"
                $status = Get-CertCacheStatus -CertStoreBase $certStoreBase -Domains $expectedDomains `
                                              -ExpectedCaDir $caInfo.Dir
                Write-DebugLog "VAR cert check cached=$($status.Cached -join ', ') wrongCa=$($status.WrongCa -join ', ') missing=$($status.Missing -join ', ')"

                if ($status.WrongCa.Count -gt 0 -or $status.Missing.Count -gt 0) {
                    Write-Host "  -> Cert cache restored (ACME account preserved)." -ForegroundColor Green
                    if ($status.WrongCa.Count -gt 0) {
                        Write-Host "  -> Cached under a different CA ($($status.WrongCaDirs -join ', ')), so not reusable: $($status.WrongCa -join ', ')" -ForegroundColor Yellow
                    }
                    if ($status.Missing.Count -gt 0) {
                        Write-Host "  -> Not in the cache at all: $($status.Missing -join ', ')" -ForegroundColor Yellow
                    }
                    Write-Host "  -> Caddy will request $($caInfo.Label) certificate(s) on first start (port 80/443 must be reachable)." -ForegroundColor Yellow
                    Write-DebugLog "WARN" "Cert cache: issuing needed from $($caInfo.Label) for missing=[$($status.Missing -join ', ')] wrongCA=[$($status.WrongCa -join ', ')]"
                } else {
                    Write-Host "  -> Cert cache valid: all $($expectedDomains.Count) domain(s) cached for $($caInfo.Label)." -ForegroundColor Green
                    Write-DebugLog "INFO" "Cert cache valid for $($caInfo.Label): $($expectedDomains -join ', ')"
                }
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
$caddyInstalled = Get-ChocoInstalledVersion -Package "caddy"
Write-DebugLog "VAR choco caddy output=$caddyInstalled"
if ([string]::IsNullOrWhiteSpace($caddyInstalled)) {
    Write-DebugLog "INFO" "Caddy not installed. Installing via choco..."
    # Invoke-Choco retries the transient feed failures (503/504/gateway timeout)
    # that otherwise abort this FATAL script at the most expensive point of the
    # run, and captures the output so the real reason reaches the debug log.
    $caddyArgs = @('install', 'caddy')
    if ($CaddyPinnedVersion) { $caddyArgs += @('--version', $CaddyPinnedVersion) }
    $caddyArgs += @('-y', '--no-progress')
    $caddyInstall = Invoke-Choco -Arguments $caddyArgs
    $caddyTail = $caddyInstall.Output
    if ($caddyTail -and $caddyTail.Length -gt 800) { $caddyTail = $caddyTail.Substring($caddyTail.Length - 800) }
    Write-DebugLog "INFO" "choco install caddy complete. Exit code=$($caddyInstall.ExitCode) attempts=$($caddyInstall.Attempts)"
    if (-not $caddyInstall.Ran) {
        Write-Error "[WebServer] choco.exe could not be located; caddy was not installed."
        Write-DebugLog "ERROR" "choco install caddy: choco.exe not found"
        exit 1
    }
    if ($caddyInstall.ExitCode -ne 0 -or $caddyInstall.Transient) {
        Write-Error "[WebServer] choco install caddy failed (exit $($caddyInstall.ExitCode))."
        Write-DebugLog "ERROR" "choco install caddy returned non-zero exit code (exit $($caddyInstall.ExitCode), transient=$($caddyInstall.Transient), attempts=$($caddyInstall.Attempts)): $caddyTail"
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
        if ($LlmEnabled) { $cfSubdomains += "`"$($LlmSubdomain.ToLower())`"" }
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
        } elseif ($a.Key -eq "Jellyseerr") {
            # Jellyseerr is served from the DuckDNS site root (no basePath support),
            # so its card must not carry the /jellyseerr prefix.
            "https://$cfgDuck$suffix"
        } else {
            "https://$cfgDuck/$($a.Slug)$suffix"
        }
        $bg = "$($a.Color)33"
        $cards += "    <a href=`"$url`" class=`"card`" target=`"_blank`">"
        $cards += "      <div class=`"badge`" style=`"background:$bg;color:$($a.Color)`">$($a.Initials)</div>"
        $cards += "      <div class=`"app-name`">$($a.Name)</div>"
        $cards += "    </a>"
    }
    if ($LlmEnabled -and $DomainMode -eq "cloudflare") {
        $llmUrl = "https://$($LlmSubdomain.ToLower()).$cfgDomain"
        $cards += "    <a href=`"$llmUrl`" class=`"card`" target=`"_blank`">"
        $cards += "      <div class=`"badge`" style=`"background:#00d26a33;color:#00d26a`">LLM</div>"
        $cards += "      <div class=`"app-name`">$($LlmSubdomain)</div>"
        $cards += "    </a>"
        Write-DebugLog "INFO" "LLM dashboard card added ($llmUrl)"
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

# -- LLM reverse proxy block (rendered only when LLM.Enabled) ------------------
$LlmBlock = ""
if ($LlmEnabled) {
    $LlmBackend = "${LlmHost}:${LlmPort}"
    Write-DebugLog "INFO" "Building Caddy LLM block: backend=$LlmBackend mode=$DomainMode"

    $LlmLog = @"
    log {
        output file "$SafeInstallDir/logs/caddy-access.log" {
            roll_size 10mb
            roll_keep 3
        }
        format json
    }
"@

    if ($DomainMode -eq "cloudflare") {
        if ([string]::IsNullOrWhiteSpace($LlmApiKey)) {
            $LlmApiHandle = @"
    # /v1 -> LLM API (no Caddy bearer gate -- the backend's own key, if any, applies)
    handle /v1/* {
        reverse_proxy $LlmBackend {
            header_up Host $LlmBackend
        }
    }
"@
        } else {
            $LlmApiHandle = @"
    # /v1 -> LLM API, Bearer key required (phone apps don't speak basic auth)
    handle /v1/* {
        @preflight method OPTIONS
        handle @preflight {
            reverse_proxy $LlmBackend {
                header_up Host $LlmBackend
            }
        }
        @llmkey header Authorization "Bearer $LlmApiKey"
        handle @llmkey {
            reverse_proxy $LlmBackend {
                header_up Host $LlmBackend
            }
        }
        respond 401
    }
"@
        }
        $LlmUiPart = if ($LlmExposeUi) {
            if ([string]::IsNullOrWhiteSpace($LlmApiKey)) {
@"
    # UI -- backend's own web interface, gated by Caddy basicauth (LLM UIs ship no login)
    handle {
        basic_auth {
            $AdminUsername $AdminBcryptHash
        }
        reverse_proxy $LlmBackend {
            header_up Host $LlmBackend
        }
    }
"@
            } else {
@"
    # UI -- backend's own web interface, gated by Caddy basicauth (LLM UIs ship no login).
    # The UI's own /metrics and /mcp calls carry its Bearer key when one is set, so that
    # key bypasses basicauth (basic_auth runs before nested handles -- keep it a sibling).
    @llmui header Authorization "Bearer $LlmApiKey"
    handle @llmui {
        reverse_proxy $LlmBackend {
            header_up Host $LlmBackend
        }
    }
    handle {
        basic_auth {
            $AdminUsername $AdminBcryptHash
        }
        reverse_proxy $LlmBackend {
            header_up Host $LlmBackend
        }
    }
"@
            }
        } else {
@"
    # UI not exposed (LLM.ExposeUi=false) -- catch-all handle, so the /v1 API route is untouched
    handle {
        respond 404
    }
"@
        }
        $LlmBlock = @"
# Local LLM -- external backend (Strata, Ollama, LM Studio, any OpenAI-compatible server)
$($LlmSubdomain.ToLower()).$($Config.General.Domain) {
    $TlsBlock
$LlmLog
$LlmApiHandle
$LlmUiPart
}
"@
    } else {
        # Path mode publishes the API only.  handle_path strips exactly "/llm", so the
        # backend receives "/v1/..." (the URL its OpenAI-compatible clients require).
        # Everything else under the prefix -- notably the backend's own UI at the stripped
        # root -- is 404'd: that UI loads its assets from absolute paths and cannot be
        # served under a path prefix, so it must not leak through the strip either.
        # (Scoping the matcher to "/llm/v1*" is NOT an option: handle_path would then strip
        # "/llm/v1" and the backend would see "/models" instead of "/v1/models".)
        if ([string]::IsNullOrWhiteSpace($LlmApiKey)) {
            $LlmBlock = @"
# Local LLM API -- external backend under /llm/v1 (API only, the backend UI is not published)
    handle_path /llm* {
        @llmapi path /v1/*
        handle @llmapi {
            reverse_proxy $LlmBackend {
                header_up Host $LlmBackend
            }
        }
        respond 404
    }
"@
        } else {
            $LlmBlock = @"
# Local LLM API -- external backend under /llm/v1 (API only, the backend UI is not published)
    handle_path /llm* {
        @llmapi path /v1/*
        handle @llmapi {
            @preflight method OPTIONS
            handle @preflight {
                reverse_proxy $LlmBackend {
                    header_up Host $LlmBackend
                }
            }
            @llmkey header Authorization "Bearer $LlmApiKey"
            handle @llmkey {
                reverse_proxy $LlmBackend {
                    header_up Host $LlmBackend
                }
            }
            respond 401
        }
        respond 404
    }
"@
        }
    }
    Write-DebugLog "INFO" "LLM Caddy block built ($($LlmBlock.Length) chars)"
} else {
    Write-DebugLog "INFO" "LLM reverse proxy disabled; no LLM block rendered"
}

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
$Content = $Content.Replace('{$LLM_BLOCK}', $LlmBlock)
Write-DebugLog "VAR LLM block rendered: size=$($LlmBlock.Length) chars"

# -- DuckDNS site root: who owns "/" ------------------------------------------
# Jellyseerr has no basePath support, so when it is installed it owns the site root and
# the dashboard moves to /dashboard (matching the Cloudflare layout, where the dashboard
# is also separate).  Without Jellyseerr the dashboard keeps "/" so the root is never a
# dead end.  Cloudflare mode always keeps the dashboard at the root domain.
$RootBlock = ""
if ($DomainMode -ne "cloudflare") {
    if ($Config.Apps.Jellyseerr -eq $true) {
        Write-DebugLog "INFO" "DuckDNS root: Jellyseerr owns '/', dashboard served from /dashboard"
        # The dashboard root is InstallDir (not InstallDir/dashboard) and the prefix is
        # NOT stripped, so /dashboard/ maps to <InstallDir>/dashboard/ and the dashboard's
        # relative fetch of ./current_status.json resolves to /dashboard/current_status.json.
        $RootBlock = @"
# Jellyseerr owns the site root: it has no basePath support, so serving it at "/" makes
# the absolute paths it emits (/_next, /api, /login, /movie/...) resolve as-is.
    handle {
        reverse_proxy 127.0.0.1:$JellyseerrPort {
            header_up X-Real-IP {remote_host}
        }
    }

    # Dashboard -- moved off the root so Jellyseerr can own "/".  basicauth only.
    handle /dashboard* {
        basic_auth {
            $AdminUsername $AdminBcryptHash
        }
        root * "$SafeInstallDir"
        file_server
    }
"@
    } else {
        Write-DebugLog "INFO" "DuckDNS root: dashboard owns '/' (Jellyseerr not enabled)"
        $RootBlock = @"
# Dashboard at root -- catches everything else (static HTML)
    handle {
        basic_auth {
            $AdminUsername $AdminBcryptHash
        }
        root * "$SafeInstallDir/dashboard"
        file_server
    }
"@
    }
}
$Content = $Content.Replace('{$ROOT_BLOCK}', $RootBlock)
Write-DebugLog "VAR root block rendered: size=$($RootBlock.Length) chars"

$CaddyfilePath = Join-Path $CaddyDir "Caddyfile"
# BOM-free: the Caddyfile is parsed by Caddy (Go), not PowerShell. Set-Content
# -Encoding UTF8 on PS 5.1 prepends EF BB BF ahead of the global-options '{'.
[System.IO.File]::WriteAllText($CaddyfilePath, $Content, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "  -> Caddyfile written to $CaddyfilePath" -ForegroundColor Green
Write-DebugLog "INFO" "Caddyfile written to $CaddyfilePath (size=$($Content.Length) chars)"

# Normalize formatting so Caddy's startup warning ("not formatted") is suppressed.
# caddy fmt tolerates syntactic errors (it always exits 0 on a malformed file), so the
# exit code is only useful for "file missing"-class failures -- log it either way.
& $caddyExe fmt --overwrite $CaddyfilePath 2>$null
$fmtExit = $LASTEXITCODE
Write-DebugLog "INFO" "Caddyfile formatted (caddy fmt, exit=$fmtExit)"
if ($fmtExit -ne 0) {
    Write-Warning "[WebServer] caddy fmt failed (exit $fmtExit). Check $CaddyfilePath."
    Write-DebugLog "WARN" "caddy fmt exited $fmtExit"
}

# Fail fast on an invalid render: NSSM keeps the service "Running" while caddy.exe
# crash-loops on a config error, so the service-state check below cannot catch it.
$savedEAP = $ErrorActionPreference
$caddyValidateExit = 1
$caddyValidateOut  = ""
try {
    $ErrorActionPreference = "Continue"
    $caddyValidateOut  = (& $caddyExe validate --adapter caddyfile --config $CaddyfilePath 2>&1 | Out-String).Trim()
    $caddyValidateExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $savedEAP
}
if ($caddyValidateExit -ne 0) {
    Write-DebugLog "ERROR" "caddy validate FAILED (exit=$caddyValidateExit): $caddyValidateOut"
    Write-Error "[WebServer] Generated Caddyfile is not valid (caddy validate exit $caddyValidateExit).$([Environment]::NewLine)$caddyValidateOut"
    exit 1
}
Write-Host "  -> Caddyfile validated (caddy validate)." -ForegroundColor Green
Write-DebugLog "INFO" "Caddyfile validated OK (caddy validate)"

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
    # Rotate the log in place. nssm only rotates at service restart without
    # AppRotateOnline, which a long-running service never reaches.
    nssm set Caddy AppRotateFiles 1 | Out-Null
    nssm set Caddy AppRotateBytes 5242880 | Out-Null
    nssm set Caddy AppRotateOnline 1 | Out-Null
    nssm set Caddy ObjectName ".\$SvcUser" $SvcPass | Out-Null
    nssm set Caddy AppExit Default Restart | Out-Null
    nssm set Caddy AppRestartDelay 5000 | Out-Null
    Write-DebugLog "VAR Caddy service log=$(Join-Path $CaddyDir 'caddy.log')"

    # Remove first: a second rule with the same DisplayName is created happily, so
    # without this every install run would leave another allow rule behind.
    Get-NetFirewallRule -DisplayName "Caddy HTTP"  -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Get-NetFirewallRule -DisplayName "Caddy HTTPS" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
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

# Ledger entry for the updater (single source of truth for installed versions)
if (-not (Get-Command Set-InstalledVersion -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "update_common.ps1")
}
Set-InstalledVersion -InstallDir $Config.General.InstallDir -AppName "Caddy" -Version $CaddyLockVer

Write-Host "[WebServer] Done." -ForegroundColor Cyan
Write-DebugLog "INFO" "01_webserver.ps1 complete"
