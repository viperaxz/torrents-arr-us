param(
    [object]$Config = $null
)

if (-not $Config) {
    $configPath = Join-Path $PSScriptRoot "..\config.json"
    if (-not (Test-Path $configPath)) {
        Write-Error "config.json not found."
        exit 1
    }
    $Config = Get-Content -Raw -Path $configPath | ConvertFrom-Json
}

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "configure_layer2_bazarr.ps1 started"

$AppName    = "Bazarr"
$Port       = $Config.Ports.Bazarr
$DomainMode = $Config.General.DomainMode
$DataDir    = "C:\ProgramData\$AppName"
$ConfigFile = Join-Path $DataDir "config\config.yaml"

$BaseUrl = if ($DomainMode -eq "duckdns") { "/bazarr" } else { "" }
$ApiBase = "http://127.0.0.1:$Port$BaseUrl"

Write-DebugLog "VAR AppName=$AppName Port=$Port DomainMode=$DomainMode"
Write-DebugLog "VAR BaseUrl=$BaseUrl ApiBase=$ApiBase ConfigFile=$ConfigFile"

if ($Config.Apps.Bazarr -ne $true) {
    Write-Host "[$AppName] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "$AppName skipped (not enabled)"
    return
}

Write-Host "[$AppName] Configuring application integration..." -ForegroundColor Cyan

# -- helpers -------------------------------------------------------------------
function Get-YamlKey {
    param([string]$Path, [string]$Section, [string]$Key)
    $inSection = $false
    foreach ($line in Get-Content $Path -ErrorAction SilentlyContinue) {
        if ($line -match "^$([regex]::Escape($Section)):") { $inSection = $true; continue }
        if ($line -match "^\S" -and $line -notmatch "^---") { $inSection = $false }
        if ($inSection -and $line -match "^\s{2}$([regex]::Escape($Key)):\s*(.*)$") {
            return $matches[1].Trim()
        }
    }
    return $null
}

function Invoke-BazarrSettings {
    param([string[]]$FormParts)
    $body = $FormParts -join "&"
    Write-DebugLog "INFO" "POST bazarr settings ($($FormParts.Count) fields)"
    Invoke-RestMethod -Uri "$ApiBase/api/system/settings" -Method POST `
        -Headers $Headers -Body $body -ContentType "application/x-www-form-urlencoded" `
        -UseBasicParsing -ErrorAction Stop | Out-Null
}

# -- 1. API key + wait ---------------------------------------------------------
Write-Host "  -> Waiting for API on port $Port..." -ForegroundColor Gray
Write-DebugLog "INFO" "Polling Bazarr API key from $ConfigFile (up to 60s)..."
$apiKeyDeadline = (Get-Date).AddSeconds(60)
$ApiKey         = $null
$keyWaited = 0
while (-not $ApiKey -and (Get-Date) -lt $apiKeyDeadline) {
    $ApiKey = Get-YamlKey -Path $ConfigFile -Section "auth" -Key "apikey"
    if (-not $ApiKey) { Start-Sleep -Seconds 3; $keyWaited += 3 }
}
Write-DebugLog "VAR Bazarr ApiKey found=$((-not [string]::IsNullOrEmpty($ApiKey))) waited=${keyWaited}s"
if (-not $ApiKey) {
    Write-Warning "[$AppName] API key not found in config.yaml after 60s. Skipping."
    Write-DebugLog "ERROR" "Bazarr API key not found in config.yaml"
    exit 1
}
$Headers = @{ "X-API-KEY" = $ApiKey }
Write-DebugLog "INFO" "API key loaded [REDACTED]"

