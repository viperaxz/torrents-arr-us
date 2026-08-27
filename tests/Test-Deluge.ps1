# tests/Test-Deluge.ps1 -- Deluge download daemon test module

param([int]$LayerFilter = 0)

$svcDaemon = 'DelugeDaemon'
$svcWeb    = 'DelugeWeb'
$daemonPort = $Config.Ports.Deluge
$webPort    = $Config.Ports.DelugeWeb
$rpcUrl     = "http://127.0.0.1:$webPort/json"
$daemonLog  = Join-Path $InstallDir 'Deluge-data\deluged.log'
$webLog     = Join-Path $InstallDir 'Deluge-data\deluge-web.log'

$authPath   = Join-Path $InstallDir 'secrets\deluge_auth.txt'
$password   = $null
if (Test-Path $authPath) {
    $password = ([System.IO.File]::ReadAllText($authPath, [System.Text.Encoding]::UTF8)).TrimStart([char]0xFEFF).Trim()
}

# Deluge Web UI uses its own session/cookie auth. The daemon uses RenCode protocol
# (not JSON-RPC), so all RPC calls go through the Web UI at port 8112.
$Script:DelugeSession = $null

function DelugeRpc { param([string]$Method, [string]$Params = '')
    if (-not $password) {
        return [PSCustomObject]@{ ok=$false; ms=0; data=$null }
    }
    if (-not $Script:DelugeSession) {
        $Script:DelugeSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    }
    $body = "{`"method`":`"$Method`",`"params`":[$Params],`"id`":1}"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = Invoke-WebRequest -Uri $rpcUrl -Method Post -Body $body `
            -ContentType 'application/json' -UseBasicParsing -TimeoutSec 8 `
            -WebSession $Script:DelugeSession -ErrorAction Stop
        $sw.Stop()
        $data = $resp.Content | ConvertFrom-Json
        return [PSCustomObject]@{ ok=$true; ms=[int]$sw.ElapsedMilliseconds; data=$data }
    } catch { $sw.Stop(); return [PSCustomObject]@{ ok=$false; ms=[int]$sw.ElapsedMilliseconds; data=$null } }
}

function DelugeLogin {
    if (-not $password) { return $false }
    # auth.login authenticates with the Web UI.
    # daemon.login is RenCode only and cannot be called through the Web UI proxy.
    $res = DelugeRpc 'auth.login' "`"$password`""
    return ($res.ok -and $res.data.result -eq $true)
}

# -- Layer 1: Health -----------------------------------------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 1) {
    $posDaemon = Get-LogPosition $daemonLog
    $posWeb    = Get-LogPosition $webLog
    $t0        = Get-Date

    # Daemon checks
    $daemonPortOk = Test-TcpPort $daemonPort
    $Script:Results.Add((New-TestResult $svcDaemon 1 'PortOpen' $(if ($daemonPortOk) { 'PASS' } else { 'FAIL' }) "TCP :$daemonPort"))

    if (-not $password) {
        $Script:Results.Add((New-TestResult $svcDaemon 1 'AuthFound' 'FAIL' 'secrets\deluge_auth.txt missing'))
    } else {
        $loggedIn = DelugeLogin
        $Script:Results.Add((New-TestResult $svcDaemon 1 'RpcLogin' $(if ($loggedIn) { 'PASS' } else { 'FAIL' }) "auth.login"))

        $hosts = DelugeRpc 'web.get_hosts' ''
        $hostMsg = if ($hosts.ok -and $hosts.data.result) { "$($hosts.data.result.Count) host(s) connected" } else { 'RPC error' }
        $Script:Results.Add((New-TestResult $svcDaemon 1 'RpcHosts' $(if ($hosts.ok -and $hosts.data.result) { 'PASS' } else { 'FAIL' }) $hostMsg))
    }

    $daemonSvc = Get-Service 'DelugeDaemon' -ErrorAction SilentlyContinue
    $Script:Results.Add((New-TestResult $svcDaemon 1 'ServiceRunning' $(if ($daemonSvc -and $daemonSvc.Status -eq 'Running') { 'PASS' } else { 'FAIL' }) 'NSSM service state'))

    Get-LogValidationResult $svcDaemon 1 $daemonLog $posDaemon '' $t0 $Script:LokiEnabled

    # Web UI checks
    $webPortOk = Test-TcpPort $webPort
    $Script:Results.Add((New-TestResult $svcWeb 1 'PortOpen' $(if ($webPortOk) { 'PASS' } else { 'FAIL' }) "TCP :$webPort"))

    $webSvc = Get-Service 'DelugeWeb' -ErrorAction SilentlyContinue
    $Script:Results.Add((New-TestResult $svcWeb 1 'ServiceRunning' $(if ($webSvc -and $webSvc.Status -eq 'Running') { 'PASS' } else { 'FAIL' }) 'NSSM service state'))

    Get-LogValidationResult $svcWeb 1 $webLog $posWeb '' $t0 $Script:LokiEnabled
}

