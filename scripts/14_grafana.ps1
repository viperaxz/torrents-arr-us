param(
    [Parameter(Mandatory=$true)]
    [object]$Config
)

. (Join-Path $PSScriptRoot "debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "14_grafana.ps1 started"

$AppName    = "Grafana"
$InstallDir = $Config.General.InstallDir
$LockFile   = Join-Path $InstallDir ".locks\.grafana.lock"
$DomainMode = $Config.General.DomainMode
$AdminUser  = $Config.General.AdminUsername
$AdminPass  = $Config.General.AdminPassword

if ($Config.Apps.Grafana -ne $true) {
    Write-Host "[$AppName] Disabled in config (Apps.Grafana = false). Skipping." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "Grafana skipped (Apps.Grafana != true)"
    return
}
if (Test-Path $LockFile) {
    Write-Host "[$AppName] Already installed. Skipping." -ForegroundColor Green
    Write-DebugLog "INFO" "Grafana already installed (lock file present)"
    return
}

Write-Host "[$AppName] Installing Grafana + Loki + Alloy..." -ForegroundColor Cyan

$GrafanaDir  = Join-Path $InstallDir "Grafana"
$GrafanaData = Join-Path $InstallDir "Grafana-data"
$LokiDir     = Join-Path $InstallDir "Loki"
$LokiData    = Join-Path $InstallDir "Loki-data"
$AlloyDir  = Join-Path $InstallDir "Alloy"
$AlloyData = Join-Path $InstallDir "Alloy-data"
$BinDir    = Join-Path $PSScriptRoot "..\bin"

$GrafanaPort = 3000
$LokiPort    = 3100

foreach ($d in @($GrafanaDir, $GrafanaData, $LokiDir, $LokiData, $AlloyDir, $AlloyData, $BinDir)) {
    if (-not (Test-Path $d)) { New-Item $d -ItemType Directory -Force | Out-Null }
}

# UTF-8 without BOM -- Grafana and Go YAML parsers reject the BOM preamble
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# -- Phase 1: Grafana ----------------------------------------------------------
# Grafana binaries are on dl.grafana.com (not GitHub releases).
# Strategy: query the Grafana stable API for version number, then probe known
# URL patterns in order -- old zip (pre-v11), new tar.gz (v11+, no build num),
# then the versioned API endpoint that includes the build number in the filename.
Write-Host "  [Grafana] Resolving download URL..." -ForegroundColor Gray

$grafanaVerOverride = if ($Config._Versions -and $Config._Versions.Apps.Grafana -and
                         $Config._Versions.Apps.Grafana.version -ne "latest") {
    ($Config._Versions.Apps.Grafana.version -replace '^v', '')
} else { $null }

try {
    # Get stable version from Grafana API (works regardless of GitHub)
    $grafanaInfo = Invoke-RestMethod "https://grafana.com/api/grafana/versions/stable" `
        -UseBasicParsing -TimeoutSec 30
    $grafanaVer = if ($grafanaVerOverride) { $grafanaVerOverride } else { $grafanaInfo.version }
    Write-DebugLog "INFO" "Grafana stable version=$grafanaVer (API=$($grafanaInfo.version) override=$grafanaVerOverride)"

    # Probe candidate URLs in preference order (zip before tar.gz, OSS before Enterprise)
    $candidates = @(
        "https://dl.grafana.com/oss/release/grafana-$grafanaVer.windows-amd64.zip",
        "https://dl.grafana.com/oss/release/grafana-$grafanaVer.windows-amd64.tar.gz",
        "https://dl.grafana.com/oss/release/grafana-oss-$grafanaVer.windows-amd64.tar.gz",
        "https://dl.grafana.com/oss/release/grafana-oss_${grafanaVer}_windows_amd64.tar.gz"
    )

    # If the Grafana API returned a Windows package URL, prepend it
    if ($grafanaInfo.packages) {
        $winPkg = $grafanaInfo.packages |
            Where-Object { $_.platform -eq "windows" -and $_.arch -eq "amd64" } |
            Select-Object -First 1
        if ($winPkg -and $winPkg.url) {
            $candidates = @($winPkg.url) + $candidates
            Write-DebugLog "VAR Grafana API package URL: $($winPkg.url)"
        }
    }

    $grafanaUrl = $null
    $grafanaFileName = $null
    foreach ($url in $candidates) {
        try {
            # Some CDNs reject HEAD requests; fall back to GET with Range: bytes=0-0
            $probe = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            if ($probe.StatusCode -eq 200) {
                $grafanaUrl      = $url
                $grafanaFileName = $url.Split('/')[-1]
                Write-DebugLog "INFO" "Grafana URL confirmed (HEAD): $grafanaUrl"
                break
            }
        } catch {
            try {
                $probe2 = Invoke-WebRequest -Uri $url -Method Get -UseBasicParsing -TimeoutSec 10 `
                    -Headers @{"Range"="bytes=0-0"} -ErrorAction Stop
                if ($probe2.StatusCode -in @(200, 206)) {
                    $grafanaUrl      = $url
                    $grafanaFileName = $url.Split('/')[-1]
                    Write-DebugLog "INFO" "Grafana URL confirmed (GET range): $grafanaUrl"
                    break
                }
            } catch {}
        }
    }

    if (-not $grafanaUrl) {
        throw "Could not find a working Grafana $grafanaVer Windows download URL. Tried: $($candidates -join '; ')"
    }

    $isZip = $grafanaFileName -like "*.zip"
    $grafanaFile = Join-Path $BinDir $grafanaFileName
    if (-not (Test-Path $grafanaFile)) {
        Write-Host "  [Grafana] Downloading $grafanaVer ($grafanaFileName)..." -ForegroundColor Gray
        Invoke-WebRequest -Uri $grafanaUrl -OutFile $grafanaFile -UseBasicParsing
        Write-DebugLog "INFO" "Grafana downloaded: $grafanaFile ($((Get-Item $grafanaFile).Length) bytes)"
    } else {
        Write-Host "  [Grafana] Using cached $grafanaFileName..." -ForegroundColor Gray
        Write-DebugLog "INFO" "Using cached Grafana: $grafanaFile"
    }

    if (Test-Path $GrafanaDir) { Remove-Item $GrafanaDir -Recurse -Force }
    New-Item $GrafanaDir -ItemType Directory -Force | Out-Null

    if ($isZip) {
        Expand-Archive $grafanaFile $GrafanaDir -Force
    } else {
        # tar.gz -- use Windows built-in tar.exe (available on Windows 10+)
        # tar.exe on Windows emits warnings to stderr on successful extractions;
        # under EAP="Stop" that throws before the exit-code check below can run.
        $savedEAP = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $tarResult = & tar -xzf "$grafanaFile" -C "$GrafanaDir" 2>&1 | Out-String
        } finally {
            $ErrorActionPreference = $savedEAP
        }
        if ($LASTEXITCODE -ne 0) {
            throw "tar extraction failed (exit=$LASTEXITCODE): $tarResult"
        }
        Write-DebugLog "INFO" "tar extraction complete. exit=$LASTEXITCODE"
    }

    # Flatten single-subdirectory layout (grafana-{version}/ wrapping all files)
    $gfTop = Get-ChildItem $GrafanaDir
    if ($gfTop.Count -eq 1 -and $gfTop[0].PSIsContainer) {
        Get-ChildItem $gfTop[0].FullName | Move-Item -Destination $GrafanaDir
        Remove-Item $gfTop[0].FullName -Recurse -Force
    }

    # grafana.exe lives at bin\grafana.exe or bin\grafana-server.exe depending on version
    $grafanaExe = Get-ChildItem (Join-Path $GrafanaDir "bin") -Filter "grafana*.exe" |
        Where-Object { $_.Name -notlike "*cli*" } | Select-Object -First 1
    if (-not $grafanaExe) { throw "grafana.exe not found in bin\ after extraction" }
    $grafanaExe = $grafanaExe.FullName
    Write-Host "  [Grafana] $grafanaVer extracted ($([System.IO.Path]::GetFileName($grafanaExe)))." -ForegroundColor Green
    Write-DebugLog "INFO" "Grafana extracted. exe=$grafanaExe"
} catch {
    Write-Warning "[$AppName] Grafana download/extract failed: $_"
    Write-DebugLog "ERROR" "Grafana download/extract failed: $_"
    exit 1
}

