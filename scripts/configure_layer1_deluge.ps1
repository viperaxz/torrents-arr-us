param(
    [object]$Config = $null
)

if (-not $Config) {
    $configPath = Join-Path $PSScriptRoot "..\config.json"
    if (-not (Test-Path $configPath)) {
        Write-Error "config.json not found at '$configPath'. Pass -Config or run from the project root."
        exit 1
    }
    $Config = Get-Content -Raw -Path $configPath | ConvertFrom-Json
}

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")

# nssm services can sit in Stop Pending indefinitely and the built-in cmdlets wait
# on that forever. These helpers are bounded. See service_helpers.ps1.
if (-not (Get-Command Stop-ServiceBounded -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "service_helpers.ps1")
}
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "configure_layer1_deluge.ps1 started"

$AppName       = "Deluge"
$DaemonPort    = $Config.Ports.Deluge
$WebPort       = $Config.Ports.DelugeWeb
$Domain        = $Config.General.Domain
$DomainMode    = $Config.General.DomainMode
$InstallDir    = $Config.General.InstallDir
$DelugeAuthFile = Join-Path $InstallDir "secrets\deluge_auth.txt"

Write-DebugLog "VAR AppName=$AppName DaemonPort=$DaemonPort WebPort=$WebPort DomainMode=$DomainMode"
Write-DebugLog "VAR DelugeAuthFile=$DelugeAuthFile (exists=$(Test-Path $DelugeAuthFile))"

if (-not (Test-Path $DelugeAuthFile)) {
    Write-Error "[$AppName] Auth file not found at '$DelugeAuthFile'. Run 07_deluge.ps1 first."
    Write-DebugLog "ERROR" "Auth file not found at $DelugeAuthFile"
    exit 1
}
$DelugePassword = (Get-Content -Path $DelugeAuthFile -Raw -Encoding UTF8).TrimStart([char]0xFEFF).Trim()
Write-DebugLog "VAR Deluge password loaded from file (length=$($DelugePassword.Length)) [REDACTED]"

Write-Host "[$AppName] Configuring..." -ForegroundColor Cyan

# -- 1. Ensure services exist and are running ----------------------------------
$daemonSvc = Get-Service -Name "DelugeDaemon" -ErrorAction SilentlyContinue
Write-DebugLog "VAR DelugeDaemon exists=$($null -ne $daemonSvc) status=$(if ($daemonSvc) { $daemonSvc.Status } else { 'N/A' })"
if (-not $daemonSvc) {
    Write-Error "[$AppName] DelugeDaemon service not found. Run 07_deluge.ps1 first."
    Write-DebugLog "ERROR" "DelugeDaemon service not found"
    exit 1
}
if ($daemonSvc.Status -ne "Running") {
    Write-Host "  -> Starting DelugeDaemon..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Starting DelugeDaemon (was $($daemonSvc.Status))..."
    Start-Service -Name "DelugeDaemon" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    $daemonSvc = Get-Service -Name "DelugeDaemon"
    Write-DebugLog "VAR DelugeDaemon status after start=$($daemonSvc.Status)"
}

$webSvc = Get-Service -Name "DelugeWeb" -ErrorAction SilentlyContinue
Write-DebugLog "VAR DelugeWeb exists=$($null -ne $webSvc) status=$(if ($webSvc) { $webSvc.Status } else { 'N/A' })"
if ($webSvc -and $webSvc.Status -ne "Running") {
    Write-Host "  -> Starting DelugeWeb..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Starting DelugeWeb (was $($webSvc.Status))..."
    Start-Service -Name "DelugeWeb" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    $webSvc = Get-Service -Name "DelugeWeb"
    Write-DebugLog "VAR DelugeWeb status after start=$($webSvc.Status)"
}

