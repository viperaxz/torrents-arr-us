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

# nssm services can sit in Stop Pending indefinitely and the built-in cmdlets wait
# on that forever. These helpers are bounded. See service_helpers.ps1.
if (-not (Get-Command Stop-ServiceBounded -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "service_helpers.ps1")
}
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "configure_layer2_prowlarr.ps1 started"

$AppName      = "Prowlarr"
$Port         = $Config.Ports.Prowlarr
$Enabled      = $Config.Apps.Prowlarr -eq $true
$Layer2Config = $Config.Layer2.Prowlarr

$DataDir         = "C:\ProgramData\$AppName"
$ConfigXml       = Join-Path $DataDir "config.xml"
$DomainMode      = $Config.General.DomainMode
$SonarrUrlBase   = if ($DomainMode -eq "duckdns") { "/sonarr"   } else { "" }
$RadarrUrlBase   = if ($DomainMode -eq "duckdns") { "/radarr"   } else { "" }
$ProwlarrUrlBase = if ($DomainMode -eq "duckdns") { "/prowlarr" } else { "" }
# URL Sonarr/Radarr use to talk back to this Prowlarr. Prowlarr derives every synced
# indexer's baseUrl from it ("<prowlarrUrl>/<indexerId>/"), so it MUST carry the
# UrlBase in DuckDNS mode or each *arr search returns 404.
$ProwlarrSelfUrl = "http://127.0.0.1:$Port$ProwlarrUrlBase"

Write-DebugLog "VAR AppName=$AppName Port=$Port Enabled=$Enabled DomainMode=$DomainMode"
Write-DebugLog "VAR ProwlarrSelfUrl=$ProwlarrSelfUrl"
Write-DebugLog "VAR ProwlarrUrlBase=$ProwlarrUrlBase SonarrUrlBase=$SonarrUrlBase RadarrUrlBase=$RadarrUrlBase"

function Set-ApiFieldValue {
    # PS5.1: the *arr API omits the "value" key entirely for a field that is
    # unset, and ConvertFrom-Json then produces an object with no such property,
    # so a plain "$field.value = x" throws:
    #   Exception setting "value": "The property 'value' cannot be found on this
    #   object. Verify that the property exists and can be set."
    # That is exactly the common case for seedRatio/seedTime -- most indexers
    # leave them empty, which is when the installer most needs to set them, so
    # the seed-rule step failed for nearly every indexer. Add the property when
    # it is missing and assign in place otherwise. Only called for fields we are
    # actually setting, so unset fields are never serialized as JSON null.
    param($Field, $Value)
    if ($Field.PSObject.Properties.Name -contains 'value') { $Field.value = $Value }
    else { $Field | Add-Member -MemberType NoteProperty -Name 'value' -Value $Value -Force }
}

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

Write-DebugLog "VAR Indexers=$($Layer2Config.Indexers.Count)"

# --- 1. Ensure service is running --------------------------------------------
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

# --- 2. Get API key ----------------------------------------------------------
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