# -- Phase 2: Loki -------------------------------------------------------------
Write-Host "  [Loki] Downloading..." -ForegroundColor Gray

$lokiVer = if ($Config._Versions -and $Config._Versions.Apps.Loki) {
    $Config._Versions.Apps.Loki.version
} else { $null }

$lokiExe  = $null
$alloyExe = $null

try {
    $lokiApiUri = if ($lokiVer) {
        "https://api.github.com/repos/grafana/loki/releases/tags/$lokiVer"
    } else {
        "https://api.github.com/repos/grafana/loki/releases/latest"
    }
    $lokiRelease = Invoke-RestMethod $lokiApiUri -UseBasicParsing -TimeoutSec 30
    $lokiTag     = $lokiRelease.tag_name
    Write-DebugLog "VAR Loki release=$lokiTag"

    $lokiAsset = $lokiRelease.assets |
        Where-Object { $_.name -eq "loki-windows-amd64.exe.zip" } |
        Select-Object -First 1
    if (-not $lokiAsset) { throw "loki-windows-amd64.exe.zip not found in release $lokiTag" }

    $lokiZip = Join-Path $BinDir "loki-$lokiTag-win.zip"
    if (-not (Test-Path $lokiZip)) {
        Write-Host "  [Loki] Downloading $lokiTag..." -ForegroundColor Gray
        Invoke-WebRequest -Uri $lokiAsset.browser_download_url -OutFile $lokiZip -UseBasicParsing
        Write-DebugLog "INFO" "Loki downloaded: $lokiZip"
    }
    Expand-Archive $lokiZip $LokiDir -Force
    $lokiBin = Get-ChildItem $LokiDir -Filter "loki-windows-amd64.exe" | Select-Object -First 1
    if ($lokiBin) { Rename-Item $lokiBin.FullName "loki.exe" -Force }
    $lokiExe = Join-Path $LokiDir "loki.exe"
    if (-not (Test-Path $lokiExe)) { throw "loki.exe not found after extraction" }
    Write-Host "  [Loki] $lokiTag extracted." -ForegroundColor Green
    Write-DebugLog "INFO" "Loki extracted. exe=$lokiExe"
} catch {
    Write-Warning "[$AppName] Loki download failed: $_"
    Write-DebugLog "ERROR" "Loki download failed: $_"
    # Non-fatal: Grafana still works without Loki. Continue to Alloy.
}

# -- Phase 3: Alloy ------------------------------------------------------------
Write-Host "  [Alloy] Downloading..." -ForegroundColor Gray

$alloyVer = if ($Config._Versions -and $Config._Versions.Apps.Alloy) {
    $Config._Versions.Apps.Alloy.version
} else { $null }

