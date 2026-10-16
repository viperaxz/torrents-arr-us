# tests/Test-Bazarr.ps1 -- Bazarr subtitle manager test module

param([int]$LayerFilter = 0)

$svc    = 'Bazarr'
$port   = $Config.Ports.Bazarr
$base   = Get-AppUrlBase 'bazarr' $Config.General.DomainMode
$apiKey = Get-BazarrApiKey
$log    = 'C:\ProgramData\Bazarr\log\bazarr.log'
$hdr    = if ($apiKey) { @{'X-Api-Key'=$apiKey} } else { @{} }

# -- Layer 1: Health -----------------------------------------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 1) {
    $pos = Get-LogPosition $log
    $t0  = Get-Date

    $portOk = Test-TcpPort $port
    $Script:Results.Add((New-TestResult $svc 1 'PortOpen' $(if ($portOk) { 'PASS' } else { 'FAIL' }) "TCP :$port"))

    if (-not $apiKey) {
        $Script:Results.Add((New-TestResult $svc 1 'ApiKeyFound' 'FAIL' 'Cannot read config.yaml'))
    } else {
        $ping = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/system/ping" $hdr -TimeoutSec 8
        $Script:Results.Add((New-TestResult $svc 1 'ApiPing' $(if ($ping.ok) { 'PASS' } else { 'FAIL' }) $ping.error $ping.latency_ms))
    }

    $nssm = Get-Service 'Bazarr' -ErrorAction SilentlyContinue
    $Script:Results.Add((New-TestResult $svc 1 'ServiceRunning' $(if ($nssm -and $nssm.Status -eq 'Running') { 'PASS' } else { 'FAIL' }) 'NSSM service state'))

    Get-LogValidationResult $svc 1 $log $pos 'bazarr' $t0 $Script:LokiEnabled
}

# -- Layer 2: Sonarr + Radarr connections healthy, providers + language profiles -
if (($LayerFilter -eq 0 -or $LayerFilter -eq 2) -and $apiKey) {
    # Sonarr + Radarr connectivity via /api/badges (sonarr_signalr / radarr_signalr)
    $badges = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/badges" $hdr -TimeoutSec 8
    if ($badges.ok) {
        $Script:Results.Add((New-TestResult $svc 2 'SonarrConnection' $(if ($badges.data.sonarr_signalr -eq 'LIVE') { 'PASS' } else { 'WARN' }) "Bazarr-Sonarr signalr=$($badges.data.sonarr_signalr)"))
        $Script:Results.Add((New-TestResult $svc 2 'RadarrConnection' $(if ($badges.data.radarr_signalr -eq 'LIVE') { 'PASS' } else { 'WARN' }) "Bazarr-Radarr signalr=$($badges.data.radarr_signalr)"))

        # wanted-subtitle queue: Bazarr only exposes these counters once the
        # Sonarr/Radarr index has been listed (Layer 2 wiring).
        if ($null -ne $badges.data.episodes -and $null -ne $badges.data.movies) {
            $Script:Results.Add((New-TestResult $svc 2 'WantedQueue' 'PASS' "$($badges.data.episodes) episode(s) / $($badges.data.movies) movie(s) awaiting subtitles"))
        } else {
            $Script:Results.Add((New-TestResult $svc 2 'WantedQueue' 'WARN' 'badges response carries no wanted-subtitle counters'))
        }
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'SonarrConnection' 'FAIL' $badges.error))
        $Script:Results.Add((New-TestResult $svc 2 'RadarrConnection'  'FAIL' $badges.error))
        $Script:Results.Add((New-TestResult $svc 2 'WantedQueue'      'FAIL' $badges.error))
    }

    # Bazarr must reach Sonarr/Radarr through the same URL base the browsers use
    # (/sonarr, /radarr in DuckDNS mode): a stale prefix breaks every library
    # sync even while SignalR reports the connection as live.
    $settings = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/system/settings" $hdr -TimeoutSec 8
    if ($settings.ok) {
        foreach ($pair in @(@{ App = 'Sonarr'; Expected = (Get-AppUrlBase 'sonarr' $Config.General.DomainMode) },
                            @{ App = 'Radarr'; Expected = (Get-AppUrlBase 'radarr' $Config.General.DomainMode) })) {
            $section = $settings.data.($pair.App.ToLower())
            $actual  = if ($section -and $section.PSObject.Properties['base_url']) { [string]$section.base_url } else { '<missing>' }
            $Script:Results.Add((New-TestResult $svc 2 "$($pair.App)BaseUrl" `
                $(if ($actual -eq $pair.Expected) { 'PASS' } else { 'WARN' }) `
                "Bazarr->$($pair.App) base_url='$actual' (expected '$($pair.Expected)')"))
        }
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'SonarrBaseUrl' 'FAIL' $settings.error))
        $Script:Results.Add((New-TestResult $svc 2 'RadarrBaseUrl' 'FAIL' $settings.error))
    }

    # /api/providers returns only enabled providers (no 'enabled' field; presence = enabled)
    $providers = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/providers" $hdr -TimeoutSec 8
    if ($providers.ok) {
        $enabledCount = @($providers.data.data).Count
        $Script:Results.Add((New-TestResult $svc 2 'ProvidersEnabled' $(if ($enabledCount -gt 0) { 'PASS' } else { 'WARN' }) "$enabledCount subtitle provider(s) enabled"))
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'ProvidersEnabled' 'FAIL' $providers.error))
    }

    # Language profiles live at /api/system/languages/profiles (not /api/languages/profiles)
    $langPro = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/system/languages/profiles" $hdr -TimeoutSec 8
    if ($langPro.ok) {
        # @() on the already-materialised property (never around the
        # Invoke-RestMethod call itself, which collapses the array on PS 5.1)
        # yields a correct count for 0, 1 and many profiles.
        $profileCount = @($langPro.data).Count
        $Script:Results.Add((New-TestResult $svc 2 'LanguageProfiles' $(if ($profileCount -gt 0) { 'PASS' } else { 'WARN' }) "$profileCount language profile(s) defined"))
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'LanguageProfiles' 'FAIL' $langPro.error))
    }
}

# -- Layer 3: Provider credentials valid --------------------------------------
if (($LayerFilter -eq 0 -or $LayerFilter -eq 3) -and $apiKey) {
    $providers = Invoke-ApiCheck "http://127.0.0.1:$port${base}/api/providers" $hdr -TimeoutSec 8
    if (-not $providers.ok) {
        $Script:Results.Add((New-TestResult $svc 3 'ProviderCredentials' 'FAIL' $providers.error))
    } else {
        # All returned providers are enabled; status field is a string ('Good' = healthy)
        $failed = @($providers.data.data | Where-Object { $_.status -and $_.status -ne 'Good' })
        if ($failed.Count -gt 0) {
            $Script:Results.Add((New-TestResult $svc 3 'ProviderCredentials' 'WARN' "$($failed.Count) provider(s) not Good: $($failed[0].name) ($($failed[0].status))"))
        } else {
            $Script:Results.Add((New-TestResult $svc 3 'ProviderCredentials' 'PASS' "$(@($providers.data.data).Count) provider(s) all Good"))
        }
    }
}
