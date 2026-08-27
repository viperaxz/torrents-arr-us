param(
    [object]$Config = $null,
    [string]$GPU    = ""          # family slug (e.g. "nvidia_ada") or legacy vendor name ("nvidia"|"intel"|"amd")
)

if (-not $Config) {
    $configPath = Join-Path $PSScriptRoot "..\config.json"
    if (-not (Test-Path $configPath)) {
        Write-Error "config.json not found at '$configPath'. Pass -Config or run from the project root."
        exit 1
    }
    $Config = Get-Content -Raw -Path $configPath | ConvertFrom-Json
}

# -- Debug logging ------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "configure_layer2_jellyfin_transcoding.ps1 started"

$AppName      = "Jellyfin"
$Port         = $Config.Ports.Jellyfin
$Enabled      = $Config.Apps.Jellyfin -eq $true
$Layer2Config = $Config.Layer2.Jellyfin

$DomainMode   = $Config.General.DomainMode
$BaseUrl      = if ($DomainMode -eq "duckdns") { "/jellyfin" } else { "" }
$ApiBase      = "http://127.0.0.1:$Port$BaseUrl"
$Client       = 'MediaBrowser Client="JellyfinConfig", Device="JellyfinConfig", DeviceId="JellyfinConfig001", Version="1.0.0"'

if (-not $GPU -and $Layer2Config.GPU) { $GPU = $Layer2Config.GPU }

Write-DebugLog "VAR AppName=$AppName Port=$Port Enabled=$Enabled DomainMode=$DomainMode"
Write-DebugLog "VAR GPU=$GPU (from param or config)"

if (-not $Enabled) {
    Write-Host "[$AppName Transcoding] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "$AppName transcoding skipped (not enabled)"
    return
}

if (-not $GPU) {
    Write-Host "[$AppName Transcoding] No GPU configured - set Layer2.Jellyfin.GPU in config.json to a family slug (e.g. 'nvidia_ada', 'intel_uhd_12th') or run detect_gpu.ps1." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "GPU not configured. Skipping transcoding setup."
    return
}

# -- Resolve legacy vendor names to a family slug via auto-detection ----------
if ($GPU -notmatch '_') {
    Write-Host "  -> Auto-detecting GPU family for vendor '$GPU'..." -ForegroundColor Gray
    Write-DebugLog "INFO" "GPU value '$GPU' is a legacy vendor name; running detect_gpu.ps1 to identify family"
    $detectScript = Join-Path $PSScriptRoot "detect_gpu.ps1"
    if (Test-Path $detectScript) {
        $detectedFamily = & $detectScript -Vendor $GPU.ToLower()
        if ($detectedFamily -and $detectedFamily -ne 'cpu') {
            Write-DebugLog "INFO" "detect_gpu.ps1 returned family '$detectedFamily'"
            $GPU = $detectedFamily
        }
    }
    if ($GPU -notmatch '_') {
        # Detection failed or no dedicated GPU found; use conservative safe fallbacks
        $GPU = switch ($GPU.ToLower()) {
            'nvidia' { 'nvidia_pascal'  }
            'intel'  { 'intel_uhd_8th'  }
            'amd'    { 'amd_rdna1'       }
            default  { 'cpu'             }
        }
        Write-Host "  -> GPU family detection not available; using safe fallback: $GPU" -ForegroundColor Yellow
        Write-DebugLog "WARN" "Falling back to conservative family slug '$GPU'"
    }
}

# -- Load profile from JSON ---------------------------------------------------
$ProfilePath = Join-Path $PSScriptRoot "..\profiles\gpu\$GPU.json"
if (-not (Test-Path $ProfilePath)) {
    Write-Warning "     No profile found for GPU family '$GPU'. Using CPU software fallback."
    Write-DebugLog "WARN" "Profile file not found at '$ProfilePath'; switching to cpu.json"
    $GPU         = 'cpu'
    $ProfilePath = Join-Path $PSScriptRoot "..\profiles\gpu\cpu.json"
}

Write-DebugLog "INFO" "Loading GPU profile from '$ProfilePath'"
$gpuProfile  = Get-Content $ProfilePath -Raw | ConvertFrom-Json
$gpuLabel    = $gpuProfile.displayName
Write-Host "  -> Profile: $gpuLabel" -ForegroundColor Gray
Write-DebugLog "VAR GPU family=$GPU displayName=$gpuLabel"

$metadataFields = @('family', 'displayName', 'vendor')

# -- 1. Ensure service is running ---------------------------------------------
$svc = Get-Service -Name "JellyfinServer" -ErrorAction SilentlyContinue
if (-not $svc) {
    $svc = Get-Service -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like "*jellyfin*" -or $_.DisplayName -like "*jellyfin*" } |
           Select-Object -First 1
}
Write-DebugLog "VAR Jellyfin service found=$($null -ne $svc) status=$(if ($svc) { $svc.Status } else { 'N/A' })"
if (-not $svc) {
    Write-Warning "[$AppName Transcoding] Service not found. Run the installer first."
    Write-DebugLog "ERROR" "Jellyfin service not found"
    exit 1
}
if ($svc.Status -ne "Running") {
    Write-Host "  -> Starting $AppName..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Starting Jellyfin..."
    Start-Service -Name $svc.Name -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10
}