$pingUrl = "$ApiBase/api/system/ping"
Write-DebugLog "INFO" "Polling Bazarr API at $pingUrl (up to 60s)..."
$apiUp   = $false
$deadline = (Get-Date).AddSeconds(60)
$apiWaited = 0
while (-not $apiUp -and (Get-Date) -lt $deadline) {
    try {
        Invoke-RestMethod -Uri $pingUrl `
            -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop | Out-Null
        $apiUp = $true
    } catch { Start-Sleep -Seconds 3; $apiWaited += 3 }
}
Write-DebugLog "VAR Bazarr API up=$apiUp waited=${apiWaited}s"
if (-not $apiUp) {
    Write-Warning "[$AppName] API not responding after 60s. Skipping."
    Write-DebugLog "ERROR" "Bazarr API not responding after 60s"
    exit 1
}

# -- 2. Read Sonarr/Radarr API keys --------------------------------------------
$SonarrKey  = $null
$RadarrKey  = $null
$SonarrBase = if ($DomainMode -eq "duckdns") { "/sonarr" } else { "" }
$RadarrBase = if ($DomainMode -eq "duckdns") { "/radarr" } else { "" }

if ($Config.Apps.Sonarr -eq $true) {
    $sonarrXml = "C:\ProgramData\Sonarr\config.xml"
    Write-DebugLog "VAR Sonarr config.xml exists=$(Test-Path $sonarrXml)"
    if (Test-Path $sonarrXml) {
        $SonarrKey = ([xml](Get-Content $sonarrXml -Encoding UTF8)).Config.ApiKey
        Write-DebugLog "VAR SonarrKey found=$((-not [string]::IsNullOrEmpty($SonarrKey)))"
    }
}
if ($Config.Apps.Radarr -eq $true) {
    $radarrXml = "C:\ProgramData\Radarr\config.xml"
    Write-DebugLog "VAR Radarr config.xml exists=$(Test-Path $radarrXml)"
    if (Test-Path $radarrXml) {
        $RadarrKey = ([xml](Get-Content $radarrXml -Encoding UTF8)).Config.ApiKey
        Write-DebugLog "VAR RadarrKey found=$((-not [string]::IsNullOrEmpty($RadarrKey)))"
    }
}
Write-DebugLog "VAR SonarrBase=$SonarrBase RadarrBase=$RadarrBase SonarrPort=$($Config.Ports.Sonarr) RadarrPort=$($Config.Ports.Radarr)"

# -- 3. Connect Sonarr + Radarr ------------------------------------------------
Write-Host "  -> Connecting Sonarr and Radarr..." -ForegroundColor Gray
$connParts = [System.Collections.Generic.List[string]]::new()

if ($SonarrKey) {
    $connParts.Add("settings-general-use_sonarr=true")
    $connParts.Add("settings-sonarr-ip=127.0.0.1")
    $connParts.Add("settings-sonarr-port=$($Config.Ports.Sonarr)")
    $connParts.Add("settings-sonarr-apikey=$([Uri]::EscapeDataString($SonarrKey))")
    $connParts.Add("settings-sonarr-base_url=$([Uri]::EscapeDataString($SonarrBase))")
    $connParts.Add("settings-sonarr-ssl=false")
    Write-DebugLog "VAR Sonarr connection: ip=127.0.0.1 port=$($Config.Ports.Sonarr) base_url=$SonarrBase apikey=[REDACTED]"
}
if ($RadarrKey) {
    $connParts.Add("settings-general-use_radarr=true")
    $connParts.Add("settings-radarr-ip=127.0.0.1")
    $connParts.Add("settings-radarr-port=$($Config.Ports.Radarr)")
    $connParts.Add("settings-radarr-apikey=$([Uri]::EscapeDataString($RadarrKey))")
    $connParts.Add("settings-radarr-base_url=$([Uri]::EscapeDataString($RadarrBase))")
    $connParts.Add("settings-radarr-ssl=false")
    Write-DebugLog "VAR Radarr connection: ip=127.0.0.1 port=$($Config.Ports.Radarr) base_url=$RadarrBase apikey=[REDACTED]"
}

if ($connParts.Count -gt 0) {
    try {
        Invoke-BazarrSettings -FormParts $connParts
        if ($SonarrKey) {
            Write-Host "     OK Sonarr connected (127.0.0.1:$($Config.Ports.Sonarr)$SonarrBase)" -ForegroundColor Green
            Write-DebugLog "INFO" "Sonarr connected in Bazarr"
        }
        if ($RadarrKey) {
            Write-Host "     OK Radarr connected (127.0.0.1:$($Config.Ports.Radarr)$RadarrBase)" -ForegroundColor Green
            Write-DebugLog "INFO" "Radarr connected in Bazarr"
        }
    } catch {
        Write-Warning "[$AppName] Could not configure Sonarr/Radarr connection: $_"
        Write-DebugLog "ERROR" "Sonarr/Radarr connection failed: $_"
    }
}

# -- 4. Enable subtitle providers ----------------------------------------------
Write-Host "  -> Enabling subtitle providers (EN + RO)..." -ForegroundColor Gray
Write-DebugLog "INFO" "Enabling subtitle providers..."

$BazarrLayer2   = $Config.Layer2.Bazarr
$OsLayer2       = $Config.Layer2.OpenSubtitles
$OsComUser      = if ($OsLayer2.Username)                     { $OsLayer2.Username }                     `
                  elseif ($BazarrLayer2.OpenSubtitlesComUsername) { $BazarrLayer2.OpenSubtitlesComUsername } `
                  else { "" }
$OsComPass      = if ($OsLayer2.Password)                     { $OsLayer2.Password }                     `
                  elseif ($BazarrLayer2.OpenSubtitlesComPassword) { $BazarrLayer2.OpenSubtitlesComPassword } `
                  else { "" }
$TitloviUser    = if ($BazarrLayer2.TitloviUsername)          { $BazarrLayer2.TitloviUsername }          else { "" }
$TitloviPass    = if ($BazarrLayer2.TitloviPassword)          { $BazarrLayer2.TitloviPassword }          else { "" }
$SubdlApiKey    = if ($BazarrLayer2.SubdlApiKey)              { $BazarrLayer2.SubdlApiKey }              else { "" }

Write-DebugLog "VAR OsComUser=$OsComUser OsComPass=[REDACTED] TitloviUser=$TitloviUser TitloviPass=[REDACTED] SubdlApiKey=[REDACTED]"

$providerParts = [System.Collections.Generic.List[string]]::new()
# subdl and subsource require API keys: enabling them without credentials makes
# Bazarr throttle them forever with ConfigurationError and retry every 12h.
# subsource is discontinued and is never enabled.  subdl is enabled only when a
# key is present in config.json (same pattern as OpenSubtitles/Titlovi).
$providers = @("opensubtitlescom","yifysubtitles","embeddedsubtitles","gestdown")
if ($TitloviUser) { $providers += "titlovi" }
if ($SubdlApiKey) { $providers += "subdl" }
$providers | ForEach-Object { $providerParts.Add("settings-general-enabled_providers=$_") }
Write-DebugLog "VAR enabling providers=$($providers -join ',')"
if ($OsComUser) {
    $providerParts.Add("settings-opensubtitlescom-username=$([Uri]::EscapeDataString($OsComUser))")
    $providerParts.Add("settings-opensubtitlescom-password=$([Uri]::EscapeDataString($OsComPass))")
    Write-DebugLog "VAR OpenSubtitles.com username=$OsComUser password=[REDACTED]"
}
if ($TitloviUser) {
    $providerParts.Add("settings-titlovi-username=$([Uri]::EscapeDataString($TitloviUser))")
    $providerParts.Add("settings-titlovi-password=$([Uri]::EscapeDataString($TitloviPass))")
    Write-DebugLog "VAR Titlovi username=$TitloviUser password=[REDACTED]"
}
if ($SubdlApiKey) {
    $providerParts.Add("settings-subdl-api_key=$([Uri]::EscapeDataString($SubdlApiKey))")
    Write-DebugLog "VAR subdl api_key=[REDACTED]"
}

try {
    Invoke-BazarrSettings -FormParts $providerParts
    Write-Host "     OK Providers: opensubtitlescom, yifysubtitles, embeddedsubtitles," -ForegroundColor Green
    Write-Host "                   gestdown, titlovi, subdl (credential-gated)" -ForegroundColor Green
    Write-DebugLog "INFO" "Subtitle providers enabled"
    if (-not $OsComUser)   { Write-Host "     ! Add OpenSubtitles.com credentials in Bazarr Settings for full quota." -ForegroundColor Yellow; Write-DebugLog "WARN" "OpenSubtitles.com credentials not set" }
    if (-not $TitloviUser) { Write-Host "     ! Add Titlovi credentials in Bazarr Settings for Romanian subtitles." -ForegroundColor Yellow; Write-DebugLog "WARN" "Titlovi credentials not set" }
    if (-not $SubdlApiKey) { Write-Host "     ! Add Layer2.Bazarr.SubdlApiKey to enable the subdl provider." -ForegroundColor Yellow; Write-DebugLog "WARN" "subdl API key not set -- provider disabled" }
} catch {
    Write-Warning "[$AppName] Could not configure providers: $_"
    Write-DebugLog "ERROR" "Provider configuration failed: $_"
}

# -- 5. Create language profiles -----------------------------------------------
Write-Host "  -> Creating language profiles..." -ForegroundColor Gray
Write-DebugLog "INFO" "Creating 3 language profiles (English, Romanian, English+Romanian)..."

$profilesJson = @(
    @{
        profileId      = 1
        name           = "English"
        cutoff         = $null
        items          = @(@{ id = 1; language = "en"; provider = $null; audio_exclude = "False"; hi = "False"; forced = "False"; audio_only_include = "False" })
        mustContain    = @()
        mustNotContain = @()
        originalFormat = $false
    }
    @{
        profileId      = 2
        name           = "Romanian"
        cutoff         = $null
        items          = @(@{ id = 1; language = "ro"; provider = $null; audio_exclude = "False"; hi = "False"; forced = "False"; audio_only_include = "False" })
        mustContain    = @()
        mustNotContain = @()
        originalFormat = $false
    }
    @{
        profileId      = 3
        name           = "English + Romanian"
        cutoff         = $null
        items          = @(
            @{ id = 1; language = "en"; provider = $null; audio_exclude = "False"; hi = "False"; forced = "False"; audio_only_include = "False" }
            @{ id = 2; language = "ro"; provider = $null; audio_exclude = "False"; hi = "False"; forced = "False"; audio_only_include = "False" }
        )
        mustContain    = @()
        mustNotContain = @()
        originalFormat = $false
    }
) | ConvertTo-Json -Depth 5 -Compress

Write-DebugLog "VAR profiles JSON length=$($profilesJson.Length) chars"
try {
    $body = "languages-profiles=$([Uri]::EscapeDataString($profilesJson))"
    Invoke-RestMethod -Uri "$ApiBase/api/system/settings" -Method POST `
        -Headers $Headers -Body $body -ContentType "application/x-www-form-urlencoded" `
        -UseBasicParsing -ErrorAction Stop | Out-Null
    Write-Host "     OK Profiles: English (1), Romanian (2), English + Romanian (3)" -ForegroundColor Green
    Write-DebugLog "INFO" "Language profiles created: English(1) Romanian(2) English+Romanian(3)"
} catch {
    Write-Warning "[$AppName] Could not create language profiles: $_"
    Write-DebugLog "ERROR" "Language profiles creation failed: $_"
}

# -- 6. Set defaults: auto-download for all content ---------------------------
Write-Host "  -> Configuring auto-download defaults..." -ForegroundColor Gray
Write-DebugLog "INFO" "Setting auto-download defaults to profile 3 (English+Romanian)..."
try {
    Invoke-BazarrSettings -FormParts @(
        "settings-general-serie_default_enabled=true"
        "settings-general-serie_default_profile=3"
        "settings-general-movie_default_enabled=true"
        "settings-general-movie_default_profile=3"
        "settings-general-use_embedded_subs=true"
        "settings-general-utf8_encode=true"
    )
    Write-Host "     OK Auto-download enabled with 'English + Romanian' profile." -ForegroundColor Green
    Write-DebugLog "INFO" "Auto-download: series+movies default_profile=3 use_embedded_subs=true utf8_encode=true"
} catch {
    Write-Warning "[$AppName] Could not set auto-download defaults: $_"
    Write-DebugLog "ERROR" "Auto-download defaults failed: $_"
}

# -- 7. Enable subtitle synchronisation ---------------------------------------
Write-Host "  -> Enabling subtitle synchronisation..." -ForegroundColor Gray
Write-DebugLog "INFO" "Enabling subtitle sync (alass/ffsubsync) without min score threshold..."
try {
    Invoke-BazarrSettings -FormParts @(
        "settings-subsync-use_subsync=true"
        "settings-subsync-use_subsync_threshold=false"
        "settings-subsync-subsync_threshold=90"
        "settings-subsync-use_subsync_movie_threshold=false"
        "settings-subsync-subsync_movie_threshold=70"
    )
    Write-Host "     OK Subtitle sync enabled (alass/ffsubsync)." -ForegroundColor Green
    Write-DebugLog "INFO" "Subtitle sync enabled: threshold=disabled (no minimum score required)"
} catch {
    Write-Warning "[$AppName] Could not enable subtitle sync: $_"
    Write-DebugLog "ERROR" "Subtitle sync configuration failed: $_"
}

Write-Host "  OK Bazarr Layer 2 configuration complete." -ForegroundColor Green
Write-Host "[$AppName] OK Configuration complete." -ForegroundColor Cyan
Write-DebugLog "INFO" "configure_layer2_bazarr.ps1 complete"
