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
    Write-DebugLog "ERROR" "ApiKey not found"
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
if ($Layer2Config.DownloadClients -and $Layer2Config.DownloadClients.Count -gt 0) {
    Write-Host "  -> Configuring download clients..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Configuring $($Layer2Config.DownloadClients.Count) download client(s)..."

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
$SeedRatio = if ($Config.Layer2.PSObject.Properties['PublicTrackerSeedRatio'] -and $null -ne $Config.Layer2.PublicTrackerSeedRatio) {
    [double]$Config.Layer2.PublicTrackerSeedRatio
} else { 1.0 }
$PublicIndexerNames = @($Config.Layer2.Prowlarr.Indexers | ForEach-Object { $_.Name })
Write-DebugLog "VAR SeedRatio=$SeedRatio PublicIndexers=$($PublicIndexerNames.Count)"

if ($SeedRatio -and $PublicIndexerNames.Count -gt 0) {
    Write-Host "  -> Configuring seed criteria (public ratio=$SeedRatio)..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Configuring seed criteria: ratio=$SeedRatio"
    try {
        $radarrIndexers = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/indexer" `
            -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
        Write-DebugLog "VAR Radarr indexers from API=$($radarrIndexers.Count)"

        foreach ($idx in $radarrIndexers) {
            $baseName   = $idx.name -replace '\s*\(Prowlarr\)\s*$', ''
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
                    $existingNotifs = @(Invoke-RestMethod -Uri "http://127.0.0.1:$Port$UrlBase/api/v3/notification" `
                        -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop)
                    Write-DebugLog "VAR existing notifications=$($existingNotifs.Count)"
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

Write-Host "  [OK] $AppName Layer 2 configuration complete." -ForegroundColor Green
Write-DebugLog "INFO" "configure_layer2_radarr.ps1 complete"