try {
    $alloyApiUri = if ($alloyVer) {
        "https://api.github.com/repos/grafana/alloy/releases/tags/$alloyVer"
    } else {
        "https://api.github.com/repos/grafana/alloy/releases/latest"
    }
    $alloyRelease = Invoke-RestMethod $alloyApiUri -UseBasicParsing -TimeoutSec 30
    $alloyTag     = $alloyRelease.tag_name
    Write-DebugLog "VAR Alloy release=$alloyTag"

    $alloyAsset = $alloyRelease.assets |
        Where-Object { $_.name -eq "alloy-windows-amd64.exe.zip" } |
        Select-Object -First 1
    if (-not $alloyAsset) { throw "alloy-windows-amd64.exe.zip not found in release $alloyTag" }

    $alloyZip = Join-Path $BinDir "alloy-$alloyTag-win.zip"
    if (-not (Test-Path $alloyZip)) {
        Invoke-WebRequest -Uri $alloyAsset.browser_download_url -OutFile $alloyZip -UseBasicParsing
        Write-DebugLog "INFO" "Alloy downloaded: $alloyZip"
    }
    Expand-Archive $alloyZip $AlloyDir -Force
    $alBin = Get-ChildItem $AlloyDir -Filter "alloy-windows-amd64.exe" | Select-Object -First 1
    if ($alBin) { Rename-Item $alBin.FullName "alloy.exe" -Force }
    $alloyExe = Join-Path $AlloyDir "alloy.exe"
    if (-not (Test-Path $alloyExe)) { throw "alloy.exe not found after extraction" }
    Write-Host "  [Alloy] $alloyTag extracted." -ForegroundColor Green
    Write-DebugLog "INFO" "Alloy extracted. exe=$alloyExe"
} catch {
    Write-Warning "  [Alloy] Download failed: $_"
    Write-DebugLog "WARN" "Alloy download failed: $_. Log shipping will be unavailable."
}

