# tests/Test-Radarr.ps1 -- Radarr movie automation test module

param([int]$LayerFilter = 0)

$svc    = 'Radarr'
$port   = $Config.Ports.Radarr
$base   = Get-AppUrlBase 'radarr' $Config.General.DomainMode
$apiKey = Get-XmlApiKey 'C:\ProgramData\Radarr\config.xml'
$log    = 'C:\ProgramData\Radarr\logs\radarr.txt'
$hdr    = if ($apiKey) { @{'X-Api-Key'=$apiKey} } else { @{} }

# -- Layer 1: Health -----------------------------------------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 1) {
    $pos = Get-LogPosition $log
    $t0  = Get-Date

    $portOk = Test-TcpPort $port
    $Script:Results.Add((New-TestResult $svc 1 'PortOpen' $(if ($portOk) { 'PASS' } else { 'FAIL' }) "TCP :$port"))

    if (-not $apiKey) {
        $Script:Results.Add((New-TestResult $svc 1 'ApiKeyFound' 'FAIL' 'Cannot read config.xml'))
    } else {
        $health = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/v3/system/status" $hdr -TimeoutSec 8
        $Script:Results.Add((New-TestResult $svc 1 'ApiHealth' $(if ($health.ok) { 'PASS' } else { 'FAIL' }) $health.error $health.latency_ms))

        $hc = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/v3/health" $hdr -TimeoutSec 8
        if ($hc.ok) {
            $criticals = @($hc.data | Where-Object { $_.type -eq 'error' })
            if ($criticals.Count -gt 0) {
                $Script:Results.Add((New-TestResult $svc 1 'HealthAlerts' 'WARN' "$($criticals.Count) error(s): $($criticals[0].message)"))
            } else {
                $Script:Results.Add((New-TestResult $svc 1 'HealthAlerts' 'PASS' 'No error-level health alerts'))
            }
        }
    }

    $nssm = Get-Service 'Radarr' -ErrorAction SilentlyContinue
    $Script:Results.Add((New-TestResult $svc 1 'ServiceRunning' $(if ($nssm -and $nssm.Status -eq 'Running') { 'PASS' } else { 'FAIL' }) 'NSSM service state'))

    Get-LogValidationResult $svc 1 $log $pos 'radarr' $t0 $Script:LokiEnabled
}

# -- Layer 2: Inter-service ----------------------------------------------------
if (($LayerFilter -eq 0 -or $LayerFilter -eq 2) -and $apiKey) {
    $apps = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/v3/downloadclient" $hdr -TimeoutSec 8
    if ($apps.ok) {
        $delugeRegistered = @($apps.data | Where-Object { $_.implementation -match 'Deluge|deluge' }).Count -gt 0
        $Script:Results.Add((New-TestResult $svc 2 'DelugeDownloadClient' $(if ($delugeRegistered) { 'PASS' } else { 'FAIL' }) 'Deluge in download clients'))
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'DelugeDownloadClient' 'FAIL' $apps.error))
    }

    $roots = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/v3/rootfolder" $hdr -TimeoutSec 8
    if ($roots.ok) {
        $cfgMovies = $Config.Paths.Movies
        $found     = @($roots.data | Where-Object { $_.path -eq $cfgMovies }).Count -gt 0
        $Script:Results.Add((New-TestResult $svc 2 'RootFolderMatch' $(if ($found) { 'PASS' } else { 'WARN' }) "Expected $cfgMovies in root folders"))
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'RootFolderMatch' 'FAIL' $roots.error))
    }

    $idx = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/v3/indexer" $hdr -TimeoutSec 8
    if ($idx.ok) {
        $idxCount = if ($idx.data -is [array]) { $idx.data.Count } else { 0 }
        $Script:Results.Add((New-TestResult $svc 2 'IndexersFromProwlarr' $(if ($idxCount -gt 0) { 'PASS' } else { 'WARN' }) "$idxCount indexer(s) synced from Prowlarr"))
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'IndexersFromProwlarr' 'FAIL' $idx.error))
    }
}

# -- Layer 3: Feature (RSS Sync) -----------------------------------------------
if (($LayerFilter -eq 0 -or $LayerFilter -eq 3) -and $apiKey) {
    $cmd = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/v3/command" $hdr -TimeoutSec 10 `
        -Method POST -Body '{"name":"RssSync"}'
    if (-not $cmd.ok) {
        $Script:Results.Add((New-TestResult $svc 3 'RssSync' 'FAIL' "Command POST failed: $($cmd.error)"))
    } else {
        $cmdId = $cmd.data.id
        $done  = $false; $attempts = 0
        while (-not $done -and $attempts -lt 15) {
            Start-Sleep -Seconds 2; $attempts++
            $status = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/v3/command/$cmdId" $hdr -TimeoutSec 8
            if ($status.ok -and $status.data.status -in @('completed','failed')) { $done = $true }
        }
        if ($done -and $status.ok -and $status.data.status -eq 'completed') {
            $Script:Results.Add((New-TestResult $svc 3 'RssSync' 'PASS' "Completed in $($attempts * 2)s" ($attempts * 2000)))
        } elseif ($done -and $status.ok -and $status.data.status -eq 'failed') {
            $Script:Results.Add((New-TestResult $svc 3 'RssSync' 'FAIL' "Command failed: $($status.data.exception)"))
        } else {
            $Script:Results.Add((New-TestResult $svc 3 'RssSync' 'WARN' 'Still running after 30s'))
        }
    }
}
