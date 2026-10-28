# collect_status.ps1 -- collects server stats and writes current_status.json to the dashboard dir.
# Run by the Seedbox_Status_Collector scheduled task every 5 minutes as SYSTEM.
# Reads config.json from the project root (parent of $PSScriptRoot).
# Writes to $InstallDir\dashboard\current_status.json -- served statically by Caddy.
# Persists per-service health state in $InstallDir\.locks\health_state.json.
# Pushes per-service metrics to Loki when Apps.Grafana = true.
# No credentials or secrets are written to any output file.

$ErrorActionPreference = 'SilentlyContinue'

$configPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'config.json'
if (-not (Test-Path $configPath)) { Write-Error "config.json not found at $configPath"; exit 1 }
$Config      = Get-Content $configPath -Raw | ConvertFrom-Json
$InstallDir  = $Config.General.InstallDir
# Fail loudly instead of silently doing nothing: with a null InstallDir every
# path below is relative and every write fails, yet the script still exits 0 --
# the scheduled task would look healthy while the dashboard froze forever.
if (-not $Config -or -not $Config.General -or [string]::IsNullOrWhiteSpace([string]$InstallDir)) {
    Write-Error "config.json at $configPath has no General.InstallDir -- cannot locate the dashboard directory"
    exit 1
}
$OutputPath  = Join-Path $InstallDir 'dashboard\current_status.json'
$StatePath   = Join-Path $InstallDir '.locks\health_state.json'
$DomainMode  = $Config.General.DomainMode

# -- Helpers -------------------------------------------------------------------
function QuickGet {
    param([string]$Uri, [hashtable]$H = @{}, [int]$Sec = 5, [switch]$JsonOnly)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r      = Invoke-WebRequest $Uri -Headers $H -UseBasicParsing -TimeoutSec $Sec -ErrorAction Stop
        $isJson = ([string]($r.Headers['Content-Type'] -join ';')) -match 'json'
        # Every *arr / Bazarr / Grafana instance answers an unknown path with its
        # own SPA: HTTP 200 + text/html.  A wrong UrlBase (or a base_url that never
        # persisted) therefore used to read as "API OK", and Invoke-RestMethod handed
        # that HTML back as a single string, so the media cards counted one "movie".
        # Probes that hit a JSON API pass -JsonOnly; Zurg and Loki legitimately
        # answer HTML/text and do not.
        if ($JsonOnly -and -not $isJson) {
            $sw.Stop()
            return [PSCustomObject]@{ ok=$false; ms=[int]$sw.ElapsedMilliseconds; data=$null }
        }
        $data = if ($isJson -and $r.Content) { $r.Content | ConvertFrom-Json } else { $r.Content }
        $sw.Stop()
        return [PSCustomObject]@{ ok=$true;  ms=[int]$sw.ElapsedMilliseconds; data=$data }
    } catch { $sw.Stop(); return [PSCustomObject]@{ ok=$false; ms=[int]$sw.ElapsedMilliseconds; data=$null } }
}

function QuickRpc {
    param([string]$Url, [string]$Json, [int]$Ms = 5000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $bytes  = [System.Text.Encoding]::UTF8.GetBytes($Json)
        $req    = [System.Net.WebRequest]::Create($Url)
        $req.Method = 'POST'; $req.ContentType = 'application/json'; $req.Timeout = $Ms
        $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
        $rd = New-Object System.IO.StreamReader($req.GetResponse().GetResponseStream())
        $body = $rd.ReadToEnd(); $rd.Close()
        $sw.Stop()
        return [PSCustomObject]@{ ok=$true; ms=[int]$sw.ElapsedMilliseconds; data=($body | ConvertFrom-Json) }
    } catch { $sw.Stop(); return [PSCustomObject]@{ ok=$false; ms=[int]$sw.ElapsedMilliseconds; data=$null } }
}

# Deluge Web UI JSON-RPC with cookie persistence.  auth.login sets a session
# cookie that every later call must carry -- QuickRpc drops cookies, so Deluge
# needs its own caller with a shared CookieContainer.
$script:delugeCookies = New-Object System.Net.CookieContainer
function QuickDelugeRpc {
    param([string]$Url, [string]$Json, [int]$Ms = 8000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $bytes  = [System.Text.Encoding]::UTF8.GetBytes($Json)
        $req    = [System.Net.WebRequest]::Create($Url)
        $req.Method = 'POST'; $req.ContentType = 'application/json'; $req.Timeout = $Ms
        $req.CookieContainer = $script:delugeCookies
        $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
        $rd = New-Object System.IO.StreamReader($req.GetResponse().GetResponseStream())
        $body = $rd.ReadToEnd(); $rd.Close()
        $sw.Stop()
        return [PSCustomObject]@{ ok=$true; ms=[int]$sw.ElapsedMilliseconds; data=($body | ConvertFrom-Json) }
    } catch { $sw.Stop(); return [PSCustomObject]@{ ok=$false; ms=[int]$sw.ElapsedMilliseconds; data=$null } }
}

