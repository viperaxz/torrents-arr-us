# tests/Test-Caddy.ps1 -- Caddy reverse proxy test module
# Dot-sourced by test-suite.ps1; expects $Config, $InstallDir already set.

param([int]$LayerFilter = 0)

$svc = 'Caddy'

# -- Layer 1: Health -----------------------------------------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 1) {
    $pos = Get-LogPosition (Join-Path $InstallDir 'logs\caddy\access.log')
    $t0  = Get-Date

    $p80 = Test-TcpPort 80
    $Script:Results.Add((New-TestResult $svc 1 'Port80Open' $(if ($p80) { 'PASS' } else { 'FAIL' }) 'TCP :80'))

    $p443 = Test-TcpPort 443
    $Script:Results.Add((New-TestResult $svc 1 'Port443Open' $(if ($p443) { 'PASS' } else { 'FAIL' }) 'TCP :443'))

    $redirects = $false
    try {
        $r = Invoke-WebRequest 'http://127.0.0.1/' -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop -MaximumRedirection 0
        $redirects = ($r.StatusCode -ge 301 -and $r.StatusCode -le 308)
    } catch {
        $redirects = ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -ge 301 -and [int]$_.Exception.Response.StatusCode -le 308)
    }
    $Script:Results.Add((New-TestResult $svc 1 'HttpRedirect' $(if ($redirects) { 'PASS' } else { 'FAIL' }) 'HTTP->HTTPS redirect'))

    $nssm = Get-Service 'Caddy' -ErrorAction SilentlyContinue
    $Script:Results.Add((New-TestResult $svc 1 'ServiceRunning' $(if ($nssm -and $nssm.Status -eq 'Running') { 'PASS' } else { 'FAIL' }) 'NSSM service state'))

    Get-LogValidationResult $svc 1 (Join-Path $InstallDir 'logs\caddy\access.log') $pos '' $t0 $Script:LokiEnabled
}

# -- Layer 2: Inter-service (backends reachable through Caddy) -----------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 2) {
    $domain = if ($Config.General.DomainMode -eq 'duckdns') { $Config.General.DuckDnsDomain } else { $Config.General.Domain }

    if ($Config.General.DomainMode -eq 'duckdns') {
        $jBase = Invoke-ApiCheck "https://$domain/jellyfin/System/Info/Public" -TimeoutSec 8
        $Script:Results.Add((New-TestResult $svc 2 'JellyfinViaProxy' $(if ($jBase.ok) { 'PASS' } else { 'FAIL' }) "https://$domain/jellyfin" $jBase.latency_ms))
    } else {
        $jBase = Invoke-ApiCheck "https://jellyfin.$domain/System/Info/Public" -TimeoutSec 8
        $Script:Results.Add((New-TestResult $svc 2 'JellyfinViaProxy' $(if ($jBase.ok) { 'PASS' } else { 'FAIL' }) "https://jellyfin.$domain" $jBase.latency_ms))
    }
}

# -- Layer 3: Feature (basic-auth rejects wrong credentials) -------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 3) {
    $domain    = if ($Config.General.DomainMode -eq 'duckdns') { $Config.General.DuckDnsDomain } else { $Config.General.Domain }
    $delugePath = if ($Config.General.DomainMode -eq 'duckdns') { "https://$domain/deluge/" } else { "https://deluge.$domain/" }

    $code = 0
    try {
        $resp = Invoke-WebRequest $delugePath -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop -MaximumRedirection 0
        $code = [int]$resp.StatusCode
    } catch {
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    }
    $Script:Results.Add((New-TestResult $svc 3 'BasicAuthPresent' $(if ($code -eq 401) { 'PASS' } else { 'WARN' }) "Deluge Web UI returned $code (expect 401)"))
}
