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

        # Set default_daemon so the Web UI auto-connects without showing Connection Manager.
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
                            $wc = Get-Content $WebConf -Raw -Encoding UTF8
                            $wc = $wc -replace '"default_daemon":\s*"[^"]*"', ('"default_daemon": "' + $hostId + '"')
                            [System.IO.File]::WriteAllText($WebConf, $wc, (New-Object System.Text.UTF8Encoding($false)))
                            Write-Host "  -> Auto-connect to daemon configured (hostId=$hostId)" -ForegroundColor Green
                            Write-DebugLog "INFO" "default_daemon set to $hostId in $WebConf"
                        }
                    }
                }
            } catch {
                Write-DebugLog "WARN" "Could not set default_daemon: $_"
            }
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
Write-Host "    Port     : $DaemonPort"                              -ForegroundColor Cyan
Write-Host "    Password : (from secrets\deluge_auth.txt)"           -ForegroundColor Cyan
Write-Host ""
Write-DebugLog "INFO" "Deluge download client info: host=127.0.0.1 port=$DaemonPort password=[REDACTED]"

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