function TcpOpen { param([int]$Port)
    try {
        $t = New-Object System.Net.Sockets.TcpClient
        $a = $t.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $a.AsyncWaitHandle.WaitOne(1500)
        if ($ok -and $t.Connected) { $t.EndConnect($a); $t.Close(); return $true }
        $t.Close(); return $false
    } catch { return $false }
}

function XmlKey { param([string]$p)
    try { return ([xml](Get-Content $p -ErrorAction Stop)).Config.ApiKey } catch { return $null }
}

function BazarrKey { param([string]$p = 'C:\ProgramData\Bazarr\config\config.yaml')
    try {
        $y = Get-Content $p -Raw -ErrorAction Stop
        if ($y -match '(?m)^\s*apikey\s*:\s*["'']?([^"''\r\n]+)["'']?') { return $Matches[1].Trim() }
    } catch {}
    return $null
}

function UBase { param([string]$app)
    if ($DomainMode -eq 'duckdns') { return "/$($app.ToLower())" } else { return '' }
}

# -- Load persisted health state -----------------------------------------------
$hs = @{}
if (Test-Path $StatePath) {
    try {
        $raw = Get-Content $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($raw) { $raw.PSObject.Properties | ForEach-Object { $hs[$_.Name] = $_.Value } }
    } catch {}
}

function GetState { param([string]$n)
    # A hand-edited or partially written health_state.json can carry a null entry;
    # treat that like a missing one instead of returning $null to SetState.
    if (-not $hs.ContainsKey($n) -or $null -eq $hs[$n]) {
        $hs[$n] = [PSCustomObject]@{ consecutive_ok=0; last_ok=$null; last_fail=$null }
    }
    return $hs[$n]
}

function SetState { param([string]$n, [bool]$ok)
    $now = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    $s   = GetState $n
    if ($ok) { $s.consecutive_ok++; $s.last_ok = $now }
    else      { $s.consecutive_ok = 0; $s.last_fail = $now }
    $hs[$n] = $s
}

function SvcEntry {
    param([string]$Name, [string]$DisplayName, [bool]$PortOpen, [bool]$ApiOk, [int]$LatencyMs, [hashtable]$Extra = @{})
    $s = GetState $DisplayName
    SetState $DisplayName $ApiOk
    $e = [ordered]@{
        name             = $DisplayName
        state            = if ($svc = Get-Service $Name -ErrorAction SilentlyContinue) { $svc.Status.ToString() } else { $null }
        port_open        = $PortOpen
        api_ok           = $ApiOk
        api_latency_ms   = $LatencyMs
        consecutive_ok   = (GetState $DisplayName).consecutive_ok
        last_ok          = (GetState $DisplayName).last_ok
        last_fail        = (GetState $DisplayName).last_fail
    }
    foreach ($k in $Extra.Keys) { $e[$k] = $Extra[$k] }
    return $e
}

# -- Collect per-service health ------------------------------------------------
$svcs = [System.Collections.Generic.List[object]]::new()

# Pre-load API keys (used across sections)
$sonarrKey   = XmlKey 'C:\ProgramData\Sonarr\config.xml'
$radarrKey   = XmlKey 'C:\ProgramData\Radarr\config.xml'
$prowlarrKey = XmlKey 'C:\ProgramData\Prowlarr\config.xml'
$bazarrKey   = BazarrKey

$sonarrPort   = $Config.Ports.Sonarr
$radarrPort   = $Config.Ports.Radarr
$prowlarrPort = $Config.Ports.Prowlarr
$jellyfinPort = $Config.Ports.Jellyfin
$delugePort   = $Config.Ports.Deluge
$bazarrPort   = $Config.Ports.Bazarr
$fsPort       = $Config.Ports.Flaresolverr
$jsePort      = $Config.Ports.Jellyseerr

# Caddy
$caddyPort80  = TcpOpen 80
$caddyPort443 = TcpOpen 443
$caddyApiOk   = $caddyPort443
SetState 'Caddy' $caddyApiOk
$cState = GetState 'Caddy'
$svcs.Add([ordered]@{
    name           = 'Caddy'
    state          = if ($sv = Get-Service 'Caddy' -ErrorAction SilentlyContinue) { $sv.Status.ToString() } else { $null }
    port_open      = $caddyPort80
    port_443_open  = $caddyPort443
    api_ok         = $caddyApiOk
    api_latency_ms = 0
    consecutive_ok = $cState.consecutive_ok
    last_ok        = $cState.last_ok
    last_fail      = $cState.last_fail
})

# Jellyfin
# DuckDNS mode runs Jellyfin with BaseUrl=/jellyfin in network.xml, so every API
# path lives under that prefix -- probe the prefixed path like every other app
# (UBase).  Without it Jellyfin answers with a 302 to the web client, which
# Invoke-WebRequest follows happily: the health check then reports a false "up"
# unless the JSON content type is enforced (-JsonOnly).
$jPort  = TcpOpen $jellyfinPort
$jBase  = UBase 'jellyfin'
$jCheck = QuickGet "http://127.0.0.1:$jellyfinPort${jBase}/System/Info/Public" @{} 5 -JsonOnly
$svcs.Add((SvcEntry 'JellyfinServer' 'Jellyfin' $jPort $jCheck.ok $jCheck.ms))

