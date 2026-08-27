param(
    [Parameter(Mandatory=$true)]
    [object]$Config
)

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "12_security.ps1 started"

$AppName    = "Security"
$InstallDir = $Config.General.InstallDir
$LockFile   = Join-Path $InstallDir ".locks\.security.lock"
$ScriptsDir = $PSScriptRoot

# CrowdSec fixed install locations (set by the MSI / chocolatey package)
$CsProgramDir = "C:\Program Files\CrowdSec"
$CsDataDir    = "C:\ProgramData\CrowdSec"
$CsConfigDir  = Join-Path $CsDataDir "config"
$CsCli        = Join-Path $CsProgramDir "cscli.exe"
$BouncerDir   = Join-Path $CsConfigDir "bouncers"
$BouncerYaml  = Join-Path $BouncerDir "cs-windows-firewall-bouncer.yaml"
$BouncerExe   = Join-Path $CsProgramDir "bouncers\cs-windows-firewall-bouncer\cs-windows-firewall-bouncer.exe"
$BouncerName  = "seedbox-windows-firewall"

Write-DebugLog "VAR AppName=$AppName InstallDir=$InstallDir LockFile=$LockFile"
Write-DebugLog "VAR CsProgramDir=$CsProgramDir CsConfigDir=$CsConfigDir CsCli=$CsCli"

if (Test-Path $LockFile) {
    Write-Host "[$AppName] Already installed. Skipping." -ForegroundColor Green
    Write-DebugLog "INFO" "$AppName already installed (lock file present)"
    return
}

Write-Host "[$AppName] Installing..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== Installing $AppName ==="

# -- Config helpers (the Security block is optional; fall back to defaults) -----
$SecCfg = $null
if ($Config.PSObject.Properties['Security']) { $SecCfg = $Config.Security }

function Get-SecSetting {
    param([string]$Name, $Default)
    if ($SecCfg -and $SecCfg.PSObject.Properties[$Name] -and $null -ne $SecCfg.$Name) {
        return $SecCfg.$Name
    }
    return $Default
}

$EnrollKey        = [string](Get-SecSetting 'CrowdSecEnrollKey' '')
$BanDurationHours = Get-SecSetting 'BanDurationHours' 4
# Validate: a non-numeric or zero value silently disables all CrowdSec banning.
# [int] casting "4h" or "4.5" yields 0, and 0h bans expire instantly.
$BanDurationHours = try { [int]$BanDurationHours } catch { 0 }
if ($BanDurationHours -le 0) {
    Write-Warning "[$AppName] BanDurationHours is $BanDurationHours in config.json. Using default (4h)."
    Write-DebugLog "WARN" "BanDurationHours invalid ($BanDurationHours). Falling back to 4."
    $BanDurationHours = 4
}
$ExtraWhitelist   = @(      Get-SecSetting 'ExtraWhitelistIps'  @())
$DoBlocklists     =         Get-SecSetting 'AbuseBlocklists'    $true

Write-DebugLog "VAR EnrollKey=$(if ($EnrollKey) { '[REDACTED]' } else { '(none)' }) BanDurationHours=$BanDurationHours"
Write-DebugLog "VAR ExtraWhitelist=$($ExtraWhitelist -join ',') DoBlocklists=$DoBlocklists"

# -- Shared helpers ------------------------------------------------------------
# Service names differ slightly between CrowdSec releases; resolve them at runtime
# instead of hardcoding, so an upstream rename does not silently break the install.
function Resolve-ServiceName {
    param([string[]]$Candidates)
    foreach ($c in $Candidates) {
        $s = Get-Service -Name $c -ErrorAction SilentlyContinue
        if ($s) { return $s.Name }
    }
    foreach ($c in $Candidates) {
        $s = Get-Service -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*$c*" -or $_.DisplayName -like "*$c*" } |
            Select-Object -First 1
        if ($s) { return $s.Name }
    }
    return $null
}

# CrowdSec parses YAML with Go's yaml lib, which rejects a UTF-8 BOM.
# PowerShell 5.1's Set-Content -Encoding UTF8 writes one -- always use this instead.
function Write-YamlFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
    Write-DebugLog "INFO" "Wrote YAML (BOM-free): $Path"
}