# --- 3. Wait for API ---------------------------------------------------------
Write-Host "  -> Waiting for API on port $Port..." -ForegroundColor Gray
$apiStatusUrl = "http://127.0.0.1:$Port$ProwlarrUrlBase/api/v1/config/host"
Write-DebugLog "INFO" "Polling $AppName API at $apiStatusUrl (up to 30s)..."
$apiUp = $false
$deadline = (Get-Date).AddSeconds(30)
$apiWaited = 0
while (-not $apiUp -and (Get-Date) -lt $deadline) {
    try {
        Invoke-WebRequest -Uri $apiStatusUrl `
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

# --- 4. Configure applications (Sonarr, Radarr) ------------------------------
Write-Host "  -> Configuring applications..." -ForegroundColor Gray
Write-DebugLog "INFO" "Configuring Sonarr/Radarr applications in Prowlarr..."

# Helper: read *Arr API key from config.xml with a retry loop.
# On first-ever service startup the file may be mid-write, yielding a truncated
# or unparseable XML. Three attempts with a 3-second pause is enough for NSSM
# to finish launching the service and flushing its config.
function Read-ArrApiKey {
    param([string]$XmlPath, [string]$AppLabel)
    $deadline = (Get-Date).AddSeconds(15)
    $lastErr  = $null
    while ((Get-Date) -lt $deadline) {
        try {
            if (-not (Test-Path $XmlPath)) { throw "config.xml not found at $XmlPath" }
            $xml = [xml](Get-Content $XmlPath -Raw -Encoding UTF8 -ErrorAction Stop)
            $key = $xml.Config.ApiKey
            if ([string]::IsNullOrWhiteSpace($key)) { throw "ApiKey element is empty or missing" }
            Write-DebugLog "INFO" "$AppLabel API key read successfully from $XmlPath"
            return $key
        } catch [System.Xml.XmlException] {
            # XML parse failure is transient (file may be mid-write). Retry.
            $lastErr = $_
            Write-DebugLog "WARN" "$AppLabel XML parse failed (transient, will retry): $_"
            Start-Sleep -Seconds 3
        } catch [System.IO.FileNotFoundException], [System.Management.Automation.ItemNotFoundException] {
            # File not found is transient (service is still creating it). Retry.
            $lastErr = $_
            Write-DebugLog "WARN" "$AppLabel config.xml not found (transient, will retry): $_"
            Start-Sleep -Seconds 3
        } catch [System.UnauthorizedAccessException] {
            # Access denied is permanent -- do not waste time retrying.
            throw "$AppLabel cannot read config.xml (access denied): $_"
        } catch {
            # Unexpected error -- may be transient (e.g. file locked). Retry
            # once, then give up on a second instance of the same error.
            $lastErr = $_
            Write-DebugLog "WARN" "$AppLabel config read attempt failed (will retry): $_"
            Start-Sleep -Seconds 3
        }
    }
    throw "$AppLabel config.xml unreadable after 15s: $lastErr"
}

try {
    $existingApps = @()
    try {
        $existingApps = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$ProwlarrUrlBase/api/v1/applications" `
            -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
        Write-DebugLog "VAR existing apps in Prowlarr=$($existingApps.Count) names=$($existingApps.name -join ',')"
    } catch { Write-DebugLog "WARN" "Could not fetch existing apps: $_" }

    if ($Config.Apps.Sonarr -eq $true) {
        try {
            $sonarrExists = $existingApps | Where-Object { $_.name -eq "Sonarr" }
            $sonarrXml = "C:\ProgramData\Sonarr\config.xml"
            Write-DebugLog "VAR Sonarr config.xml exists=$(Test-Path $sonarrXml)"
            $sonarrApiKey = Read-ArrApiKey -XmlPath $sonarrXml -AppLabel "Sonarr"
            $sonarrUrl = "http://127.0.0.1:$($Config.Ports.Sonarr)$SonarrUrlBase"
            Write-DebugLog "VAR Sonarr URL=$sonarrUrl apiKey=[REDACTED] exists=$($null -ne $sonarrExists)"
            $sonarrPayload = @{
                name               = "Sonarr"
                syncLevel          = "fullSync"
                fields             = @(
                    @{ name = "prowlarrUrl"; value = $ProwlarrSelfUrl }
                    @{ name = "baseUrl"; value = $sonarrUrl }
                    @{ name = "apiKey";  value = $sonarrApiKey }
                )
                implementation     = "Sonarr"
                implementationName = "Sonarr"
                configContract     = "SonarrSettings"
                tags               = @()
            }
            if ($sonarrExists) {
                $sonarrPayload["id"] = $sonarrExists.id
                Invoke-RestMethod -Uri "http://127.0.0.1:$Port$ProwlarrUrlBase/api/v1/applications/$($sonarrExists.id)" `
                    -Method Put `
                    -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
                    -Body ($sonarrPayload | ConvertTo-Json -Depth 10 -Compress) `
                    -UseBasicParsing -ErrorAction Stop | Out-Null
                Write-Host "     OK Updated Sonarr application." -ForegroundColor Green
                Write-DebugLog "INFO" "Sonarr application updated in Prowlarr (id=$($sonarrExists.id))"
            } else {
                Invoke-RestMethod -Uri "http://127.0.0.1:$Port$ProwlarrUrlBase/api/v1/applications" `
                    -Method Post `
                    -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
                    -Body ($sonarrPayload | ConvertTo-Json -Depth 10 -Compress) `
                    -UseBasicParsing -ErrorAction Stop | Out-Null
                Write-Host "     OK Configured Sonarr application." -ForegroundColor Green
                Write-DebugLog "INFO" "Sonarr application added to Prowlarr"
            }
        } catch {
            Write-Warning "     Failed to configure Sonarr: $_"
            Write-DebugLog "ERROR" "Prowlarr Sonarr app configuration failed: $_"
        }
    }

    if ($Config.Apps.Radarr -eq $true) {
        try {
            $radarrExists = $existingApps | Where-Object { $_.name -eq "Radarr" }
            $radarrXml = "C:\ProgramData\Radarr\config.xml"
            Write-DebugLog "VAR Radarr config.xml exists=$(Test-Path $radarrXml)"
            $radarrApiKey = Read-ArrApiKey -XmlPath $radarrXml -AppLabel "Radarr"
            $radarrUrl = "http://127.0.0.1:$($Config.Ports.Radarr)$RadarrUrlBase"
            Write-DebugLog "VAR Radarr URL=$radarrUrl apiKey=[REDACTED] exists=$($null -ne $radarrExists)"
            $radarrPayload = @{
                name               = "Radarr"
                syncLevel          = "fullSync"
                fields             = @(
                    @{ name = "prowlarrUrl"; value = $ProwlarrSelfUrl }
                    @{ name = "baseUrl"; value = $radarrUrl }
                    @{ name = "apiKey";  value = $radarrApiKey }
                )
                implementation     = "Radarr"
                implementationName = "Radarr"
                configContract     = "RadarrSettings"
                tags               = @()
            }
            if ($radarrExists) {
                $radarrPayload["id"] = $radarrExists.id
                Invoke-RestMethod -Uri "http://127.0.0.1:$Port$ProwlarrUrlBase/api/v1/applications/$($radarrExists.id)" `
                    -Method Put `
                    -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
                    -Body ($radarrPayload | ConvertTo-Json -Depth 10 -Compress) `
                    -UseBasicParsing -ErrorAction Stop | Out-Null
                Write-Host "     OK Updated Radarr application." -ForegroundColor Green
                Write-DebugLog "INFO" "Radarr application updated in Prowlarr (id=$($radarrExists.id))"
            } else {
                Invoke-RestMethod -Uri "http://127.0.0.1:$Port$ProwlarrUrlBase/api/v1/applications" `
                    -Method Post `
                    -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
                    -Body ($radarrPayload | ConvertTo-Json -Depth 10 -Compress) `
                    -UseBasicParsing -ErrorAction Stop | Out-Null
                Write-Host "     OK Configured Radarr application." -ForegroundColor Green
                Write-DebugLog "INFO" "Radarr application added to Prowlarr"
            }
        } catch {
            Write-Warning "     Failed to configure Radarr: $_"
            Write-DebugLog "ERROR" "Prowlarr Radarr app configuration failed: $_"
        }
    }
} catch {
    Write-Warning "[$AppName] Failed to configure applications: $_"
    Write-DebugLog "ERROR" "Applications configuration failed: $_"
    exit 1
}

# --- 5. Configure Indexers ---------------------------------------------------
if (-not ($Layer2Config -and $Layer2Config.Indexers -and $Layer2Config.Indexers.Count -gt 0)) {
    Write-Host "  OK $AppName Layer 2 configuration complete." -ForegroundColor Green
    Write-DebugLog "INFO" "No indexers to configure. Done."
    return
}

Write-Host "  -> Configuring indexers..." -ForegroundColor Gray
Write-DebugLog "INFO" "Configuring $($Layer2Config.Indexers.Count) indexers..."

# --- 5a. FlareSolverr tag ----------------------------------------------------
# configure_layer2_flaresolverr.ps1 owns the indexer-proxy resource and resolves
# this same tag by label, so all this script needs is the tag id: the
# Cloudflare-protected indexers it creates below must be born with the tag, and
# the proxy is never written from here.
#
# The proxy must not be written from here either way: on a fresh install it does
# not exist yet (the FlareSolverr step runs after this one in
# master_configure_layer2.ps1, which is also why proxying this block was a no-op),
# and on a re-run the FlareSolverr step re-PUTs it authoritatively with
# ?forceSave=true. Writing it here would hit Prowlarr's
# ProviderControllerBase.UpdateProvider, where the proxy counts as enabled as soon
# as it carries a tag (`IndexerProxyDefinition.Enable => Tags.Any()`) and no
# forceSave is sent, so Prowlarr would run a real FlareSolverr Test() -- a full
# browser round-trip -- mid-install and reject the save while the solver is still
# warming up.
$flareTagId = $null
if ($Config.Apps.Flaresolverr -eq $true) {
    $tagBase = "http://127.0.0.1:$Port$ProwlarrUrlBase/api/v1/tag"
    try {
        $tags = Invoke-RestMethod -Uri $tagBase `
            -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
        # Label comparison matches configure_layer2_flaresolverr.ps1's so the two
        # steps can never create two different tags for the same proxy/indexers.
        $fsTag = @($tags) | Where-Object { $_.label -ieq "flaresolverr" } | Select-Object -First 1
        Write-DebugLog "VAR flaresolverr tag exists=$($null -ne $fsTag)"
        if (-not $fsTag) {
            $fsTag = Invoke-RestMethod -Uri $tagBase `
                -Method Post `
                -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
                -Body (@{ label = "flaresolverr" } | ConvertTo-Json) `
                -UseBasicParsing -ErrorAction Stop
            Write-DebugLog "INFO" "FlareSolverr tag created id=$($fsTag.id)"
        }
        $flareTagId = [int]$fsTag.id
        Write-DebugLog "VAR flareTagId=$flareTagId"
    } catch {
        # Not fatal: the FlareSolverr step re-tags CF indexers by definition name.
        Write-Warning "     Could not resolve the FlareSolverr tag: $_"
        Write-DebugLog "WARN" "FlareSolverr tag setup failed (FlareSolverr layer will apply it): $_"
    }
}