# Sonarr
if ($sonarrKey) {
    $sPort  = TcpOpen $sonarrPort
    $sBase  = UBase 'sonarr'
    $sCheck = QuickGet "http://127.0.0.1:$sonarrPort${sBase}/api/v3/system/status" @{'X-Api-Key'=$sonarrKey} 5 -JsonOnly
    $sQueue = QuickGet "http://127.0.0.1:$sonarrPort${sBase}/api/v3/queue/status"  @{'X-Api-Key'=$sonarrKey} 5 -JsonOnly
    $sWant  = QuickGet "http://127.0.0.1:$sonarrPort${sBase}/api/v3/wanted/missing?pageSize=1" @{'X-Api-Key'=$sonarrKey} 5 -JsonOnly
    $svcs.Add((SvcEntry 'Sonarr' 'Sonarr' $sPort $sCheck.ok $sCheck.ms @{
        queue_count  = if ($sQueue.ok) { [int]$sQueue.data.totalCount } else { $null }
        wanted_count = if ($sWant.ok  -and $sWant.data.totalRecords) { [int]$sWant.data.totalRecords } else { $null }
    }))
}

# Radarr
if ($radarrKey) {
    $rPort  = TcpOpen $radarrPort
    $rBase  = UBase 'radarr'
    $rCheck = QuickGet "http://127.0.0.1:$radarrPort${rBase}/api/v3/system/status" @{'X-Api-Key'=$radarrKey} 5 -JsonOnly
    $rQueue = QuickGet "http://127.0.0.1:$radarrPort${rBase}/api/v3/queue/status"  @{'X-Api-Key'=$radarrKey} 5 -JsonOnly
    $svcs.Add((SvcEntry 'Radarr' 'Radarr' $rPort $rCheck.ok $rCheck.ms @{
        queue_count = if ($rQueue.ok) { [int]$rQueue.data.totalCount } else { $null }
    }))
}

# Prowlarr
if ($prowlarrKey) {
    $pPort   = TcpOpen $prowlarrPort
    $pBase   = UBase 'prowlarr'
    $pCheck  = QuickGet "http://127.0.0.1:$prowlarrPort${pBase}/api/v1/system/status" @{'X-Api-Key'=$prowlarrKey} 5 -JsonOnly
    $pIdxRaw = QuickGet "http://127.0.0.1:$prowlarrPort${pBase}/api/v1/indexer" @{'X-Api-Key'=$prowlarrKey} 5 -JsonOnly
    $enabledIdx = 0; $failedIdx = 0
    if ($pIdxRaw.ok -and $pIdxRaw.data) {
        $enabledIdx = @($pIdxRaw.data | Where-Object { $_.enable -eq $true }).Count
        $failedIdx  = @($pIdxRaw.data | Where-Object { $_.enable -eq $true -and $_.status -and $_.status.disabledTill }).Count
    }
    $svcs.Add((SvcEntry 'Prowlarr' 'Prowlarr' $pPort $pCheck.ok $pCheck.ms @{
        indexers_enabled = $enabledIdx
        indexers_failed  = $failedIdx
    }))
}

