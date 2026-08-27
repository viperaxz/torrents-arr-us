# tests/Test-Jellyseerr.ps1 -- Jellyseerr media request portal test module

param([int]$LayerFilter = 0)

$svc  = 'Jellyseerr'
$port = $Config.Ports.Jellyseerr
$base = Get-AppUrlBase 'jellyseerr' $Config.General.DomainMode

if ($Config.Apps.Jellyseerr -ne $true) {
    $Script:Results.Add((New-TestResult $svc 1 'Enabled' 'SKIP' 'Apps.Jellyseerr = false in config'))
    return
}

$apiKeyPath = Join-Path $InstallDir 'secrets\jellyseerr_api_key.txt'
$apiKey     = $null
if (Test-Path $apiKeyPath) {
    $apiKey = ([System.IO.File]::ReadAllText($apiKeyPath, [System.Text.Encoding]::UTF8)).TrimStart([char]0xFEFF).Trim()
}
$hdr = if ($apiKey) { @{'X-Api-Key'=$apiKey} } else { @{} }

# -- Layer 1: Health -----------------------------------------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 1) {
    $portOk = Test-TcpPort $port
    $Script:Results.Add((New-TestResult $svc 1 'PortOpen' $(if ($portOk) { 'PASS' } else { 'FAIL' }) "TCP :$port"))

    $status = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/v1/status" -TimeoutSec 8
    if ($status.ok) {
        $ver = if ($status.data -and $status.data.version) { $status.data.version } else { 'unknown' }
        $Script:Results.Add((New-TestResult $svc 1 'ApiStatus' 'PASS' "Jellyseerr $ver" $status.latency_ms))
    } else {
        $Script:Results.Add((New-TestResult $svc 1 'ApiStatus' 'FAIL' $status.error $status.latency_ms))
    }

    $nssm = Get-Service 'Jellyseerr' -ErrorAction SilentlyContinue
    $Script:Results.Add((New-TestResult $svc 1 'ServiceRunning' $(if ($nssm -and $nssm.Status -eq 'Running') { 'PASS' } else { 'FAIL' }) "NSSM service state"))
}

# -- Layer 2: Jellyfin, Sonarr, Radarr healthy; users imported ----------------
if (($LayerFilter -eq 0 -or $LayerFilter -eq 2) -and $apiKey) {
    $settings = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/v1/settings/main" $hdr -TimeoutSec 8
    if ($settings.ok) {
        $jfOk = $settings.data.jellyfinExternalUrl -or $settings.data.jellyfinInternalUrl
        $Script:Results.Add((New-TestResult $svc 2 'JellyfinConfigured' $(if ($jfOk) { 'PASS' } else { 'FAIL' }) "Jellyfin URL in Jellyseerr settings"))
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'JellyfinConfigured' 'FAIL' $settings.error))
    }

    $services = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/v1/settings/sonarr" $hdr -TimeoutSec 8
    if ($services.ok) {
        $sonarrCount = if ($services.data -is [array]) { $services.data.Count } else { 0 }
        $Script:Results.Add((New-TestResult $svc 2 'SonarrLinked' $(if ($sonarrCount -gt 0) { 'PASS' } else { 'FAIL' }) "$sonarrCount Sonarr instance(s) in Jellyseerr"))
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'SonarrLinked' 'FAIL' $services.error))
    }

    $radarrSvc = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/v1/settings/radarr" $hdr -TimeoutSec 8
    if ($radarrSvc.ok) {
        $radarrCount = if ($radarrSvc.data -is [array]) { $radarrSvc.data.Count } else { 0 }
        $Script:Results.Add((New-TestResult $svc 2 'RadarrLinked' $(if ($radarrCount -gt 0) { 'PASS' } else { 'FAIL' }) "$radarrCount Radarr instance(s) in Jellyseerr"))
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'RadarrLinked' 'FAIL' $radarrSvc.error))
    }

    $users = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/v1/user" $hdr -TimeoutSec 8
    if ($users.ok) {
        $total = if ($users.data.results) { $users.data.results.Count } elseif ($users.data -is [array]) { $users.data.Count } else { 0 }
        $Script:Results.Add((New-TestResult $svc 2 'UsersImported' $(if ($total -gt 0) { 'PASS' } else { 'WARN' }) "$total user(s) in Jellyseerr"))
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'UsersImported' 'FAIL' $users.error))
    }
}

# -- Layer 3: Discovery page browse -------------------------------------------
if (($LayerFilter -eq 0 -or $LayerFilter -eq 3) -and $apiKey) {
    $discover = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/v1/discover/movies?page=1" $hdr -TimeoutSec 15
    if ($discover.ok) {
        $count = if ($discover.data.results) { $discover.data.results.Count } else { 0 }
        $Script:Results.Add((New-TestResult $svc 3 'DiscoveryMovies' $(if ($count -gt 0) { 'PASS' } else { 'WARN' }) "$count movie(s) on discover page" $discover.latency_ms))
    } else {
        $Script:Results.Add((New-TestResult $svc 3 'DiscoveryMovies' 'FAIL' $discover.error $discover.latency_ms))
    }
}
