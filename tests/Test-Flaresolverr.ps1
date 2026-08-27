# tests/Test-Flaresolverr.ps1 -- FlareSolverr CAPTCHA bypass test module

param([int]$LayerFilter = 0)

$svc  = 'Flaresolverr'
$port = $Config.Ports.Flaresolverr

if ($Config.Apps.Flaresolverr -ne $true) {
    $Script:Results.Add((New-TestResult $svc 1 'Enabled' 'SKIP' 'Apps.Flaresolverr = false in config'))
    return
}

# -- Layer 1: Health -----------------------------------------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 1) {
    $portOk = Test-TcpPort $port
    $Script:Results.Add((New-TestResult $svc 1 'PortOpen' $(if ($portOk) { 'PASS' } else { 'FAIL' }) "TCP :$port"))

    $health = Invoke-ApiCheck "http://127.0.0.1:$port/" -TimeoutSec 8
    if ($health.ok) {
        $ver = if ($health.data -and $health.data.version) { $health.data.version } else { 'unknown' }
        $Script:Results.Add((New-TestResult $svc 1 'HealthEndpoint' 'PASS' "FlareSolverr $ver" $health.latency_ms))
    } else {
        $Script:Results.Add((New-TestResult $svc 1 'HealthEndpoint' 'FAIL' $health.error $health.latency_ms))
    }

    $nssm = Get-Service 'Flaresolverr' -ErrorAction SilentlyContinue
    $Script:Results.Add((New-TestResult $svc 1 'ServiceRunning' $(if ($nssm -and $nssm.Status -eq 'Running') { 'PASS' } else { 'FAIL' }) "NSSM service state"))
}

# -- Layer 2: Registered in Prowlarr ------------------------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 2) {
    $prowlarrKey  = Get-XmlApiKey 'C:\ProgramData\Prowlarr\config.xml'
    $prowlarrPort = $Config.Ports.Prowlarr
    $pBase        = Get-AppUrlBase 'prowlarr' $Config.General.DomainMode

    if ($prowlarrKey) {
        $proxies = Invoke-ApiCheck "http://127.0.0.1:$prowlarrPort${pBase}/api/v1/indexerproxy" @{'X-Api-Key'=$prowlarrKey} -TimeoutSec 8
        if ($proxies.ok) {
            $fsReg = @($proxies.data | Where-Object { $_.implementation -match 'FlareSolverr|flaresolverr' }).Count -gt 0
            $Script:Results.Add((New-TestResult $svc 2 'RegisteredInProwlarr' $(if ($fsReg) { 'PASS' } else { 'FAIL' }) "FlareSolverr proxy in Prowlarr indexer proxies"))
        } else {
            $Script:Results.Add((New-TestResult $svc 2 'RegisteredInProwlarr' 'FAIL' "Prowlarr API error: $($proxies.error)"))
        }
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'RegisteredInProwlarr' 'SKIP' 'Prowlarr config.xml unreadable'))
    }
}