# Deluge (shared data reused in downloads section below)
# Skipped entirely when Apps.Deluge is disabled: the probe would otherwise add two
# permanently-red rows to the status panel for an app the installer never installed.
$delugeEnabled   = ($Config.Apps.Deluge -ne $false)
$delugeAuthPath  = Join-Path $InstallDir 'secrets\deluge_auth.txt'
$delugePassword  = $null
$delugeLoggedIn  = $false
$delugeWebPort   = $Config.Ports.DelugeWeb
if (Test-Path $delugeAuthPath) {
    $delugePassword = ([System.IO.File]::ReadAllText($delugeAuthPath, [System.Text.Encoding]::UTF8)).TrimStart([char]0xFEFF).Trim()
}
$delugePortOpen = TcpOpen $delugePort
$delugeWebOpen  = TcpOpen $delugeWebPort
# The Web UI JSON-RPC exposes auth.login + web.update_ui.  web.update_ui returns
# exactly what the Web UI renders: session stats and per-torrent status, so the
# dashboard shows the same numbers a browser session would see.
$dlStats  = $null
$dlCounts = @{ total = 0; downloading = 0; seeding = 0; paused = 0; active = 0 }
$dlItems  = @()
if ($delugePassword -and $delugeWebOpen) {
    $delugeRpc       = "http://127.0.0.1:$delugeWebPort/json"
    $delugeLoginBody = @{ method = "auth.login"; params = @($delugePassword); id = 1 } | ConvertTo-Json -Compress
    $delugeLogin     = QuickDelugeRpc $delugeRpc $delugeLoginBody
    $delugeLoggedIn  = ($delugeLogin.ok -and $delugeLogin.data.result -eq $true)
    if ($delugeLoggedIn) {
        $uiBody = @{
            method = "web.update_ui"
            params = @(
                @('name','state','progress','download_payload_rate','upload_payload_rate','total_done','total_size','eta','ratio'),
                @{}
            )
            id = 2
        } | ConvertTo-Json -Depth 5 -Compress
        $ui = QuickDelugeRpc $delugeRpc $uiBody 12000
        if ($ui.ok -and $ui.data.result) {
            $dlStats = $ui.data.result
            if ($dlStats.torrents) {
                foreach ($tp in $dlStats.torrents.PSObject.Properties) {
                    $t = $tp.Value
                    $dlCounts.total++
                    if ($t.state -eq 'Downloading')       { $dlCounts.downloading++; $dlCounts.active++ }
                    elseif ($t.state -eq 'Seeding')       { $dlCounts.seeding++;     $dlCounts.active++ }
                    elseif ($t.state -eq 'Paused')        { $dlCounts.paused++ }
                    if ($t.state -eq 'Downloading') {
                        $dlItems += [pscustomobject]@{
                            name     = [string]$t.name
                            progress = [math]::Round([double]$t.progress, 1)
                        }
                    }
                }
                $dlItems = @($dlItems | Sort-Object progress -Descending | Select-Object -First 6)
            }
        }
    }
    $svcs.Add((SvcEntry 'DelugeDaemon' 'Deluge Daemon' $delugePortOpen $delugeLoggedIn $delugeLogin.ms @{
        active_downloads    = $dlCounts.downloading
        waiting_downloads   = $dlCounts.paused
        download_speed_mbps = if ($dlStats) { [math]::Round([double]$dlStats.stats.download_rate / 1MB, 3) } else { $null }
        upload_speed_mbps   = if ($dlStats) { [math]::Round([double]$dlStats.stats.upload_rate / 1MB, 3) } else { $null }
    }))
} elseif ($delugeEnabled) {
    # No stored Web UI password (or the Web UI port is closed): the daemon entry
    # still has to report the daemon's own port, not a hardcoded $false, or a
    # healthy daemon shows up as "port closed" and resets its consecutive_ok.
    $svcs.Add((SvcEntry 'DelugeDaemon' 'Deluge Daemon' $delugePortOpen $false 0))
}

# Deluge Web UI (separate entry -- serves the browser interface)
$delugeWebOk = $false
if ($delugeWebOpen) {
    if ($delugeLoggedIn) {
        # auth.login above already round-tripped through the Web UI's JSON-RPC.
        # Fetching "/" re-renders the index, and the Windows build logs two
        # "WebUI falling back to debug mode" warnings on every render (its
        # pre-built "normal" mode scripts are absent) -- 576 lines a day in Loki.
        $delugeWebOk = $true
    } else {
        try {
            # GET /json is answered with 405 without rendering the UI; any HTTP
            # response still proves the web server is serving.
            $null = Invoke-WebRequest "http://127.0.0.1:$delugeWebPort/json" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            $delugeWebOk = $true
        } catch {
            $delugeWebOk = [bool]($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 405)
        }
    }
}
if ($delugeEnabled) {
    $svcs.Add((SvcEntry 'DelugeWeb' 'Deluge Web UI' $delugeWebOpen $delugeWebOk 0))
}

# Bazarr
if ($bazarrKey) {
    $bPort  = TcpOpen $bazarrPort
    $bBase  = UBase 'bazarr'
    $bCheck = QuickGet "http://127.0.0.1:$bazarrPort${bBase}/api/system/ping" @{'X-Api-Key'=$bazarrKey} 5 -JsonOnly
    # Bazarr exposes the wanted-subtitle counters on /api/badges (episodes/movies).
    # /api/wanted/episode and /api/wanted/movie do not exist: Bazarr answers them
    # with its SPA (200 + text/html), so the old probes returned null forever.
    $bBadges = QuickGet "http://127.0.0.1:$bazarrPort${bBase}/api/badges" @{'X-Api-Key'=$bazarrKey} 5 -JsonOnly
    $svcs.Add((SvcEntry 'Bazarr' 'Bazarr' $bPort $bCheck.ok $bCheck.ms @{
        wanted_episodes = if ($bBadges.ok -and $null -ne $bBadges.data.episodes) { [int]$bBadges.data.episodes } else { $null }
        wanted_movies   = if ($bBadges.ok -and $null -ne $bBadges.data.movies)   { [int]$bBadges.data.movies }   else { $null }
    }))
}

# Flaresolverr
if ($Config.Apps.Flaresolverr -eq $true) {
    $fsOpen  = TcpOpen $fsPort
    $fsCheck = QuickGet "http://127.0.0.1:$fsPort/"
    $svcs.Add((SvcEntry 'Flaresolverr' 'Flaresolverr' $fsOpen $fsCheck.ok $fsCheck.ms))
}

