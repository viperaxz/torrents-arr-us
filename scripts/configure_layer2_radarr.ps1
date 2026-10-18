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

# Bounded service control: nssm services wedge in Stop/Start Pending and the
# built-in cmdlets wait indefinitely. See service_helpers.ps1.
if (-not (Get-Command Start-ServiceBounded -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "service_helpers.ps1")
}
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "configure_layer2_radarr.ps1 started"

$AppName      = "Radarr"
$Port         = $Config.Ports.Radarr
$Enabled      = $Config.Apps.Radarr -eq $true
$Layer2Config = $Config.Layer2.Radarr
$DomainMode   = $Config.General.DomainMode
$UrlBase      = if ($DomainMode -eq "duckdns") { "/radarr" } else { "" }

$DataDir   = "C:\ProgramData\$AppName"
$ConfigXml = Join-Path $DataDir "config.xml"

Write-DebugLog "VAR AppName=$AppName Port=$Port Enabled=$Enabled DomainMode=$DomainMode UrlBase=$UrlBase"

if (-not $Enabled) {
    Write-Host "[$AppName] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "$AppName skipped (not enabled)"
    return
}

if (-not $Layer2Config) {
    Write-Host "  [WARN] No Layer2 config found for $AppName. Skipping." -ForegroundColor Yellow
    Write-DebugLog "WARN" "No Layer2 config for $AppName"
    return
}

Write-DebugLog "VAR Layer2 RootFolders=$($Layer2Config.RootFolders.Count) DownloadClients=$($Layer2Config.DownloadClients.Count)"

# -- 1. Ensure service is running ----------------------------------------------
$svc = Get-Service -Name $AppName -ErrorAction SilentlyContinue
Write-DebugLog "VAR $AppName service exists=$($null -ne $svc) status=$(if ($svc) { $svc.Status } else { 'N/A' })"
if (-not $svc) {
    Write-Warning "[$AppName] Service not found. Run the installer first."
    Write-DebugLog "ERROR" "$AppName service not found"
    exit 1
}
if ($svc.Status -ne "Running") {
    Write-Host "  -> Starting $AppName..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Starting $AppName..."
    $null = Start-ServiceBounded -Name $AppName
    Start-Sleep -Seconds 5
}

# -- 2. Get API key ------------------------------------------------------------
Write-DebugLog "VAR ConfigXml=$ConfigXml (exists=$(Test-Path $ConfigXml))"
if (-not (Test-Path $ConfigXml)) {
    Write-Warning "[$AppName] config.xml not found at '$ConfigXml'. Skipping."
    Write-DebugLog "ERROR" "config.xml not found"
    exit 1
}
[xml]$cfgXml = Get-Content -Path $ConfigXml -Encoding UTF8
$ApiKey = $cfgXml.Config.ApiKey
Write-DebugLog "VAR ApiKey found=$((-not [string]::IsNullOrEmpty($ApiKey)))"
if (-not $ApiKey) {
    Write-Warning "[$AppName] API key not found in config.xml. Skipping."
    Write-DebugLog "ERROR" "ApiKey not found"
    exit 1
}

# -- 3. Wait for API -----------------------------------------------------------
# Same prefix rule as Layer 1: every call below is built from $UrlBase, so a
# config.xml that disagrees with the mode fails at the poll with a generic
# timeout instead of naming the UrlBase mismatch.
$CfgUrlBase = [string]$cfgXml.Config.UrlBase
if ($CfgUrlBase -ne $UrlBase) {
    Write-Warning "[$AppName] config.xml UrlBase is '$CfgUrlBase' but $DomainMode mode needs '$UrlBase'. The API calls below use that prefix."
    Write-DebugLog "WARN" "config.xml UrlBase '$CfgUrlBase' does not match the $DomainMode prefix '$UrlBase'"
}
Write-Host "  -> Waiting for API on port $Port..." -ForegroundColor Gray
$apiUrl = "http://127.0.0.1:$Port$UrlBase/api/v3/config/host"
Write-DebugLog "INFO" "Polling $AppName API at $apiUrl (up to 30s)..."
$apiUp = $false
$deadline = (Get-Date).AddSeconds(30)
$apiWaited = 0
while (-not $apiUp -and (Get-Date) -lt $deadline) {
    try {
        Invoke-WebRequest -Uri $apiUrl `
            -Headers @{"X-Api-Key" = $ApiKey} `
            -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop | Out-Null
        $apiUp = $true
    } catch { Start-Sleep -Seconds 3; $apiWaited += 3 }
}
Write-DebugLog "VAR $AppName API up=$apiUp waited=${apiWaited}s"
if (-not $apiUp) {
    Write-Warning "[$AppName] API not responding after 30s. Skipping."
    Write-DebugLog "ERROR" "$AppName API not responding after 30s"
    exit 1
}