# -- 2. Wait for API ----------------------------------------------------------
Write-Host "  -> Waiting for API on port $Port..." -ForegroundColor Gray
$pingUrl  = "$ApiBase/System/Info/Public"
Write-DebugLog "INFO" "Polling Jellyfin API at $pingUrl (up to 180s)..."
$apiUp    = $false
$deadline = (Get-Date).AddSeconds(180)
$apiWaited = 0
while (-not $apiUp -and (Get-Date) -lt $deadline) {
    try {
        Invoke-WebRequest -Uri $pingUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop | Out-Null
        $apiUp = $true
    } catch { Start-Sleep -Seconds 3; $apiWaited += 3 }
}
Write-DebugLog "VAR Jellyfin API up=$apiUp waited=${apiWaited}s"
if (-not $apiUp) {
    Write-Warning "[$AppName Transcoding] API not responding after 180s. Skipping."
    Write-DebugLog "ERROR" "Jellyfin API not responding after 180s"
    exit 1
}

# -- 3. Authenticate ----------------------------------------------------------
$Username = $Config.General.AdminUsername
$Password = $Config.General.AdminPassword

Write-Host "  -> Authenticating..." -ForegroundColor Gray
Write-DebugLog "INFO" "Authenticating as '$Username'..."
$authBody = @{ Username = $Username; Pw = $Password } | ConvertTo-Json -Compress
$authResp = $null
try {
    $authResp = Invoke-RestMethod -Uri "$ApiBase/Users/AuthenticateByName" -Method Post `
        -Body $authBody -ContentType "application/json" `
        -Headers @{"Authorization" = $Client} -UseBasicParsing -ErrorAction Stop
    Write-DebugLog "VAR Auth succeeded. Token length=$($authResp.AccessToken.Length)"
} catch {
    Write-Warning "[$AppName Transcoding] Authentication failed: $_"
    Write-DebugLog "ERROR" "Authentication failed: $_"
    exit 1
}
if (-not $authResp.AccessToken) {
    Write-Warning "[$AppName Transcoding] No access token in response."
    Write-DebugLog "ERROR" "No access token in auth response"
    exit 1
}
$UserAuth = @{"X-MediaBrowser-Token" = $authResp.AccessToken; "Authorization" = $Client}

# -- 4. Fetch current encoding config and merge profile -----------------------
Write-Host "  -> Applying transcoding profile '$GPU'..." -ForegroundColor Gray
Write-DebugLog "INFO" "Fetching current encoding config from Jellyfin..."
$encodingPayload = @{}
try {
    $current = Invoke-RestMethod -Uri "$ApiBase/System/Configuration/encoding" `
        -Headers $UserAuth -UseBasicParsing -ErrorAction Stop
    $current.PSObject.Properties | ForEach-Object { $encodingPayload[$_.Name] = $_.Value }
    Write-DebugLog "VAR current encoding config keys=$($encodingPayload.Keys.Count) HardwareAccelerationType=$($encodingPayload['HardwareAccelerationType'])"
} catch {
    Write-Warning "     Could not fetch current encoding config; applying profile on blank base: $_"
    Write-DebugLog "WARN" "Could not fetch current encoding config: $_"
}

$mergedKeys = @()
foreach ($prop in $gpuProfile.PSObject.Properties) {
    if ($prop.Name -in $metadataFields) { continue }
    if ($encodingPayload.ContainsKey($prop.Name)) {
        $before = $encodingPayload[$prop.Name]
        $encodingPayload[$prop.Name] = $prop.Value
        $mergedKeys += $prop.Name
        Write-DebugLog "VAR encoding key '$($prop.Name)' changed: '$before' -> '$($prop.Value)'"
    }
}
Write-DebugLog "VAR merged $($mergedKeys.Count) encoding settings for '$GPU'"

# -- 5. Push config -----------------------------------------------------------
Write-DebugLog "INFO" "Pushing encoding config for '$GPU' ($gpuLabel)..."
try {
    Invoke-RestMethod -Uri "$ApiBase/System/Configuration/encoding" -Method Post `
        -Body ($encodingPayload | ConvertTo-Json -Depth 5 -Compress) `
        -ContentType "application/json" `
        -Headers $UserAuth `
        -UseBasicParsing -ErrorAction Stop | Out-Null
    Write-Host "     OK: Transcoding configured -- $gpuLabel." -ForegroundColor Green
    Write-DebugLog "INFO" "Encoding config pushed successfully for '$GPU' ($gpuLabel)"
} catch {
    Write-Warning "     Failed to apply transcoding settings: $_"
    Write-DebugLog "ERROR" "Failed to push encoding config: $_"
    exit 1
}

Write-Host "  OK: $AppName transcoding configuration complete." -ForegroundColor Green
Write-DebugLog "INFO" "configure_layer2_jellyfin_transcoding.ps1 complete"