# Jellyseerr
if ($Config.Apps.Jellyseerr -eq $true) {
    # Jellyseerr has no basePath/urlBase support: the Caddyfile routes
    # /jellyseerr* with handle_path, which STRIPS the prefix before proxying, and
    # the browser asks for /api* and /_next* at the domain root.  A direct probe
    # therefore must NOT carry the DuckDNS prefix -- /jellyseerr/api/v1/status
    # 404s and the dashboard would report Jellyseerr as down in DuckDNS mode.
    $jseOpen  = TcpOpen $jsePort
    $jseCheck = QuickGet "http://127.0.0.1:$jsePort/api/v1/status" @{} 5 -JsonOnly
    $svcs.Add((SvcEntry 'Jellyseerr' 'Jellyseerr' $jseOpen $jseCheck.ok $jseCheck.ms))
}

# Grafana / Loki / Alloy
if ($Config.Apps.Grafana -eq $true) {
    # DuckDNS mode runs Grafana with serve_from_sub_path=true, so its API lives
    # under /grafana -- probe the prefixed path like every other app (UBase).
    $gfBase  = UBase 'grafana'
    $gfCheck = QuickGet "http://127.0.0.1:3000${gfBase}/api/health" @{} 5 -JsonOnly
    $svcs.Add((SvcEntry 'Grafana' 'Grafana' (TcpOpen 3000) $gfCheck.ok $gfCheck.ms))
    $lokiCheck = QuickGet 'http://127.0.0.1:3100/ready'
    $svcs.Add((SvcEntry 'Loki' 'Loki' (TcpOpen 3100) $lokiCheck.ok $lokiCheck.ms))
    $alloyState = if ($sv = Get-Service 'Alloy' -ErrorAction SilentlyContinue) { $sv.Status.ToString() } else { $null }
    $alloyOk    = ($alloyState -eq 'Running')
    SetState 'Alloy' $alloyOk
    $aSt = GetState 'Alloy'
    $svcs.Add([ordered]@{
        name = 'Alloy'; state = $alloyState; port_open = $null; api_ok = $alloyOk; api_latency_ms = 0
        consecutive_ok = $aSt.consecutive_ok; last_ok = $aSt.last_ok; last_fail = $aSt.last_fail
    })
}

# Zurg / rclone
if ($Config.Apps.RealDebrid -eq $true) {
    $zurgCheck = QuickGet 'http://127.0.0.1:9999/'
    $svcs.Add((SvcEntry 'Zurg' 'Zurg' (TcpOpen 9999) $zurgCheck.ok $zurgCheck.ms))

    # Mounts since the Zurg movies/shows split (zurg:movies, zurg:shows), plus the
    # optional zurg:anime mount that holds absolute-numbered anime packs.
    $mountSpecs = @(
        @{ Svc = 'rclone-rd-movies'; Key = 'MountLetter';   Default = 'R' },
        @{ Svc = 'rclone-rd-shows';  Key = 'TvMountLetter'; Default = 'S' }
    )
    $animeEnabled = [bool]($Config.Anime -and $Config.Anime.PSObject.Properties['Enabled'] -and $Config.Anime.Enabled -eq $true -and
                           $Config.Anime.PSObject.Properties['Sources'] -and @($Config.Anime.Sources).Count -gt 0)
    if ($animeEnabled -and (Get-Service -Name 'rclone-rd-anime' -ErrorAction SilentlyContinue)) {
        $animeLetter = if ($Config.Anime.PSObject.Properties['MountLetter'] -and $Config.Anime.MountLetter) {
            $Config.Anime.MountLetter.ToString().ToUpper().TrimEnd(':')
        } else { 'T' }
        $mountSpecs += @{ Svc = 'rclone-rd-anime'; Explicit = $animeLetter }
    }
    foreach ($ms in $mountSpecs) {
        $letter = if ($ms.ContainsKey('Explicit')) { $ms.Explicit }
                  elseif ($Config.RealDebrid -and $Config.RealDebrid.PSObject.Properties[$ms.Key] -and $Config.RealDebrid.($ms.Key)) {
                      $Config.RealDebrid.($ms.Key).ToString().ToUpper().TrimEnd(':')
                  } else { $ms.Default }
        $drive   = "$letter`:"
        $mounted = Test-Path "$letter`:\"
        SetState $ms.Svc $mounted
        $st = GetState $ms.Svc
        $svcs.Add([ordered]@{
            name = $ms.Svc; state = if ($sv = Get-Service $ms.Svc -ErrorAction SilentlyContinue) { $sv.Status.ToString() } else { $null }
            port_open = $null; api_ok = $mounted; api_latency_ms = 0
            drive = $drive; drive_mounted = $mounted
            consecutive_ok = $st.consecutive_ok; last_ok = $st.last_ok; last_fail = $st.last_fail
        })
    }
}