# --- 5b. Fetch schema and existing indexers ----------------------------------
Write-DebugLog "INFO" "Fetching indexer schema..."
$schemas = $null
try {
    $schemas = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$ProwlarrUrlBase/api/v1/indexer/schema" `
        -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
    Write-DebugLog "VAR indexer schemas fetched=$($schemas.Count)"
} catch {
    Write-Warning "     Failed to fetch indexer schema: $_"
    Write-DebugLog "ERROR" "Failed to fetch indexer schema: $_"
}

if (-not $schemas) {
    Write-Host "  OK $AppName Layer 2 configuration complete." -ForegroundColor Green
    Write-DebugLog "WARN" "No indexer schemas  --  skipping indexer setup"
    return
}

$existingIndexers = @()
try {
    $existingIndexers = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$ProwlarrUrlBase/api/v1/indexer" `
        -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
    Write-DebugLog "VAR existing indexers=$($existingIndexers.Count)"
} catch { Write-DebugLog "WARN" "Could not fetch existing indexers: $_" }

# --- 5c. Add indexers --------------------------------------------------------
$cfIndexerIds    = [System.Collections.Generic.List[int]]::new()
$seedRulesMap    = @{}   # name -> SeedRules, populated for enabled indexers that have them
$enabledCount    = ($Layer2Config.Indexers | Where-Object { $_.Enabled -ne $false }).Count
Write-DebugLog "INFO" "Adding $enabledCount enabled indexers (of $($Layer2Config.Indexers.Count) total)..."