# -- 4. Configure Root Folders -------------------------------------------------
if ($Layer2Config.RootFolders -and $Layer2Config.RootFolders.Count -gt 0) {
    Write-Host "  -> Configuring root folders..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Configuring $($Layer2Config.RootFolders.Count) root folder(s)..."

    try {
        $existingFolders = @()
        try {
            $existingFolders = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/rootFolder" `
                -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
            Write-DebugLog "VAR existing root folders=$($existingFolders.Count)"
        } catch { Write-DebugLog "WARN" "Could not fetch existing root folders: $_" }

        foreach ($folder in $Layer2Config.RootFolders) {
            $folderPath = $folder.Path
            $exists = $existingFolders | Where-Object { $_.path -eq $folderPath }
            Write-DebugLog "VAR root folder '$folderPath' exists=$($null -ne $exists)"
            if ($exists) {
                Write-Host "     Root folder already configured: $folderPath" -ForegroundColor DarkGray
                Write-DebugLog "INFO" "Root folder already exists: $folderPath"
            } else {
                $newFolder = @{
                    path       = $folderPath
                    accessible = $true
                    freeSpace  = 0
                } | ConvertTo-Json -Compress
                Write-DebugLog "INFO" "Adding root folder: $folderPath"
                Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/rootFolder" `
                    -Method Post `
                    -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
                    -Body $newFolder `
                    -UseBasicParsing -ErrorAction Stop | Out-Null
                Write-Host "     [OK] Added root folder: $folderPath" -ForegroundColor Green
                Write-DebugLog "INFO" "Root folder added: $folderPath"
            }
        }
    } catch {
        Write-Warning "[$AppName] Failed to configure root folders: $_"
        Write-DebugLog "ERROR" "Root folder configuration failed: $_"
        exit 1
    }
}

# -- 5. Configure Download Clients ---------------------------------------------
# A missing Deluge password skips only this section: the seed criteria, naming and
# Jellyfin notification below do not depend on Deluge. Returning from the script
# here used to drop all of them (and still exited 0, so the run looked complete).
$DelugeAuthFile = Join-Path $Config.General.InstallDir "secrets\deluge_auth.txt"
Write-DebugLog "VAR DelugeAuthFile=$DelugeAuthFile (exists=$(Test-Path $DelugeAuthFile))"
$HasDownloadClients = [bool]($Layer2Config.DownloadClients -and $Layer2Config.DownloadClients.Count -gt 0)
if ($HasDownloadClients -and -not (Test-Path $DelugeAuthFile)) {
    Write-Warning "[$AppName] Deluge auth file not found at '$DelugeAuthFile'. Download client NOT configured."
    Write-Warning "     Run configure_layer1_deluge.ps1 first, then re-run this script to add the download client."
    Write-DebugLog "WARN" "Deluge auth file not found -- skipping download client config"
}