# Local LLM backend (optional, externally managed -- never installed by this project)
if ($Config.LLM -and $Config.LLM.PSObject.Properties["Enabled"] -and $Config.LLM.Enabled -eq $true) {
    $llmPort  = if ($Config.LLM.PSObject.Properties["BackendPort"] -and $Config.LLM.BackendPort) { [int]$Config.LLM.BackendPort } else { 8081 }
    $llmOpen  = TcpOpen $llmPort
    $llmCheck = QuickGet "http://127.0.0.1:$llmPort/health"
    $svcs.Add((SvcEntry 'LLM' 'Local LLM' $llmOpen $llmCheck.ok $llmCheck.ms))
}

# -- System --------------------------------------------------------------------
$status = [ordered]@{
    # UTC with an explicit Z: the dashboard runs timeSince() in the browser, and a
    # bare "yyyy-MM-ddTHH:mm:ss" is parsed as the *browser's* local time, so a phone
    # in another timezone showed a wrong (sometimes negative) "updated X ago".
    timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    system    = [ordered]@{}
    drives    = @()
    services  = $svcs.ToArray()
    media     = [ordered]@{}
    downloads = [ordered]@{}
    security  = [ordered]@{}
}

try {
    $os      = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $uptimeH = [math]::Round(($os.LocalDateTime - $os.LastBootUpTime).TotalHours, 1)
    $memUsed = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 1)
    $memTot  = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $status.system = [ordered]@{
        uptime_hours    = $uptimeH
        memory_used_gb  = $memUsed
        memory_total_gb = $memTot
        memory_percent  = if ($memTot -gt 0) { [int]($memUsed / $memTot * 100) } else { 0 }
    }
} catch { $status.system = [ordered]@{ error = 'unavailable' } }

# -- Drives --------------------------------------------------------------------
$drives = [System.Collections.Generic.List[object]]::new()
Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
    Where-Object { $_.Root -match '^[A-Z]:\\$' -and $_.Used -ne $null } |
    ForEach-Object {
        $total = $_.Used + $_.Free
        if ($total -gt 0) {
            $drives.Add([ordered]@{
                drive        = $_.Root
                free_gb      = [math]::Round($_.Free  / 1GB, 1)
                used_gb      = [math]::Round($_.Used  / 1GB, 1)
                total_gb     = [math]::Round($total   / 1GB, 1)
                percent_used = [int]($_.Used / $total * 100)
            })
        }
    }
$status.drives = $drives.ToArray()

# -- Media: Jellyfin (the real library, including Real-Debrid movies) ---------
# The Jellyfin API key is stored by Jellyseerr during Layer 2 wiring, so the
# collector reads it from Jellyseerr's settings instead of logging in every run.
$status.media.jellyfin = $null
try {
    # Key source 1: Jellyseerr stores the Jellyfin API key it generated in its own
    # settings.json (jellyfin.apiKey).  Key source 2: the Seedbox-Integration key
    # the installer writes to secrets\jellyfin_api_key.txt (the file the test
    # modules read too) -- used when Jellyseerr is disabled or not yet wired up.
    $jfKey      = $null
    $jfSettings = 'C:\ProgramData\Jellyseerr\settings.json'
    if (Test-Path $jfSettings) {
        # Jellyseerr rewrites settings.json at runtime, so a half-written file must
        # not abort the whole block -- the secrets\jellyfin_api_key.txt fallback
        # below is still usable.
        try {
            $js = Get-Content $jfSettings -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($js.jellyfin -and $js.jellyfin.apiKey) { $jfKey = ([string]$js.jellyfin.apiKey).Trim() }
        } catch {}
    }
    if (-not $jfKey) {
        $jfKeyFile = Join-Path $InstallDir 'secrets\jellyfin_api_key.txt'
        if (Test-Path $jfKeyFile) {
            $jfKey = ([System.IO.File]::ReadAllText($jfKeyFile, [System.Text.Encoding]::UTF8)).TrimStart([char]0xFEFF).Trim()
        }
    }
    if ($jfKey) {
        # Same BaseUrl prefix as the health probe above -- without it Jellyfin
        # 302s to the web client, the body comes back as HTML and the library
        # card reads 0 movies / 0 series / 0 episodes.
        #
        # The key must travel in the Authorization header: Jellyfin answers 401
        # for X-MediaBrowser-Token, with an API key as well as a user token
        # (measured on a live server). Sending it the old way left this card
        # reading zero without any error surfacing.
        $jfBase   = UBase 'jellyfin'
        $jfClient = 'MediaBrowser Client="seedbox-status", Device="collector", DeviceId="seedbox-status", Version="1.0.0"'
        # -JsonOnly: with the wrong BaseUrl Jellyfin redirects to the web client and
        # the HTML body used to be read as "0 movies / 0 series / 0 episodes".
        $jfRes    = QuickGet "http://127.0.0.1:$jellyfinPort${jfBase}/Items/Counts" @{ 'Authorization' = ($jfClient + ', Token="' + $jfKey + '"') } 10 -JsonOnly
        if ($jfRes.ok -and $jfRes.data) {
            $jfCounts = $jfRes.data
            $status.media.jellyfin = [ordered]@{
                movies   = [int]$jfCounts.MovieCount
                series   = [int]$jfCounts.SeriesCount
                episodes = [int]$jfCounts.EpisodeCount
            }
        }
    }
} catch { $status.media.jellyfin = $null }