foreach ($idx in $Layer2Config.Indexers) {
    if ($idx.Enabled -eq $false) {
        Write-Host "     - Disabled: $($idx.Name)" -ForegroundColor DarkGray
        Write-DebugLog "INFO" "Indexer '$($idx.Name)' disabled  --  skipping"
        continue
    }

    $idxName = $idx.Name
    $idxDef  = $idx.DefinitionName

    if ($idx.PSObject.Properties['SeedRules'] -and $idx.SeedRules) {
        $seedRulesMap[$idxName] = $idx.SeedRules
        Write-DebugLog "VAR indexer '$idxName' SeedRules ratio=$($idx.SeedRules.Ratio) seedTime=$($idx.SeedRules.SeedTimeMinutes)m"
    }

    $schemaEntry = $schemas | Where-Object { $_.definitionName -eq $idxDef } | Select-Object -First 1

    # Some indexers sit behind Cloudflare but Prowlarr's schema does not flag them,
    # so info_flaresolverr alone under-detects. torrentdownloads answers with a real
    # CloudFlareProtectionException while its schema says False.
    $knownCFDefs = @("RuTracker.org", "torrentdownloads")
    $needsFlare = $false
    if ($schemaEntry) {
        $needsFlare = @($schemaEntry.fields | Where-Object { $_.name -eq "info_flaresolverr" }).Count -gt 0
        if (-not $needsFlare -and $knownCFDefs -contains $idxDef) {
            $needsFlare = $true
            Write-DebugLog "VAR indexer '$idxName' (def=$idxDef) needsFlare=TRUE (hardcoded fallback)"
        }
    }
    Write-DebugLog "VAR indexer '$idxName' (def=$idxDef) needsFlare=$needsFlare"

    $exists = $existingIndexers | Where-Object { $_.definitionName -eq $idxDef -or $_.name -eq $idxName }
    if ($exists) {
        Write-Host "     ~ Already configured: $idxName" -ForegroundColor DarkGray
        Write-DebugLog "INFO" "Indexer '$idxName' already exists  --  skip"
        # Reinstalls reuse the indexer created by the first install, so the FlareSolverr
        # tag has to be re-checked here: a Cloudflare-blocked indexer without the tag
        # stays unsearchable, and Prowlarr then answers its feed with 429 while it backs
        # off, which makes the *arr reject the indexer with 400 and the install look
        # healthy while every search from that indexer fails.
        if ($needsFlare -and $flareTagId -and ($exists.tags -notcontains [int]$flareTagId)) {
            $existsHdrs = @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"}
            $existsTags = New-Object System.Collections.Generic.List[int]
            foreach ($t in @($exists.tags)) { if ($null -ne $t) { $existsTags.Add([int]$t) } }
            $existsTags.Add([int]$flareTagId)
            if ($exists.PSObject.Properties['tags']) { $exists.tags = @($existsTags) }
            else { $exists | Add-Member -MemberType NoteProperty -Name 'tags' -Value @($existsTags) -Force }
            try {
                Invoke-RestMethod -Uri "http://127.0.0.1:$Port$ProwlarrUrlBase/api/v1/indexer/$($exists.id)" `
                    -Method Put -Headers $existsHdrs `
                    -Body ($exists | ConvertTo-Json -Depth 20 -Compress) `
                    -UseBasicParsing -ErrorAction Stop | Out-Null
                Write-Host "     [CF] Tagged existing indexer $idxName for FlareSolverr." -ForegroundColor Cyan
                Write-DebugLog "INFO" "Attached FlareSolverr tag $flareTagId to existing indexer '$idxName' (id=$($exists.id))"
            } catch {
                Write-Warning "     Could not tag existing indexer '$idxName' for FlareSolverr: $_"
                Write-DebugLog "WARN" "FlareSolverr tag on existing indexer '$idxName' failed: $_"
            }
        }
        continue
    }

    if (-not $schemaEntry) {
        Write-Warning "     Indexer definition '$idxDef' not found in Prowlarr schema. Skipping."
        Write-DebugLog "WARN" "Indexer definition '$idxDef' not in schema"
        continue
    }

    $clone = $schemaEntry | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $payload = @{}
    $clone.PSObject.Properties | ForEach-Object { $payload[$_.Name] = $_.Value }
    $payload["name"]         = $idxName
    $payload["appProfileId"] = 1
    $payload["priority"]     = if ($null -ne $payload["priority"] -and [double]$payload["priority"] -gt 0) { $payload["priority"] } else { 25 }
    $tagsArr = New-Object System.Collections.Generic.List[int]
    if ($needsFlare -and $flareTagId) { $tagsArr.Add([int]$flareTagId) }
    $payload["tags"] = $tagsArr

    # Inject credentials from config into matching schema fields (case-insensitive name match).
    # Schema fields parsed from JSON may lack a 'value' property (e.g. textbox with null default);
    # use Add-Member -Force so we can set the property whether or not it pre-exists on the object.
    if ($idx.PSObject.Properties['Credentials'] -and $idx.Credentials) {
        $credMap = @{}
        $idx.Credentials.PSObject.Properties | ForEach-Object { $credMap[$_.Name.ToLower()] = $_.Value }
        $injected = [System.Collections.Generic.List[string]]::new()
        foreach ($field in $clone.fields) {
            $key = $field.name.ToLower()
            if ($credMap.ContainsKey($key) -and -not [string]::IsNullOrEmpty($credMap[$key])) {
                $field | Add-Member -MemberType NoteProperty -Name 'value' -Value $credMap[$key] -Force
                $injected.Add($key)
            }
        }
        $payload["fields"] = $clone.fields
        Write-DebugLog "VAR indexer '$idxName' credentials injected for fields: $($injected -join ', ')"
    }

    if ($needsFlare) {
        $payload["enable"] = $false; $payload["enableRss"] = $false
        $payload["enableAutomaticSearch"] = $false; $payload["enableInteractiveSearch"] = $false
    } else {
        $payload["enable"] = $true; $payload["enableRss"] = $true
        $payload["enableAutomaticSearch"] = $true; $payload["enableInteractiveSearch"] = $true
    }

    $body = $payload | ConvertTo-Json -Depth 10 -Compress

    try {
        $added = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$ProwlarrUrlBase/api/v1/indexer" -Method Post `
            -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
            -Body $body -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop

        if ($needsFlare) {
            $cfIndexerIds.Add($added.id)
            Write-Host "     [CF] Added (pending enable): $idxName (id=$($added.id))" -ForegroundColor Cyan
            Write-DebugLog "INFO" "CF-protected indexer '$idxName' added as disabled (id=$($added.id))"
        } else {
            Write-Host "     OK Added indexer: $idxName" -ForegroundColor Green
            Write-DebugLog "INFO" "Indexer '$idxName' added (id=$($added.id))"
        }
    } catch {
        $rawBody = ""; $errMsg = ""
        try {
            $stream  = $_.Exception.Response.GetResponseStream()
            $rawBody = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
            $parsed  = $rawBody | ConvertFrom-Json
            $errMsg  = ($parsed | Select-Object -ExpandProperty message -ErrorAction SilentlyContinue)
            if (-not $errMsg) {
                $errMsg = ($parsed | Select-Object -ExpandProperty errorMessage -ErrorAction SilentlyContinue) -join "; "
            }
        } catch {}
        if (-not $errMsg) { $errMsg = if ($rawBody) { $rawBody } else { $_.Exception.Message } }

        Write-DebugLog "VAR indexer '$idxName' add error=$errMsg"

        if ($errMsg -like "*timed out*" -or $errMsg -like "*operation has timed out*" `
         -or $errMsg -like "*TaskCanceledException*" -or $errMsg -like "*408*") {
            Write-Host "     ! $idxName timed out (60s) -- skipping." -ForegroundColor Yellow
            Write-DebugLog "WARN" "Indexer '$idxName' timed out"
        } elseif (-not $needsFlare -and ($errMsg -like "*CloudFlare*" -or $errMsg -like "*Cloudflare*")) {
            Write-Host "     [CF] $idxName is CF-protected (detected via error) -- adding disabled." -ForegroundColor Cyan
            Write-DebugLog "INFO" "Indexer '$idxName' detected as CF-protected via error response"
            $cfTagArr = New-Object System.Collections.Generic.List[int]
            if ($flareTagId) { $cfTagArr.Add([int]$flareTagId) }
            $payload["enable"] = $false; $payload["enableRss"] = $false
            $payload["enableAutomaticSearch"] = $false; $payload["enableInteractiveSearch"] = $false
            $payload["tags"] = $cfTagArr
            $cfBody = $payload | ConvertTo-Json -Depth 10 -Compress
            try {
                $added = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$ProwlarrUrlBase/api/v1/indexer" -Method Post `
                    -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
                    -Body $cfBody -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
                $cfIndexerIds.Add($added.id)
                Write-Host "     [CF] Added (pending enable): $idxName (id=$($added.id))" -ForegroundColor Cyan
                Write-DebugLog "INFO" "CF retry '$idxName' added as disabled (id=$($added.id))"
            } catch {
                Write-Warning "     Failed to add CF-retry for '$idxName': $($_.Exception.Message)"
                Write-DebugLog "ERROR" "CF retry failed for '$idxName': $($_.Exception.Message)"
            }
        } else {
            Write-Warning "     Failed to add indexer '$idxName': $errMsg"
            Write-DebugLog "ERROR" "Indexer '$idxName' add failed: $errMsg"
        }
    }
}

# --- 5d. Enable CF-protected indexers via SQLite ----------------------------
Write-DebugLog "VAR CF-protected indexers pending enable=$($cfIndexerIds.Count) ids=$($cfIndexerIds -join ',')"
if ($cfIndexerIds.Count -gt 0) {
    Write-Host "  -> Enabling $($cfIndexerIds.Count) CF-protected indexer(s) via database..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Enabling $($cfIndexerIds.Count) CF indexers via SQLite..."

    $pythonExe = $null
    if (Test-Path "C:\Python312\python.exe") {
        $pythonExe = "C:\Python312\python.exe"
    } else {
        Get-ChildItem "C:\Python3*" -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | ForEach-Object {
                if ($pythonExe) { return }
                $p = Join-Path $_.FullName "python.exe"
                if (Test-Path $p) { $pythonExe = $p }
            }
    }
    if (-not $pythonExe) {
        $gcResult = Get-Command python -ErrorAction SilentlyContinue
        if ($gcResult) { $pythonExe = $gcResult.Source }
    }
    Write-DebugLog "VAR pythonExe=$pythonExe"

    if ($pythonExe) {
        $null = Stop-ServiceBounded -Name Prowlarr
        $stopDeadline = (Get-Date).AddSeconds(15)
        while ((Get-Service Prowlarr -ErrorAction SilentlyContinue).Status -eq "Running" `
               -and (Get-Date) -lt $stopDeadline) {
            Start-Sleep -Seconds 1
        }
        Write-DebugLog "INFO" "Prowlarr stopped for SQLite update"

        $dbPath  = "C:\ProgramData\Prowlarr\prowlarr.db"
        $idsList = $cfIndexerIds -join ","
        Write-DebugLog "VAR SQLite dbPath=$dbPath idsList=$idsList"
        $pyScript = @'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
ids = [int(x) for x in sys.argv[2].split(",")]
placeholders = ",".join("?" * len(ids))
db.execute(f"UPDATE Indexers SET Enable=1 WHERE Id IN ({placeholders})", ids)
db.commit()
changed = db.execute(f"SELECT COUNT(*) FROM Indexers WHERE Id IN ({placeholders}) AND Enable=1", ids).fetchone()[0]
db.close()
print(f"Enabled {changed}/{len(ids)} CF-protected indexer(s)")
'@
        $tmpPy = [System.IO.Path]::GetTempFileName() + ".py"
        $pyScript | Set-Content -Path $tmpPy -Encoding UTF8
        # master_configure_layer2.ps1 sets EAP="Stop"; a single stderr line from Python
        # would throw here, skipping the temp-file cleanup and the service restart below.
        $savedEAP = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $result = & $pythonExe $tmpPy $dbPath $idsList 2>&1 | Out-String
        } finally {
            $ErrorActionPreference = $savedEAP
        }
        Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue
        Write-Host "     OK $result" -ForegroundColor Green
        Write-DebugLog "INFO" "SQLite update result: $result"

        $null = Start-ServiceBounded -Name Prowlarr
        $startDeadline = (Get-Date).AddSeconds(30)
        $apiBack = $false
        $restartWaited = 0
        while (-not $apiBack -and (Get-Date) -lt $startDeadline) {
            try {
                Invoke-WebRequest -Uri "http://127.0.0.1:$Port$ProwlarrUrlBase/api/v1/system/status" `
                    -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop | Out-Null
                $apiBack = $true
            } catch { Start-Sleep -Seconds 2; $restartWaited += 2 }
        }
        Write-DebugLog "VAR Prowlarr API back after restart=$apiBack waited=${restartWaited}s"
        if ($apiBack) {
            Write-Host "     OK Prowlarr restarted, API up." -ForegroundColor Green
            Write-DebugLog "INFO" "Prowlarr restarted and API is up  --  startup sync will push CF indexers to apps"

            # The SQLite edit ran against a stopped Prowlarr; read the flags back
            # instead of trusting the write, otherwise an indexer that never got
            # enabled stays silently unusable.
            try {
                # No @() around the call: in PS 5.1 @(Invoke-RestMethod ...) collapses
                # the whole response array into ONE element, so the filter below would
                # hand $_ the array itself and [int]$_.id would throw -- the check would
                # never verify anything.
                $idxAfter = @()
                $idxAfter = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$ProwlarrUrlBase/api/v1/indexer" `
                    -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
                $stillDisabled = @($idxAfter |
                    Where-Object { $cfIndexerIds -contains [int]$_.id -and $_.enable -ne $true } |
                    ForEach-Object { "$($_.name) (id=$($_.id))" })
                if ($stillDisabled.Count -eq 0) {
                    Write-Host "     OK Verified enabled via API ($($cfIndexerIds.Count) CF-protected indexer(s))." -ForegroundColor Green
                    Write-DebugLog "INFO" "Verified CF indexers enabled: $($cfIndexerIds -join ',')"
                } else {
                    Write-Warning "     $($stillDisabled.Count) CF-protected indexer(s) still disabled: $($stillDisabled -join ', ')"
                    Write-DebugLog "WARN" "CF indexers still disabled after SQLite enable: $($stillDisabled -join ', ')"
                }
            } catch {
                Write-Warning "     Could not verify CF-protected indexer state: $_"
                Write-DebugLog "WARN" "CF indexer enable verification failed: $_"
            }
        } else {
            Write-Warning "     Prowlarr API did not come back within 30s."
            Write-DebugLog "WARN" "Prowlarr API did not come back after restart within 30s"
        }
    } else {
        Write-Warning "     Python not found -- CF-protected indexers remain disabled."
        Write-DebugLog "WARN" "Python not found  --  CF indexers remain disabled"
    }
}