# Run a native executable and capture its combined output.
#
# master_install.ps1 sets $ErrorActionPreference="Stop", which child scripts inherit.
# Under PS 5.1 that turns ANY stderr output from a native command into a terminating
# NativeCommandError before the pipeline can swallow it -- and both cscli and choco
# write progress, warnings and hub-update chatter to stderr on completely successful
# runs. Without dropping to "Continue" here, `cscli hub update` alone would abort the
# whole security phase. Same hazard already documented for pip in 09_bazarr.ps1 and
# for caddy reload in 01_webserver.ps1.
function Invoke-Native {
    param([string]$Exe, [string[]]$NativeArgs)
    $saved = $ErrorActionPreference
    $out   = ""
    $code  = 0
    try {
        $ErrorActionPreference = "Continue"
        $out  = (& $Exe @NativeArgs 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } catch {
        $out  = "$_"
        $code = if ($LASTEXITCODE) { $LASTEXITCODE } else { 1 }
    } finally {
        $ErrorActionPreference = $saved
    }
    return [pscustomobject]@{ Output = $out; ExitCode = $code }
}

function Invoke-Cscli {
    param([string[]]$CliArgs, [switch]$IgnoreErrors)
    Write-DebugLog "INFO" "cscli $($CliArgs -join ' ')"
    $r = Invoke-Native -Exe $CsCli -NativeArgs $CliArgs
    Write-DebugLog "VAR cscli exit=$($r.ExitCode) output=$($r.Output.Trim())"
    if ($r.ExitCode -ne 0 -and -not $IgnoreErrors) {
        throw "cscli $($CliArgs -join ' ') failed (exit $($r.ExitCode)): $($r.Output.Trim())"
    }
    return $r.Output
}

# -- Detect public IP (whitelisted so you cannot lock yourself out) ------------
$publicIp = $null
try {
    $publicIp = (Invoke-RestMethod "https://api.ipify.org" -UseBasicParsing -TimeoutSec 10).Trim()
    Write-DebugLog "VAR publicIp=$publicIp"
} catch {
    Write-DebugLog "WARN" "Public IP detection failed: $_"
}

$crowdsecOk = $false
$bouncerOk  = $false

# == Phase 1: CrowdSec Security Engine =========================================
Write-Host "  [CrowdSec] Installing Security Engine..." -ForegroundColor Gray
Write-DebugLog "INFO" "=== PHASE 1: CrowdSec Security Engine ==="

try {
    # -- 1a. Install the engine ------------------------------------------------
    # cscli.exe can survive a chocolatey uninstall (choco does not always remove
    # the Program Files tree), but C:\ProgramData\CrowdSec\config\config.yaml is
    # deleted by the uninstaller.  If the config is missing, cscli prints a YAML
    # read error on EVERY command (hub update, collections install, console
    # enroll), and none of the detection or enforcement phases can complete.
    # Treat "cscli present but config absent" the same as a missing install.
    $configYaml = Join-Path $CsConfigDir "config.yaml"
    $cscliPresent  = Test-Path $CsCli
    $configPresent = Test-Path $configYaml
    $svcPresent    = (Resolve-ServiceName @("crowdsec", "CrowdSec")) -ne $null
    $needsInstall  = (-not $cscliPresent) -or (-not $configPresent) -or (-not $svcPresent)

    Write-DebugLog "VAR cscliPresent=$cscliPresent configPresent=$configPresent svcPresent=$svcPresent needsInstall=$needsInstall"

    if ($needsInstall) {
        if ($cscliPresent -and -not $configPresent) {
            Write-Host "     CrowdSec binary found but config/data missing (partial uninstall). Reinstalling..." -ForegroundColor DarkGray
            Write-DebugLog "INFO" "cscli.exe present but config.yaml missing -- reinstalling"
        } elseif ($cscliPresent -and -not $svcPresent) {
            Write-Host "     CrowdSec binary found but service missing. Reinstalling..." -ForegroundColor DarkGray
            Write-DebugLog "INFO" "cscli.exe present but service absent -- reinstalling"
        }

        $installed = $false

        # Preferred path: chocolatey (already bootstrapped by 00_prerequisites.ps1)
        try {
            Write-DebugLog "INFO" "Installing CrowdSec via chocolatey..."
            $choco = Invoke-Native -Exe "choco" -NativeArgs @("install", "crowdsec", "-y", "--no-progress", "--limit-output")
            Write-DebugLog "VAR choco crowdsec exit=$($choco.ExitCode)"
            Write-DebugLog "VAR choco output=$($choco.Output.Trim())"
            if (Test-Path $CsCli) { $installed = $true }
        } catch {
            Write-DebugLog "WARN" "chocolatey install of crowdsec failed: $_"
        }

        # Fallback: MSI straight from the GitHub release
        if (-not $installed) {
            Write-Host "     Chocolatey package unavailable, falling back to MSI..." -ForegroundColor DarkGray
            Write-DebugLog "INFO" "Falling back to GitHub MSI download"
            $release = Invoke-RestMethod "https://api.github.com/repos/crowdsecurity/crowdsec/releases/latest" -UseBasicParsing
            $asset   = $release.assets |
                Where-Object { $_.name -like "*windows*amd64*.msi" -or $_.name -like "*windows*.msi" } |
                Select-Object -First 1
            if (-not $asset) { throw "No .msi asset found in CrowdSec release $($release.tag_name)" }
            Write-DebugLog "VAR CrowdSec release=$($release.tag_name) asset=$($asset.name)"

            $msi = Join-Path $env:TEMP $asset.name
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msi -UseBasicParsing
            $p = Start-Process msiexec.exe -ArgumentList @("/i", "`"$msi`"", "/qn", "/norestart") -Wait -PassThru
            Write-DebugLog "VAR msiexec exit=$($p.ExitCode)"
            Remove-Item $msi -Force -ErrorAction SilentlyContinue
            if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
                throw "msiexec returned $($p.ExitCode) installing CrowdSec"
            }
            # MSI may return before all files are on disk; retry up to 15 s.
            $msiRetries = 0
            while (-not (Test-Path $CsCli) -and $msiRetries -lt 5) {
                Start-Sleep -Seconds 3
                $msiRetries++
                Write-DebugLog "VAR cscli.exe check retry $msiRetries/5 after MSI install"
            }
        }
    } else {
        Write-Host "     CrowdSec already present, skipping download." -ForegroundColor DarkGray
        Write-DebugLog "INFO" "CrowdSec already installed (cscli + config + service present)"
    }

    if (-not (Test-Path $CsCli)) { throw "cscli.exe not found at $CsCli after install" }

    $CrowdSecSvc = Resolve-ServiceName @("crowdsec", "CrowdSec")
    Write-DebugLog "VAR CrowdSecSvc=$CrowdSecSvc"
    if (-not $CrowdSecSvc) { throw "CrowdSec Windows service not found after install" }

    # Ensure the service is running BEFORE running cscli commands.  cscli reads
    # config.yaml which the service creates on first start.  If the service was
    # just installed (or reinstalled) the file may not exist yet.
    $csSvc = Get-Service -Name $CrowdSecSvc -ErrorAction SilentlyContinue
    Write-DebugLog "VAR CrowdSec service status before start: $(if ($csSvc) { $csSvc.Status } else { 'not found' })"
    if ($csSvc -and $csSvc.Status -ne "Running") {
        Write-Host "     Starting CrowdSec service to generate default config..." -ForegroundColor DarkGray
        Write-DebugLog "INFO" "Starting $CrowdSecSvc service"
        Start-Service -Name $CrowdSecSvc -ErrorAction SilentlyContinue
        # Wait up to 30s for config.yaml to appear
        $cfgDeadline = (Get-Date).AddSeconds(30)
        while (-not (Test-Path $configYaml) -and (Get-Date) -lt $cfgDeadline) {
            Start-Sleep -Seconds 2
        }
        Write-DebugLog "VAR config.yaml exists after start: $(Test-Path $configYaml)"
        if (-not (Test-Path $configYaml)) {
            Write-Warning "     config.yaml not created after 30s. cscli commands may fail."
            Write-DebugLog "WARN" "config.yaml not generated after 30s of service runtime"
        }
    }

    # -- 1b. Hub collections ---------------------------------------------------
    # caddy   : parses the Caddy JSON access log -> covers every proxied app
    #           (Jellyfin, all *Arr, Deluge Web UI, dashboard) in one source.
    # windows : parses the Security event log -> RDP / SMB / local auth bruteforce.
    Write-Host "     Installing hub collections..." -ForegroundColor DarkGray
    Invoke-Cscli @("hub", "update") -IgnoreErrors | Out-Null
    foreach ($collection in @("crowdsecurity/caddy", "crowdsecurity/windows")) {
        try {
            Invoke-Cscli @("collections", "install", $collection) | Out-Null
            Write-Host "       OK $collection" -ForegroundColor DarkGray
        } catch {
            Write-DebugLog "WARN" "Collection $collection failed to install: $_"
            Write-Host "       WARN $collection could not be installed" -ForegroundColor Yellow
        }
    }

    # -- 1c. Acquisition: Caddy access log + Windows Security event log --------
    # Single-quoted YAML scalars keep Windows backslashes literal.
    #
    # The native wineventlog acquisition module is unreliable on Windows
    # (v1.7.x: module starts, immediately dies with no error).  We use a
    # file-based workaround instead: a scheduled task exports 4625 events
    # to a single-line-XML file, and the seedbox-eventlog-file parser
    # (step 1d) extracts the fields the downstream parsers need.
    $logDir          = Join-Path $InstallDir "logs"
    $caddyLogPath    = Join-Path $logDir "caddy-access.log"
    $security4625Log = Join-Path $logDir "security-4625.xml"
    Write-DebugLog "VAR caddyLogPath=$caddyLogPath"
    Write-DebugLog "VAR security4625Log=$security4625Log"

    $acquis = @"
# Managed by win-seedbox (scripts/12_security.ps1) -- edits will be overwritten.
---
# Caddy JSON access log. Covers every service behind the reverse proxy:
# Jellyfin, Sonarr, Radarr, Prowlarr, Bazarr, Deluge Web UI, Jellyseerr, dashboard.
filenames:
  - '$caddyLogPath'
labels:
  type: caddy
---
# Windows Security event log, failed logon (4625): RDP, SMB, local auth.
# Uses file-based acquisition -- the wineventlog module is unreliable on Windows.
# Seedbox_SecurityEventExport scheduled task exports events every 5 min.
filenames:
  - '$security4625Log'
labels:
  type: eventlog
"@
    Write-YamlFile -Path (Join-Path $CsConfigDir "acquis.yaml") -Content $acquis
    Write-Host "     Acquisition configured (Caddy access log + Security event log [file-based])." -ForegroundColor DarkGray

    # -- 1d. Custom parser for file-based event log XML ------------------------
    # The built-in windows-logs parser only handles the native wineventlog
    # acquisition module (filter: evt.Line.Module == 'wineventlog').  Our file
    # source has Module == 'file', so we need a custom s00-raw parser that
    # extracts Channel/EventID/Provider from the single-line XML and passes them
    # downstream where windows-auth (s01-parse) and windows-bf (scenario) can
    # consume them.
    $seedboxEventlogParser = @"
# Managed by win-seedbox (scripts/12_security.ps1) -- edits will be overwritten.
filter: "evt.Line.Labels.type == 'eventlog' && evt.Line.Module == 'file'"
onsuccess: next_stage
name: seedbox/windows-eventlog-file
statics:
  - meta: datasource_path
    expression: evt.Line.Src
  - meta: datasource_type
    expression: evt.Line.Module
  - target: evt.StrTime
    expression: XMLGetAttributeValue(evt.Line.Raw, "/Event/System[1]/TimeCreated", "SystemTime")
  - parsed: Channel
    expression: XMLGetNodeValue(evt.Line.Raw, "/Event/System[1]/Channel")
  - parsed: EventID
    expression: XMLGetNodeValue(evt.Line.Raw, "/Event/System[1]/EventID")
  - parsed: Source
    expression: XMLGetAttributeValue(evt.Line.Raw, "/Event/System[1]/Provider", "Name")
  - parsed: Computer
    expression: XMLGetNodeValue(evt.Line.Raw, "/Event/System[1]/Computer")
  - parsed: UserSID
    expression: XMLGetAttributeValue(evt.Line.Raw, "/Event/System[1]/Security", "UserID")
  - parsed: program
    expression: evt.Line.Labels.type
"@
    Write-YamlFile -Path (Join-Path $CsConfigDir "parsers\s00-raw\seedbox-eventlog-file.yaml") -Content $seedboxEventlogParser
    Write-Host "     Custom eventlog-file parser deployed (s00-raw)." -ForegroundColor DarkGray

    # -- 1e. Event log export script + scheduled task --------------------------
    # Copies the export script from the project tree and registers a SYSTEM
    # scheduled task that runs every 5 minutes.
    $exportScriptSrc  = Join-Path $ScriptsDir "export_security_events.ps1"
    $installScripts   = Join-Path $InstallDir "scripts"
    $exportScriptDst  = Join-Path $installScripts "export_security_events.ps1"
    if (-not (Test-Path $installScripts)) { New-Item -Path $installScripts -ItemType Directory -Force | Out-Null }
    Copy-Item -LiteralPath $exportScriptSrc -Destination $exportScriptDst -Force

    $evtAction  = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$exportScriptDst`" -LogDir `"$logDir`""
    $evtTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes 5) `
        -RepetitionDuration ([TimeSpan]::MaxValue)
    $evtPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" `
        -LogonType ServiceAccount -RunLevel Highest
    $evtSettings  = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName "Seedbox_SecurityEventExport" `
        -Action $evtAction -Trigger $evtTrigger `
        -Principal $evtPrincipal -Settings $evtSettings -Force | Out-Null

    # Run once immediately so CrowdSec has data on first start.
    try { & $exportScriptDst -LogDir $logDir } catch { Write-DebugLog "WARN" "Initial event log export failed: $_" }
    Write-Host "     Event log export task registered (Seedbox_SecurityEventExport, every 5 min)." -ForegroundColor DarkGray

    # -- 1f. Whitelist: the anti-lockout guarantee -----------------------------
    # Split into single IPs and CIDRs, because CrowdSec rejects a CIDR in the
    # 'ip:' list and silently ignores a bare IP in the 'cidr:' list.
    $wlIps   = [System.Collections.Generic.List[string]]::new()
    $wlCidrs = [System.Collections.Generic.List[string]]::new()

    $wlIps.Add("127.0.0.1")
    $wlIps.Add("::1")
    if ($publicIp) { $wlIps.Add($publicIp) }

    # RFC1918 + link-local + CGNAT. 100.64.0.0/10 is the Tailscale range: it is the
    # out-of-band way back in if a ban ever locks you out over the public path.
    foreach ($c in @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16',
                     '169.254.0.0/16', '100.64.0.0/10')) { $wlCidrs.Add($c) }

    # Every locally-configured IPv4 address, so the box can never ban itself
    # through hairpin NAT or a service calling in over its own LAN address.
    try {
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -and $_.IPAddress -ne '127.0.0.1' } |
            ForEach-Object { if (-not $wlIps.Contains($_.IPAddress)) { $wlIps.Add($_.IPAddress) } }
    } catch {
        Write-DebugLog "WARN" "Could not enumerate local IPs for whitelist: $_"
    }

    foreach ($extra in $ExtraWhitelist) {
        $e = [string]$extra
        if (-not $e) { continue }
        if ($e -match '/') {
            if (-not $wlCidrs.Contains($e)) { $wlCidrs.Add($e) }
        } elseif (-not $wlIps.Contains($e)) {
            $wlIps.Add($e)
        }
    }

    $wlIpYaml   = ($wlIps   | ForEach-Object { "    - '$_'" }) -join "`n"
    $wlCidrYaml = ($wlCidrs | ForEach-Object { "    - '$_'" }) -join "`n"
    Write-DebugLog "VAR whitelist ips=$($wlIps -join ',')"
    Write-DebugLog "VAR whitelist cidrs=$($wlCidrs -join ',')"

    $whitelist = @"
# Managed by win-seedbox (scripts/12_security.ps1) -- edits will be overwritten.
# Runs at s02-enrich, BEFORE any scenario sees the event, so a whitelisted source
# can never fill a bucket and therefore can never be banned.
name: seedbox/trusted-networks
description: "Never ban loopback, LAN, Tailscale, local addresses, or the operator's own public IP"
whitelist:
  reason: "seedbox trusted network"
  ip:
$wlIpYaml
  cidr:
$wlCidrYaml
"@
    Write-YamlFile -Path (Join-Path $CsConfigDir "parsers\s02-enrich\seedbox-whitelist.yaml") -Content $whitelist
    Write-Host "     Whitelist: $($wlIps.Count) IP(s) + $($wlCidrs.Count) range(s), incl. LAN and Tailscale." -ForegroundColor DarkGray
    if (-not $publicIp) {
        Write-Host "     WARNING: public IP not detected -- your WAN IP is NOT whitelisted." -ForegroundColor Yellow
    }

    # -- 1g. Ban duration profile ---------------------------------------------
    $profiles = @"
# Managed by win-seedbox (scripts/12_security.ps1) -- edits will be overwritten.
name: default_ip_remediation
filters:
  - Alert.Remediation == true && Alert.GetScope() == "Ip"
decisions:
  - type: ban
    duration: ${BanDurationHours}h
on_success: break
"@
    Write-YamlFile -Path (Join-Path $CsConfigDir "profiles.yaml") -Content $profiles
    Write-Host "     Ban duration set to ${BanDurationHours}h." -ForegroundColor DarkGray

    # -- 1h. Optional CrowdSec Console enrollment ------------------------------
    if ($EnrollKey) {
        try {
            Invoke-Cscli @("console", "enroll", $EnrollKey) | Out-Null
            Write-Host "     Enrolled in CrowdSec Console." -ForegroundColor DarkGray
            Write-DebugLog "INFO" "Console enrollment succeeded"
        } catch {
            Write-DebugLog "WARN" "Console enrollment failed: $_"
            Write-Host "     WARN Console enrollment failed (see debug log)." -ForegroundColor Yellow
        }
    }

    # -- 1i. Restart so acquisition + collections take effect ------------------
    Restart-Service -Name $CrowdSecSvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    $svc = Get-Service -Name $CrowdSecSvc -ErrorAction SilentlyContinue
    Write-DebugLog "VAR CrowdSec service status=$(if ($svc) { $svc.Status } else { 'not found' })"
    if ($svc -and $svc.Status -eq "Running") {
        Write-Host "  -> CrowdSec Security Engine running." -ForegroundColor Green
        $crowdsecOk = $true
    } else {
        Write-Host "  -> CrowdSec installed but not running yet." -ForegroundColor Yellow
        Write-DebugLog "WARN" "CrowdSec service not Running after restart"
    }
} catch {
    Write-DebugLog "ERROR" "CrowdSec engine install failed: $_"
    Write-Host "  -> CrowdSec install skipped (see debug log)." -ForegroundColor Yellow
}

Write-DebugLog "VAR crowdsecOk=$crowdsecOk"

# == Phase 2: Windows Firewall Remediation Component (bouncer) =================
# The engine only *detects*. Without a bouncer nothing is ever actually blocked --
# this is the piece that writes Windows Firewall rules from CrowdSec decisions.
if ($crowdsecOk) {
    Write-Host "  [CrowdSec] Installing Windows Firewall bouncer..." -ForegroundColor Gray
    Write-DebugLog "INFO" "=== PHASE 2: Windows Firewall bouncer ==="

    try {
        # -- 2a. Register the bouncer and capture its API key ------------------
        # Re-registering is the idempotent path: delete any stale entry first so a
        # re-run always ends up with a key that matches the yaml we write below.
        # Check existence first to avoid a noisy "bouncer not found" error.
        $bouncerList = Invoke-Cscli @("bouncers", "list") -IgnoreErrors
        if ($bouncerList -match [regex]::Escape($BouncerName)) {
            Invoke-Cscli @("bouncers", "delete", $BouncerName) -IgnoreErrors | Out-Null
        }

        $apiKey = (Invoke-Cscli @("bouncers", "add", $BouncerName, "-o", "raw")).Trim()
        if ($apiKey -notmatch '^[A-Za-z0-9+/=]{20,}$') {
            # Older cscli versions ignore -o raw and print a prose block instead.
            $m = [regex]::Match($apiKey, '(?m)^\s*([A-Za-z0-9+/=]{20,})\s*$')
            if ($m.Success) { $apiKey = $m.Groups[1].Value }
        }
        if (-not $apiKey -or $apiKey.Length -lt 20) { throw "Could not obtain a bouncer API key from cscli" }
        Write-DebugLog "VAR bouncer apiKey=[REDACTED] length=$($apiKey.Length)"

        # -- 2b. Install the component ----------------------------------------
        # The bouncer MSI writes its config to config\bouncers\ (not bouncers\),
        # and the service can be orphaned if the EXE was deleted by a prior
        # uninstall that removed Program Files without unregistering the MSI.
        # Check all three: config file, service, AND the actual executable.
        $bouncerPresent = (Test-Path $BouncerYaml) -and
                          ($null -ne (Resolve-ServiceName @("cs-windows-firewall-bouncer"))) -and
                          (Test-Path $BouncerExe)
        if (-not $bouncerPresent) {
            $installed = $false
            try {
                Write-DebugLog "INFO" "Installing bouncer via chocolatey..."
                $choco = Invoke-Native -Exe "choco" -NativeArgs @("install", "crowdsec-windows-firewall-bouncer", "-y", "--no-progress", "--limit-output")
                Write-DebugLog "VAR choco bouncer exit=$($choco.ExitCode) output=$($choco.Output.Trim())"
                # Check 3 ways: config dir exists, service exists, or choco reported success.
                $chocoSvc = Get-Service -Name "cs-windows-firewall-bouncer" -ErrorAction SilentlyContinue
                $chocoOk  = (Test-Path $BouncerDir) -or ($null -ne $chocoSvc) -or
                            ($choco.Output -match 'successful')
                if ($chocoOk) { $installed = $true }
            } catch {
                Write-DebugLog "WARN" "chocolatey install of bouncer failed: $_"
            }

            if (-not $installed) {
                Write-Host "     Chocolatey package unavailable, falling back to MSI..." -ForegroundColor DarkGray
                Write-DebugLog "INFO" "Falling back to GitHub MSI for the bouncer"
                $release = Invoke-RestMethod "https://api.github.com/repos/crowdsecurity/cs-windows-firewall-bouncer/releases/latest" -UseBasicParsing
                $asset   = $release.assets | Where-Object { $_.name -like "*windows*amd64*.msi" -or $_.name -like "*win64*.msi" -or $_.name -like "*.msi" } | Select-Object -First 1
                if (-not $asset) { throw "No .msi asset found in bouncer release $($release.tag_name)" }
                Write-DebugLog "VAR bouncer release=$($release.tag_name) asset=$($asset.name)"

                $msi = Join-Path $env:TEMP $asset.name
                Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msi -UseBasicParsing
                $p = Start-Process msiexec.exe -ArgumentList @("/i", "`"$msi`"", "/qn", "/norestart") -Wait -PassThru
                Write-DebugLog "VAR msiexec bouncer exit=$($p.ExitCode)"
                Remove-Item $msi -Force -ErrorAction SilentlyContinue
                if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
                    throw "msiexec returned $($p.ExitCode) installing the firewall bouncer"
                }
            }
        } else {
            Write-DebugLog "INFO" "Bouncer already installed -- reconfiguring only"
        }

        # -- 2c. Point the bouncer at the local LAPI with our key --------------
        $bouncerCfg = @"
# Managed by win-seedbox (scripts/12_security.ps1) -- edits will be overwritten.
api_endpoint: http://127.0.0.1:8080/
api_key: $apiKey
update_frequency: 10
log_media: file
log_dir: C:\ProgramData\CrowdSec\log\
log_level: info
fw_profiles:
  - domain
  - private
  - public
"@
        Write-YamlFile -Path $BouncerYaml -Content $bouncerCfg

        $BouncerSvc = Resolve-ServiceName @("cs-windows-firewall-bouncer", "crowdsec-firewall", "firewall-bouncer")
        Write-DebugLog "VAR BouncerSvc=$BouncerSvc"
        if (-not $BouncerSvc) { throw "Firewall bouncer service not found after install" }

        # Bouncer may need multiple start attempts and more time to come up.
        $bouncerRetries = 0
        $bouncerMaxRetries = 5
        $bouncerRunning = $false
        while (-not $bouncerRunning -and $bouncerRetries -lt $bouncerMaxRetries) {
            $bsvc = Get-Service -Name $BouncerSvc -ErrorAction SilentlyContinue
            if ($bsvc -and $bsvc.Status -eq "Running") {
                $bouncerRunning = $true
                break
            }
            if ($bsvc -and $bsvc.Status -eq "Stopped") {
                Start-Service -Name $BouncerSvc -ErrorAction SilentlyContinue
            } else {
                Restart-Service -Name $BouncerSvc -Force -ErrorAction SilentlyContinue
            }
            $bouncerRetries++
            if ($bouncerRetries -lt $bouncerMaxRetries) {
                Start-Sleep -Seconds 5
            }
        }
        $bsvc = Get-Service -Name $BouncerSvc -ErrorAction SilentlyContinue
        Write-DebugLog "VAR bouncer status=$(if ($bsvc) { $bsvc.Status } else { 'not found' }) retries=$bouncerRetries"
        if ($bsvc -and $bsvc.Status -eq "Running") {
            Write-Host "  -> Firewall bouncer running (enforcing CrowdSec decisions)." -ForegroundColor Green
            $bouncerOk = $true
        } else {
            Write-Host "  -> Bouncer installed but not running after $bouncerMaxRetries attempts." -ForegroundColor Yellow
            Write-DebugLog "WARN" "Bouncer service not Running after $bouncerMaxRetries start attempts"
        }
    } catch {
        Write-DebugLog "ERROR" "Firewall bouncer install failed: $_"
        Write-Host "  -> Bouncer install failed -- CrowdSec will DETECT but not BLOCK." -ForegroundColor Yellow
    }
} else {
    Write-DebugLog "WARN" "Skipping bouncer: engine not healthy"
}

Write-DebugLog "VAR bouncerOk=$bouncerOk"

# == Phase 3: Abuse blocklists (Spamhaus + Firehol) ============================
# Independent of CrowdSec: static reputation lists applied straight to the firewall.
if ($DoBlocklists) {
    Write-Host "  [Blocklist] Fetching abuse IP lists (Spamhaus + Firehol)..." -ForegroundColor Gray
    Write-DebugLog "INFO" "=== PHASE 3: Abuse blocklists ==="
    $blocklistScript = Join-Path $ScriptsDir "update_blocklists.ps1"
    try {
        & $blocklistScript
        Write-DebugLog "INFO" "Initial blocklist update complete"
    } catch {
        Write-DebugLog "WARN" "Blocklist initial run failed: $_"
    }

    $sysSettings  = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    $sysPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" `
        -LogonType ServiceAccount -RunLevel Highest

    $blAction  = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$blocklistScript`""
    $blTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Hours 6) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    try {
        Register-ScheduledTask -TaskName "Seedbox_Blocklist_Update" `
            -Action $blAction -Trigger $blTrigger `
            -Settings $sysSettings -Principal $sysPrincipal -Force | Out-Null
        Write-Host "  -> Blocklist task registered (every 6h, SYSTEM)." -ForegroundColor DarkGray
        Write-DebugLog "INFO" "Seedbox_Blocklist_Update task registered"
    } catch {
        Write-DebugLog "WARN" "Could not register Seedbox_Blocklist_Update: $_"
    }
} else {
    Write-Host "  [Blocklist] Disabled via Security.AbuseBlocklists." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "Abuse blocklists disabled by config"
}

# -- Summary -------------------------------------------------------------------
Write-Host ""
Write-Host "  Security summary:" -ForegroundColor Cyan
Write-Host "    Detection (CrowdSec engine) : $(if ($crowdsecOk) { 'OK' } else { 'FAILED' })" `
    -ForegroundColor $(if ($crowdsecOk) { 'Green' } else { 'Yellow' })
Write-Host "    Enforcement (FW bouncer)    : $(if ($bouncerOk)  { 'OK' } else { 'FAILED' })" `
    -ForegroundColor $(if ($bouncerOk)  { 'Green' } else { 'Yellow' })
Write-Host "    Abuse blocklists            : $(if ($DoBlocklists) { 'OK' } else { 'disabled' })" -ForegroundColor DarkGray
if ($crowdsecOk) {
    Write-Host ""
    Write-Host "    Inspect with:" -ForegroundColor DarkGray
    Write-Host "      & '$CsCli' metrics" -ForegroundColor DarkGray
    Write-Host "      & '$CsCli' decisions list" -ForegroundColor DarkGray
    Write-Host "      & '$CsCli' alerts list" -ForegroundColor DarkGray
}

# -- Write lock file (only when detection actually came up) --------------------
if ($crowdsecOk) {
    [System.IO.File]::WriteAllText($LockFile, "installed", [System.Text.Encoding]::UTF8)
    Write-DebugLog "INFO" "12_security.ps1 complete. Lock: $LockFile"
} else {
    Write-DebugLog "WARN" "Lock file NOT written -- re-run will retry the install"
}
Write-Host "[$AppName] Done." -ForegroundColor Cyan
