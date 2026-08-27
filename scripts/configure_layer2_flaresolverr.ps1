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
$payload["enable"] = $true
$payload["tags"]   = @()

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

try {
    if ($existing) {
        $payload["id"] = $existing.id
        $body = $payload | ConvertTo-Json -Depth 10 -Compress
        Write-DebugLog "INFO" "Updating existing FlareSolverr proxy (id=$($existing.id)) with host=$flareUrl"
        Invoke-RestMethod -Uri "$proxyBase/$($existing.id)" -Method Put `
            -Headers $headers -Body $body -UseBasicParsing -ErrorAction Stop | Out-Null
        Write-Host "  -> OK: FlareSolverr proxy updated ($flareUrl)" -ForegroundColor Green
        Write-DebugLog "INFO" "FlareSolverr proxy updated (id=$($existing.id) host=$flareUrl)"
    } else {
        Write-DebugLog "INFO" "Creating FlareSolverr proxy with host=$flareUrl..."
        Invoke-RestMethod -Uri $proxyBase -Method Post `
            -Headers $headers -Body $body -UseBasicParsing -ErrorAction Stop | Out-Null
        Write-Host "  -> OK: FlareSolverr proxy registered ($flareUrl)" -ForegroundColor Green
        Write-DebugLog "INFO" "FlareSolverr proxy registered (host=$flareUrl)"
    }
} catch {
    Write-Warning "[$AppName] Failed to register FlareSolverr proxy with Prowlarr: $_"
    Write-DebugLog "ERROR" "FlareSolverr proxy registration failed: $_"
    exit 1
}

# -- 5. Verify FlareSolverr is reachable ---------------------------------------
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