# --- 6. Apply minimum seeders to all synced indexers in Sonarr and Radarr ----
$minSeeders = 1
if ($Config.Layer2.PSObject.Properties['MinimumSeeders'] -and [int]$Config.Layer2.MinimumSeeders -gt 1) {
    $minSeeders = [int]$Config.Layer2.MinimumSeeders
}
Write-DebugLog "VAR MinimumSeeders=$minSeeders"

if ($minSeeders -gt 1) {
    Write-Host "  -> Setting minimum seeders = $minSeeders on all synced indexers..." -ForegroundColor Gray

    # Wait up to 30 s for Prowlarr's fullSync to push indexers into Sonarr/Radarr.
    # Pick the first enabled *Arr app as the sync-check target; do not assume Sonarr
    # is installed just because MinimumSeeders > 1.
    $syncCheckApp = $null
    if ($Config.Apps.Sonarr -eq $true -and (Test-Path "C:\ProgramData\Sonarr\config.xml")) {
        $syncCheckApp = @{
            Name="Sonarr"; Port=$Config.Ports.Sonarr; UrlBase=$SonarrUrlBase
            Xml="C:\ProgramData\Sonarr\config.xml"
        }
    } elseif ($Config.Apps.Radarr -eq $true -and (Test-Path "C:\ProgramData\Radarr\config.xml")) {
        $syncCheckApp = @{
            Name="Radarr"; Port=$Config.Ports.Radarr; UrlBase=$RadarrUrlBase
            Xml="C:\ProgramData\Radarr\config.xml"
        }
    }
    $syncReady = $false
    if ($syncCheckApp) {
        $syncApiKey   = ([xml](Get-Content $syncCheckApp.Xml -Encoding UTF8)).Config.ApiKey
        $syncBase     = "http://127.0.0.1:$($syncCheckApp.Port)$($syncCheckApp.UrlBase)"
        $syncDeadline = (Get-Date).AddSeconds(30)
        while (-not $syncReady -and (Get-Date) -lt $syncDeadline) {
            try {
                $n = (Invoke-RestMethod "$syncBase/api/v3/indexer" `
                    -Headers @{"X-Api-Key"=$syncApiKey} -UseBasicParsing -ErrorAction Stop).Count
                if ($n -gt 0) { $syncReady = $true } else { Start-Sleep -Seconds 3 }
            } catch { Start-Sleep -Seconds 3 }
        }
        Write-DebugLog "VAR indexer sync check via $($syncCheckApp.Name): ready=$syncReady"
    } else {
        Write-DebugLog "WARN" "No enabled *Arr app available for sync check; skipping wait"
    }

    $appTargets = @(
        @{ Name="Sonarr"; Port=$Config.Ports.Sonarr; UrlBase=$SonarrUrlBase
           Xml="C:\ProgramData\Sonarr\config.xml";  Db="C:\ProgramData\Sonarr\sonarr.db"
           AppEnabled=($Config.Apps.Sonarr -eq $true) }
        @{ Name="Radarr"; Port=$Config.Ports.Radarr; UrlBase=$RadarrUrlBase
           Xml="C:\ProgramData\Radarr\config.xml";  Db="C:\ProgramData\Radarr\radarr.db"
           AppEnabled=($Config.Apps.Radarr -eq $true) }
    )
    foreach ($app in $appTargets) {
        if (-not $app.AppEnabled) { continue }
        $appKey  = ([xml](Get-Content $app.Xml -Encoding UTF8)).Config.ApiKey
        $appBase = "http://127.0.0.1:$($app.Port)$($app.UrlBase)"
        $appHdrs = @{"X-Api-Key"=$appKey; "Content-Type"="application/json"}

        try {
            $idxList = Invoke-RestMethod "$appBase/api/v3/indexer" -Headers $appHdrs -UseBasicParsing -ErrorAction Stop
            $apiOk   = 0; $apiFail = @()

            foreach ($idx in $idxList) {
                $f = $idx.fields | Where-Object { $_.name -eq "minimumSeeders" }
                if (-not $f -or [int]$f.value -eq $minSeeders) { continue }
                Set-ApiFieldValue -Field $f -Value $minSeeders
                try {
                    Invoke-RestMethod "$appBase/api/v3/indexer/$($idx.id)" `
                        -Method Put -Headers $appHdrs `
                        -Body ($idx | ConvertTo-Json -Depth 20 -Compress) `
                        -UseBasicParsing -ErrorAction Stop | Out-Null
                    $apiOk++
                } catch {
                    # API validation fails for CF-protected indexers (Prowlarr returns 429 on caps
                    # check through FlareSolverr). Fall back to direct SQLite edit for those.
                    $apiFail += $idx.id
                }
                Start-Sleep -Milliseconds 400
            }

            # SQLite fallback for indexers whose API PUT was rejected
            if ($apiFail.Count -gt 0 -and $pythonExe -and (Test-Path $app.Db)) {
                $null = Stop-ServiceBounded -Name $app.Name
                $stopDl = (Get-Date).AddSeconds(15)
                while ((Get-Service $app.Name -EA SilentlyContinue).Status -eq "Running" -and (Get-Date) -lt $stopDl) {
                    Start-Sleep -Seconds 1
                }
                $idsList = $apiFail -join ","
                $pySql = @"
import sqlite3, sys, json
db = sqlite3.connect(sys.argv[1])
ids = [int(x) for x in sys.argv[2].split(",")]
n = 0
for row_id, s in db.execute("SELECT Id,Settings FROM Indexers WHERE Id IN (%s)" % ",".join("?"*len(ids)), ids).fetchall():
    cfg = json.loads(s)
    if "minimumSeeders" in cfg:
        cfg["minimumSeeders"] = int(sys.argv[3])
        db.execute("UPDATE Indexers SET Settings=? WHERE Id=?", (json.dumps(cfg), row_id))
        n += 1
db.commit(); db.close(); print(n)
"@
                $tmpPy = [System.IO.Path]::GetTempFileName() + ".py"
                $pySql | Set-Content -Path $tmpPy -Encoding UTF8
                # See above -- EAP guard so Python stderr cannot abort the loop.
                $savedEAP = $ErrorActionPreference
                try {
                    $ErrorActionPreference = "Continue"
                    $sqlResult = & $pythonExe $tmpPy $app.Db $idsList $minSeeders 2>&1 | Out-String
                } finally {
                    $ErrorActionPreference = $savedEAP
                }
                Remove-Item $tmpPy -Force -EA SilentlyContinue
                $null = Start-ServiceBounded -Name $app.Name
                $startDl = (Get-Date).AddSeconds(20)
                while ((Get-Service $app.Name -EA SilentlyContinue).Status -ne "Running" -and (Get-Date) -lt $startDl) {
                    Start-Sleep -Seconds 1
                }
                Write-Host "     OK $($app.Name): SQLite fallback updated $sqlResult indexer(s) (CF-protected)" -ForegroundColor Green
                Write-DebugLog "INFO" "$($app.Name) SQLite fallback: $sqlResult CF indexers updated"
            }

            $total = $apiOk + $apiFail.Count
            Write-Host "     OK $($app.Name): minimumSeeders=$minSeeders applied to $total/$($idxList.Count) indexers" -ForegroundColor Green
            Write-DebugLog "INFO" "$($app.Name) minimumSeeders=$($minSeeders) API=$apiOk SQLite=$($apiFail.Count) of $($idxList.Count)"
        } catch {
            Write-Warning "     Could not update $($app.Name) indexers: $_"
            Write-DebugLog "WARN" "$($app.Name) minimumSeeders update failed: $_"
        }
    }
}

