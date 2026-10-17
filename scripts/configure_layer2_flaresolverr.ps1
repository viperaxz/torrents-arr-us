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
Write-DebugLog "INFO" "configure_layer2_flaresolverr.ps1 started"

$AppName          = "Flaresolverr"
$FlaresolverrPort = if ($Config.Ports.PSObject.Properties["Flaresolverr"]) { $Config.Ports.Flaresolverr } else { 8191 }
$ProwlarrPort     = $Config.Ports.Prowlarr
$DomainMode       = $Config.General.DomainMode
$ProwlarrUrlBase  = if ($DomainMode -eq "duckdns") { "/prowlarr" } else { "" }

Write-DebugLog "VAR AppName=$AppName FlaresolverrPort=$FlaresolverrPort ProwlarrPort=$ProwlarrPort"
Write-DebugLog "VAR DomainMode=$DomainMode ProwlarrUrlBase=$ProwlarrUrlBase"

if ($Config.Apps.Flaresolverr -ne $true) {
    Write-Host "[$AppName] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "$AppName skipped (not enabled)"
    return
}

if ($Config.Apps.Prowlarr -ne $true) {
    Write-Host "[$AppName] Prowlarr not enabled - skipping FlareSolverr registration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "Prowlarr not enabled  --  skipping FlareSolverr registration"
    return
}

# -- 1. Get Prowlarr API key ---------------------------------------------------
$ProwlarrConfigXml = "C:\ProgramData\Prowlarr\config.xml"
Write-DebugLog "VAR ProwlarrConfigXml=$ProwlarrConfigXml (exists=$(Test-Path $ProwlarrConfigXml))"
if (-not (Test-Path $ProwlarrConfigXml)) {
    Write-Warning "[$AppName] Prowlarr config.xml not found. Run the installer first."
    Write-DebugLog "ERROR" "Prowlarr config.xml not found"
    exit 1
}
[xml]$cfgXml = Get-Content -Path $ProwlarrConfigXml -Encoding UTF8
$ApiKey = $cfgXml.Config.ApiKey
Write-DebugLog "VAR Prowlarr ApiKey found=$((-not [string]::IsNullOrEmpty($ApiKey)))"
if (-not $ApiKey) {
    Write-Warning "[$AppName] Prowlarr API key not found in config.xml. Skipping."
    Write-DebugLog "ERROR" "Prowlarr ApiKey not found"
    exit 1
}

# -- 2. Ensure Prowlarr is running ---------------------------------------------
$svc = Get-Service -Name "Prowlarr" -ErrorAction SilentlyContinue
Write-DebugLog "VAR Prowlarr service exists=$($null -ne $svc) status=$(if ($svc) { $svc.Status } else { 'N/A' })"
if (-not $svc) {
    Write-Warning "[$AppName] Prowlarr service not found. Run the installer first."
    Write-DebugLog "ERROR" "Prowlarr service not found"
    exit 1
}
if ($svc.Status -ne "Running") {
    Write-Host "  -> Starting Prowlarr..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Starting Prowlarr..."
    Start-Service -Name "Prowlarr" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
}

