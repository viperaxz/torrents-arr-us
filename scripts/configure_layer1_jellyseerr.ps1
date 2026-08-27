param(
    [object]$Config = $null
)

if (-not $Config) {
    $configPath = Join-Path $PSScriptRoot "..\config.json"
    if (-not (Test-Path $configPath)) {
        Write-Error "config.json not found at '$configPath'. Pass -Config or run from the project root."
        exit 1
    }
    $Config = Get-Content -Raw -Path $configPath | ConvertFrom-Json
}

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "configure_layer1_jellyseerr.ps1 started"

$AppName    = "Jellyseerr"
$AppPort    = if ($Config.Ports.PSObject.Properties["Jellyseerr"]) { $Config.Ports.Jellyseerr } else { 5055 }
$JfPort     = $Config.Ports.Jellyfin
$SonarrPort = $Config.Ports.Sonarr
$RadarrPort = $Config.Ports.Radarr
$DomainMode = $Config.General.DomainMode
$AdminUser  = $Config.General.AdminUsername
$AdminPass  = $Config.General.AdminPassword
$TVPath     = $Config.Paths.TV
$MoviesPath = $Config.Paths.Movies

$JfUrlBase    = if ($DomainMode -eq "duckdns") { "/jellyfin"  } else { "" }
$SonarrBase   = if ($DomainMode -eq "duckdns") { "/sonarr"   } else { "" }
$RadarrBase   = if ($DomainMode -eq "duckdns") { "/radarr"   } else { "" }
$ApiBase      = "http://127.0.0.1:$AppPort"

$PublicUrl = if ($DomainMode -eq "duckdns") {
    "https://$($Config.General.DuckDnsDomain)/jellyseerr"
} else {
    "https://jellyseerr.$($Config.General.Domain)"
}

Write-DebugLog "VAR AppName=$AppName AppPort=$AppPort DomainMode=$DomainMode"
Write-DebugLog "VAR JfPort=$JfPort SonarrPort=$SonarrPort RadarrPort=$RadarrPort"
Write-DebugLog "VAR PublicUrl=$PublicUrl AdminUser=$AdminUser AdminPass=[REDACTED]"

if ($Config.Apps.Jellyseerr -ne $true) {
    Write-Host "[$AppName] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "$AppName skipped (not enabled)"
    return
}

Write-Host "[$AppName] Configuring..." -ForegroundColor Cyan

# -- 1. Ensure service is running ----------------------------------------------
$svc = Get-Service -Name $AppName -ErrorAction SilentlyContinue
Write-DebugLog "VAR $AppName service exists=$($null -ne $svc) status=$(if ($svc) { $svc.Status } else { 'N/A' })"
if (-not $svc) {
    Write-Warning "[$AppName] Service not found. Run the installer first."
    Write-DebugLog "ERROR" "Jellyseerr service not found"
    return
}
if ($svc.Status -ne "Running") {
    Write-Host "  -> Starting $AppName..." -ForegroundColor Gray
    Start-Service -Name $AppName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10
    $svc = Get-Service -Name $AppName
    Write-DebugLog "VAR $AppName status after start=$($svc.Status)"
}

# -- 2. Wait for API -----------------------------------------------------------
Write-Host "  -> Waiting for Jellyseerr API..." -ForegroundColor Gray
$statusUrl = "$ApiBase/api/v1/status"
Write-DebugLog "INFO" "Polling $statusUrl (up to 90s)..."
$apiUp    = $false
$deadline = (Get-Date).AddSeconds(90)
$waited   = 0
$statusData = $null
while (-not $apiUp -and (Get-Date) -lt $deadline) {
    try {
        $statusData = Invoke-RestMethod -Uri $statusUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        $apiUp = $true
    } catch { Start-Sleep -Seconds 5; $waited += 5 }
}
Write-DebugLog "VAR Jellyseerr API up=$apiUp waited=${waited}s isSetupDone=$($statusData.isSetupDone)"
if (-not $apiUp) {
    Write-Warning "[$AppName] API not responding after 90s. Skipping."
    Write-DebugLog "ERROR" "Jellyseerr API not responding"
    exit 1
}