# --- 7. Apply per-indexer seed rules (ratio + seed time) in Sonarr and Radarr
Write-DebugLog "VAR seedRulesMap count=$($seedRulesMap.Count) keys=$($seedRulesMap.Keys -join ',')"
if ($seedRulesMap.Count -gt 0) {
    Write-Host "  -> Applying per-indexer seed rules..." -ForegroundColor Gray

    $appTargets2 = @(
        @{ Name="Sonarr"; Port=$Config.Ports.Sonarr; UrlBase=$SonarrUrlBase; Xml="C:\ProgramData\Sonarr\config.xml"; AppEnabled=($Config.Apps.Sonarr -eq $true) }
        @{ Name="Radarr"; Port=$Config.Ports.Radarr; UrlBase=$RadarrUrlBase; Xml="C:\ProgramData\Radarr\config.xml"; AppEnabled=($Config.Apps.Radarr -eq $true) }
    )

    foreach ($app in $appTargets2) {
        if (-not $app.AppEnabled) { continue }
        $appKey  = ([xml](Get-Content $app.Xml -Encoding UTF8)).Config.ApiKey
        $appBase = "http://127.0.0.1:$($app.Port)$($app.UrlBase)"
        $appHdrs = @{"X-Api-Key"=$appKey; "Content-Type"="application/json"}

        try {
            $idxList  = Invoke-RestMethod "$appBase/api/v3/indexer" -Headers $appHdrs -UseBasicParsing -ErrorAction Stop
            $appOk    = 0

            foreach ($syncedIdx in $idxList) {
                # Prowlarr syncs indexers into the *arr apps as "<Name> (Prowlarr)".
                $baseName = $syncedIdx.name -replace '\s*\(Prowlarr\)\s*$', ''
                if (-not $seedRulesMap.ContainsKey($baseName)) { continue }
                $rules    = $seedRulesMap[$baseName]
                $changed  = $false

                foreach ($field in $syncedIdx.fields) {
                    if ($field.name -eq "seedCriteria.seedRatio" -and $null -ne $rules.Ratio) {
                        if ($field.value -ne $rules.Ratio) { Set-ApiFieldValue -Field $field -Value $rules.Ratio; $changed = $true }
                    }
                    if ($field.name -eq "seedCriteria.seedTime" -and $null -ne $rules.SeedTimeMinutes) {
                        if ($field.value -ne $rules.SeedTimeMinutes) { Set-ApiFieldValue -Field $field -Value $rules.SeedTimeMinutes; $changed = $true }
                    }
                }

                if (-not $changed) { continue }

                try {
                    Invoke-RestMethod "$appBase/api/v3/indexer/$($syncedIdx.id)" `
                        -Method Put -Headers $appHdrs `
                        -Body ($syncedIdx | ConvertTo-Json -Depth 20 -Compress) `
                        -UseBasicParsing -ErrorAction Stop | Out-Null
                    $appOk++
                    Write-DebugLog "INFO" "$($app.Name) indexer '$($syncedIdx.name)' seed rules applied (ratio=$($rules.Ratio) seedTime=$($rules.SeedTimeMinutes)m)"
                } catch {
                    Write-DebugLog "WARN" "$($app.Name) indexer '$($syncedIdx.name)' seed rules PUT failed: $_"
                }
                Start-Sleep -Milliseconds 300
            }

            if ($appOk -gt 0) {
                Write-Host "     OK $($app.Name): seed rules applied to $appOk indexer(s)" -ForegroundColor Green
                Write-DebugLog "INFO" "$($app.Name) seed rules applied to $appOk indexers"
            }
        } catch {
            Write-Warning "     Could not apply seed rules to $($app.Name): $_"
            Write-DebugLog "WARN" "$($app.Name) seed rules update failed: $_"
        }
    }
}

# --- 8. Make Prowlarr the source of truth for the synced indexers ------------
# Prowlarr derives each synced indexer's baseUrl from the application entry's
# "prowlarrUrl" field and it forwards its own torrentBaseSettings seed values --
# but only during a fullSync, which it runs on a schedule, never because the
# application entry changed. Two failures follow, both silent:
#
#  1. Changing DomainMode (DuckDNS <-> Cloudflare) or the Prowlarr port leaves
#     already-synced indexers pointing at a path Prowlarr no longer serves.
#     Prowlarr answers those requests with its login page and the *arr reports an
#     XML parse error that names neither Prowlarr nor the URL:
#       Unable to connect to indexer: '/' is an unexpected token. The expected
#       token is '='. Line 54, position 5.
#     (Line 54 of that login page is "    />", so position 5 is its '/'.)
#  2. The seed criteria sections 6/7 write straight into Sonarr/Radarr are
#     reverted to Prowlarr's empty torrentBaseSettings on the next sync, so they
#     disappear hours after the installer reported success.
#
# Both *arr also validate an indexer when it is PUT, so while a baseUrl is stale
# every write to it fails too -- that is the "seed rules PUT failed: 400 Bad
# Request" and the minimumSeeders SQLite fallback, not a CF/FlareSolverr problem.
#
# Writing the values into Prowlarr and forcing one sync fixes both at the source
# and keeps them fixed across every scheduled sync that follows.
$syncTargets = @()
if ($Config.Apps.Sonarr -eq $true -and (Test-Path "C:\ProgramData\Sonarr\config.xml")) {
    $syncTargets += @{ Name="Sonarr"; Port=$Config.Ports.Sonarr; UrlBase=$SonarrUrlBase
                       Xml="C:\ProgramData\Sonarr\config.xml" }
}
if ($Config.Apps.Radarr -eq $true -and (Test-Path "C:\ProgramData\Radarr\config.xml")) {
    $syncTargets += @{ Name="Radarr"; Port=$Config.Ports.Radarr; UrlBase=$RadarrUrlBase
                       Xml="C:\ProgramData\Radarr\config.xml" }
}

if ($syncTargets.Count -gt 0) {
    Write-Host "  -> Making Prowlarr the source of truth for synced indexers..." -ForegroundColor Gray

    $plUpdated = 0
    $plEnabled = 0
    try {
        $plIndexers = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$ProwlarrUrlBase/api/v1/indexer" `
            -Headers @{"X-Api-Key"=$ApiKey} -UseBasicParsing -ErrorAction Stop
        foreach ($plIdx in $plIndexers) {
            if ($plIdx.enable -ne $true) { continue }
            $plEnabled++
            $changed = $false

            if ($minSeeders -gt 1) {
                $f = $plIdx.fields | Where-Object { $_.name -eq "torrentBaseSettings.appMinimumSeeders" } | Select-Object -First 1
                if ($f -and [int]$f.value -ne [int]$minSeeders) { Set-ApiFieldValue -Field $f -Value $minSeeders; $changed = $true }
            }
            if ($seedRulesMap.ContainsKey($plIdx.name)) {
                $rules = $seedRulesMap[$plIdx.name]
                if ($null -ne $rules.Ratio) {
                    $f = $plIdx.fields | Where-Object { $_.name -eq "torrentBaseSettings.seedRatio" } | Select-Object -First 1
                    if ($f -and [double]$f.value -ne [double]$rules.Ratio) { Set-ApiFieldValue -Field $f -Value $rules.Ratio; $changed = $true }
                }
                if ($null -ne $rules.SeedTimeMinutes) {
                    $f = $plIdx.fields | Where-Object { $_.name -eq "torrentBaseSettings.seedTime" } | Select-Object -First 1
                    if ($f -and [int]$f.value -ne [int]$rules.SeedTimeMinutes) { Set-ApiFieldValue -Field $f -Value $rules.SeedTimeMinutes; $changed = $true }
                }
            }
            if (-not $changed) { continue }

            try {
                Invoke-RestMethod -Uri "http://127.0.0.1:$Port$ProwlarrUrlBase/api/v1/indexer/$($plIdx.id)" `
                    -Method Put `
                    -Headers @{"X-Api-Key"=$ApiKey; "Content-Type"="application/json"} `
                    -Body ($plIdx | ConvertTo-Json -Depth 20 -Compress) `
                    -UseBasicParsing -ErrorAction Stop | Out-Null
                $plUpdated++
            } catch {
                Write-Warning "     Prowlarr indexer '$($plIdx.name)' seed settings update failed: $_"
                Write-DebugLog "WARN" "Prowlarr indexer '$($plIdx.name)' seed settings PUT failed: $_"
            }
            Start-Sleep -Milliseconds 300
        }
        if ($plUpdated -gt 0) {
            Write-Host "     OK Prowlarr: seed criteria stored on $plUpdated/$plEnabled indexer(s)" -ForegroundColor Green
        }
        Write-DebugLog "INFO" "Prowlarr seed criteria stored on $plUpdated/$plEnabled indexers"
    } catch {
        Write-Warning "     Could not store seed criteria in Prowlarr: $_"
        Write-DebugLog "WARN" "Prowlarr seed criteria update failed: $_"
    }

    $syncCmd = $null
    try {
        $syncCmd = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$ProwlarrUrlBase/api/v1/command" `
            -Method Post `
            -Headers @{"X-Api-Key"=$ApiKey; "Content-Type"="application/json"} `
            -Body '{"name":"ApplicationIndexerSync"}' `
            -UseBasicParsing -ErrorAction Stop
        Write-DebugLog "INFO" "ApplicationIndexerSync queued (id=$($syncCmd.id))"
    } catch {
        Write-Warning "     Could not trigger a Prowlarr sync: $_"
        Write-DebugLog "WARN" "ApplicationIndexerSync trigger failed: $_"
    }

    # Wait for the sync to push corrected baseUrls, bounded: it walks Sonarr and
    # Radarr one indexer at a time, which took ~65s on a 12-indexer install. With
    # no sync queued there is nothing to wait for, so probe once and fall through
    # to the direct repair below.
    $wantPattern = '^' + [regex]::Escape($ProwlarrSelfUrl) + '/\d+/$'
    $syncDeadline = if ($syncCmd) { (Get-Date).AddSeconds(150) } else { Get-Date }
    $stale = @()
    while ($true) {
        $stale = @()
        $probed = 0
        foreach ($t in $syncTargets) {
            $tKey  = ([xml](Get-Content $t.Xml -Encoding UTF8)).Config.ApiKey
            $tBase = "http://127.0.0.1:$($t.Port)$($t.UrlBase)"
            try {
                $tIdx = Invoke-RestMethod "$tBase/api/v3/indexer" `
                    -Headers @{"X-Api-Key"=$tKey} -UseBasicParsing -ErrorAction Stop
                foreach ($e in $tIdx) {
                    if ($e.name -notmatch '\(Prowlarr\)\s*$') { continue }
                    $probed++
                    $u = ($e.fields | Where-Object { $_.name -eq "baseUrl" } | Select-Object -First 1).value
                    if ($u -notmatch $wantPattern) { $stale += "$($t.Name)/$($e.name)=$u" }
                }
            } catch { }
        }
        if ($probed -gt 0 -and $stale.Count -eq 0) { break }
        if ((Get-Date) -ge $syncDeadline) { break }
        Start-Sleep -Seconds 5
    }

    # The scheduled sync gets it right on its own; if it was rate-limited or still
    # queued, write the URL the *arr should use directly rather than leave the
    # install in a state where every search fails.
    if ($stale.Count -gt 0) {
        Write-DebugLog "WARN" "$($stale.Count) indexer(s) still on a stale baseUrl after sync: $($stale -join ', ')"
        foreach ($t in $syncTargets) {
            $tKey  = ([xml](Get-Content $t.Xml -Encoding UTF8)).Config.ApiKey
            $tBase = "http://127.0.0.1:$($t.Port)$($t.UrlBase)"
            $tHdrs = @{"X-Api-Key"=$tKey; "Content-Type"="application/json"}
            try {
                $tIdx = Invoke-RestMethod "$tBase/api/v3/indexer" -Headers $tHdrs -UseBasicParsing -ErrorAction Stop
                foreach ($e in $tIdx) {
                    if ($e.name -notmatch '\(Prowlarr\)\s*$') { continue }
                    $f = $e.fields | Where-Object { $_.name -eq "baseUrl" } | Select-Object -First 1
                    if (-not $f -or $f.value -match $wantPattern) { continue }
                    # Keep the feed id already in the URL -- Prowlarr ids are stable
                    # and match the trailing "/<id>/" segment of the existing baseUrl.
                    if ($f.value -notmatch '/(\d+)/?$') { continue }
                    Set-ApiFieldValue -Field $f -Value "$ProwlarrSelfUrl/$($Matches[1])/"
                    try {
                        Invoke-RestMethod "$tBase/api/v3/indexer/$($e.id)" `
                            -Method Put -Headers $tHdrs `
                            -Body ($e | ConvertTo-Json -Depth 20 -Compress) `
                            -UseBasicParsing -ErrorAction Stop | Out-Null
                        Write-DebugLog "INFO" "$($t.Name) indexer '$($e.name)' baseUrl repaired directly to $($f.value)"
                    } catch {
                        Write-DebugLog "WARN" "$($t.Name) indexer '$($e.name)' baseUrl repair PUT failed: $_"
                    }
                    Start-Sleep -Milliseconds 300
                }
            } catch { }
        }

        $stale = @()
        foreach ($t in $syncTargets) {
            $tKey  = ([xml](Get-Content $t.Xml -Encoding UTF8)).Config.ApiKey
            $tBase = "http://127.0.0.1:$($t.Port)$($t.UrlBase)"
            try {
                $tIdx = Invoke-RestMethod "$tBase/api/v3/indexer" `
                    -Headers @{"X-Api-Key"=$tKey} -UseBasicParsing -ErrorAction Stop
                foreach ($e in $tIdx) {
                    if ($e.name -notmatch '\(Prowlarr\)\s*$') { continue }
                    $u = ($e.fields | Where-Object { $_.name -eq "baseUrl" } | Select-Object -First 1).value
                    if ($u -notmatch $wantPattern) { $stale += "$($t.Name)/$($e.name)=$u" }
                }
            } catch { }
        }
    }

    if ($stale.Count -eq 0) {
        Write-Host "     OK Indexer URLs point at $ProwlarrSelfUrl/<id>/ in all *arr apps" -ForegroundColor Green
        Write-DebugLog "INFO" "All synced indexer baseUrls match $ProwlarrSelfUrl/<id>/"
    } else {
        Write-Warning "     $($stale.Count) indexer(s) still use a stale URL: $($stale -join ', ')"
        Write-DebugLog "ERROR" "Stale indexer baseUrls remain: $($stale -join ', ')"
    }
}

Write-Host "  OK $AppName Layer 2 configuration complete." -ForegroundColor Green
Write-DebugLog "INFO" "configure_layer2_prowlarr.ps1 complete"

exit 0