# -- Media: Radarr -------------------------------------------------------------
# NOTE: Invoke-WebRequest returns a scalar PSCustomObject for a 1-element JSON
# array, and .Count on a scalar PSCustomObject is $null in PS 5.1 -- always
# normalize through @() before counting (the old code returned null when exactly
# one movie matched hasFile, which rendered as '--' on the dashboard).
try {
    $rBase   = UBase 'radarr'
    $rMovies = QuickGet "http://127.0.0.1:$radarrPort${rBase}/api/v3/movie" @{'X-Api-Key'=$radarrKey} 10 -JsonOnly
    if ($rMovies.ok) {
        $movies = if ($null -eq $rMovies.data) { @() } else { @($rMovies.data) }
        $status.media.movies_total      = $movies.Count
        $status.media.movies_downloaded = @($movies | Where-Object { $_.hasFile }).Count
    } else {
        $status.media.movies_total = $null; $status.media.movies_downloaded = $null
    }
} catch { $status.media.movies_total = $null; $status.media.movies_downloaded = $null }

# -- Media: Sonarr -------------------------------------------------------------
try {
    $sBase   = UBase 'sonarr'
    $rSeries = QuickGet "http://127.0.0.1:$sonarrPort${sBase}/api/v3/series" @{'X-Api-Key'=$sonarrKey} 10 -JsonOnly
    if ($rSeries.ok) {
        $series = if ($null -eq $rSeries.data) { @() } else { @($rSeries.data) }
        $status.media.series_total        = $series.Count
        $status.media.episodes_total      = [int](($series | ForEach-Object { $_.statistics.totalEpisodeCount } | Measure-Object -Sum).Sum)
        $status.media.episodes_downloaded = [int](($series | ForEach-Object { $_.statistics.episodeFileCount  } | Measure-Object -Sum).Sum)
    } else {
        $status.media.series_total = $null; $status.media.episodes_total = $null; $status.media.episodes_downloaded = $null
    }
} catch { $status.media.series_total = $null; $status.media.episodes_total = $null; $status.media.episodes_downloaded = $null }

# -- Downloads: Deluge (live session stats from web.update_ui) -----------------
if ($dlStats) {
    $status.downloads = [ordered]@{
        total_torrents      = $dlCounts.total
        downloading         = $dlCounts.downloading
        seeding             = $dlCounts.seeding
        paused              = $dlCounts.paused
        active              = $dlCounts.active
        download_speed_mbps = [math]::Round([double]$dlStats.stats.download_rate / 1MB, 2)
        upload_speed_mbps   = [math]::Round([double]$dlStats.stats.upload_rate / 1MB, 2)
        incoming_ok         = ([int]$dlStats.stats.has_incoming_connections -eq 1)
        active_items        = $dlItems
    }
} elseif ($delugePassword -and $delugeLoggedIn) {
    $status.downloads = [ordered]@{ active = $null; error = 'Deluge session failed' }
} else {
    $status.downloads = [ordered]@{ active = $null; error = $(if ($delugeEnabled) { 'Deluge unavailable' } else { 'Deluge disabled in config' }) }
}

# -- Security ------------------------------------------------------------------
try {
    $csCli = 'C:\Program Files\CrowdSec\cscli.exe'

    $csSvc  = Get-Service 'crowdsec' -ErrorAction SilentlyContinue
    $bncSvc = Get-Service 'cs-windows-firewall-bouncer' -ErrorAction SilentlyContinue
    $status.security.crowdsec_running = ($null -ne $csSvc  -and $csSvc.Status  -eq 'Running')
    $status.security.bouncer_running  = ($null -ne $bncSvc -and $bncSvc.Status -eq 'Running')

    if (Test-Path $csCli) {
        # Active bans: each alert carries one or more decisions.
        $decRaw = & $csCli decisions list -o json 2>$null | Out-String
        $decRaw = $decRaw.Trim()
        if ($decRaw -and $decRaw -ne 'null') {
            $alerts  = @($decRaw | ConvertFrom-Json)
            $banCount = 0
            foreach ($a in $alerts) { if ($a.decisions) { $banCount += @($a.decisions).Count } }
            $status.security.crowdsec_active_bans = $banCount
        } else {
            $status.security.crowdsec_active_bans = 0
        }

        # Total alerts raised (all alerts held in the local DB, no time filter).
        # -l 0 lifts the default 50-row limit.
        $alertRaw = (& $csCli alerts list -o json -l 0 2>$null | Out-String).Trim()
        $status.security.crowdsec_total_alerts =
            if ($alertRaw -and $alertRaw -ne 'null') { @($alertRaw | ConvertFrom-Json).Count } else { 0 }

        # Alerts raised in the last 24h.
        $alert24Raw = (& $csCli alerts list -o json --since 24h 2>$null | Out-String).Trim()
        $status.security.crowdsec_alerts_24h =
            if ($alert24Raw -and $alert24Raw -ne 'null') { @($alert24Raw | ConvertFrom-Json).Count } else { 0 }
    } else {
        $status.security.crowdsec_active_bans  = $null
        $status.security.crowdsec_total_alerts = $null
        $status.security.crowdsec_alerts_24h   = $null
    }
} catch {
    $status.security.crowdsec_active_bans  = $null
    $status.security.crowdsec_total_alerts = $null
    $status.security.crowdsec_alerts_24h   = $null
}