$isSetupDone = $statusData.isSetupDone -eq $true
Write-DebugLog "VAR isSetupDone=$isSetupDone"

# -- 3. Initial setup via POST /api/v1/auth/jellyfin --------------------------
# This endpoint handles both first-run setup AND subsequent logins.
# On first run it creates the Jellyseerr admin account linked to the Jellyfin admin.
# The session cookie returned here is used for all subsequent API calls.
Write-Host "  -> Authenticating with Jellyfin credentials..." -ForegroundColor Gray

$authBody = @{
    username   = $AdminUser
    password   = $AdminPass
    hostname   = "127.0.0.1"
    port       = $JfPort
    urlBase    = $JfUrlBase
    useSsl     = $false
    serverType = 2
} | ConvertTo-Json -Compress

Write-DebugLog "INFO" "POST /api/v1/auth/jellyfin (user=$AdminUser jfPort=$JfPort urlBase=$JfUrlBase)"

# Jellyseerr is often still connecting to Jellyfin internally when it first starts.
# A single-shot auth attempt can fail on a fresh install even though the status
# endpoint is already responding.  Retry with back-off for up to 60 s.
$session   = $null
$authUp    = $false
$authErr   = ""
$deadline  = (Get-Date).AddSeconds(60)
$authWaited = 0
while (-not $authUp -and (Get-Date) -lt $deadline) {
    try {
        $authResp = Invoke-RestMethod -Uri "$ApiBase/api/v1/auth/jellyfin" -Method Post `
            -Body $authBody -ContentType "application/json" `
            -UseBasicParsing -SessionVariable "session" -ErrorAction Stop
        if ($authResp.id) {
            $authUp = $true
            Write-Host "  -> Authenticated as '$($authResp.displayName)' (id=$($authResp.id))." -ForegroundColor Green
            Write-DebugLog "INFO" "Jellyseerr auth succeeded. userId=$($authResp.id) displayName=$($authResp.displayName)"
        } else {
            $authErr = "auth response missing id field"
            Write-DebugLog "VAR Jellyseerr auth response had no id: $($authResp | ConvertTo-Json -Compress)"
            Start-Sleep -Seconds 3; $authWaited += 3
        }
    } catch {
        $authErr = $_.ToString()
        if ($_.Exception.Response) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $authErr = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
            } catch {}
        }
        Write-DebugLog "VAR Jellyseerr auth attempt failed (${authWaited}s): $authErr"
        Start-Sleep -Seconds 3; $authWaited += 3
    }
}
Write-DebugLog "VAR Jellyseerr auth up=$authUp waited=${authWaited}s"
if (-not $authUp) {
    Write-Warning "[$AppName] Authentication failed after ${authWaited}s: $authErr"
    Write-DebugLog "ERROR" "Jellyseerr auth failed after ${authWaited}s: $authErr"
    exit 1
}

# Helper: authenticated Invoke-RestMethod using the session cookie
function Invoke-JellyseerrApi {
    param(
        [string]$Path,
        [string]$Method = "Get",
        [object]$Body   = $null
    )
    $params = @{
        Uri            = "$ApiBase$Path"
        Method         = $Method
        WebSession     = $session
        UseBasicParsing = $true
        ErrorAction    = "Stop"
    }
    if ($Body) {
        $params["Body"]        = ($Body | ConvertTo-Json -Compress -Depth 10)
        $params["ContentType"] = "application/json"
    }
    return Invoke-RestMethod @params
}

