# tests/Test-Grafana.ps1 -- Grafana / Loki / Alloy observability stack test module

param([int]$LayerFilter = 0)

$svc = 'Grafana'

if ($Config.Apps.Grafana -ne $true) {
    $Script:Results.Add((New-TestResult $svc 1 'Enabled' 'SKIP' 'Apps.Grafana = false in config'))
    return
}

# -- Layer 1: All three services running ---------------------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 1) {
    foreach ($pair in @(@{n='Grafana';s='Grafana';p=3000}, @{n='Loki';s='Loki';p=3100}, @{n='Alloy';s='Alloy';p=0})) {
        $nssm = Get-Service $pair.s -ErrorAction SilentlyContinue
        $Script:Results.Add((New-TestResult $svc 1 "$($pair.n)Running" $(if ($nssm -and $nssm.Status -eq 'Running') { 'PASS' } else { 'FAIL' }) "NSSM service state: $($nssm.Status)"))
    }

    $gfHealth = Invoke-ApiCheck 'http://127.0.0.1:3000/api/health' -TimeoutSec 8
    $Script:Results.Add((New-TestResult $svc 1 'GrafanaApiHealth' $(if ($gfHealth.ok) { 'PASS' } else { 'FAIL' }) $gfHealth.error $gfHealth.latency_ms))

    $lokiReady = Invoke-ApiCheck 'http://127.0.0.1:3100/ready' -TimeoutSec 8
    $Script:Results.Add((New-TestResult $svc 1 'LokiReady' $(if ($lokiReady.ok) { 'PASS' } else { 'FAIL' }) $lokiReady.error $lokiReady.latency_ms))
}

# -- Layer 2: Loki datasource, dashboards provisioned -------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 2) {
    $adminUser = $Config.General.AdminUsername
    $adminPass = $Config.General.AdminPassword
    $basicCred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${adminUser}:${adminPass}"))
    $authHdr   = @{ Authorization = "Basic $basicCred" }

    $ds = Invoke-ApiCheck 'http://127.0.0.1:3000/api/datasources' $authHdr -TimeoutSec 8
    if ($ds.ok) {
        $lokiDs = @($ds.data | Where-Object { $_.type -eq 'loki' })
        $Script:Results.Add((New-TestResult $svc 2 'LokiDatasource' $(if ($lokiDs.Count -gt 0) { 'PASS' } else { 'FAIL' }) "$($lokiDs.Count) Loki datasource(s) in Grafana"))
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'LokiDatasource' 'FAIL' "Grafana /api/datasources: $($ds.error)"))
    }

    $dash = Invoke-ApiCheck 'http://127.0.0.1:3000/api/search?type=dash-db' $authHdr -TimeoutSec 8
    if ($dash.ok) {
        $count = if ($dash.data -is [array]) { $dash.data.Count } else { 0 }
        $Script:Results.Add((New-TestResult $svc 2 'DashboardsProvisioned' $(if ($count -gt 0) { 'PASS' } else { 'WARN' }) "$count dashboard(s) provisioned"))
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'DashboardsProvisioned' 'FAIL' $dash.error))
    }

    # Verify Loki actually accepts queries
    $query = [System.Web.HttpUtility]::UrlEncode('{job=~".+"}')
    $endNs   = [string]([long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) * 1000000)
    $startNs = [string]([long](([DateTimeOffset]::UtcNow.AddMinutes(-10)).ToUnixTimeMilliseconds()) * 1000000)
    $lokiQ = Invoke-ApiCheck "http://127.0.0.1:3100/loki/api/v1/query_range?query=$query&start=$startNs&end=$endNs&limit=5" -TimeoutSec 10
    $Script:Results.Add((New-TestResult $svc 2 'LokiQueryable' $(if ($lokiQ.ok) { 'PASS' } else { 'FAIL' }) "Loki query_range API" $lokiQ.latency_ms))
}

# -- Layer 3: Loki has log lines from core services in last 10 minutes ---------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 3) {
    $endNs    = [string]([long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) * 1000000)

    foreach ($job in @('caddy', 'jellyfin', 'sonarr', 'radarr', 'prowlarr')) {
        # Use 60-min window: checks pipeline health, not recent activity
        $since   = (Get-Date).AddMinutes(-60)
        $sinceNs = [string]([long]([DateTimeOffset]::new($since.ToUniversalTime(), [TimeSpan]::Zero).ToUnixTimeMilliseconds()) * 1000000)
        $q    = [System.Web.HttpUtility]::UrlEncode("{job=`"$job`"}")
        $resp = Invoke-ApiCheck "http://127.0.0.1:3100/loki/api/v1/query_range?query=$q&start=$sinceNs&end=$endNs&limit=1" -TimeoutSec 10
        if ($resp.ok) {
            $hasLines = ($resp.data.data -and $resp.data.data.result -and $resp.data.data.result.Count -gt 0)
            $Script:Results.Add((New-TestResult $svc 3 "LogDelivery_$job" $(if ($hasLines) { 'PASS' } else { 'WARN' }) "Loki has $job logs in last 60 min" $resp.latency_ms))
        } else {
            $Script:Results.Add((New-TestResult $svc 3 "LogDelivery_$job" 'FAIL' $resp.error))
        }
    }
}