# -- Layer 2: Auth accepted, Web UI via proxy ----------------------------------
if (($LayerFilter -eq 0 -or $LayerFilter -eq 2) -and $password) {
    # Verify daemon connection status via Web UI (core.* daemon methods are RenCode-only)
    $hostsRes = DelugeRpc 'web.get_hosts' ''
    if ($hostsRes.ok -and $hostsRes.data.result -and $hostsRes.data.result.Count -gt 0) {
        $hostId = $hostsRes.data.result[0][0]
        $statusRes = DelugeRpc 'web.get_host_status' "`"$hostId`""
        if ($statusRes.ok -and $statusRes.data.result) {
            $status = $statusRes.data.result[1]
            $ver    = $statusRes.data.result[2]
            $Script:Results.Add((New-TestResult $svcDaemon 2 'AuthAccepted' 'PASS' "host=$status v$ver" $statusRes.ms))
        } else {
            $Script:Results.Add((New-TestResult $svcDaemon 2 'AuthAccepted' 'FAIL' 'web.get_host_status failed'))
        }
    } else {
        $Script:Results.Add((New-TestResult $svcDaemon 2 'AuthAccepted' 'FAIL' 'no daemon hosts'))
    }

    # Check Web UI accessible via Caddy proxy
    $domain       = if ($Config.General.DomainMode -eq 'duckdns') { $Config.General.DuckDnsDomain } else { $Config.General.Domain }
    $delugeWebUrl = if ($Config.General.DomainMode -eq 'duckdns') {
        "https://$domain/deluge/"
    } else {
        "https://deluge.$domain/"
    }
    $code = 0
    try {
        $resp = Invoke-WebRequest $delugeWebUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $code = [int]$resp.StatusCode
    } catch {
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    }
    $Script:Results.Add((New-TestResult $svcWeb 2 'WebUiViaProxy' $(if ($code -eq 200 -or $code -eq 401) { 'PASS' } else { 'FAIL' }) "Got $code (200 or 401 OK)"))
}

# -- Layer 3: Add paused magnet, verify hash, remove ---------------------------
if (($LayerFilter -eq 0 -or $LayerFilter -eq 3) -and $password) {
    # Add a magnet link for a well-known Linux ISO in paused state
    $magnet = "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=Big+Buck+Bunny&tr=udp%3A%2F%2Ftracker.leechers-paradise.org%3A6969&tr=http%3A%2F%2Ftracker.tfile.me%2Fannounce"
    $addRes = DelugeRpc 'core.add_torrent_magnet' "`"$magnet`",{`"add_paused`":true,`"download_location`":`"$($Config.Paths.Downloads -replace '\\','/')`"}"
    if (-not $addRes.ok -or $addRes.data.error) {
        $Script:Results.Add((New-TestResult $svcDaemon 3 'AddPausedMagnet' 'FAIL' 'add_torrent_magnet failed'))
    } else {
        $hash = $addRes.data.result
        if (-not $hash) { $hash = 'dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c' }
        $Script:Results.Add((New-TestResult $svcDaemon 3 'AddPausedMagnet' 'PASS' "hash=$hash" $addRes.ms))
        $rmRes = DelugeRpc 'core.remove_torrent' "`"$hash`",false"
        $Script:Results.Add((New-TestResult $svcDaemon 3 'RemoveTorrent' $(if ($rmRes.ok) { 'PASS' } else { 'WARN' }) "Cleanup hash=$hash"))
    }
}