# -- 4. Mark app as initialized -----------------------------------------------
# POST /api/v1/settings/initialize sets public.initialized=true. Without this
# the Next.js _app.tsx.getInitialProps redirects every page to /setup.
Write-Host "  -> Marking Jellyseerr as initialized..." -ForegroundColor Gray
Write-DebugLog "INFO" "POST /api/v1/settings/initialize"
try {
    Invoke-JellyseerrApi -Path "/api/v1/settings/initialize" -Method Post | Out-Null
    Write-Host "  -> Jellyseerr initialized." -ForegroundColor Green
    Write-DebugLog "INFO" "initialized flag set"
} catch {
    Write-Warning "[$AppName] Could not mark as initialized: $_"
    Write-DebugLog "WARN" "Failed POST /api/v1/settings/initialize: $_"
}

# -- 5. Set application URL and title -----------------------------------------
Write-Host "  -> Setting application URL..." -ForegroundColor Gray
Write-DebugLog "INFO" "Setting applicationUrl=$PublicUrl"
try {
    Invoke-JellyseerrApi -Path "/api/v1/settings/main" -Method Post -Body @{
        applicationUrl   = $PublicUrl
        applicationTitle = "Jellyseerr"
    } | Out-Null
    Write-Host "  -> Application URL: $PublicUrl" -ForegroundColor Green
    Write-DebugLog "INFO" "applicationUrl set to $PublicUrl"
} catch {
    Write-Warning "[$AppName] Could not set application URL: $_"
    Write-DebugLog "WARN" "Failed to set applicationUrl: $_"
}