# -- 2. Wait for Daemon RPC (via Web UI JSON-RPC endpoint) --------------------
Write-Host "  -> Waiting for daemon RPC (via Web UI on port $WebPort)..." -ForegroundColor Gray
$rpcUrl = "http://127.0.0.1:$WebPort/json"
Write-DebugLog "INFO" "Polling Deluge daemon via Web UI JSON-RPC at $rpcUrl (up to 30s)..."
$rpcUp   = $false
$deadline = (Get-Date).AddSeconds(30)
$rpcWaited = 0
while (-not $rpcUp -and (Get-Date) -lt $deadline) {
    try {
        # auth.login authenticates with the Web UI (not daemon.login which is daemon-protocol only).
        # The Web UI auto-connects to the daemon via hostlist.conf (localclient).
        $loginBody = @{ method = "auth.login"; params = @($DelugePassword); id = 1 } | ConvertTo-Json -Compress
        $resp = Invoke-RestMethod -Uri $rpcUrl -Method Post `
            -Body $loginBody -ContentType "application/json" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($resp.result -eq $true) {
            $rpcUp = $true
        } elseif ($resp.error) {
            Write-DebugLog "VAR Deluge auth.login error: $($resp.error.message)"
            Start-Sleep -Seconds 2; $rpcWaited += 2
        } else {
            Start-Sleep -Seconds 2; $rpcWaited += 2
        }
    } catch {
        Write-DebugLog "VAR Deluge RPC exception: $_"
        Start-Sleep -Seconds 2; $rpcWaited += 2
    }
}
Write-DebugLog "VAR Deluge RPC up=$rpcUp waited=${rpcWaited}s"
if (-not $rpcUp) {
    Write-Warning "[$AppName] Daemon RPC did not respond within 30s."
    Write-DebugLog "ERROR" "Deluge daemon RPC not responding at $rpcUrl after 30s"
    exit 1
}

Write-Host "  -> Daemon RPC OK" -ForegroundColor Green
Write-DebugLog "INFO" "Deluge daemon RPC responding. Login successful."

# -- 3. Wait for Web UI ---------------------------------------------------------
if ($webSvc) {
    Write-Host "  -> Waiting for Web UI on port $WebPort..." -ForegroundColor Gray
    $webUrl = "http://127.0.0.1:$WebPort"
    Write-DebugLog "INFO" "Polling Deluge Web UI at $webUrl (up to 15s)..."
    $webUp   = $false
    $deadline = (Get-Date).AddSeconds(15)
    while (-not $webUp -and (Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri $webUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($resp.StatusCode -eq 200) {
                $webUp = $true
            } else {
                Start-Sleep -Seconds 2
            }
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    Write-DebugLog "VAR Deluge Web UI up=$webUp"
    if ($webUp) {
        Write-Host "  -> Web UI OK" -ForegroundColor Green

        # Set default_daemon so the Web UI auto-connects without showing the Connection Manager.
        # Deluge only reads this key when deluge-web starts, so the service is restarted
        # below whenever the value changes -- a running instance would otherwise ignore the
        # edit and could even overwrite it (it keeps web.conf in memory and re-saves it).
        $HostlistConf = Join-Path $InstallDir "Deluge-data\hostlist.conf"
        $WebConf      = Join-Path $InstallDir "Deluge-data\web.conf"
        Write-DebugLog "VAR HostlistConf=$HostlistConf (exists=$(Test-Path $HostlistConf))"
        if (Test-Path $HostlistConf) {
            try {
                # Deluge writes two JSON objects concatenated in one file:
                #   {"file":3,"format":1}{"hosts":[["<uuid>","127.0.0.1",58846,...]]}
                # Split on the }{ boundary between them and parse the second object.
                $hlRaw = Get-Content $HostlistConf -Raw -Encoding UTF8
                # Find the first occurrence of '}{' which separates the header from the data
                $splitIdx = $hlRaw.IndexOf('}{')
                if ($splitIdx -ge 0) {
                    $hostsJson = $hlRaw.Substring($splitIdx + 1)
                    $hl = $hostsJson | ConvertFrom-Json
                    if ($hl.hosts -and $hl.hosts.Count -gt 0) {
                        $hostId = $hl.hosts[0][0]
                        Write-DebugLog "VAR hostId=$hostId"
                        if ($hostId) {
                            $wcRaw = [System.IO.File]::ReadAllText($WebConf, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
                            # Layout is '<header json><body json>'. Deluge writes both objects with
                            # no separator; 07_deluge.ps1 writes a newline between them. Split after
                            # the header's closing brace, which is the first '}' in the file.
                            $wcSplit = $wcRaw.IndexOf('}')
                            $wcBodyText = if ($wcSplit -ge 0) { $wcRaw.Substring($wcSplit + 1).Trim() } else { '' }
                            if (-not $wcBodyText -or -not $wcBodyText.StartsWith('{')) {
                                Write-Warning "[$AppName] Unexpected web.conf layout -- default_daemon not written."
                                Write-DebugLog "WARN" "web.conf header/body split failed (len=$($wcRaw.Length))"
                            } else {
                                $wcHeader = $wcRaw.Substring(0, $wcSplit + 1)
                                $wcBody   = $wcBodyText | ConvertFrom-Json
                                $webConfChanged = $false

                                # Keep the Web UI loopback-only: Deluge's own default interface is
                                # 0.0.0.0, which would expose it to the whole LAN.
                                if (-not $wcBody.PSObject.Properties['interface'] -or [string]$wcBody.interface -ne '127.0.0.1') {
                                    if ($wcBody.PSObject.Properties['interface']) {
                                        $wcBody.interface = '127.0.0.1'
                                    } else {
                                        $wcBody | Add-Member -MemberType NoteProperty -Name 'interface' -Value '127.0.0.1'
                                    }
                                    $webConfChanged = $true
                                    Write-Host "  -> Web UI bound to loopback only (interface=127.0.0.1)" -ForegroundColor Green
                                    Write-DebugLog "INFO" "web.conf interface set to 127.0.0.1"
                                }

                                # default_daemon lets the Web UI connect without the Connection Manager.
                                $currentDaemon = if ($wcBody.PSObject.Properties['default_daemon']) { [string]$wcBody.default_daemon } else { '' }
                                if ($currentDaemon -ne $hostId) {
                                    if ($wcBody.PSObject.Properties['default_daemon']) {
                                        $wcBody.default_daemon = $hostId
                                    } else {
                                        $wcBody | Add-Member -MemberType NoteProperty -Name 'default_daemon' -Value $hostId
                                    }
                                    $webConfChanged = $true
                                    Write-Host "  -> Auto-connect to daemon configured (hostId=$hostId)" -ForegroundColor Green
                                    Write-DebugLog "INFO" "default_daemon set to $hostId in $WebConf"
                                }

                                if (-not $webConfChanged) {
                                    Write-Host "  -> Web UI config already up to date" -ForegroundColor Green
                                    Write-DebugLog "INFO" "web.conf already loopback-only with default_daemon=$hostId"
                                } else {
                                    [System.IO.File]::WriteAllText($WebConf, ($wcHeader + ($wcBody | ConvertTo-Json -Depth 10)), (New-Object System.Text.UTF8Encoding($false)))
                                    Write-DebugLog "INFO" "web.conf updated -- restarting DelugeWeb so Deluge re-reads it"

                                    $null = Restart-ServiceBounded -Name "DelugeWeb"
                                    $webBack = $false
                                    $deadline = (Get-Date).AddSeconds(20)
                                    while (-not $webBack -and (Get-Date) -lt $deadline) {
                                        try {
                                            $probe = Invoke-WebRequest -Uri $webUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
                                            if ($probe.StatusCode -eq 200) { $webBack = $true }
                                        } catch { }
                                        if (-not $webBack) { Start-Sleep -Seconds 2 }
                                    }
                                    Write-DebugLog "VAR DelugeWeb restarted for web.conf change; web UI back=$webBack"
                                    if (-not $webBack) {
                                        Write-Warning "[$AppName] Web UI did not come back within 20s after restarting DelugeWeb."
                                    }
                                }
                            }
                        }
                    }
                }
            } catch {
                Write-DebugLog "WARN" "Could not update Deluge Web UI config: $_"
            }
        } else {
            Write-DebugLog "WARN" "hostlist.conf not found yet ($HostlistConf) -- auto-connect not configured"
        }
    } else {
        Write-Warning "[$AppName] Web UI not responding after 15s."
        Write-DebugLog "WARN" "Deluge Web UI not responding at $webUrl"
    }
}

# -- 4. Print Sonarr/Radarr setup info -----------------------------------------
Write-Host ""
Write-Host "  [$AppName] Sonarr / Radarr download client settings:" -ForegroundColor Yellow
Write-Host "    Name     : Deluge"                                   -ForegroundColor Cyan
Write-Host "    Type     : Deluge"                                   -ForegroundColor Cyan
Write-Host "    Host     : 127.0.0.1"                               -ForegroundColor Cyan
# Sonarr/Radarr drive Deluge through its Web UI JSON-RPC endpoint (POST /json on the
# web port) -- the daemon port speaks RenCode, which *arr cannot speak.
Write-Host "    Port     : $WebPort"                                 -ForegroundColor Cyan
Write-Host "    Password : (from secrets\deluge_auth.txt)"           -ForegroundColor Cyan
Write-Host ""
Write-DebugLog "INFO" "Deluge download client info: host=127.0.0.1 port=$WebPort webUI-JSON-RPC password=[REDACTED]"

# -- 5. Print Web UI URL -------------------------------------------------------
if ($DomainMode -eq "cloudflare") {
    $webUrl = "https://deluge.$Domain"
} else {
    $webUrl = "https://$($Config.General.DuckDnsDomain)/deluge"
}
Write-Host "  [Deluge Web UI]: $webUrl" -ForegroundColor Cyan
Write-DebugLog "VAR Deluge Web UI URL=$webUrl"
Write-Host ""
Write-Host "[$AppName] Configuration complete." -ForegroundColor Cyan
Write-DebugLog "INFO" "configure_layer1_deluge.ps1 complete"