# -- Phase 4: Loki config ------------------------------------------------------
$SafeLokiData = $LokiData.Replace('\', '/')
$LokiConfig   = Join-Path $LokiDir "loki-config.yml"
$lokiYaml = @"
auth_enabled: false

server:
  http_listen_port: $LokiPort
  grpc_listen_port: 9096
  log_level: warn

common:
  instance_addr: 127.0.0.1
  path_prefix: $SafeLokiData
  storage:
    filesystem:
      chunks_directory: $SafeLokiData/chunks
      rules_directory: $SafeLokiData/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2020-10-24
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  retention_period: 720h
  ingestion_rate_mb: 4
  ingestion_burst_size_mb: 6

compactor:
  working_directory: $SafeLokiData/compactor
  compaction_interval: 10m
  retention_enabled: true
  retention_delete_delay: 2h
  delete_request_store: filesystem

query_range:
  results_cache:
    cache:
      embedded_cache:
        enabled: true
        max_size_mb: 100
"@
[System.IO.File]::WriteAllText($LokiConfig, $lokiYaml, $utf8NoBom)
Write-DebugLog "INFO" "Loki config written to $LokiConfig"

# -- Phase 5: Alloy config -----------------------------------------------------
$SafeInstallDir = $InstallDir.Replace('\', '/')
$AlloyConfig    = Join-Path $AlloyDir "alloy-config.alloy"
$alloyHcl = @"
// Alloy -- Seedbox log shipping to Loki

logging {
  level  = "warn"
  format = "logfmt"
}

loki.write "default" {
  endpoint {
    url = "http://127.0.0.1:$LokiPort/loki/api/v1/push"
  }
}

// Caddy access logs -- JSON/zap, ts is Unix float epoch
loki.source.file "caddy_access" {
  targets = [{
    __path__ = "$SafeInstallDir/logs/caddy-access.log",
    job      = "caddy-access",
    host     = "seedbox",
  }]
  forward_to = [loki.process.caddy_access.receiver]
}
loki.process "caddy_access" {
  stage.json {
    expressions = { level = "level", ts = "ts", status = "status" }
  }
  stage.timestamp {
    source = "ts"
    format = "Unix"
  }
  stage.template {
    source   = "level"
    template = "{{ ToLower .Value }}"
  }
  stage.labels {
    values = { level = "", status = "" }
  }
  forward_to = [loki.write.default.receiver]
}

// Caddy server logs -- JSON/zap, ts is Unix float epoch
loki.source.file "caddy" {
  targets = [{
    __path__ = "$SafeInstallDir/Caddy/caddy.log",
    job      = "caddy",
    host     = "seedbox",
  }]
  forward_to = [loki.process.caddy.receiver]
}
loki.process "caddy" {
  stage.json {
    expressions = { level = "level", ts = "ts", logger = "logger" }
  }
  stage.timestamp {
    source = "ts"
    format = "Unix"
  }
  stage.template {
    source   = "level"
    template = "{{ ToLower .Value }}"
  }
  stage.labels {
    values = { level = "", logger = "" }
  }
  forward_to = [loki.write.default.receiver]
}

// CrowdSec engine -- logrus logfmt: time="..." level=info msg="..."
// This is the detection side: parsed Caddy requests and Windows auth failures.
loki.source.file "crowdsec" {
  targets = [{
    __path__ = "C:/ProgramData/CrowdSec/log/crowdsec.log",
    job      = "crowdsec",
    host     = "seedbox",
  }]
  forward_to = [loki.process.crowdsec.receiver]
}
loki.process "crowdsec" {
  stage.logfmt {
    mapping = { "ts" = "time", "level" = "", "msg" = "" }
  }
  stage.timestamp {
    source = "ts"
    format = "RFC3339"
  }
  stage.labels {
    values = { level = "" }
  }
  forward_to = [loki.write.default.receiver]
}

// CrowdSec firewall bouncer -- pipe-delimited: 2026-08-27 12:03:26.5402|INFO|Api.ApiClient|message
// (log file name uses underscores, not hyphens). This is the enforcement side;
// if it stops shipping logs, decisions are no longer reaching Windows Firewall.
loki.source.file "crowdsec_bouncer" {
  targets = [{
    __path__ = "C:/ProgramData/CrowdSec/log/cs_windows_firewall_bouncer.log",
    job      = "crowdsec-bouncer",
    host     = "seedbox",
  }]
  forward_to = [loki.process.crowdsec_bouncer.receiver]
}
loki.process "crowdsec_bouncer" {
  stage.multiline {
    firstline     = "^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}"
    max_wait_time = "3s"
  }
  stage.regex {
    expression = "^(?P<ts>\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\.\\d+)\\|(?P<level>[^|]+)\\|(?P<component>[^|]+)\\|"
  }
  stage.timestamp {
    source   = "ts"
    format   = "2006-01-02 15:04:05.999999999"
    location = "Local"
  }
  stage.template {
    source   = "level"
    template = "{{ ToLower .Value }}"
  }
  stage.labels {
    values = { level = "", component = "" }
  }
  forward_to = [loki.write.default.receiver]
}

// Deluge daemon -- Deluge 2.x lines look like:
//   HH:MM:SS [WARN ][deluge.ui.web.server :67  ] message
// (no MM/DD date prefix; decolorize strips ANSI codes first)
loki.source.file "deluge" {
  targets = [{
    __path__ = "$SafeInstallDir/Deluge-data/deluged.log",
    job      = "deluge",
    host     = "seedbox",
  }]
  forward_to = [loki.process.deluge.receiver]
}
loki.process "deluge" {
  stage.decolorize {}
  stage.regex {
    expression = "^(?:\\d{2}/\\d{2} )?\\d{2}:\\d{2}:\\d{2}(?:\\.[0-9]+)? \\[(?P<level>[A-Z]+)"
  }
  stage.template {
    source   = "level"
    template = "{{ ToLower .Value }}"
  }
  stage.labels {
    values = { level = "" }
  }
  forward_to = [loki.write.default.receiver]
}

// Deluge Web UI -- same decolorize + regex format as daemon log
loki.source.file "deluge_web" {
  targets = [{
    __path__ = "$SafeInstallDir/Deluge-data/deluge-web.log",
    job      = "deluge-web",
    host     = "seedbox",
  }]
  forward_to = [loki.process.deluge_web.receiver]
}
loki.process "deluge_web" {
  stage.decolorize {}
  stage.regex {
    expression = "^(?:\\d{2}/\\d{2} )?\\d{2}:\\d{2}:\\d{2}(?:\\.[0-9]+)? \\[(?P<level>[A-Z]+)"
  }
  stage.template {
    source   = "level"
    template = "{{ ToLower .Value }}"
  }
  stage.labels {
    values = { level = "" }
  }
  forward_to = [loki.write.default.receiver]
}

// Sonarr -- NLog pipe-delimited: 2026-06-12 17:47:28.9|Debug|QualityParser|message
loki.source.file "sonarr" {
  targets = [{
    __path__ = "C:/ProgramData/Sonarr/logs/sonarr.txt",
    job      = "sonarr",
    host     = "seedbox",
  }]
  forward_to = [loki.process.sonarr.receiver]
}
loki.process "sonarr" {
  stage.multiline {
    firstline     = "^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}"
    max_wait_time = "3s"
  }
  stage.regex {
    expression = "^(?P<ts>\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\.\\d+)\\|(?P<level>[^|]+)\\|(?P<component>[^|]+)\\|"
  }
  stage.timestamp {
    source   = "ts"
    format   = "2006-01-02 15:04:05.999999999"
    location = "Local"
  }
  stage.template {
    source   = "level"
    template = "{{ ToLower .Value }}"
  }
  stage.labels {
    values = { level = "", component = "" }
  }
  forward_to = [loki.write.default.receiver]
}

// Radarr -- same NLog format as Sonarr
loki.source.file "radarr" {
  targets = [{
    __path__ = "C:/ProgramData/Radarr/logs/radarr.txt",
    job      = "radarr",
    host     = "seedbox",
  }]
  forward_to = [loki.process.radarr.receiver]
}
loki.process "radarr" {
  stage.multiline {
    firstline     = "^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}"
    max_wait_time = "3s"
  }
  stage.regex {
    expression = "^(?P<ts>\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\.\\d+)\\|(?P<level>[^|]+)\\|(?P<component>[^|]+)\\|"
  }
  stage.timestamp {
    source   = "ts"
    format   = "2006-01-02 15:04:05.999999999"
    location = "Local"
  }
  stage.template {
    source   = "level"
    template = "{{ ToLower .Value }}"
  }
  stage.labels {
    values = { level = "", component = "" }
  }
  forward_to = [loki.write.default.receiver]
}

// Prowlarr -- same NLog format as Sonarr
loki.source.file "prowlarr" {
  targets = [{
    __path__ = "C:/ProgramData/Prowlarr/logs/prowlarr.txt",
    job      = "prowlarr",
    host     = "seedbox",
  }]
  forward_to = [loki.process.prowlarr.receiver]
}
loki.process "prowlarr" {
  stage.multiline {
    firstline     = "^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}"
    max_wait_time = "3s"
  }
  stage.regex {
    expression = "^(?P<ts>\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\.\\d+)\\|(?P<level>[^|]+)\\|(?P<component>[^|]+)\\|"
  }
  stage.timestamp {
    source   = "ts"
    format   = "2006-01-02 15:04:05.999999999"
    location = "Local"
  }
  stage.template {
    source   = "level"
    template = "{{ ToLower .Value }}"
  }
  stage.labels {
    values = { level = "", component = "" }
  }
  forward_to = [loki.write.default.receiver]
}

// Jellyfin -- Serilog with tz offset: [2026-06-12 17:16:10.212 +03:00] [INF] [9] Source: message
loki.source.file "jellyfin" {
  targets = [{
    __path__ = "C:/ProgramData/Jellyfin/Server/log/jellyfin.log",
    job      = "jellyfin",
    host     = "seedbox",
  }]
  forward_to = [loki.process.jellyfin.receiver]
}
loki.process "jellyfin" {
  stage.multiline {
    firstline     = "^\\["
    max_wait_time = "3s"
  }
  stage.regex {
    expression = "^\\[(?P<ts>\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\.\\d+ [+-]\\d{2}:\\d{2})\\] \\[(?P<level>[A-Z]{3})\\] \\[(?P<thread>[^\\]]+)\\]"
  }
  stage.timestamp {
    source = "ts"
    format = "2006-01-02 15:04:05.999 -07:00"
  }
  stage.template {
    source   = "level"
    template = "{{ if eq .Value \"INF\" }}info{{ else if eq .Value \"WRN\" }}warn{{ else if eq .Value \"ERR\" }}error{{ else if eq .Value \"FTL\" }}fatal{{ else if eq .Value \"DBG\" }}debug{{ else if eq .Value \"TRC\" }}trace{{ else }}{{ ToLower .Value }}{{ end }}"
  }
  stage.labels {
    values = { level = "" }
  }
  forward_to = [loki.write.default.receiver]
}

// Bazarr -- Python logging: 2026-06-12 17:11:34,763 - waitress (54d8) :  INFO (wasyncore:485) - message
// Comma millisecond separator matched with [.,] to avoid stage.replace capture-group issues on Windows.
loki.source.file "bazarr" {
  targets = [{
    __path__ = "C:/ProgramData/Bazarr/bazarr-stderr.log",
    job      = "bazarr",
    host     = "seedbox",
  }]
  forward_to = [loki.process.bazarr.receiver]
}
loki.process "bazarr" {
  stage.regex {
    expression = "^(?P<ts>\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2})[.,]\\d+ - (?P<logger>\\S+)\\s+\\([0-9a-f]+\\) :\\s+(?P<level>[A-Z]+)"
  }
  stage.timestamp {
    source   = "ts"
    format   = "2006-01-02 15:04:05"
    location = "Local"
  }
  stage.template {
    source   = "level"
    template = "{{ if eq .Value \"WARNING\" }}warn{{ else }}{{ ToLower .Value }}{{ end }}"
  }
  stage.labels {
    values = { level = "", logger = "" }
  }
  forward_to = [loki.write.default.receiver]
}

// Bazarr's own log file -- NLog pipe-delimited:
//   2026-08-21 00:23:04|ERROR   |root                            |message|
loki.source.file "bazarr_file" {
  targets = [{
    __path__ = "C:/ProgramData/Bazarr/log/bazarr.log",
    job      = "bazarr",
    host     = "seedbox",
  }]
  forward_to = [loki.process.bazarr_file.receiver]
}
loki.process "bazarr_file" {
  stage.multiline {
    firstline     = "^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}"
    max_wait_time = "3s"
  }
  stage.regex {
    expression = "^(?P<ts>\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2})\\|(?P<level>[^|]+)\\|(?P<component>[^|]+)\\|"
  }
  stage.timestamp {
    source   = "ts"
    format   = "2006-01-02 15:04:05"
    location = "Local"
  }
  stage.template {
    source   = "level"
    template = "{{ ToLower (trim .Value) }}"
  }
  stage.template {
    source   = "component"
    template = "{{ trim .Value }}"
  }
  stage.labels {
    values = { level = "", component = "" }
  }
  forward_to = [loki.write.default.receiver]
}

// FlareSolverr -- Python logging with %-8s level padding:
// 2026-06-12 17:39:46 INFO     Response in 16.034 s
loki.source.file "flaresolverr" {
  targets = [{
    __path__ = "C:/ProgramData/Flaresolverr/flaresolverr-stdout.log",
    job      = "flaresolverr",
    host     = "seedbox",
  }]
  forward_to = [loki.process.flaresolverr.receiver]
}
loki.process "flaresolverr" {
  stage.regex {
    expression = "^(?P<ts>\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}) (?P<level>[A-Z]+)\\s+"
  }
  stage.timestamp {
    source   = "ts"
    format   = "2006-01-02 15:04:05"
    location = "Local"
  }
  stage.template {
    source   = "level"
    template = "{{ if eq .Value \"WARNING\" }}warn{{ else }}{{ ToLower .Value }}{{ end }}"
  }
  stage.labels {
    values = { level = "" }
  }
  forward_to = [loki.write.default.receiver]
}

// Jellyseerr -- Winston with ANSI codes (decolorize first)
// 2026-06-12T14:45:00.016Z [info][Jellyfin Sync]: message
loki.source.file "jellyseerr" {
  targets = [{
    __path__ = "C:/ProgramData/Jellyseerr/jellyseerr-stdout.log",
    job      = "jellyseerr",
    host     = "seedbox",
  }]
  forward_to = [loki.process.jellyseerr.receiver]
}
loki.process "jellyseerr" {
  stage.decolorize {}
  stage.regex {
    expression = "^(?P<ts>\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d+Z) \\[(?P<level>[a-z]+)\\]\\["
  }
  stage.timestamp {
    source = "ts"
    format = "2006-01-02T15:04:05.999Z07:00"
  }
  stage.labels {
    values = { level = "" }
  }
  forward_to = [loki.write.default.receiver]
}
"@
[System.IO.File]::WriteAllText($AlloyConfig, $alloyHcl, $utf8NoBom)
Write-DebugLog "INFO" "Alloy config written to $AlloyConfig"

# Jellyfin logs to a date-rolled file (log_YYYYMMDD.log) by default, which Alloy
# cannot tail via glob on Windows (CreateFile rejects * in paths). Override to a
# fixed filename so Alloy can point to a stable path.
$jellyfinCfgDir = "C:\ProgramData\Jellyfin\Server\config"
if (Test-Path $jellyfinCfgDir) {
    $jellyfinLogging = @'
{
    "Serilog": {
        "MinimumLevel": {
            "Default": "Information",
            "Override": {
                "Microsoft": "Warning",
                "System": "Warning"
            }
        },
        "WriteTo": [
            {
                "Name": "Console",
                "Args": {
                    "outputTemplate": "[{Timestamp:HH:mm:ss}] [{Level:u3}] [{ThreadId}] {SourceContext}: {Message:lj}{NewLine}{Exception}"
                }
            },
            {
                "Name": "Async",
                "Args": {
                    "configure": [
                        {
                            "Name": "File",
                            "Args": {
                                "path": "%JELLYFIN_LOG_DIR%//jellyfin.log",
                                "rollingInterval": "Infinite",
                                "retainedFileCountLimit": 1,
                                "rollOnFileSizeLimit": true,
                                "fileSizeLimitBytes": 100000000,
                                "outputTemplate": "[{Timestamp:yyyy-MM-dd HH:mm:ss.fff zzz}] [{Level:u3}] [{ThreadId}] {SourceContext}: {Message}{NewLine}{Exception}"
                            }
                        }
                    ]
                }
            }
        ],
        "Enrich": [ "FromLogContext", "WithThreadId" ]
    }
}
'@
    $jellyfinLoggingPath = Join-Path $jellyfinCfgDir "logging.json"
    [System.IO.File]::WriteAllText($jellyfinLoggingPath, $jellyfinLogging, $utf8NoBom)
    Write-DebugLog "INFO" "Jellyfin logging.json written -- Jellyfin restart required to activate"
}

# -- Phase 6: Grafana provisioning (Loki data source) -------------------------
# Pre-configure Loki so it shows up on first Grafana start without API calls.
$provisioningDir = Join-Path $GrafanaData "provisioning\datasources"
New-Item $provisioningDir -ItemType Directory -Force | Out-Null
$lokiDsYaml = @"
apiVersion: 1
datasources:
  - name: Loki
    type: loki
    uid: loki-seedbox
    url: http://127.0.0.1:$LokiPort
    access: proxy
    isDefault: true
    editable: true
    jsonData:
      maxLines: 5000
"@
[System.IO.File]::WriteAllText(
    (Join-Path $provisioningDir "loki.yaml"),
    $lokiDsYaml,
    $utf8NoBom
)
Write-DebugLog "INFO" "Grafana Loki provisioning file written"

# -- Phase 6.5: Grafana provisioning (Dashboards) -----------------------------
# Dashboard JSON files live in scripts\grafana-dashboards\ (version-controlled).
# The installer copies them to the Grafana data directory at install time.
$dashboardsProvDir = Join-Path $GrafanaData "provisioning\dashboards"
$dashboardsJsonDir = Join-Path $GrafanaData "dashboards"
$SafeGrafanaData   = $GrafanaData.Replace('\', '/')
New-Item $dashboardsProvDir -ItemType Directory -Force | Out-Null
New-Item $dashboardsJsonDir -ItemType Directory -Force | Out-Null

$dashProvYaml = @"
apiVersion: 1
providers:
  - name: Seedbox
    orgId: 1
    folder: Seedbox
    type: file
    disableDeletion: false
    updateIntervalSeconds: 60
    allowUiUpdates: true
    options:
      path: $SafeGrafanaData/dashboards
"@
[System.IO.File]::WriteAllText(
    (Join-Path $dashboardsProvDir "default.yaml"),
    $dashProvYaml,
    $utf8NoBom
)

# Copy all dashboard JSON files from the source directory (version-controlled)
Get-ChildItem (Join-Path $PSScriptRoot "grafana-dashboards") -Filter "*.json" | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $dashboardsJsonDir $_.Name) -Force
}
Write-DebugLog "INFO" "Grafana dashboards copied from grafana-dashboards\ to $dashboardsJsonDir"


# -- Phase 7: NSSM services ----------------------------------------------------
Write-Host "  -> Registering Windows services..." -ForegroundColor Gray

$grafanaRootUrl = if ($DomainMode -eq "cloudflare") {
    "https://grafana.$($Config.General.Domain)"
} else {
    "https://$($Config.General.DuckDnsDomain)/grafana"
}
$serveSubPath = if ($DomainMode -eq "duckdns") { "true" } else { "false" }
Write-DebugLog "VAR grafanaRootUrl=$grafanaRootUrl serveSubPath=$serveSubPath"

# Loki
if (-not (Get-Service "Loki" -ErrorAction SilentlyContinue)) {
    nssm install Loki "`"$lokiExe`"" | Out-Null
    nssm set Loki AppParameters "--config.file=`"$LokiConfig`"" | Out-Null
    nssm set Loki AppDirectory $LokiDir | Out-Null
    nssm set Loki Description "Loki - Log aggregation backend (win-seedbox)" | Out-Null
    nssm set Loki Start SERVICE_AUTO_START | Out-Null
    nssm set Loki AppStdout (Join-Path $LokiDir "loki.log") | Out-Null
    nssm set Loki AppStderr (Join-Path $LokiDir "loki.log") | Out-Null
    nssm set Loki ObjectName LocalSystem | Out-Null
    nssm set Loki AppExit Default Restart | Out-Null
    nssm set Loki AppRestartDelay 5000 | Out-Null
    Write-DebugLog "INFO" "Loki NSSM service created"
}

# Alloy
if ($alloyExe -and -not (Get-Service "Alloy" -ErrorAction SilentlyContinue)) {
    nssm install Alloy "`"$alloyExe`"" | Out-Null
    nssm set Alloy AppParameters "run `"$AlloyConfig`" --storage.path=`"$AlloyData`" --server.http.listen-addr=127.0.0.1:12345" | Out-Null
    nssm set Alloy AppDirectory $AlloyDir | Out-Null
    nssm set Alloy Description "Alloy - Log shipper for Loki (win-seedbox)" | Out-Null
    nssm set Alloy Start SERVICE_AUTO_START | Out-Null
    nssm set Alloy AppStdout (Join-Path $AlloyDir "alloy.log") | Out-Null
    nssm set Alloy AppStderr (Join-Path $AlloyDir "alloy.log") | Out-Null
    nssm set Alloy ObjectName LocalSystem | Out-Null
    nssm set Alloy AppExit Default Restart | Out-Null
    nssm set Alloy AppRestartDelay 5000 | Out-Null
    Write-DebugLog "INFO" "Alloy NSSM service created"
}

# Grafana
if (-not (Get-Service "Grafana" -ErrorAction SilentlyContinue)) {
    New-Item (Join-Path $GrafanaData "logs") -ItemType Directory -Force | Out-Null
    New-Item (Join-Path $GrafanaData "plugins") -ItemType Directory -Force | Out-Null
    # Grafana v10+ uses unified CLI: grafana.exe server (no separate grafana-server.exe)
    nssm install Grafana "`"$grafanaExe`"" | Out-Null
    nssm set Grafana AppParameters "server" | Out-Null
    nssm set Grafana AppDirectory (Join-Path $GrafanaDir "bin") | Out-Null
    nssm set Grafana Description "Grafana - Observability dashboard (win-seedbox)" | Out-Null
    nssm set Grafana Start SERVICE_AUTO_START | Out-Null
    nssm set Grafana AppStdout (Join-Path $GrafanaData "logs\grafana.log") | Out-Null
    nssm set Grafana AppStderr (Join-Path $GrafanaData "logs\grafana.log") | Out-Null
    nssm set Grafana ObjectName LocalSystem | Out-Null
    $grafanaEnv = @(
        "set", "Grafana", "AppEnvironmentExtra",
        "GF_SERVER_HTTP_PORT=$GrafanaPort",
        "GF_SERVER_ROOT_URL=$grafanaRootUrl",
        "GF_SERVER_SERVE_FROM_SUB_PATH=$serveSubPath",
        "GF_PATHS_DATA=$GrafanaData",
        "GF_PATHS_LOGS=$GrafanaData\logs",
        "GF_PATHS_PLUGINS=$GrafanaData\plugins",
        "GF_PATHS_PROVISIONING=$GrafanaData\provisioning",
        "GF_SECURITY_ADMIN_USER=$AdminUser",
        "GF_SECURITY_ADMIN_PASSWORD=$AdminPass",
        "GF_AUTH_ANONYMOUS_ENABLED=false",
        "GF_ANALYTICS_REPORTING_ENABLED=false",
        "GF_ANALYTICS_CHECK_FOR_UPDATES=false",
        "GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false"
    )
    & nssm @grafanaEnv | Out-Null
    nssm set Grafana AppExit Default Restart | Out-Null
    nssm set Grafana AppRestartDelay 5000 | Out-Null
    Write-DebugLog "INFO" "Grafana NSSM service created. rootUrl=$grafanaRootUrl"
}

# Start all three in order: Loki first (Alloy needs it), then Grafana
foreach ($svcName in @("Loki", "Alloy", "Grafana")) {
    $svc = Get-Service $svcName -ErrorAction SilentlyContinue
    if ($svc) {
        Start-Service $svcName -ErrorAction SilentlyContinue
        Write-DebugLog "INFO" "Started service: $svcName"
    }
}

# Wait up to 60s for Grafana API
Write-Host "  -> Waiting for Grafana to start (up to 60s)..." -ForegroundColor DarkGray
$grafanaReady = $false
$deadline     = (Get-Date).AddSeconds(60)
while (-not $grafanaReady -and (Get-Date) -lt $deadline) {
    try {
        Invoke-RestMethod "http://127.0.0.1:$GrafanaPort/api/health" `
            -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop | Out-Null
        $grafanaReady = $true
    } catch { Start-Sleep -Seconds 3 }
}
Write-DebugLog "VAR Grafana API ready=$grafanaReady"