if ($HasDownloadClients -and (Test-Path $DelugeAuthFile)) {
    Write-Host "  -> Configuring download clients..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Configuring $($Layer2Config.DownloadClients.Count) download client(s)..."

    $DelugePassword = (Get-Content -Path $DelugeAuthFile -Raw -Encoding UTF8).TrimStart([char]0xFEFF).Trim()
    Write-DebugLog "VAR DelugePassword loaded (length=$($DelugePassword.Length)) [REDACTED]"

    try {
        $existingClients = @()
        try {
            $existingClients = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/downloadclient" `
                -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
            Write-DebugLog "VAR existing download clients=$($existingClients.Count)"
        } catch { Write-DebugLog "WARN" "Could not fetch existing clients: $_" }

        Write-DebugLog "INFO" "Fetching download client schema..."
        $schemas = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/downloadclient/schema" `
            -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
        $delugeSchema = $schemas | Where-Object { $_.implementation -eq "Deluge" } | Select-Object -First 1
        Write-DebugLog "VAR Deluge schema found=$($null -ne $delugeSchema)"
        if (-not $delugeSchema) {
            Write-Warning "     Deluge not found in $AppName download client schema."
            Write-DebugLog "ERROR" "Deluge not in download client schema"
            exit 1
        }

        foreach ($client in $Layer2Config.DownloadClients) {
            $clientName = $client.Name
            $exists = $existingClients | Where-Object { $_.name -eq $clientName }
            Write-DebugLog "VAR client '$clientName' exists=$($null -ne $exists) host=$($client.Host) port=$($client.Port)"

            $schemaClone = $delugeSchema | ConvertTo-Json -Depth 10 | ConvertFrom-Json
            foreach ($field in $schemaClone.fields) {
                # PS5.1: ConvertFrom-Json objects are frozen -- ensure 'value' property exists before setting
                if (-not (Get-Member -InputObject $field -Name 'value' -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
                    $field | Add-Member -MemberType NoteProperty -Name 'value' -Value $null -ErrorAction SilentlyContinue
                }
                switch ($field.name) {
                    "host"         { $field.value = $client.Host }
                    "port"         { $field.value = [int]$client.Port }
                    "password"     { $field.value = $DelugePassword }
                    "urlBase"      { $field.value = "/" }
                    "useSsl"       { $field.value = $false }
                    "movieCategory" { $field.value = "radarr" }
                    { $_ -eq "recentMoviePriority" -or $_ -eq "olderMoviePriority" } { $field.value = 1 }
                }
            }
            $payload = @{}
            $schemaClone.PSObject.Properties | ForEach-Object { $payload[$_.Name] = $_.Value }
            $payload["enable"]   = $true
            $payload["name"]     = $clientName
            $payload["priority"] = [int]$client.Priority
            if ($exists) { $payload["id"] = $exists.id }
            $body = $payload | ConvertTo-Json -Depth 10 -Compress

            if ($exists) {
                Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/downloadclient/$($exists.id)" `
                    -Method Put `
                    -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
                    -Body $body -UseBasicParsing -ErrorAction Stop | Out-Null
                Write-Host "     [OK] Updated download client: $clientName" -ForegroundColor Green
                Write-DebugLog "INFO" "Download client '$clientName' updated"
            } else {
                Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/downloadclient" `
                    -Method Post `
                    -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
                    -Body $body -UseBasicParsing -ErrorAction Stop | Out-Null
                Write-Host "     [OK] Added download client: $clientName" -ForegroundColor Green
                Write-DebugLog "INFO" "Download client '$clientName' created"
            }
        }
    } catch {
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $detail = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
            Write-Warning "  API detail: $detail"
            Write-DebugLog "ERROR" "API error detail: $detail"
        } catch {}
        Write-Warning "[$AppName] Failed to configure download clients: $_"
        Write-DebugLog "ERROR" "Download client configuration failed: $_"
        exit 1
    }
}

# -- 6. Configure seed criteria -----------------------------------------------
function Invoke-IndexerPut {
    param([string]$Uri, [hashtable]$Headers, [string]$Body)
    try {
        $r = Invoke-WebRequest -Uri $Uri -Method Put -Headers $Headers -Body $Body `
            -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        return [pscustomobject]@{ Ok = $true; Status = [int]$r.StatusCode; Body = '' }
    } catch {
        $resp = $_.Exception.Response
        $bodyText = ''
        if ($resp) {
            try {
                $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $bodyText = $sr.ReadToEnd()
            } catch { }
            return [pscustomobject]@{ Ok = $false; Status = [int]$resp.StatusCode; Body = $bodyText }
        }
        return [pscustomobject]@{ Ok = $false; Status = 0; Body = $_.Exception.Message }
    }
}
# Prowlarr answers 429 while the tracker is in its own failure backoff, some
# definitions reply "no results in the configured categories", and a private
# tracker with no credentials in config answers 403 from its own login page
# ("Unable to connect to indexer ... [403:Forbidden] at .../login.php", captured
# from RuTracker). All three mean this app can never validate that indexer, so
# retrying the same PUT is pointless.
function Test-IndexerPermanentlyUnavailable {
    param([string]$Body)
    if (-not $Body) { return $false }
    return ($Body -match '\[429' -or $Body -match 'TooManyRequests' -or $Body -match 'no results in the configured categor' -or $Body -match 'Unable to connect to indexer')
}

$SeedRatio = if ($Config.Layer2.PSObject.Properties['PublicTrackerSeedRatio'] -and $null -ne $Config.Layer2.PublicTrackerSeedRatio) {
    [double]$Config.Layer2.PublicTrackerSeedRatio
} else { 1.0 }
$PublicIndexerNames = @($Config.Layer2.Prowlarr.Indexers |
    Where-Object { -not ($_.PSObject.Properties['SeedRules'] -and $_.SeedRules) } |
    ForEach-Object { $_.Name })
# Indexers that declare SeedRules are private trackers: configure_layer2_prowlarr.ps1
# already pushed their per-indexer ratio + seed time into this app (it runs before
# this script), so their ratio must not be overwritten with the public-tracker
# default here.
$SeedRuleIndexerNames = @($Config.Layer2.Prowlarr.Indexers |
    Where-Object { $_.PSObject.Properties['SeedRules'] -and $_.SeedRules } |
    ForEach-Object { $_.Name })
$ConfiguredIndexerNames = @($Config.Layer2.Prowlarr.Indexers | ForEach-Object { $_.Name })
Write-DebugLog "VAR SeedRatio=$SeedRatio PublicIndexers=$($PublicIndexerNames.Count) SeedRuleIndexers=$($SeedRuleIndexerNames.Count)"

if ($SeedRatio -and $ConfiguredIndexerNames.Count -gt 0) {
    Write-Host "  -> Configuring seed criteria (public ratio=$SeedRatio)..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Configuring seed criteria: ratio=$SeedRatio"
    try {
        $radarrIndexers = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/indexer" `
            -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
        Write-DebugLog "VAR Radarr indexers from API=$($radarrIndexers.Count)"

        $skippedUnavailable = 0
        foreach ($idx in $radarrIndexers) {
            $baseName   = $idx.name -replace '\s*\(Prowlarr\)\s*$', ''
            if ($SeedRuleIndexerNames -contains $baseName) {
                Write-DebugLog "VAR indexer '$($idx.name)' declares SeedRules -- ratio/seed time left as applied by configure_layer2_prowlarr.ps1"
                continue
            }
            $isPublic   = $PublicIndexerNames -contains $baseName
            $ratioField = $idx.fields | Where-Object { $_.name -eq "seedCriteria.seedRatio" }
            if (-not $ratioField) { continue }

            $targetRatio  = if ($isPublic) { $SeedRatio } else { $null }
            $currentRatio = $ratioField.value
            Write-DebugLog "VAR indexer '$($idx.name)' isPublic=$isPublic currentRatio=$currentRatio targetRatio=$targetRatio"
            if ($currentRatio -eq $targetRatio) { continue }

            $ratioField | Add-Member -MemberType NoteProperty -Name 'value' -Value $targetRatio -Force
            $payload = @{}
            $idx.PSObject.Properties | ForEach-Object { $payload[$_.Name] = $_.Value }
            $body = $payload | ConvertTo-Json -Depth 10 -Compress

            # Same as the Sonarr twin: the *arr validates the indexer on PUT by asking
            # Prowlarr for its caps, so retry with backoff and keep the response body
            # (it names the real cause: 429 backoff or no results for the categories).
            $putOk   = $false
            $putBody = ''
            $putUnavailable = $false
            $putDelays = @(5, 10)
            for ($putAttempt = 1; $putAttempt -le 3; $putAttempt++) {
                $res = Invoke-IndexerPut -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/indexer/$($idx.id)" `
                    -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} -Body $body
                $putBody = $res.Body
                if ($res.Ok) { $putOk = $true; break }
                # See the Sonarr twin: a permanently unavailable indexer rejects the
                # identical PUT for the rest of the install, so stop sleeping on it.
                if (Test-IndexerPermanentlyUnavailable -Body $putBody) {
                    $putUnavailable = $true
                    break
                }
                if ($putAttempt -lt 3) {
                    Write-DebugLog "DEBUG" "Indexer '$($idx.name)' PUT rejected (attempt $putAttempt, HTTP $($res.Status)), retrying"
                    Start-Sleep -Seconds $putDelays[$putAttempt - 1]
                }
            }
            if ($putOk) {
                if ($isPublic) {
                    Write-Host "     [OK] $($idx.name): seed ratio set to $SeedRatio" -ForegroundColor Green
                    Write-DebugLog "INFO" "Indexer '$($idx.name)' seed ratio set to $SeedRatio"
                } else {
                    Write-Host "     [OK] $($idx.name): seed ratio cleared (private  --  unlimited)" -ForegroundColor Green
                    Write-DebugLog "INFO" "Indexer '$($idx.name)' seed ratio cleared (private)"
                }
            } else {
                # See the Sonarr twin: a 429 from Prowlarr means the tracker is in its
                # own failure backoff, and "no results in the configured categories"
                # means the definition cannot answer this app at all. Neither is
                # something this installer can fix.
                if ($putUnavailable) {
                    $skippedUnavailable++
                    Write-DebugLog "INFO" "Indexer '$($idx.name)' skipped: Prowlarr cannot serve it for these categories (429 backoff or no results)"
                } else {
                    $firstErr = if ($putBody -match 'errorMessage"\s*:\s*"([^"]+)') { $Matches[1] } else { $putBody }
                    Write-Warning "     Failed to update seed ratio for '$($idx.name)': $firstErr"
                    Write-DebugLog "WARN" "Failed to update seed ratio for '$($idx.name)' after 3 attempts: $firstErr"
                }
            }
        }
        if ($skippedUnavailable -gt 0) {
            Write-Host "     $skippedUnavailable indexer(s) skipped: Prowlarr cannot serve them for these categories (429 backoff or no results) -- not a config problem." -ForegroundColor DarkGray
            Write-DebugLog "INFO" "$skippedUnavailable indexer(s) skipped because Prowlarr cannot serve them (429 or no results in the requested categories)"
        }
    } catch {
        Write-Warning "[$AppName] Failed to configure seed criteria: $_"
        Write-DebugLog "WARN" "Seed criteria configuration failed: $_"
    }
}

# -- 7. Naming scheme + Media Management --------------------------------------
Write-Host "  -> Configuring naming scheme and media management..." -ForegroundColor Gray
Write-DebugLog "INFO" "Configuring TRaSH naming scheme for movies..."
try {
    $naming = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/config/naming" `
        -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
    Write-DebugLog "VAR current renameMovies=$($naming.renameMovies)"

    $naming.renameMovies        = $true
    $naming.standardMovieFormat = "{Movie CleanTitle} {(Release Year)} [imdbid-{ImdbId}] - {Edition Tags} {[MediaInfo 3D]}{[Custom Formats]}{[Quality Full]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}"
    $naming.movieFolderFormat   = "{Movie CleanTitle} ({Release Year})"

    Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/config/naming" `
        -Method Put -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
        -Body ($naming | ConvertTo-Json -Depth 10 -Compress) -UseBasicParsing -ErrorAction Stop | Out-Null
    Write-DebugLog "INFO" "Naming scheme updated (TRaSH movie format, renameMovies=true)"

    $mgmt = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/config/mediamanagement" `
        -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
    Write-DebugLog "VAR current downloadPropersAndRepacks=$($mgmt.downloadPropersAndRepacks)"
    $mgmt.downloadPropersAndRepacks = "doNotPrefer"
    Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/config/mediamanagement" `
        -Method Put -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
        -Body ($mgmt | ConvertTo-Json -Depth 10 -Compress) -UseBasicParsing -ErrorAction Stop | Out-Null
    Write-DebugLog "INFO" "Media management: downloadPropersAndRepacks=doNotPrefer"

    Write-Host "     [OK] Naming and media management configured." -ForegroundColor Green
} catch {
    Write-Warning "[$AppName] Failed to configure naming/media management: $_"
    Write-DebugLog "WARN" "Naming/media management failed: $_"
}

# -- 8. Configure Jellyfin (MediaBrowser) notification ------------------------
if ($Config.Apps.Jellyfin -eq $true) {
    Write-Host "  -> Configuring Jellyfin notification..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Configuring Jellyfin MediaBrowser notification..."

    $JellyfinKeyFile = Join-Path $Config.General.InstallDir "secrets\jellyfin_api_key.txt"
    Write-DebugLog "VAR JellyfinKeyFile=$JellyfinKeyFile (exists=$(Test-Path $JellyfinKeyFile))"
    if (-not (Test-Path $JellyfinKeyFile)) {
        Write-Host "  [WARN] Jellyfin API key not found  --  run Jellyfin Layer 2 first. Skipping." -ForegroundColor Yellow
        Write-DebugLog "WARN" "Jellyfin API key not found"
    } else {
        $JellyfinApiKey  = (Get-Content $JellyfinKeyFile -Raw -Encoding UTF8).TrimStart([char]0xFEFF).Trim()
        $JellyfinPort    = $Config.Ports.Jellyfin
        $JellyfinUrlBase = if ($DomainMode -eq "duckdns") { "/jellyfin" } else { "" }
        Write-DebugLog "VAR JellyfinPort=$JellyfinPort JellyfinUrlBase=$JellyfinUrlBase JellyfinApiKey=[REDACTED]"

        try {
            # Use a fresh variable name (not $schemas, which is reused for download client
            # schemas earlier) and a foreach+break loop instead of Where-Object|Select-Object
            # -First 1, which can return the full collection under $ErrorActionPreference=Stop.
            $notifSchemas = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/notification/schema" `
                -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
            $mbSchema = $null
            foreach ($s in $notifSchemas) {
                if ($s.implementation -eq "MediaBrowser") { $mbSchema = $s; break }
            }
            Write-DebugLog "VAR MediaBrowser notification schema found=$($null -ne $mbSchema) impl=$([string]$mbSchema.implementation) fields=$($mbSchema.fields.Count)"

            if (-not $mbSchema) {
                Write-Warning "     MediaBrowser (Jellyfin) not found in $AppName notification schema. Skipping."
                Write-DebugLog "WARN" "MediaBrowser schema not found"
            } else {
                $existingNotifs = @()
                try {
                    # No @() around the call: in PS 5.1 @(Invoke-RestMethod ...) collapses
                    # the whole response array into ONE element, so the loop below would
                    # hand $jfNotif the array itself and $jfNotif.id would read back as
                    # "11 12 13" -- pointing the update PUT at a non-existent id.
                    $existingNotifs = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/notification" `
                        -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
                    Write-DebugLog "VAR existing notifications=$(@($existingNotifs).Count)"
                } catch { Write-DebugLog "WARN" "Could not fetch existing notifications: $_" }
                $jfNotif = $null
                foreach ($n in $existingNotifs) {
                    if ($n.implementation -eq "MediaBrowser") { $jfNotif = $n; break }
                }
                Write-DebugLog "VAR Jellyfin notification exists=$($null -ne $jfNotif)"

                # Patch field values in-place.  Schema fields carry 'defaultValue' but no
                # 'value'; Radarr rejects a POST where any field is missing 'value'.
                foreach ($field in $mbSchema.fields) {
                    if (-not ($field.PSObject.Properties.Name -contains 'value')) {
                        $dv = if ($field.PSObject.Properties.Name -contains 'defaultValue') { $field.defaultValue } else { $null }
                        $field | Add-Member -MemberType NoteProperty -Name 'value' -Value $dv -Force
                    }
                    switch ($field.name) {
                        "host"          { $field | Add-Member -MemberType NoteProperty -Name 'value' -Value '127.0.0.1'        -Force }
                        "port"          { $field | Add-Member -MemberType NoteProperty -Name 'value' -Value ([int]$JellyfinPort) -Force }
                        "apiKey"        { $field | Add-Member -MemberType NoteProperty -Name 'value' -Value $JellyfinApiKey    -Force }
                        "ssl"           { $field | Add-Member -MemberType NoteProperty -Name 'value' -Value $false             -Force }
                        "urlBase"       { $field | Add-Member -MemberType NoteProperty -Name 'value' -Value $JellyfinUrlBase   -Force }
                        "updateLibrary" { $field | Add-Member -MemberType NoteProperty -Name 'value' -Value $true              -Force }
                    }
                }
                Write-DebugLog "VAR notification fields patched: host=127.0.0.1 port=$JellyfinPort urlBase=$JellyfinUrlBase apiKey=[REDACTED]"

                # Build payload with explicit typed property access to avoid any
                # PSObject.Properties array-flattening issues in PS 5.1.
                $payload = [ordered]@{
                    id                   = 0
                    name                 = "Jellyfin"
                    enable               = $true
                    implementationName   = [string]$mbSchema.implementationName
                    implementation       = [string]$mbSchema.implementation
                    configContract       = [string]$mbSchema.configContract
                    infoLink             = [string]$mbSchema.infoLink
                    fields               = @($mbSchema.fields)
                    tags                 = @()
                    onGrab               = $false
                    onDownload           = $true
                    onUpgrade            = $true
                    onRename             = $true
                    onMovieAdded         = $false
                    onMovieDelete        = $true
                    onMovieFileDelete    = $true
                    onMovieFileDeleteForUpgrade = $true
                    onHealthIssue        = $false
                    onHealthRestored     = $false
                    onApplicationUpdate  = $false
                    onManualInteractionRequired = $false
                    supportsOnGrab       = [bool]$mbSchema.supportsOnGrab
                    supportsOnDownload   = [bool]$mbSchema.supportsOnDownload
                    supportsOnUpgrade    = [bool]$mbSchema.supportsOnUpgrade
                    includeHealthWarnings = $false
                }
                Write-DebugLog "VAR notification payload: implementation=$($payload['implementation']) configContract=$($payload['configContract']) fields=$($payload['fields'].Count)"

                if ($jfNotif) { $payload["id"] = $jfNotif.id }
                $body = $payload | ConvertTo-Json -Depth 10 -Compress

                if ($jfNotif) {
                    Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/notification/$($jfNotif.id)" `
                        -Method Put `
                        -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
                        -Body $body -UseBasicParsing -ErrorAction Stop | Out-Null
                    Write-Host "     [OK] Updated Jellyfin notification." -ForegroundColor Green
                    Write-DebugLog "INFO" "Jellyfin notification updated (id=$($jfNotif.id))"
                } else {
                    Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/notification" `
                        -Method Post `
                        -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
                        -Body $body -UseBasicParsing -ErrorAction Stop | Out-Null
                    Write-Host "     [OK] Added Jellyfin notification." -ForegroundColor Green
                    Write-DebugLog "INFO" "Jellyfin notification created"
                }
            }
        } catch {
            try {
                $errStream = $_.Exception.Response.GetResponseStream()
                $errDetail = (New-Object System.IO.StreamReader($errStream)).ReadToEnd()
                Write-DebugLog "WARN" "Jellyfin notification API error body: $errDetail"
            } catch {}
            Write-Warning "[$AppName] Failed to configure Jellyfin notification: $_"
            Write-DebugLog "WARN" "Jellyfin notification configuration failed: $_"
        }
    }
}

# -- 9. Register the Jellyfin movie refresh hook ------------------------------
# Mirrors Sonarr's hook, for a different reason: Sonarr repairs a broken season
# hierarchy, Radarr only needs the discovery step. The library scan at install
# time runs while the media folder is still empty, so Jellyfin logs
# "inaccessible or empty, skipping"; the MediaBrowser notification's
# Library/Media/Updated then only refreshes paths Jellyfin already knows, and a
# movie imported afterwards stays invisible until the next full scan. The hook
# triggers POST /Library/Refresh when Jellyfin does not know the movie. It
# re-launches itself detached, so it cannot stall Radarr's import pipeline.
if ($Config.Apps.Jellyfin -eq $true) {
    $JellyfinKeyFile = Join-Path $Config.General.InstallDir "secrets\jellyfin_api_key.txt"
    $HookSource      = Join-Path $PSScriptRoot "sonarr_jellyfin_refresh.py"
    if (-not (Test-Path $JellyfinKeyFile) -or -not (Test-Path $HookSource)) {
        Write-Host "  [WARN] Jellyfin API key or hook source missing  --  movie refresh hook skipped." -ForegroundColor Yellow
        Write-DebugLog "WARN" "Movie refresh hook skipped (key=$(Test-Path $JellyfinKeyFile) source=$(Test-Path $HookSource))"
    } else {
        try {
            $JellyfinApiKey  = (Get-Content $JellyfinKeyFile -Raw -Encoding UTF8).TrimStart([char]0xFEFF).Trim()
            $JellyfinPort    = $Config.Ports.Jellyfin
            $JellyfinUrlBase = if ($DomainMode -eq "duckdns") { "/jellyfin" } else { "" }
            $JellyfinBase    = "http://127.0.0.1:$JellyfinPort$JellyfinUrlBase"
            $InstallDir      = $Config.General.InstallDir

            # Same interpreter rules as Sonarr's hook: the wrapper is executed by
            # Radarr, which runs as seedbox-svc, so a per-user Python or the Store
            # alias cannot be used.
            $PythonExe = $null
            foreach ($candidate in @("C:\Python312\python.exe")) {
                if (Test-Path $candidate) { $PythonExe = $candidate; break }
            }
            if (-not $PythonExe) {
                Get-ChildItem "C:\Python3*" -Directory -ErrorAction SilentlyContinue |
                    Sort-Object Name -Descending | ForEach-Object {
                        if ($PythonExe) { return }
                        $p = Join-Path $_.FullName "python.exe"
                        if (Test-Path $p) { $PythonExe = $p }
                    }
            }
            if (-not $PythonExe) {
                $gc = Get-Command python -ErrorAction SilentlyContinue
                if ($gc -and $gc.Source -notlike "$env:SystemDrive\Users\*" -and $gc.Source -notlike '*\WindowsApps\*') {
                    $PythonExe = $gc.Source
                }
            }
            if (-not $PythonExe) { throw "no Python interpreter usable by the service account was found" }

            # The sidecar is normally written by Sonarr's Layer 2; write it here when
            # Sonarr is disabled or ran after this script.
            $HookConfigPath = Join-Path $InstallDir "secrets\jellyfin_hook.json"
            if (-not (Test-Path $HookConfigPath)) {
                $jfClient = 'MediaBrowser Client="seedbox-install", Device="configure", DeviceId="seedbox-install", Version="1.0.0"'
                $jfUsers  = Invoke-RestMethod -Uri "$JellyfinBase/Users" `
                    -Headers @{"Authorization" = ($jfClient + ', Token="' + $JellyfinApiKey + '"')} `
                    -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
                $JellyfinUserId = $null
                foreach ($u in $jfUsers) {
                    if ($u.Policy -and $u.Policy.IsAdministrator -eq $true) { $JellyfinUserId = [string]$u.Id; break }
                }
                if (-not $JellyfinUserId) { throw "no Jellyfin administrator account resolved at '$JellyfinBase'" }
                $hookSettings = [ordered]@{ base_url = $JellyfinBase; api_key = $JellyfinApiKey; user_id = $JellyfinUserId }
                [System.IO.File]::WriteAllText($HookConfigPath, ($hookSettings | ConvertTo-Json -Compress),
                    (New-Object System.Text.UTF8Encoding($false)))
                Write-DebugLog "INFO" "Jellyfin hook settings written by Radarr Layer 2: $HookConfigPath"
            }

            $RefreshPy  = Join-Path $InstallDir "radarr_jellyfin_refresh.py"
            $RefreshCmd = Join-Path $InstallDir "radarr_jellyfin_refresh.cmd"
            Copy-Item -LiteralPath $HookSource -Destination $RefreshPy -Force
            [System.IO.File]::WriteAllText($RefreshCmd,
                "@echo off`r`n`"$PythonExe`" `"%~dp0radarr_jellyfin_refresh.py`"`r`n",
                [System.Text.Encoding]::ASCII)

            # Radarr validates a CustomScript notification by executing it and
            # requiring exit 0 -- prove the wrapper first, so registration cannot
            # fail with a bare 400.
            $probeOut  = & cmd.exe /c "`"$RefreshCmd`"" 2>&1
            $probeCode = $LASTEXITCODE
            if ($probeCode -ne 0) {
                throw "generated hook wrapper exits $probeCode when Radarr tests it ($(($probeOut -join ' ').Trim()))"
            }

            $notifSchemas = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/notification/schema" `
                -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
            $scriptSchema = $null
            foreach ($s in $notifSchemas) {
                if ($s.implementation -eq "CustomScript") { $scriptSchema = $s; break }
            }
            if (-not $scriptSchema) { throw "CustomScript not present in the Radarr notification schema" }

            $existingScripts = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/notification" `
                -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
            $hookExists = $null
            foreach ($n in $existingScripts) {
                if ($n.implementation -eq "CustomScript" -and
                    ($n.fields | Where-Object { $_.name -eq "path" -and $_.value -like "*radarr_jellyfin_refresh*" })) {
                    $hookExists = $n; break
                }
            }

            foreach ($field in $scriptSchema.fields) {
                $v = if ($field.PSObject.Properties.Name -contains 'defaultValue') { $field.defaultValue } else { $null }
                if ($field.name -eq "path") { $v = $RefreshCmd }
                $field | Add-Member -MemberType NoteProperty -Name 'value' -Value $v -Force
            }

            $hookPayload = [ordered]@{
                id                 = if ($hookExists) { $hookExists.id } else { 0 }
                name               = "Jellyfin Movie Refresh"
                enable             = $true
                implementationName = [string]$scriptSchema.implementationName
                implementation     = [string]$scriptSchema.implementation
                configContract     = [string]$scriptSchema.configContract
                infoLink           = [string]$scriptSchema.infoLink
                fields             = @($scriptSchema.fields)
                tags               = @()
                onGrab             = $false
                onDownload         = $true
                onUpgrade          = $true
                onRename           = $false
                onMovieAdded       = $false
                onMovieDelete      = $false
                onMovieFileDelete  = $false
                onMovieFileDeleteForUpgrade = $false
                onHealthIssue      = $false
                onHealthRestored   = $false
                onApplicationUpdate = $false
                onManualInteractionRequired = $false
                includeHealthWarnings = $false
            }
            $hookBody = $hookPayload | ConvertTo-Json -Depth 10 -Compress

            if ($hookExists) {
                Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/notification/$($hookExists.id)" `
                    -Method Put -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
                    -Body $hookBody -UseBasicParsing -ErrorAction Stop | Out-Null
                Write-Host "     [OK] Jellyfin movie refresh hook updated." -ForegroundColor Green
            } else {
                Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/notification" `
                    -Method Post -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
                    -Body $hookBody -UseBasicParsing -ErrorAction Stop | Out-Null
                Write-Host "     [OK] Jellyfin movie refresh hook registered." -ForegroundColor Green
            }
            Write-DebugLog "INFO" "Jellyfin movie refresh hook registered: $RefreshCmd (settings=$HookConfigPath)"
        } catch {
            Write-Warning "[$AppName] Failed to register the Jellyfin movie refresh hook: $_"
            Write-DebugLog "WARN" "Movie refresh hook registration failed: $_"
        }
    }
}

Write-Host "  [OK] $AppName Layer 2 configuration complete." -ForegroundColor Green
Write-DebugLog "INFO" "configure_layer2_radarr.ps1 complete"

exit 0