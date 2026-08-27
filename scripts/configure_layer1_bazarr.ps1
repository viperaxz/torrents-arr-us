param(
    [object]$Config = $null
)

if (-not $Config) {
    $configPath = Join-Path $PSScriptRoot "..\config.json"
    if (-not (Test-Path $configPath)) {
        Write-Error "config.json not found at '$configPath'."
        exit 1
    }
    $Config = Get-Content -Raw -Path $configPath | ConvertFrom-Json
}

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "configure_layer1_bazarr.ps1 started"

$AppName    = "Bazarr"
$Port       = $Config.Ports.Bazarr
$DomainMode = $Config.General.DomainMode
$Username   = $Config.General.AdminUsername
$Password   = $Config.General.AdminPassword
$DataDir    = "C:\ProgramData\$AppName"
$ConfigFile = Join-Path $DataDir "config\config.yaml"

# Bazarr API lives under /bazarr in DuckDNS mode (base_url set during install)
$BaseUrl = if ($DomainMode -eq "duckdns") { "/bazarr" } else { "" }
$ApiBase = "http://127.0.0.1:$Port$BaseUrl"

Write-DebugLog "VAR AppName=$AppName Port=$Port DomainMode=$DomainMode"
Write-DebugLog "VAR BaseUrl=$BaseUrl ApiBase=$ApiBase"
Write-DebugLog "VAR DataDir=$DataDir ConfigFile=$ConfigFile"
Write-DebugLog "VAR AdminUsername=$Username AdminPassword=[REDACTED]"

if ($Config.Apps.Bazarr -ne $true) {
    Write-Host "[$AppName] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "$AppName skipped (not enabled)"
    return
}

Write-Host "[$AppName] Configuring..." -ForegroundColor Cyan

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

# -- 1. Ensure service is running ----------------------------------------------
$svc = Get-Service -ErrorAction SilentlyContinue |
       Where-Object { $_.Name -like "*bazarr*" -or $_.DisplayName -like "*bazarr*" } |
       Select-Object -First 1
Write-DebugLog "VAR $AppName service found=$($null -ne $svc) name=$(if ($svc) { $svc.Name } else { 'N/A' }) status=$(if ($svc) { $svc.Status } else { 'N/A' })"
if (-not $svc) {
    Write-Warning "[$AppName] Service not found. Run the installer first."
    Write-DebugLog "ERROR" "Bazarr service not found"
    exit 1
}
if ($svc.Status -ne "Running") {
    Write-DebugLog "INFO" "Starting $AppName (was $($svc.Status))..."
    Start-Service -Name $svc.Name -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10
    $svc = Get-Service -Name $svc.Name
    Write-DebugLog "VAR $AppName status after start=$($svc.Status)"
}

# -- 2. Read API key from config.yaml -----------------------------------------
Write-Host "  -> Reading API key from config.yaml..." -ForegroundColor Gray
Write-DebugLog "INFO" "Polling for API key in $ConfigFile (up to 60s)..."
$deadline = (Get-Date).AddSeconds(60)
$ApiKey   = $null
$waited   = 0
while (-not $ApiKey -and (Get-Date) -lt $deadline) {
    Write-DebugLog "VAR ConfigFile exists=$(Test-Path $ConfigFile)"
    $ApiKey = Get-YamlKey -Path $ConfigFile -Section "auth" -Key "apikey"
    if (-not $ApiKey) { Start-Sleep -Seconds 3; $waited += 3 }
}
Write-DebugLog "VAR Bazarr ApiKey found=$((-not [string]::IsNullOrEmpty($ApiKey))) waited=${waited}s"
if (-not $ApiKey) {
    Write-Warning "[$AppName] API key not found in config.yaml after 60s. Skipping."
    Write-DebugLog "ERROR" "Bazarr API key not found in $ConfigFile after 60s"
    exit 1
}
$Headers = @{ "X-API-KEY" = $ApiKey }
Write-DebugLog "INFO" "API key loaded from config.yaml [REDACTED]"

# -- 3. Wait for API -----------------------------------------------------------
Write-Host "  -> Waiting for API on port $Port..." -ForegroundColor Gray
$pingUrl = "$ApiBase/api/system/ping"
Write-DebugLog "INFO" "Polling Bazarr API at $pingUrl (up to 90s)..."
$apiUp   = $false
$deadline = (Get-Date).AddSeconds(90)
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
    Write-Warning "[$AppName] API not responding after 90s. Skipping."
    Write-DebugLog "ERROR" "Bazarr API not responding at $pingUrl after 90s"
    exit 1
}

# -- 4. Configure form authentication -----------------------------------------
# Bazarr settings API uses form data with settings-{section}-{key} key format.
# The backend MD5-hashes the password server-side, so we send it plain.
Write-Host "  -> Configuring authentication..." -ForegroundColor Gray
Write-DebugLog "INFO" "Posting auth settings to $ApiBase/api/system/settings (method=form username=$Username password=[REDACTED])"
$body = "settings-auth-type=form" +
        "&settings-auth-username=$([Uri]::EscapeDataString($Username))" +
        "&settings-auth-password=$([Uri]::EscapeDataString($Password))"
Write-DebugLog "VAR POST body fields=auth-type,auth-username,auth-password (password REDACTED)"

try {
    Invoke-RestMethod -Uri "$ApiBase/api/system/settings" -Method Post `
        -Body $body -ContentType "application/x-www-form-urlencoded" `
        -Headers $Headers -UseBasicParsing -ErrorAction Stop | Out-Null
    Write-Host "  -> Auth method : Forms" -ForegroundColor Green
    Write-Host "  -> Username    : $Username" -ForegroundColor Green
    Write-DebugLog "INFO" "Bazarr auth configured: method=form username=$Username"
} catch {
    Write-Warning "[$AppName] Could not set authentication: $_"
    Write-DebugLog "ERROR" "POST auth settings failed: $_"
    exit 1
}

Write-Host "[$AppName] Configuration complete." -ForegroundColor Cyan
Write-DebugLog "INFO" "configure_layer1_bazarr.ps1 complete"