$svcGrafana = Get-Service "Grafana" -ErrorAction SilentlyContinue
if ($svcGrafana -and $svcGrafana.Status -eq "Running") {
    Write-Host "  -> Grafana running on port $GrafanaPort." -ForegroundColor Green
} else {
    Write-Host "  -> Grafana may not have started. Check $GrafanaData\logs\grafana.log" -ForegroundColor Yellow
}
Write-DebugLog "VAR Grafana service status=$(if ($svcGrafana) { $svcGrafana.Status } else { 'NOT FOUND' })"

# -- Phase 8: Patch Caddyfile --------------------------------------------------
Write-Host "  -> Patching Caddyfile..." -ForegroundColor Gray
$caddyExe      = (Get-Command caddy.exe -ErrorAction SilentlyContinue).Source
$CaddyfilePath = Join-Path $InstallDir "Caddy\Caddyfile"

if ((Test-Path $CaddyfilePath) -and $caddyExe) {
    $caddyContent = Get-Content $CaddyfilePath -Raw -Encoding UTF8
    $grafanaAdded = $false

    if ($DomainMode -eq "cloudflare") {
        $Domain = $Config.General.Domain
        if ($caddyContent -notmatch "grafana\.$([regex]::Escape($Domain))") {
            $TlsMode = $Config.General.TlsMode
            $TlsLine = switch ($TlsMode) {
                "internal"            { "    tls internal" }
                "letsencrypt"         { "    tls $($Config.General.TlsEmail)" }
                "letsencrypt-staging" { "    tls $($Config.General.TlsEmail) {`n        ca https://acme-staging-v02.api.letsencrypt.org/directory`n    }" }
                default               { "    tls internal" }
            }
            $safeDir = $InstallDir.Replace('\', '/')
            $grafanaBlock = "`n# Grafana`ngrafana.$Domain {`n$TlsLine`n    log {`n        output file `"$safeDir/logs/caddy-access.log`" {`n            roll_size 10mb`n            roll_keep 3`n        }`n        format json`n    }`n    reverse_proxy 127.0.0.1:$GrafanaPort`n}`n"
            $caddyContent += $grafanaBlock
            $grafanaAdded = $true
            Write-DebugLog "INFO" "Grafana subdomain block appended (cloudflare mode)"
        }
    } else {
        # DuckDNS: insert handle /grafana* before the dashboard catch-all
        if ($caddyContent -notmatch "handle /grafana\*") {
            $grafanaHandle = "    handle /grafana* {`n        reverse_proxy 127.0.0.1:$GrafanaPort`n    }`n`n"
            if ($caddyContent -match "# Dashboard at root") {
                $caddyContent = $caddyContent -replace "(?m)([\t ]*# Dashboard at root)", ($grafanaHandle + '$1')
            } else {
                # Fallback: insert before the final handle { (dashboard catch-all)
                $caddyContent = [regex]::Replace(
                    $caddyContent,
                    "(?ms)([\t ]+handle \{[\s\S]*?basic_auth[\s\S]*?file_server[\s\S]*?\}[\s\S]*?\})\s*$",
                    "`n" + $grafanaHandle + '$1' + "`n"
                )
            }
            $grafanaAdded = $true
            Write-DebugLog "INFO" "Grafana handle inserted (duckdns mode)"
        }
    }

    if ($grafanaAdded) {
        # BOM-free -- parsed by Caddy (Go), see 01_webserver.ps1.
        [System.IO.File]::WriteAllText($CaddyfilePath, $caddyContent, (New-Object System.Text.UTF8Encoding($false)))
        try { & $caddyExe fmt --overwrite $CaddyfilePath 2>&1 | Out-Null } catch {}
        try { & $caddyExe reload --config $CaddyfilePath 2>&1 | Out-Null } catch {}
        Write-Host "  -> Caddyfile updated and reloaded." -ForegroundColor Green
        Write-DebugLog "INFO" "Caddy reloaded with Grafana route"
    } else {
        Write-DebugLog "INFO" "Grafana route already present in Caddyfile - skipping"
    }
} else {
    Write-Warning "  -> Caddyfile not found or caddy.exe unavailable. Add Grafana route manually."
    Write-DebugLog "WARN" "Caddyfile not found at $CaddyfilePath or caddy.exe missing"
}

# -- Phase 9: Add grafana subdomain to Cloudflare DNS updater -----------------
if ($DomainMode -eq "cloudflare") {
    $updaterPath = Join-Path $InstallDir "Update-CloudflareDNS.ps1"
    if (Test-Path $updaterPath) {
        $updaterContent = Get-Content $updaterPath -Raw -Encoding UTF8
        if ($updaterContent -notmatch '"grafana"') {
            $updaterContent = [regex]::Replace(
                $updaterContent,
                '(\$Subdomains\s*=\s*@\([^)]+)',
                '$1,"grafana"'
            )
            Set-Content $updaterPath $updaterContent -Encoding UTF8
            Write-Host "  -> grafana subdomain added to Cloudflare DNS updater." -ForegroundColor Green
            Write-DebugLog "INFO" "grafana added to Cloudflare DNS updater subdomains"

            # Run an immediate DNS update so grafana resolves right away
            Write-Host "  -> Running immediate DNS update for grafana..." -ForegroundColor DarkGray
            try {
                $prevEap = $ErrorActionPreference
                $ErrorActionPreference = "Continue"
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updaterPath 2>&1 | Out-Null
                $ErrorActionPreference = $prevEap
                Write-DebugLog "INFO" "Immediate DNS update for grafana triggered"
            } catch {
                Write-DebugLog "WARN" "Immediate DNS update for grafana failed (will retry on schedule): $_"
            }
        }
    }
}

# -- Write lock file -----------------------------------------------------------
[System.IO.File]::WriteAllText($LockFile, "installed", $utf8NoBom)
Write-DebugLog "INFO" "14_grafana.ps1 complete. Lock: $LockFile"

# Ledger entries for the updater (single source of truth for versions)
if (-not (Get-Command Set-InstalledVersion -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "update_common.ps1")
}
if ($grafanaVer) { Set-InstalledVersion -InstallDir $InstallDir -AppName "Grafana" -Version $grafanaVer }
if ($lokiTag)    { Set-InstalledVersion -InstallDir $InstallDir -AppName "Loki" -Version $lokiTag }
if ($alloyTag)   { Set-InstalledVersion -InstallDir $InstallDir -AppName "Alloy" -Version $alloyTag }
Write-Host "[$AppName] Done." -ForegroundColor Cyan
$grafanaUrl = if ($DomainMode -eq "cloudflare") {
    "https://grafana.$($Config.General.Domain)"
} else {
    "https://$($Config.General.DuckDnsDomain)/grafana"
}
Write-Host "  -> Grafana UI: $grafanaUrl" -ForegroundColor Green
Write-Host "  -> Login with admin credentials from config.json" -ForegroundColor DarkGray
Write-Host "  -> Loki is pre-configured as default data source." -ForegroundColor DarkGray
exit 0
