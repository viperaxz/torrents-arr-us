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
Write-DebugLog "INFO" "configure_layer2_sonarr.ps1 started"

$AppName      = "Sonarr"
$Port         = $Config.Ports.Sonarr
$Enabled      = $Config.Apps.Sonarr -eq $true
$Layer2Config = $Config.Layer2.Sonarr
$DomainMode   = $Config.General.DomainMode
$UrlBase      = if ($DomainMode -eq "duckdns") { "/sonarr" } else { "" }

$DataDir  = "C:\ProgramData\$AppName"
$ConfigXml = Join-Path $DataDir "config.xml"

Write-DebugLog "VAR AppName=$AppName Port=$Port Enabled=$Enabled DomainMode=$DomainMode UrlBase=$UrlBase"

if (-not $Enabled) {
    Write-Host "[$AppName] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "$AppName skipped (not enabled)"
    return
}

if (-not $Layer2Config) {
    Write-Host "  [WARN] No Layer2 config found for $AppName. Skipping." -ForegroundColor Yellow
    Write-DebugLog "WARN" "No Layer2 config found for $AppName"
    return
}

Write-DebugLog "VAR Layer2Config RootFolders=$($Layer2Config.RootFolders.Count) DownloadClients=$($Layer2Config.DownloadClients.Count)"

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
    Start-Service -Name $AppName -ErrorAction SilentlyContinue
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
    Write-DebugLog "ERROR" "ApiKey not found in config.xml"
    exit 1
}