# -- 3. Wait for Prowlarr API --------------------------------------------------
Write-Host "  -> Waiting for Prowlarr API..." -ForegroundColor Gray
$statusUrl = "http://127.0.0.1:$ProwlarrPort$ProwlarrUrlBase/api/v1/system/status"
Write-DebugLog "INFO" "Polling Prowlarr API at $statusUrl (up to 30s)..."
$apiUp    = $false
$deadline = (Get-Date).AddSeconds(30)
$apiWaited = 0
while (-not $apiUp -and (Get-Date) -lt $deadline) {
    try {
        Invoke-WebRequest -Uri $statusUrl `
            -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop | Out-Null
        $apiUp = $true
    } catch { Start-Sleep -Seconds 3; $apiWaited += 3 }
}
Write-DebugLog "VAR Prowlarr API up=$apiUp waited=${apiWaited}s"
if (-not $apiUp) {
    Write-Warning "[$AppName] Prowlarr API not responding after 30s. Skipping."
    Write-DebugLog "ERROR" "Prowlarr API not responding after 30s"
    exit 1
}

# -- 4. Register FlareSolverr as an Indexer Proxy in Prowlarr -----------------
Write-Host "  -> Registering FlareSolverr proxy with Prowlarr..." -ForegroundColor Gray
$flareUrl  = "http://127.0.0.1:$FlaresolverrPort"
$proxyBase = "http://127.0.0.1:$ProwlarrPort$ProwlarrUrlBase/api/v1/indexerproxy"
$headers   = @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"}
Write-DebugLog "VAR flareUrl=$flareUrl proxyBase=$proxyBase"

# -- 4a. Resolve the tag that links the proxy to its indexers ------------------
# Prowlarr's IndexerProxyDefinition is only active while it carries at least one
# tag (`public override bool Enable => Tags.Any()`), and
# IndexerHttpClient.GetProxies() hands a proxy to an indexer only when the two
# tag lists intersect (it also returns nothing at all for an indexer without
# tags). A proxy created with an empty tag list is therefore stored but never
# used. The proxy and every indexer that must be fetched through it have to
# share one tag id, so reuse the existing "flaresolverr" tag - the Prowlarr
# layer-2 script creates the same label - and only create it when missing: a
# second tag with the same label would split the two sides apart again.
$tagBase    = "http://127.0.0.1:$ProwlarrPort$ProwlarrUrlBase/api/v1/tag"
$tagLabel   = "flaresolverr"
$flareTagId = $null

$allTags = @()
try {
    # No @() around the call: in PS 5.1 @(Invoke-RestMethod ...) collapses the whole
    # response array into ONE element, so $allTags[0] would be the array itself and the
    # label lookup below would compare whole arrays instead of single tags.
    $allTags = Invoke-RestMethod -Uri $tagBase -Headers @{"X-Api-Key" = $ApiKey} `
        -UseBasicParsing -ErrorAction Stop
    Write-DebugLog "VAR Prowlarr tags=$(@($allTags).Count)"
} catch {
    Write-Warning "[$AppName] Could not read Prowlarr tags: $_"
    Write-DebugLog "ERROR" "Failed to read Prowlarr tags: $_"
    exit 1
}

$fsTag = $allTags | Where-Object { $_.label -ieq $tagLabel } | Select-Object -First 1
if ($fsTag) {
    $flareTagId = [int]$fsTag.id
    Write-DebugLog "VAR reusing '$tagLabel' tag id=$flareTagId"
} else {
    try {
        $fsTag = Invoke-RestMethod -Uri $tagBase -Method Post -Headers $headers `
            -Body (@{ label = $tagLabel } | ConvertTo-Json) -UseBasicParsing -ErrorAction Stop
        $flareTagId = [int]$fsTag.id
        Write-DebugLog "INFO" "Created Prowlarr tag '$tagLabel' id=$flareTagId"
    } catch {
        Write-Warning "[$AppName] Could not create Prowlarr tag '$tagLabel': $_"
        Write-DebugLog "ERROR" "Failed to create Prowlarr tag: $_"
        exit 1
    }
}
Write-Host "  -> Using Prowlarr tag '$tagLabel' (id=$flareTagId)..." -ForegroundColor Gray

# Check if a FlareSolverr proxy already exists
$existingProxies = @()
try {
    $existingProxies = Invoke-RestMethod -Uri $proxyBase `
        -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
    Write-DebugLog "VAR existing proxies=$($existingProxies.Count)"
} catch {
    Write-Warning "[$AppName] Could not query existing proxies: $_"
    Write-DebugLog "WARN" "Could not fetch existing proxies: $_"
}

$existing = $existingProxies | Where-Object { $_.implementation -eq "FlareSolverr" } | Select-Object -First 1
Write-DebugLog "VAR FlareSolverr proxy already exists=$($null -ne $existing)"

# Fetch the FlareSolverr schema from Prowlarr
Write-DebugLog "INFO" "Fetching indexer proxy schema from Prowlarr..."
$schemas = $null
try {
    $schemas = Invoke-RestMethod -Uri "$proxyBase/schema" `
        -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
    Write-DebugLog "VAR proxy schemas count=$($schemas.Count)"
} catch {
    Write-Warning "[$AppName] Failed to fetch indexer proxy schema: $_"
    Write-DebugLog "ERROR" "Failed to fetch proxy schema: $_"
    exit 1
}

$fsSchema = $schemas | Where-Object { $_.implementation -eq "FlareSolverr" } | Select-Object -First 1
Write-DebugLog "VAR FlareSolverr schema found=$($null -ne $fsSchema)"
if (-not $fsSchema) {
    Write-Warning "[$AppName] FlareSolverr proxy type not found in Prowlarr schema. Prowlarr version may not support it."
    Write-DebugLog "ERROR" "FlareSolverr not found in proxy schema"
    exit 1
}

# Build payload from schema, setting the host URL field
$clone = $fsSchema | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$payload = @{}
$clone.PSObject.Properties | ForEach-Object { $payload[$_.Name] = $_.Value }
$payload["name"]   = "FlareSolverr"
# There is no "enable" field on the indexer-proxy wire model: Prowlarr derives
# IndexerProxyDefinition.Enable from Tags.Any(), so the tag list below is what
# makes the proxy active. Sending it an empty list leaves it permanently inert.
$payload["tags"]   = @([int]$flareTagId)

# Set the host field (Prowlarr stores the FlareSolverr URL under the "host" field)
for ($i = 0; $i -lt $payload["fields"].Count; $i++) {
    if ($payload["fields"][$i].name -eq "host") {
        $payload["fields"][$i] = @{ name = "host"; value = $flareUrl }
        Write-DebugLog "VAR field 'host' set to $flareUrl"
    }
    if ($payload["fields"][$i].name -eq "requestTimeout") {
        $payload["fields"][$i] = @{ name = "requestTimeout"; value = 60 }
        Write-DebugLog "VAR field 'requestTimeout' set to 60"
    }
}

$body = $payload | ConvertTo-Json -Depth 10 -Compress

# forceSave: a tagged proxy counts as enabled, so without it Prowlarr runs its
# FlareSolverr Test() (a real browser request through the proxy) on every
# POST/PUT and rejects the whole registration while the browser is still warming
# up. Reachability is checked explicitly at the end of this script instead.
try {
    if ($existing) {
        $payload["id"] = $existing.id
        $body = $payload | ConvertTo-Json -Depth 10 -Compress
        Write-DebugLog "INFO" "Updating existing FlareSolverr proxy (id=$($existing.id)) tags=@($flareTagId) host=$flareUrl"
        Invoke-RestMethod -Uri "$proxyBase/$($existing.id)?forceSave=true" -Method Put `
            -Headers $headers -Body $body -UseBasicParsing -ErrorAction Stop | Out-Null
        Write-Host "  -> OK: FlareSolverr proxy updated ($flareUrl, tag id=$flareTagId)" -ForegroundColor Green
        Write-DebugLog "INFO" "FlareSolverr proxy updated (id=$($existing.id) host=$flareUrl tags=@($flareTagId))"
    } else {
        Write-DebugLog "INFO" "Creating FlareSolverr proxy with host=$flareUrl tags=@($flareTagId)..."
        Invoke-RestMethod -Uri "$($proxyBase)?forceSave=true" -Method Post `
            -Headers $headers -Body $body -UseBasicParsing -ErrorAction Stop | Out-Null
        Write-Host "  -> OK: FlareSolverr proxy registered ($flareUrl, tag id=$flareTagId)" -ForegroundColor Green
        Write-DebugLog "INFO" "FlareSolverr proxy registered (host=$flareUrl tags=@($flareTagId))"
    }
} catch {
    Write-Warning "[$AppName] Failed to register FlareSolverr proxy with Prowlarr: $_"
    Write-DebugLog "ERROR" "FlareSolverr proxy registration failed: $_"
    exit 1
}

# -- 5. Tag the indexers that must be fetched through FlareSolverr ------------
# GetProxies() attaches a proxy to an indexer only when their tag lists
# intersect, so the Cloudflare-protected indexers need the same tag the proxy
# now carries. Prowlarr's indexer schema flags the Cardigann definitions that
# need it with an `info_flaresolverr` setting; native definitions have no
# Cardigann schema and are listed explicitly instead.
# In the normal Layer 2 order (master_configure_layer2.ps1) the Prowlarr script
# runs first and already adds the tag when it creates an indexer, so on a fresh
# run there is usually nothing left to do here -- this pass repairs installs
# where the tag was not applied (indexers created before FlareSolverr was
# enabled, or a run where Prowlarr's tag setup failed).
$knownFlareDefs = @("RuTracker.org")
$indexerBase    = "http://127.0.0.1:$ProwlarrPort$ProwlarrUrlBase/api/v1/indexer"
$schemaNeedsFr  = @{}

$idxSchemas = @()
try {
    # No @() around the call: in PS 5.1 @(Invoke-RestMethod ...) collapses the whole
    # response array into ONE element, so the loop below would run once over the array
    # and every $entry.definitionName would be the stringified array -- mapping no
    # definition to its FlareSolverr flag.
    $idxSchemas = Invoke-RestMethod -Uri "$indexerBase/schema" -Headers @{"X-Api-Key" = $ApiKey} `
        -UseBasicParsing -ErrorAction Stop
    foreach ($entry in $idxSchemas) {
        $schemaNeedsFr[[string]$entry.definitionName] =
            @($entry.fields | Where-Object { $_.name -eq "info_flaresolverr" }).Count -gt 0
    }
    Write-DebugLog "VAR indexer schemas=$(@($idxSchemas).Count) flagged=$((@($schemaNeedsFr.Values) | Where-Object { $_ }).Count)"
} catch {
    Write-Warning "[$AppName] Could not fetch the indexer schema: $_"
    Write-DebugLog "WARN" "Could not fetch indexer schema: $_"
}

$tagIds   = [System.Collections.Generic.List[int]]::new()
$tagNames = [System.Collections.Generic.List[string]]::new()
$indexerList = @()
try {
    # No @() around the call (see above): the wrapper would make $indexerList a single
    # element that IS the array, so the loop would run once and every indexer would be
    # skipped as "not FlareSolverr-dependent".
    $indexerList = Invoke-RestMethod -Uri $indexerBase -Headers @{"X-Api-Key" = $ApiKey} `
        -UseBasicParsing -ErrorAction Stop
    Write-DebugLog "VAR Prowlarr indexers=$(@($indexerList).Count)"
    foreach ($idx in $indexerList) {
        $defName = [string]$idx.definitionName
        $isFlare = $knownFlareDefs -contains $defName
        if (-not $isFlare -and $schemaNeedsFr.ContainsKey($defName)) { $isFlare = [bool]$schemaNeedsFr[$defName] }
        if (-not $isFlare) { continue }
        if (@($idx.tags) -contains $flareTagId) { continue }
        $tagIds.Add([int]$idx.id)
        $tagNames.Add([string]$idx.name)
    }
} catch {
    Write-Warning "[$AppName] Could not list Prowlarr indexers: $_"
    Write-DebugLog "WARN" "Could not list Prowlarr indexers: $_"
}

if ($tagIds.Count -gt 0) {
    Write-Host "  -> Tagging $($tagIds.Count) FlareSolverr-dependent indexer(s)..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Adding tag id=$flareTagId to indexers: $($tagNames -join ', ')"
    # Bulk tag edit via the provider bulk endpoint: it only rewrites the tag list
    # (applyTags=add keeps existing tags) and skips the indexer capability test,
    # which would fail for exactly the Cloudflare-protected indexers being fixed.
    $bulkBody = @{ ids = $tagIds.ToArray(); tags = @([int]$flareTagId); applyTags = "add" } |
        ConvertTo-Json -Depth 5 -Compress
    try {
        Invoke-RestMethod -Uri "$indexerBase/bulk" -Method Put -Headers $headers -Body $bulkBody `
            -UseBasicParsing -ErrorAction Stop | Out-Null
        Write-Host "  -> OK: tagged $($tagNames -join ', ')" -ForegroundColor Green
        Write-DebugLog "INFO" "Tagged indexers with id=${flareTagId}: $($tagNames -join ', ')"
    } catch {
        Write-Warning "[$AppName] Could not tag indexers ($($tagNames -join ', ')): $_"
        Write-DebugLog "ERROR" "Indexer bulk tag update failed: $_"
    }
} else {
    Write-DebugLog "INFO" "No FlareSolverr-dependent indexer was missing the '$tagLabel' tag"
}

# -- 5b. Verify the tag reached Prowlarr --------------------------------------
# The proxy is inert without it, so read it back instead of assuming the write
# landed (an untagged proxy is exactly the failure this step exists to prevent).
$verifyProxies = @()
try {
    # No @() around the call (see above): with the wrapper $verifyProxies is one element
    # holding the whole array, and the tag check below would then read the array's own
    # property instead of a single proxy's.
    $verifyProxies = Invoke-RestMethod -Uri $proxyBase -Headers @{"X-Api-Key" = $ApiKey} `
        -UseBasicParsing -ErrorAction Stop
    $vProxy = $verifyProxies | Where-Object { $_.implementation -eq "FlareSolverr" } | Select-Object -First 1
    if ($vProxy -and (@($vProxy.tags) -contains $flareTagId)) {
        Write-Host "  -> OK: FlareSolverr proxy is active (tag id=$flareTagId)." -ForegroundColor Green
        Write-DebugLog "INFO" "Verified proxy tags=@($(@($vProxy.tags) -join ','))"
    } else {
        Write-Warning "[$AppName] FlareSolverr proxy is missing tag id=$flareTagId - Prowlarr will not use it."
        Write-DebugLog "ERROR" "Proxy tag verification failed (tags=@($(@($vProxy.tags) -join ',')))"
    }
} catch {
    Write-Warning "[$AppName] Could not verify the proxy tag: $_"
    Write-DebugLog "WARN" "Could not verify proxy tags: $_"
}

# -- 6. Verify FlareSolverr is reachable ---------------------------------------
Write-Host "  -> Checking FlareSolverr health..." -ForegroundColor Gray
Write-DebugLog "INFO" "Health check for FlareSolverr at $flareUrl..."
try {
    $healthResp = Invoke-RestMethod -Uri "http://127.0.0.1:$FlaresolverrPort/" `
        -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    Write-Host "  -> OK: FlareSolverr is reachable at $flareUrl" -ForegroundColor Green
    Write-DebugLog "INFO" "FlareSolverr is reachable. Response version=$($healthResp.version)"
} catch {
    Write-Host "  -> ! FlareSolverr not yet reachable at $flareUrl (still starting up)." -ForegroundColor Yellow
    Write-Host "       Prowlarr will use it automatically once it is running." -ForegroundColor Yellow
    Write-DebugLog "WARN" "FlareSolverr not reachable at $flareUrl (may still be starting up): $_"
}

Write-Host "  $AppName Layer 2 configuration complete." -ForegroundColor Green
Write-DebugLog "INFO" "configure_layer2_flaresolverr.ps1 complete"

exit 0
