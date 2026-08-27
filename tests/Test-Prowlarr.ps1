# tests/Test-Prowlarr.ps1 -- Prowlarr indexer manager test module

param([int]$LayerFilter = 0)

$svc    = 'Prowlarr'
$port   = $Config.Ports.Prowlarr
$base   = Get-AppUrlBase 'prowlarr' $Config.General.DomainMode
$apiKey = Get-XmlApiKey 'C:\ProgramData\Prowlarr\config.xml'
$log    = 'C:\ProgramData\Prowlarr\logs\prowlarr.txt'
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
        $health = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/v1/system/status" $hdr -TimeoutSec 8
        $Script:Results.Add((New-TestResult $svc 1 'ApiHealth' $(if ($health.ok) { 'PASS' } else { 'FAIL' }) $health.error $health.latency_ms))

        $idxRaw = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/v1/indexer" $hdr -TimeoutSec 8
        if ($idxRaw.ok) {
            $enabled = @($idxRaw.data | Where-Object { $_.enable -eq $true }).Count
            $Script:Results.Add((New-TestResult $svc 1 'IndexersEnabled' $(if ($enabled -gt 0) { 'PASS' } else { 'WARN' }) "$enabled enabled indexer(s)"))
        } else {
            $Script:Results.Add((New-TestResult $svc 1 'IndexersEnabled' 'FAIL' $idxRaw.error))
        }
    }

    $nssm = Get-Service 'Prowlarr' -ErrorAction SilentlyContinue
    $Script:Results.Add((New-TestResult $svc 1 'ServiceRunning' $(if ($nssm -and $nssm.Status -eq 'Running') { 'PASS' } else { 'FAIL' }) 'NSSM service state'))

    Get-LogValidationResult $svc 1 $log $pos 'prowlarr' $t0 $Script:LokiEnabled
}

# -- Layer 2: Sonarr + Radarr registered, FlareSolverr proxy ------------------
if (($LayerFilter -eq 0 -or $LayerFilter -eq 2) -and $apiKey) {
    $apps = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/v1/applications" $hdr -TimeoutSec 8
    if ($apps.ok) {
        $sonarrReg = @($apps.data | Where-Object { $_.name -match 'Sonarr' }).Count -gt 0
        $radarrReg = @($apps.data | Where-Object { $_.name -match 'Radarr' }).Count -gt 0
        $Script:Results.Add((New-TestResult $svc 2 'SonarrRegistered' $(if ($sonarrReg) { 'PASS' } else { 'FAIL' }) 'Sonarr in Prowlarr applications'))
        $Script:Results.Add((New-TestResult $svc 2 'RadarrRegistered'  $(if ($radarrReg) { 'PASS' } else { 'FAIL' }) 'Radarr in Prowlarr applications'))
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'SonarrRegistered' 'FAIL' $apps.error))
        $Script:Results.Add((New-TestResult $svc 2 'RadarrRegistered'  'FAIL' $apps.error))
    }

    if ($Config.Apps.Flaresolverr -eq $true) {
        $proxies = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/v1/indexerproxy" $hdr -TimeoutSec 8
        if ($proxies.ok) {
            $fsReg = @($proxies.data | Where-Object { $_.implementation -match 'FlareSolverr|flaresolverr' }).Count -gt 0
            $Script:Results.Add((New-TestResult $svc 2 'FlareSolverrProxy' $(if ($fsReg) { 'PASS' } else { 'FAIL' }) 'FlareSolverr proxy registered in Prowlarr'))
        } else {
            $Script:Results.Add((New-TestResult $svc 2 'FlareSolverrProxy' 'FAIL' $proxies.error))
        }
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'FlareSolverrProxy' 'SKIP' 'Flaresolverr not enabled in config'))
    }
}

# -- Layer 3: Live indexer search ----------------------------------------------
if (($LayerFilter -eq 0 -or $LayerFilter -eq 3) -and $apiKey) {
    $idxRaw  = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/v1/indexer" $hdr -TimeoutSec 8
    # Prefer a public (no-credential) indexer so the test doesn't rely on private tracker auth
    $publicNames = @('1337x','Nyaa','TPB','RARBG','YTS','LimeTorrents','TorrentGalaxy','ThePirateBay')
    $tgtIdx = $null
    if ($idxRaw.ok) {
        foreach ($n in $publicNames) {
            $match = @($idxRaw.data | Where-Object { $_.enable -eq $true -and $_.name -match $n })[0]
            if ($match) { $tgtIdx = $match; break }
        }
        if (-not $tgtIdx) { $tgtIdx = @($idxRaw.data | Where-Object { $_.enable -eq $true })[0] }
    }

    if (-not $tgtIdx) {
        $Script:Results.Add((New-TestResult $svc 3 'LiveSearch' 'SKIP' 'No enabled indexer found to test with'))
    } else {
        # Prowlarr search API: /api/v1/search?query=...&indexerIds=...&categories=2000 (movies)
        $q    = [System.Web.HttpUtility]::UrlEncode('test')
        $srch = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/v1/search?query=$q&indexerIds=$($tgtIdx.id)&categories=2000&limit=5" $hdr -TimeoutSec 30
        if ($srch.ok) {
            $hits = if ($srch.data -is [array]) { $srch.data.Count } else { 0 }
            $Script:Results.Add((New-TestResult $svc 3 'LiveSearch' $(if ($hits -gt 0) { 'PASS' } else { 'WARN' }) "$hits result(s) from $($tgtIdx.name)" $srch.latency_ms))
        } else {
            $Script:Results.Add((New-TestResult $svc 3 'LiveSearch' 'FAIL' "$($tgtIdx.name): $($srch.error)" $srch.latency_ms))
        }
    }
}