# -- 3. Wait for API -----------------------------------------------------------
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
            Write-DebugLog "VAR root folder '$folderPath' alreadyExists=$($null -ne $exists)"

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
if ($Layer2Config.DownloadClients -and $Layer2Config.DownloadClients.Count -gt 0) {
    Write-Host "  -> Configuring download clients..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Configuring $($Layer2Config.DownloadClients.Count) download client(s)..."

    # Read Deluge password written by 07_deluge.ps1 / configure_layer1_deluge.ps1
    $DelugeAuthFile = Join-Path $Config.General.InstallDir "secrets\deluge_auth.txt"
    Write-DebugLog "VAR DelugeAuthFile=$DelugeAuthFile (exists=$(Test-Path $DelugeAuthFile))"
    if (-not (Test-Path $DelugeAuthFile)) {
        Write-Warning "[$AppName] Deluge auth file not found at '$DelugeAuthFile'. Download client NOT configured."
        Write-Warning "     Run configure_layer1_deluge.ps1 first, then re-run this script to add the download client."
        Write-DebugLog "WARN" "Deluge auth file not found -- skipping download client config"
        return
    }
    $DelugePassword = (Get-Content -Path $DelugeAuthFile -Raw -Encoding UTF8).TrimStart([char]0xFEFF).Trim()
    Write-DebugLog "VAR DelugePassword loaded (length=$($DelugePassword.Length)) [REDACTED]"

    try {
        $existingClients = @()
        try {
            $existingClients = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/downloadclient" `
                -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
            Write-DebugLog "VAR existing download clients=$($existingClients.Count)"
        } catch { Write-DebugLog "WARN" "Could not fetch existing clients: $_" }

        # Fetch the Deluge schema  --  Sonarr requires a complete schema-valid payload
        Write-DebugLog "INFO" "Fetching download client schema..."
        $schemas = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/downloadclient/schema" `
            -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
        $delugeSchema = $schemas | Where-Object { $_.implementation -eq "Deluge" } | Select-Object -First 1
        Write-DebugLog "VAR Deluge schema found=$($null -ne $delugeSchema)"
        if (-not $delugeSchema) {
            Write-Warning "     Deluge not found in $AppName download client schema  --  check $AppName version."
            Write-DebugLog "ERROR" "Deluge not found in download client schema"
            exit 1
        }

        foreach ($client in $Layer2Config.DownloadClients) {
            $clientName = $client.Name
            $exists = $existingClients | Where-Object { $_.name -eq $clientName }
            Write-DebugLog "VAR download client '$clientName' exists=$($null -ne $exists) host=$($client.Host) port=$($client.Port)"

            # Deep-clone schema so we start from a complete valid object
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
                    "tvCategory"   { $field.value = "tv-sonarr" }
                    { $_ -eq "recentTvPriority" -or $_ -eq "olderTvPriority" } { $field.value = 1 }
                }
            }
            Write-DebugLog "VAR download client payload fields patched (host=$($client.Host) port=$($client.Port) password=[REDACTED])"

            # Convert to hashtable so we can cleanly inject id/name/etc
            $payload = @{}
            $schemaClone.PSObject.Properties | ForEach-Object { $payload[$_.Name] = $_.Value }
            $payload["enable"]   = $true
            $payload["name"]     = $clientName
            $payload["priority"] = [int]$client.Priority
            if ($exists) { $payload["id"] = $exists.id }
            $body = $payload | ConvertTo-Json -Depth 10 -Compress

            if ($exists) {
                Write-DebugLog "INFO" "Updating existing download client '$clientName' (id=$($exists.id))..."
                Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/downloadclient/$($exists.id)" `
                    -Method Put `
                    -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
                    -Body $body `
                    -UseBasicParsing -ErrorAction Stop | Out-Null
                Write-Host "     [OK] Updated download client: $clientName" -ForegroundColor Green
                Write-DebugLog "INFO" "Download client '$clientName' updated"
            } else {
                Write-DebugLog "INFO" "Creating download client '$clientName'..."
                Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/downloadclient" `
                    -Method Post `
                    -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
                    -Body $body `
                    -UseBasicParsing -ErrorAction Stop | Out-Null
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
    Write-DebugLog "INFO" "Configuring seed criteria: ratio=$SeedRatio for $($PublicIndexerNames.Count) public indexers"

    try {
        $sonarrIndexers = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/indexer" `
            -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
        Write-DebugLog "VAR Sonarr indexers from API=$($sonarrIndexers.Count)"

        foreach ($idx in $sonarrIndexers) {
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
            if ($currentRatio -eq $targetRatio) {
                Write-DebugLog "VAR indexer '$($idx.name)' ratio already correct"
                continue
            }

            $ratioField | Add-Member -MemberType NoteProperty -Name 'value' -Value $targetRatio -Force
            $payload = @{}
            $idx.PSObject.Properties | ForEach-Object { $payload[$_.Name] = $_.Value }
            $body = $payload | ConvertTo-Json -Depth 10 -Compress

            try {
                Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/indexer/$($idx.id)" `
                    -Method Put `
                    -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
                    -Body $body -UseBasicParsing -ErrorAction Stop | Out-Null
                if ($isPublic) {
                    Write-Host "     [OK] $($idx.name): seed ratio set to $SeedRatio" -ForegroundColor Green
                    Write-DebugLog "INFO" "Indexer '$($idx.name)' seed ratio set to $SeedRatio"
                } else {
                    Write-Host "     [OK] $($idx.name): seed ratio cleared (private  --  unlimited)" -ForegroundColor Green
                    Write-DebugLog "INFO" "Indexer '$($idx.name)' seed ratio cleared (private)"
                }
            } catch {
                Write-Warning "     Failed to update seed ratio for '$($idx.name)': $_"
                Write-DebugLog "WARN" "Failed to update seed ratio for '$($idx.name)': $_"
            }
        }
    } catch {
        Write-Warning "[$AppName] Failed to configure seed criteria: $_"
        Write-DebugLog "WARN" "Seed criteria configuration failed: $_"
    }
}

# -- 7. Naming scheme + Media Management --------------------------------------
Write-Host "  -> Configuring naming scheme and media management..." -ForegroundColor Gray
Write-DebugLog "INFO" "Configuring TRaSH naming scheme..."
try {
    $naming = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/config/naming" `
        -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
    Write-DebugLog "VAR current renameEpisodes=$($naming.renameEpisodes)"

    $naming.renameEpisodes        = $true
    $naming.standardEpisodeFormat = "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle:90} {[Custom Formats]}{[Quality Full]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}"
    $naming.dailyEpisodeFormat    = "{Series TitleYear} - {Air-Date} - {Episode CleanTitle:90} {[Custom Formats]}{[Quality Full]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}"
    $naming.seriesFolderFormat    = "{Series TitleYear}"
    $naming.seasonFolderFormat    = "Season {season:00}"
    $naming.multiEpisodeStyle     = 5

    Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/config/naming" `
        -Method Put -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
        -Body ($naming | ConvertTo-Json -Depth 10 -Compress) -UseBasicParsing -ErrorAction Stop | Out-Null
    Write-DebugLog "INFO" "Naming scheme updated (TRaSH format, renameEpisodes=true)"

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
    Write-DebugLog "WARN" "Naming/media management configuration failed: $_"
}

# -- 8. Configure Jellyfin (MediaBrowser) notification ------------------------
if ($Config.Apps.Jellyfin -eq $true) {
    Write-Host "  -> Configuring Jellyfin notification..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Configuring Jellyfin MediaBrowser notification..."

    $JellyfinKeyFile = Join-Path $Config.General.InstallDir "secrets\jellyfin_api_key.txt"
    Write-DebugLog "VAR JellyfinKeyFile=$JellyfinKeyFile (exists=$(Test-Path $JellyfinKeyFile))"
    if (-not (Test-Path $JellyfinKeyFile)) {
        Write-Host "  [WARN] Jellyfin API key not found  --  run Jellyfin Layer 2 first. Skipping." -ForegroundColor Yellow
        Write-DebugLog "WARN" "Jellyfin API key file not found at $JellyfinKeyFile  --  skipping notification setup"
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
                Write-DebugLog "WARN" "MediaBrowser schema not found in $AppName notifications"
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
                # 'value'; Sonarr rejects a POST where any field is missing 'value'.
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
                    onSeriesAdd          = $false
                    onSeriesDelete       = $true
                    onEpisodeFileDelete  = $true
                    onEpisodeFileDeleteForUpgrade = $true
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
                    Write-Host "     [OK] Updated Jellyfin notification (library refresh on import)." -ForegroundColor Green
                    Write-DebugLog "INFO" "Jellyfin notification updated (id=$($jfNotif.id))"
                } else {
                    Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/notification" `
                        -Method Post `
                        -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
                        -Body $body -UseBasicParsing -ErrorAction Stop | Out-Null
                    Write-Host "     [OK] Added Jellyfin notification (library refresh on import)." -ForegroundColor Green
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

# -- 9. Register post-import Jellyfin series refresh hook ---------------------
# Sonarr fires its Jellyfin notification immediately at import, before TVDB
# metadata finishes  --  leaving the season detached from the series. This custom
# script fires on every OnDownload event, waits 45 s, then calls
# Items/{seriesId}/Refresh so the hierarchy is always correct.
#
# The hook runs as seedbox-svc, which must NOT be able to read config.json (it
# holds every credential in the stack).  It therefore gets a purpose-built sidecar
# in the ACL-protected secrets directory -- base URL, Jellyfin API key and admin
# user id, nothing else -- and both the script and its wrapper are deployed into
# InstallDir, which is already that account's own directory.  No ACL anywhere is
# widened for this hook.
$RefreshScriptSrc = Join-Path $PSScriptRoot "sonarr_jellyfin_refresh.py"
Write-DebugLog "VAR RefreshScriptSrc=$RefreshScriptSrc (exists=$(Test-Path $RefreshScriptSrc))"

if ((Test-Path $RefreshScriptSrc) -and $Config.Apps.Jellyfin -eq $true) {
    # The chosen interpreter is baked into a .cmd that SONARR executes, and Sonarr
    # runs as the service account -- so the interpreter must be readable by THAT
    # account, not merely by the operator running this installer. A Python under
    # C:\Users\<name>\ is not (another user's profile grants no access), and the
    # Microsoft Store alias under WindowsApps is not a real interpreter at all.
    # The PATH fallback below previously selected the operator's per-user Python,
    # producing a wrapper that died with "is not recognized as an internal or
    # external command" -- which made Sonarr reject the notification with HTTP
    # 400 "Script exited with code: 1".
    function Test-PythonForService {
        param([string]$Path)
        if (-not $Path -or -not (Test-Path $Path)) { return $false }
        if ($Path -like "$env:SystemDrive\Users\*" -or $Path -like '*\WindowsApps\*') {
            Write-DebugLog "WARN" "Python candidate rejected -- not readable by service account: $Path"
            return $false
        }
        return $true
    }

    $PythonExe = $null
    if (Test-PythonForService "C:\Python312\python.exe") {
        $PythonExe = "C:\Python312\python.exe"
    } else {
        Get-ChildItem "C:\Python3*" -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | ForEach-Object {
                if ($PythonExe) { return }
                $p = Join-Path $_.FullName "python.exe"
                if (Test-PythonForService $p) { $PythonExe = $p }
            }
    }
    if (-not $PythonExe) {
        $gc = Get-Command python -ErrorAction SilentlyContinue
        if ($gc -and (Test-PythonForService $gc.Source)) { $PythonExe = $gc.Source }
    }

    if ($PythonExe -and (Test-Path $PythonExe)) {
        Write-Host "  -> Registering Jellyfin series refresh hook..." -ForegroundColor Gray
        try {
            # -- 9a. Resolve what the hook needs: no config.json, no password ----
            $InstallDir      = $Config.General.InstallDir
            $JellyfinKeyFile = Join-Path $InstallDir "secrets\jellyfin_api_key.txt"
            Write-DebugLog "VAR JellyfinKeyFile=$JellyfinKeyFile (exists=$(Test-Path $JellyfinKeyFile))"
            if (-not (Test-Path $JellyfinKeyFile)) {
                throw "Jellyfin API key not found at '$JellyfinKeyFile' -- re-run scripts\configure_layer2_jellyfin_libraries.ps1 (it writes the key), then re-run this script"
            }
            $JellyfinApiKey = ([System.IO.File]::ReadAllText($JellyfinKeyFile, [System.Text.Encoding]::UTF8)).TrimStart([char]0xFEFF).Trim()
            if (-not $JellyfinApiKey) {
                throw "Jellyfin API key file '$JellyfinKeyFile' is empty -- re-run scripts\configure_layer2_jellyfin_libraries.ps1, then re-run this script"
            }

            # Mode-aware base URL, built the same way section 8 does it.
            $JellyfinUrlBase = if ($DomainMode -eq "duckdns") { "/jellyfin" } else { "" }
            $JellyfinBase    = "http://127.0.0.1:$($Config.Ports.Jellyfin)$JellyfinUrlBase"

            # Resolve the admin user id HERE, at configure time, so a hook that
            # cannot authenticate fails loudly during install instead of silently
            # no-op'ing on every future download.
            $JellyfinUserId = $null
            try {
                # No @() around the call: in PS 5.1 @(Invoke-RestMethod ...) collapses the
                # response array into a single element, so the loop below would receive the
                # array rather than a user and [string]$u.Id would become "id1 id2 id3".
                $jfUsers = Invoke-RestMethod -Uri "$JellyfinBase/Users" `
                    -Headers @{"X-Emby-Authorization" = "MediaBrowser Token=`"$JellyfinApiKey`""} `
                    -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
                foreach ($u in $jfUsers) {
                    if ($u.Policy -and $u.Policy.IsAdministrator -eq $true) { $JellyfinUserId = [string]$u.Id; break }
                }
                Write-DebugLog "VAR Jellyfin users=$(@($jfUsers).Count) adminUserId=$JellyfinUserId"
            } catch {
                Write-DebugLog "WARN" "Could not list Jellyfin users at $JellyfinBase : $_"
            }
            if (-not $JellyfinUserId) {
                throw "no Jellyfin administrator account resolved at '$JellyfinBase' -- check that Jellyfin is running and has an admin user, then re-run this script"
            }

            # -- 9b. Write the hook's own settings into the ACL-protected dir ----
            $HookConfigPath = Join-Path $InstallDir "secrets\jellyfin_hook.json"
            $hookSettings = [ordered]@{
                base_url = $JellyfinBase
                api_key  = $JellyfinApiKey
                user_id  = $JellyfinUserId
            }
            $secretsDir = Split-Path $HookConfigPath -Parent
            if (-not (Test-Path $secretsDir)) { New-Item -Path $secretsDir -ItemType Directory -Force | Out-Null }
            # BOM-free, and only those three fields -- secrets\ keeps its existing
            # ACL (Administrators/SYSTEM full, seedbox-svc read); nothing here
            # loosens it, and the admin password is never copied out of config.json.
            [System.IO.File]::WriteAllText($HookConfigPath, ($hookSettings | ConvertTo-Json -Compress),
                (New-Object System.Text.UTF8Encoding($false)))
            Write-DebugLog "INFO" "Jellyfin hook settings written: $HookConfigPath (base_url=$JellyfinBase userId=$JellyfinUserId ******"

            # -- 9c. Deploy the hook into InstallDir (seedbox-svc's own dir) -----
            # %~dp0 keeps the wrapper location-independent, so the .py finds its
            # sidecar as <script dir>\secrets\jellyfin_hook.json wherever it lands.
            $RefreshPy  = Join-Path $InstallDir "sonarr_jellyfin_refresh.py"
            $RefreshCmd = Join-Path $InstallDir "sonarr_jellyfin_refresh.cmd"
            Copy-Item -LiteralPath $RefreshScriptSrc -Destination $RefreshPy -Force
            $cmdContent = "@echo off`r`n`"$PythonExe`" `"%~dp0sonarr_jellyfin_refresh.py`"`r`n"
            [System.IO.File]::WriteAllText($RefreshCmd, $cmdContent, [System.Text.Encoding]::ASCII)
            $RefreshScript = $RefreshCmd
            Write-DebugLog "INFO" "Refresh hook deployed: $RefreshScript (settings=$HookConfigPath)"

            # Sonarr validates a CustomScript notification by EXECUTING it and
            # requiring exit code 0 (the hook script itself exits 0 when
            # sonarr_eventtype is empty). Prove the wrapper works here instead of
            # letting the registration POST fail with a bare 400 whose only clue
            # is "Script exited with code: 1" -- which is exactly what a wrong or
            # unreadable interpreter produces.
            $probeOut  = & cmd.exe /c "`"$RefreshCmd`"" 2>&1
            $probeCode = $LASTEXITCODE
            Write-DebugLog "VAR hook wrapper self-test exit=$probeCode output=$(($probeOut -join ' ').Trim())"
            if ($probeCode -ne 0) {
                throw "generated hook wrapper exits $probeCode when Sonarr tests it ($(($probeOut -join ' ').Trim()))"
            }

            # -- 9d. Register the Custom Script connection in Sonarr -------------
            # No @() around the call: in PS 5.1 @(Invoke-RestMethod ...) collapses the
            # response array into a single element, which would make the detection loop
            # below select the array itself and read .id as "11 12 13".
            $existingScripts = Invoke-RestMethod `
                -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/notification" `
                -Headers @{"X-Api-Key"=$ApiKey} -UseBasicParsing -ErrorAction Stop
            $hookExists = $null
            foreach ($n in $existingScripts) {
                if ($n.implementation -eq "CustomScript" -and
                    ($n.fields | Where-Object { $_.name -eq "path" -and $_.value -like "*sonarr_jellyfin_refresh*" })) {
                    $hookExists = $n; break
                }
            }
            $hookPath = if ($hookExists) {
                ($hookExists.fields | Where-Object { $_.name -eq "path" } | Select-Object -First 1).value
            } else { $null }
            Write-DebugLog "VAR JellyfinRefreshHook exists=$($null -ne $hookExists) path=$hookPath"

            if ($hookExists -and $hookPath -ne $RefreshScript) {
                # An earlier install registered the hook against a different path
                # (for example a copy made under the project tree). Re-point it
                # instead of leaving a hook that silently does nothing.
                foreach ($field in $hookExists.fields) {
                    if (-not ($field.PSObject.Properties.Name -contains 'value')) {
                        $field | Add-Member -MemberType NoteProperty -Name 'value' -Value $null -Force
                    }
                    if ($field.name -eq "path") { $field.value = $RefreshScript }
                }
                $hookExists.enable     = $true
                $hookExists.onDownload = $true
                $hookExists.onUpgrade  = $true
                Invoke-RestMethod `
                    -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/notification/$($hookExists.id)" `
                    -Method Put `
                    -Headers @{"X-Api-Key"=$ApiKey; "Content-Type"="application/json"} `
                    -Body ($hookExists | ConvertTo-Json -Depth 10 -Compress) `
                    -UseBasicParsing -ErrorAction Stop | Out-Null
                Write-Host "     [OK] Jellyfin series refresh hook re-pointed to the project script." -ForegroundColor Green
                Write-DebugLog "INFO" "Jellyfin refresh hook re-pointed: '$hookPath' -> '$RefreshScript'"
            } elseif (-not $hookExists) {
                $hookSchema = $null
                $schemas2 = Invoke-RestMethod `
                    -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/notification/schema" `
                    -Headers @{"X-Api-Key"=$ApiKey} -UseBasicParsing -ErrorAction Stop
                foreach ($s in $schemas2) {
                    if ($s.implementation -eq "CustomScript") { $hookSchema = $s; break }
                }

                if ($hookSchema) {
                    foreach ($field in $hookSchema.fields) {
                        $v = $field.defaultValue
                        # Sonarr v4 removed the arguments field  --  path must be
                        # a directly-executable file (.cmd wrapping python)
                        if ($field.name -eq "path") { $v = $RefreshScript }
                        $field | Add-Member -MemberType NoteProperty -Name 'value' -Value $v -Force
                    }

                    $hookPayload = [ordered]@{
                        id                 = 0
                        name               = "Jellyfin Series Refresh"
                        enable             = $true
                        implementationName = [string]$hookSchema.implementationName
                        implementation     = [string]$hookSchema.implementation
                        configContract     = [string]$hookSchema.configContract
                        infoLink           = [string]$hookSchema.infoLink
                        fields             = @($hookSchema.fields)
                        tags               = @()
                        onGrab             = $false
                        onDownload         = $true
                        onUpgrade          = $true
                        onRename           = $false
                        onSeriesAdd        = $false
                        onSeriesDelete     = $false
                        onEpisodeFileDelete              = $false
                        onEpisodeFileDeleteForUpgrade    = $false
                        onHealthIssue      = $false
                        onHealthRestored   = $false
                        onApplicationUpdate              = $false
                        onManualInteractionRequired      = $false
                        supportsOnGrab     = [bool]$hookSchema.supportsOnGrab
                        supportsOnDownload = [bool]$hookSchema.supportsOnDownload
                        supportsOnUpgrade  = [bool]$hookSchema.supportsOnUpgrade
                        includeHealthWarnings = $false
                    }
                    $hookBody = $hookPayload | ConvertTo-Json -Depth 10 -Compress
                    Invoke-RestMethod `
                        -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/notification" `
                        -Method Post `
                        -Headers @{"X-Api-Key"=$ApiKey; "Content-Type"="application/json"} `
                        -Body $hookBody -UseBasicParsing -ErrorAction Stop | Out-Null
                    Write-Host "     [OK] Jellyfin series refresh hook registered." -ForegroundColor Green
                    Write-DebugLog "INFO" "Jellyfin refresh custom script registered in Sonarr"
                }
            } else {
                Write-Host "     ~ Jellyfin series refresh hook already registered." -ForegroundColor DarkGray
                Write-DebugLog "INFO" "Jellyfin refresh hook already exists"
            }
        } catch {
            Write-Warning "     Jellyfin series refresh hook NOT registered: $_"
            Write-DebugLog "WARN" "Jellyfin refresh hook not registered: $_"
        }
    } else {
        Write-Warning "     Python not found  --  Jellyfin series refresh hook NOT registered."
        Write-DebugLog "WARN" "No Python interpreter found; refresh hook skipped"
    }
}

Write-Host "  [OK] $AppName Layer 2 configuration complete." -ForegroundColor Green
Write-DebugLog "INFO" "configure_layer2_sonarr.ps1 complete"

exit 0