# Abuse blocklist: presence of the firewall rules + state written by
# update_blocklists.ps1 (sources, CIDR count, last successful update).
try {
    $blStatePath = Join-Path $InstallDir 'dashboard\blocklist_state.json'
    $blState = $null
    if (Test-Path $blStatePath) {
        try { $blState = Get-Content $blStatePath -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $blState = $null }
    }
    $blRules = @(Get-NetFirewallRule -DisplayName 'Seedbox-Abuse-Blocklist*' -ErrorAction SilentlyContinue)
    $status.security.blocklist_active  = ($blRules.Count -gt 0)
    $status.security.blocklist_rules   = $blRules.Count
    $status.security.blocklist_sources = if ($blState -and $blState.sources) { [string]$blState.sources } elseif ($blRules.Count -gt 0) { 'Spamhaus DROP + Firehol level-1' } else { $null }
    $status.security.blocklist_cidrs   = if ($blState -and $null -ne $blState.cidr_count) { [int]$blState.cidr_count } else { $null }
    $status.security.blocklist_updated = if ($blState -and $blState.updated) { [string]$blState.updated } else { $null }
} catch { $status.security.blocklist_active = $null }

# -- Push metrics to Loki (only when Grafana stack is enabled) -----------------
if ($Config.Apps.Grafana -eq $true) {
    try {
        $nowNs   = [string]([long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) * 1000000)
        $streams = @($status.services | ForEach-Object {
            $svc = $_
            $fields = [ordered]@{
                api_ok         = $svc.api_ok
                api_latency_ms = $svc.api_latency_ms
                port_open      = $svc.port_open
                consecutive_ok = $svc.consecutive_ok
            }
            foreach ($k in $svc.Keys) {
                if ($k -notin @('name','state','api_ok','api_latency_ms','port_open','consecutive_ok','last_ok','last_fail')) {
                    $fields[$k] = $svc[$k]
                }
            }
            @{
                stream = @{ job = 'health-check'; service = $svc.name }
                values = @(,@($nowNs, ($fields | ConvertTo-Json -Compress)))
            }
        })
        # CrowdSec counters (authoritative, straight from the local DB) so the
        # Grafana CrowdSec panel shows the same numbers as the dashboard.
        $secFields = [ordered]@{
            crowdsec_total_alerts = if ($null -eq $status.security.crowdsec_total_alerts) { 0 } else { [int]$status.security.crowdsec_total_alerts }
            crowdsec_alerts_24h   = if ($null -eq $status.security.crowdsec_alerts_24h)   { 0 } else { [int]$status.security.crowdsec_alerts_24h }
            crowdsec_active_bans  = if ($null -eq $status.security.crowdsec_active_bans)  { 0 } else { [int]$status.security.crowdsec_active_bans }
            blocklist_active      = if ($status.security.blocklist_active -eq $true) { 1 } else { 0 }
        }
        $streams += @{
            stream = @{ job = 'health-check'; service = 'CrowdSec' }
            values = @(,@($nowNs, ($secFields | ConvertTo-Json -Compress)))
        }
        $body = @{ streams = $streams } | ConvertTo-Json -Depth 6 -Compress
        Invoke-RestMethod 'http://127.0.0.1:3100/loki/api/v1/push' -Method Post -Body $body `
            -ContentType 'application/json' -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop | Out-Null
    } catch {}
}

# -- Persist health state -------------------------------------------------------
# WriteAllText does not create the parent directory, so make sure .locks exists
# (the very first run can happen before -- or without -- the installer's
# .locks dir); otherwise the state file is never written and consecutive_ok /
# last_ok / last_fail stay empty forever.
try {
    $stateDir = Split-Path $StatePath -Parent
    if (-not (Test-Path $stateDir)) { New-Item $stateDir -ItemType Directory -Force | Out-Null }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($StatePath, ($hs | ConvertTo-Json -Depth 4), $utf8NoBom)
} catch {}

# -- Write output JSON ---------------------------------------------------------
$dir = Split-Path $OutputPath -Parent
if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutputPath, ($status | ConvertTo-Json -Depth 6), $utf8NoBom)
