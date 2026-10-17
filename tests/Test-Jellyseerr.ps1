# tests/Test-Jellyseerr.ps1 -- Jellyseerr media request portal test module

param([int]$LayerFilter = 0)

$svc  = 'Jellyseerr'
$port = $Config.Ports.Jellyseerr
# NOTE: Jellyseerr has no basePath/urlBase support, so every direct API call below
# targets /api/v1/... at the root of the port -- adding the "/jellyseerr" Caddy
# prefix here would 404. The prefix exists only in the Caddyfile (DuckDNS mode).

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

    $status = Invoke-ApiCheck "http://127.0.0.1:$port/api/v1/status" -TimeoutSec 8
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
if ($LayerFilter -eq 0 -or $LayerFilter -eq 2) {
    if (-not $apiKey) {
        $Script:Results.Add((New-TestResult $svc 2 'JellyfinConfigured' 'SKIP' 'No API key at secrets\jellyseerr_api_key.txt (re-run configure_layer1_jellyseerr.ps1)'))
        $Script:Results.Add((New-TestResult $svc 2 'SonarrLinked' 'SKIP' 'No Jellyseerr API key'))
        $Script:Results.Add((New-TestResult $svc 2 'RadarrLinked' 'SKIP' 'No Jellyseerr API key'))
        $Script:Results.Add((New-TestResult $svc 2 'UsersImported' 'SKIP' 'No Jellyseerr API key'))
    } else {
        # The Jellyfin connection is not part of /settings/main -- it lives in
        # /settings/jellyfin (ip/port/urlBase), which is what has to carry the
        # /jellyfin prefix in DuckDNS mode.
        $jfSettings = Invoke-ApiCheck "http://127.0.0.1:$port/api/v1/settings/jellyfin" $hdr -TimeoutSec 8
        $expectedBase = if ($Config.General.DomainMode -eq 'duckdns') { '/jellyfin' } else { '' }
        if ($jfSettings.ok) {
            $actualBase = [string]$jfSettings.data.urlBase
            $jfOk = [bool]($jfSettings.data.ip -and $jfSettings.data.port)
            if ($expectedBase -and $actualBase.TrimEnd('/') -ne $expectedBase) { $jfOk = $false }
            $detail = "Jellyfin $($jfSettings.data.ip):$($jfSettings.data.port)$actualBase"
            if (-not $jfOk -and $expectedBase) { $detail = "Jellyfin urlBase expected '$expectedBase', got '$actualBase'" }
            $Script:Results.Add((New-TestResult $svc 2 'JellyfinConfigured' $(if ($jfOk) { 'PASS' } else { 'FAIL' }) $detail))
        } else {
            $Script:Results.Add((New-TestResult $svc 2 'JellyfinConfigured' 'FAIL' $jfSettings.error))
        }

        $settings = Invoke-ApiCheck "http://127.0.0.1:$port/api/v1/settings/main" $hdr -TimeoutSec 8
        if ($settings.ok) {
            # DuckDNS serves Jellyseerr from the site root (no basePath support), so the
            # published applicationUrl has no /jellyseerr prefix.
            $expectedUrl = if ($Config.General.DomainMode -eq 'duckdns') { "https://$($Config.General.DuckDnsDomain)" } else { "https://jellyseerr.$($Config.General.Domain)" }
            $actualUrl   = [string]$settings.data.applicationUrl
            $Script:Results.Add((New-TestResult $svc 2 'ApplicationUrl' $(if ($actualUrl.TrimEnd('/') -eq $expectedUrl) { 'PASS' } else { 'FAIL' }) "applicationUrl='$actualUrl' (expected '$expectedUrl')"))
        } else {
            $Script:Results.Add((New-TestResult $svc 2 'ApplicationUrl' 'FAIL' $settings.error))
        }

        # Prefix quirk: in DuckDNS mode Sonarr/Radarr answer only on /sonarr and
        # /radarr, and Jellyseerr stores that prefix in DVRSettings.baseUrl -- the
        # `urlBase` field is ignored by the server.  Counting instances alone let a
        # connection without a prefix pass this test, so baseUrl is asserted too.
        $expectedSonarrBase = if ($Config.General.DomainMode -eq 'duckdns') { '/sonarr' } else { '' }
        $services = Invoke-ApiCheck "http://127.0.0.1:$port/api/v1/settings/sonarr" $hdr -TimeoutSec 8
        if ($services.ok) {
            $sonarrInstances = @(@($services.data) | Where-Object { $null -ne $_ })
            if ($sonarrInstances.Count -eq 0) {
                $Script:Results.Add((New-TestResult $svc 2 'SonarrLinked' 'FAIL' '0 Sonarr instance(s) in Jellyseerr'))
            } else {
                $defaultSonarr = $sonarrInstances | Where-Object { $_.isDefault } | Select-Object -First 1
                if (-not $defaultSonarr) { $defaultSonarr = $sonarrInstances[0] }
                $sonarrBase = [string]$defaultSonarr.baseUrl
                $sonarrOk   = $true
                $sonarrMsg  = "$($sonarrInstances.Count) Sonarr instance(s), baseUrl='$sonarrBase'"
                if ($expectedSonarrBase -and $sonarrBase.TrimEnd('/') -ne $expectedSonarrBase) {
                    $sonarrOk  = $false
                    $sonarrMsg = "Sonarr baseUrl expected '$expectedSonarrBase', got '$sonarrBase'"
                }
                $Script:Results.Add((New-TestResult $svc 2 'SonarrLinked' $(if ($sonarrOk) { 'PASS' } else { 'FAIL' }) $sonarrMsg))
            }
        } else {
            $Script:Results.Add((New-TestResult $svc 2 'SonarrLinked' 'FAIL' $services.error))
        }

        $expectedRadarrBase = if ($Config.General.DomainMode -eq 'duckdns') { '/radarr' } else { '' }
        $radarrSvc = Invoke-ApiCheck "http://127.0.0.1:$port/api/v1/settings/radarr" $hdr -TimeoutSec 8
        if ($radarrSvc.ok) {
            $radarrInstances = @(@($radarrSvc.data) | Where-Object { $null -ne $_ })
            if ($radarrInstances.Count -eq 0) {
                $Script:Results.Add((New-TestResult $svc 2 'RadarrLinked' 'FAIL' '0 Radarr instance(s) in Jellyseerr'))
            } else {
                $defaultRadarr = $radarrInstances | Where-Object { $_.isDefault } | Select-Object -First 1
                if (-not $defaultRadarr) { $defaultRadarr = $radarrInstances[0] }
                $radarrBase = [string]$defaultRadarr.baseUrl
                $radarrOk   = $true
                $radarrMsg  = "$($radarrInstances.Count) Radarr instance(s), baseUrl='$radarrBase'"
                if ($expectedRadarrBase -and $radarrBase.TrimEnd('/') -ne $expectedRadarrBase) {
                    $radarrOk  = $false
                    $radarrMsg = "Radarr baseUrl expected '$expectedRadarrBase', got '$radarrBase'"
                }
                $Script:Results.Add((New-TestResult $svc 2 'RadarrLinked' $(if ($radarrOk) { 'PASS' } else { 'FAIL' }) $radarrMsg))
            }
        } else {
            $Script:Results.Add((New-TestResult $svc 2 'RadarrLinked' 'FAIL' $radarrSvc.error))
        }

        $users = Invoke-ApiCheck "http://127.0.0.1:$port/api/v1/user" $hdr -TimeoutSec 8
        if ($users.ok) {
            $total = if ($users.data.results) { $users.data.results.Count } elseif ($users.data -is [array]) { $users.data.Count } else { 0 }
            $Script:Results.Add((New-TestResult $svc 2 'UsersImported' $(if ($total -gt 0) { 'PASS' } else { 'WARN' }) "$total user(s) in Jellyseerr"))
        } else {
            $Script:Results.Add((New-TestResult $svc 2 'UsersImported' 'FAIL' $users.error))
        }
    }
}

# -- Layer 3: Discovery page browse -------------------------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 3) {
    if (-not $apiKey) {
        $Script:Results.Add((New-TestResult $svc 3 'DiscoveryMovies' 'SKIP' 'No Jellyseerr API key'))
    } else {
        $discover = Invoke-ApiCheck "http://127.0.0.1:$port/api/v1/discover/movies?page=1" $hdr -TimeoutSec 15
        if ($discover.ok) {
            $count = if ($discover.data.results) { $discover.data.results.Count } else { 0 }
            $Script:Results.Add((New-TestResult $svc 3 'DiscoveryMovies' $(if ($count -gt 0) { 'PASS' } else { 'WARN' }) "$count movie(s) on discover page" $discover.latency_ms))
        } else {
            $Script:Results.Add((New-TestResult $svc 3 'DiscoveryMovies' 'FAIL' $discover.error $discover.latency_ms))
        }
    }
}