# -- 6. Connect Sonarr ---------------------------------------------------------
if ($Config.Apps.Sonarr -eq $true) {
    Write-Host "  -> Connecting Sonarr..." -ForegroundColor Gray
    $sonarrXml = "C:\ProgramData\Sonarr\config.xml"
    Write-DebugLog "VAR sonarrXml=$sonarrXml (exists=$(Test-Path $sonarrXml))"
    if (Test-Path $sonarrXml) {
        [xml]$sXml = Get-Content -Path $sonarrXml -Encoding UTF8
        $sonarrApiKey = $sXml.Config.ApiKey
        Write-DebugLog "VAR Sonarr ApiKey found=$((-not [string]::IsNullOrEmpty($sonarrApiKey)))"

        if ($sonarrApiKey) {
            # Fetch quality profiles from Sonarr -- activeProfileId + activeProfileName required by Jellyseerr v3.3.0
            $sonarrActiveProfileId   = 0
            $sonarrActiveProfileName = ""
            try {
                $sonarrProfiles = Invoke-RestMethod -Uri "http://127.0.0.1:$SonarrPort$SonarrBase/api/v3/qualityprofile" `
                    -Headers @{"X-Api-Key" = $sonarrApiKey} -UseBasicParsing -ErrorAction Stop
                if ($sonarrProfiles -and $sonarrProfiles.Count -gt 0) {
                    $sonarrActiveProfileId   = $sonarrProfiles[0].id
                    $sonarrActiveProfileName = $sonarrProfiles[0].name
                }
                Write-DebugLog "VAR Sonarr quality profiles=$($sonarrProfiles.Count) activeProfileId=$sonarrActiveProfileId activeProfileName=$sonarrActiveProfileName"
            } catch {
                Write-DebugLog "WARN" "Could not fetch Sonarr quality profiles: $_ -- using defaults"
            }

            # Check if Sonarr is already configured in Jellyseerr
            $existingSonarr = $null
            try {
                $existingSonarr = Invoke-JellyseerrApi -Path "/api/v1/settings/sonarr" -Method Get
                Write-DebugLog "VAR existing Sonarr instances=$($existingSonarr.Count)"
            } catch {
                Write-DebugLog "WARN" "Could not get existing Sonarr config: $_"
            }

            $alreadyConfigured = ($existingSonarr -and $existingSonarr.Count -gt 0)
            Write-DebugLog "VAR Sonarr alreadyConfigured=$alreadyConfigured"

            $sonarrPayload = @{
                name                = "Sonarr"
                hostname            = "127.0.0.1"
                port                = $SonarrPort
                apiKey              = $sonarrApiKey
                urlBase             = $SonarrBase
                useSsl              = $false
                is4k                = $false
                isDefault           = $true
                activeProfileId     = $sonarrActiveProfileId
                activeProfileName   = $sonarrActiveProfileName
                activeDirectory     = if ($TVPath) { $TVPath } else { "" }
                enableSeasonFolders = $true
                externalUrl         = ""
                syncEnabled         = $false
                preventSearch       = $false
            }

            try {
                if ($alreadyConfigured) {
                    $existingId = $existingSonarr[0].id
                    $sonarrPayload["id"] = $existingId
                    Invoke-JellyseerrApi -Path "/api/v1/settings/sonarr/$existingId" -Method Put -Body $sonarrPayload | Out-Null
                    Write-Host "  -> Sonarr connection updated (id=$existingId)." -ForegroundColor Green
                    Write-DebugLog "INFO" "Sonarr connection updated id=$existingId"
                } else {
                    Invoke-JellyseerrApi -Path "/api/v1/settings/sonarr" -Method Post -Body $sonarrPayload | Out-Null
                    Write-Host "  -> Sonarr connected (127.0.0.1:$SonarrPort$SonarrBase)." -ForegroundColor Green
                    Write-DebugLog "INFO" "Sonarr connection created port=$SonarrPort urlBase=$SonarrBase"
                }
            } catch {
                Write-Warning "[$AppName] Could not configure Sonarr connection: $_"
                Write-DebugLog "WARN" "Sonarr connection failed: $_"
            }
        } else {
            Write-Warning "[$AppName] Sonarr API key missing in config.xml. Skipping Sonarr connection."
            Write-DebugLog "WARN" "Sonarr API key not found in config.xml"
        }
    } else {
        Write-Warning "[$AppName] Sonarr config.xml not found. Skipping Sonarr connection."
        Write-DebugLog "WARN" "Sonarr config.xml not found: $sonarrXml"
    }
} else {
    Write-Host "  -> Sonarr not enabled  --  skipping Sonarr connection." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "Sonarr not enabled"
}

# -- 7. Connect Radarr ---------------------------------------------------------
if ($Config.Apps.Radarr -eq $true) {
    Write-Host "  -> Connecting Radarr..." -ForegroundColor Gray
    $radarrXml = "C:\ProgramData\Radarr\config.xml"
    Write-DebugLog "VAR radarrXml=$radarrXml (exists=$(Test-Path $radarrXml))"
    if (Test-Path $radarrXml) {
        [xml]$rXml = Get-Content -Path $radarrXml -Encoding UTF8
        $radarrApiKey = $rXml.Config.ApiKey
        Write-DebugLog "VAR Radarr ApiKey found=$((-not [string]::IsNullOrEmpty($radarrApiKey)))"

        if ($radarrApiKey) {
            # Fetch quality profiles from Radarr -- activeProfileId + activeProfileName required by Jellyseerr v3.3.0
            $radarrActiveProfileId   = 0
            $radarrActiveProfileName = ""
            try {
                $radarrProfiles = Invoke-RestMethod -Uri "http://127.0.0.1:$RadarrPort$RadarrBase/api/v3/qualityprofile" `
                    -Headers @{"X-Api-Key" = $radarrApiKey} -UseBasicParsing -ErrorAction Stop
                if ($radarrProfiles -and $radarrProfiles.Count -gt 0) {
                    $radarrActiveProfileId   = $radarrProfiles[0].id
                    $radarrActiveProfileName = $radarrProfiles[0].name
                }
                Write-DebugLog "VAR Radarr quality profiles=$($radarrProfiles.Count) activeProfileId=$radarrActiveProfileId activeProfileName=$radarrActiveProfileName"
            } catch {
                Write-DebugLog "WARN" "Could not fetch Radarr quality profiles: $_ -- using defaults"
            }

            $existingRadarr = $null
            try {
                $existingRadarr = Invoke-JellyseerrApi -Path "/api/v1/settings/radarr" -Method Get
                Write-DebugLog "VAR existing Radarr instances=$($existingRadarr.Count)"
            } catch {
                Write-DebugLog "WARN" "Could not get existing Radarr config: $_"
            }

            $alreadyConfigured = ($existingRadarr -and $existingRadarr.Count -gt 0)
            Write-DebugLog "VAR Radarr alreadyConfigured=$alreadyConfigured"

            $radarrPayload = @{
                name                = "Radarr"
                hostname            = "127.0.0.1"
                port                = $RadarrPort
                apiKey              = $radarrApiKey
                urlBase             = $RadarrBase
                useSsl              = $false
                is4k                = $false
                isDefault           = $true
                activeProfileId     = $radarrActiveProfileId
                activeProfileName   = $radarrActiveProfileName
                activeDirectory     = if ($MoviesPath) { $MoviesPath } else { "" }
                minimumAvailability = "released"
                externalUrl         = ""
                syncEnabled         = $false
                preventSearch       = $false
            }

            try {
                if ($alreadyConfigured) {
                    $existingId = $existingRadarr[0].id
                    $radarrPayload["id"] = $existingId
                    Invoke-JellyseerrApi -Path "/api/v1/settings/radarr/$existingId" -Method Put -Body $radarrPayload | Out-Null
                    Write-Host "  -> Radarr connection updated (id=$existingId)." -ForegroundColor Green
                    Write-DebugLog "INFO" "Radarr connection updated id=$existingId"
                } else {
                    Invoke-JellyseerrApi -Path "/api/v1/settings/radarr" -Method Post -Body $radarrPayload | Out-Null
                    Write-Host "  -> Radarr connected (127.0.0.1:$RadarrPort$RadarrBase)." -ForegroundColor Green
                    Write-DebugLog "INFO" "Radarr connection created port=$RadarrPort urlBase=$RadarrBase"
                }
            } catch {
                Write-Warning "[$AppName] Could not configure Radarr connection: $_"
                Write-DebugLog "WARN" "Radarr connection failed: $_"
            }
        } else {
            Write-Warning "[$AppName] Radarr API key missing in config.xml. Skipping Radarr connection."
            Write-DebugLog "WARN" "Radarr API key not found in config.xml"
        }
    } else {
        Write-Warning "[$AppName] Radarr config.xml not found. Skipping Radarr connection."
        Write-DebugLog "WARN" "Radarr config.xml not found: $radarrXml"
    }
} else {
    Write-Host "  -> Radarr not enabled  --  skipping Radarr connection." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "Radarr not enabled"
}

# -- 8. Set default user permissions (32 = REQUEST only) ----------------------
Write-Host "  -> Setting default user permissions..." -ForegroundColor Gray
Write-DebugLog "INFO" "Setting defaultPermissions=32 (request-only)"
try {
    Invoke-JellyseerrApi -Path "/api/v1/settings/main" -Method Post -Body @{
        defaultPermissions = 32
    } | Out-Null
    Write-Host "  -> Default permissions: Request only (32)." -ForegroundColor Green
    Write-DebugLog "INFO" "Default permissions set to 32"
} catch {
    Write-Warning "[$AppName] Could not set default permissions: $_"
    Write-DebugLog "WARN" "Failed to set defaultPermissions: $_"
}

Write-Host ""
Write-Host "  -> Application URL : $PublicUrl" -ForegroundColor Green
Write-Host "  -> Jellyfin server : 127.0.0.1:$JfPort$JfUrlBase" -ForegroundColor Green
Write-Host "[$AppName] Layer 1 configuration complete." -ForegroundColor Cyan
Write-DebugLog "INFO" "configure_layer1_jellyseerr.ps1 complete"
