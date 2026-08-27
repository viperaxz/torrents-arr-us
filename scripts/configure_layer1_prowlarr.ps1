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
Write-DebugLog "INFO" "configure_layer1_prowlarr.ps1 started"

$AppName  = "Prowlarr"
$Port     = $Config.Ports.Prowlarr
$Enabled  = $Config.Apps.Prowlarr -eq $true

$DataDir   = "C:\ProgramData\$AppName"
$ConfigXml = Join-Path $DataDir "config.xml"
$ConfigBak = "$ConfigXml.bak"
$Username  = $Config.General.AdminUsername
$Password  = $Config.General.AdminPassword
$DomainMode = $Config.General.DomainMode
$UrlBase    = if ($DomainMode -eq "duckdns") { "/prowlarr" } else { "" }

Write-DebugLog "VAR AppName=$AppName Port=$Port Enabled=$Enabled"
Write-DebugLog "VAR DataDir=$DataDir ConfigXml=$ConfigXml"
Write-DebugLog "VAR DomainMode=$DomainMode UrlBase=$UrlBase"
Write-DebugLog "VAR AdminUsername=$Username AdminPassword=[REDACTED]"

if (-not $Enabled) {
    Write-Host "[$AppName] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "$AppName skipped (not enabled)"
    return
}

Write-Host "[$AppName] Configuring authentication..." -ForegroundColor Cyan

# -- 1. Ensure service is running ----------------------------------------------
$svc = Get-Service -Name $AppName -ErrorAction SilentlyContinue
Write-DebugLog "VAR $AppName service exists=$($null -ne $svc) status=$(if ($svc) { $svc.Status } else { 'N/A' })"
if (-not $svc) {
    Write-Warning "[$AppName] Service not found. Run the installer first."
    Write-DebugLog "ERROR" "$AppName service not found"
    return
}
if ($svc.Status -ne "Running") {
    Write-Host "  -> Starting $AppName..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Starting $AppName (was $($svc.Status))..."
    Start-Service -Name $AppName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    $svc = Get-Service -Name $AppName
    Write-DebugLog "VAR $AppName status after start=$($svc.Status)"
}

# -- 2. Read API key from config.xml ------------------------------------------
Write-DebugLog "VAR ConfigXml exists=$(Test-Path $ConfigXml)"
if (-not (Test-Path $ConfigXml)) {
    Write-Warning "[$AppName] config.xml not found at '$ConfigXml'. Skipping."
    Write-DebugLog "ERROR" "config.xml not found at $ConfigXml"
    exit 1
}
[xml]$cfgXml = Get-Content -Path $ConfigXml -Encoding UTF8
$ApiKey = $cfgXml.Config.ApiKey
Write-DebugLog "VAR ApiKey found=$((-not [string]::IsNullOrEmpty($ApiKey)))"
if (-not $ApiKey) {
    Write-Warning "[$AppName] API key not found in config.xml. Skipping."
    Write-DebugLog "ERROR" "ApiKey not found in $ConfigXml"
    exit 1
}

# -- 3. Wait for API -----------------------------------------------------------
# Prowlarr uses /api/v1/ (not v3)
Write-Host "  -> Waiting for API on port $Port..." -ForegroundColor Gray
$apiUrl = "http://127.0.0.1:$Port$UrlBase/api/v1/config/host"
Write-DebugLog "INFO" "Polling Prowlarr API at $apiUrl (up to 30s)..."
$apiUp    = $false
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
    Write-DebugLog "ERROR" "$AppName API not responding at $apiUrl after 30s"
    exit 1
}

# -- 4. GET current config ---------------------------------------------------
$originalCfg = $null
Write-DebugLog "INFO" "GET current host config..."
try {
    $originalCfg = Invoke-RestMethod -Uri $apiUrl `
        -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -ErrorAction Stop
    Write-DebugLog "VAR current authMethod=$($originalCfg.authenticationMethod) username=$($originalCfg.username)"
} catch {
    Write-Warning "[$AppName] Could not read host config: $_"
    Write-DebugLog "ERROR" "GET host config failed: $_"
    exit 1
}

# -- 5. Backup config.xml ------------------------------------------------------
Copy-Item -Path $ConfigXml -Destination $ConfigBak -Force
Write-Host "  -> Backed up config.xml." -ForegroundColor Gray
Write-DebugLog "INFO" "config.xml backed up to $ConfigBak"

# -- 6. Build patched config --------------------------------------------------
$newCfg = $originalCfg | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$beforeAuth = $newCfg.authenticationMethod
$newCfg.authenticationMethod   = "forms"
$newCfg.authenticationRequired = "enabled"
$newCfg.username               = $Username
$newCfg.password               = $Password
if ($newCfg.PSObject.Properties["passwordConfirmation"]) {
    $newCfg.passwordConfirmation = $Password
}
Write-DebugLog "VAR authMethod '$beforeAuth' -> 'forms' username='$Username' password=[REDACTED]"

# -- 7. PUT new config ---------------------------------------------------------
$putOk = $false
Write-DebugLog "INFO" "PUT new config to $apiUrl"
try {
    Invoke-RestMethod -Uri $apiUrl -Method Put `
        -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
        -Body ($newCfg | ConvertTo-Json -Depth 10 -Compress) `
        -UseBasicParsing -ErrorAction Stop | Out-Null
    $putOk = $true
    Write-DebugLog "INFO" "PUT config successful"
} catch {
    Write-Warning "[$AppName] PUT failed - no changes were applied: $_"
    Write-DebugLog "ERROR" "PUT host config failed: $_"
}

if (-not $putOk) {
    Remove-Item $ConfigBak -Force -ErrorAction SilentlyContinue
    Write-Host "  -> Manual configuration required: http://127.0.0.1:$Port$UrlBase/settings/general" -ForegroundColor Yellow
    Write-DebugLog "ERROR" "PUT failed. Manual config required."
    exit 1
}

# -- 8. Restart ----------------------------------------------------------------
Write-Host "  -> Restarting $AppName..." -ForegroundColor Gray
Write-DebugLog "INFO" "Restarting $AppName..."
Stop-Service -Name $AppName -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
Start-Service -Name $AppName -ErrorAction SilentlyContinue

# -- 9. Verify -----------------------------------------------------------------
Write-Host "  -> Verifying..." -ForegroundColor Gray
Write-DebugLog "INFO" "Verifying auth config (up to 60s)..."
$ok      = $false
$deadline = (Get-Date).AddSeconds(60)
$verifyWaited = 0
while (-not $ok -and (Get-Date) -lt $deadline) {
    try {
        $check = Invoke-RestMethod -Uri $apiUrl `
            -Headers @{"X-Api-Key" = $ApiKey} -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        Write-DebugLog "VAR verify: authMethod=$($check.authenticationMethod) username=$($check.username)"
        if ($check.authenticationMethod -eq "forms" -and $check.username -eq $Username) {
            $ok = $true
        } else {
            Start-Sleep -Seconds 3; $verifyWaited += 3
        }
    } catch { Start-Sleep -Seconds 3; $verifyWaited += 3 }
}
Write-DebugLog "VAR verification ok=$ok waited=${verifyWaited}s"

if ($ok) {
    Remove-Item $ConfigBak -Force -ErrorAction SilentlyContinue
    Write-Host "  -> Auth method : Forms" -ForegroundColor Green
    Write-Host "  -> Username    : $Username" -ForegroundColor Green
    Write-Host "  -> Password    : (from config)" -ForegroundColor Green
    Write-Host "[$AppName] Authentication configured." -ForegroundColor Cyan
    Write-DebugLog "INFO" "$AppName auth configured: method=forms username=$Username"
    return
}

# -- 10. Rollback --------------------------------------------------------------
Write-Warning "[$AppName] Verification failed. Rolling back..."
Write-DebugLog "WARN" "Verification failed. Rolling back..."
$rolledBack = $false
$svcNow = Get-Service -Name $AppName -ErrorAction SilentlyContinue
if ($svcNow -and $svcNow.Status -eq "Running") {
    try {
        Invoke-RestMethod -Uri $apiUrl -Method Put `
            -Headers @{"X-Api-Key" = $ApiKey; "Content-Type" = "application/json"} `
            -Body ($originalCfg | ConvertTo-Json -Depth 10 -Compress) `
            -UseBasicParsing -ErrorAction Stop | Out-Null
        $rolledBack = $true
        Write-Host "  -> Config restored via API." -ForegroundColor Yellow
        Write-DebugLog "INFO" "API rollback successful"
    } catch { Write-DebugLog "ERROR" "API rollback failed: $_" }
}
if (-not $rolledBack -and (Test-Path $ConfigBak)) {
    Stop-Service -Name $AppName -Force -ErrorAction SilentlyContinue
    # Wait up to 15s for the service to actually stop before overwriting
    # its config file, otherwise the running process may undo the rollback
    # on its next periodic config save.
    $stoppedDeadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Seconds 2
        $svcNow = Get-Service -Name $AppName -ErrorAction SilentlyContinue
    } while ($svcNow -and $svcNow.Status -ne "Stopped" -and (Get-Date) -lt $stoppedDeadline)
    Write-DebugLog "VAR $AppName status after stop wait=$(if ($svcNow) { $svcNow.Status } else { 'N/A' })"
    Copy-Item -Path $ConfigBak -Destination $ConfigXml -Force
    Write-Host "  -> config.xml restored from backup." -ForegroundColor Yellow
    Write-DebugLog "INFO" "File rollback successful"
}
$svcFinal = Get-Service -Name $AppName -ErrorAction SilentlyContinue
if ($svcFinal -and $svcFinal.Status -ne "Running") {
    Start-Service -Name $AppName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}
Remove-Item $ConfigBak -Force -ErrorAction SilentlyContinue
Write-Warning "[$AppName] Authentication change failed and was rolled back."
Write-DebugLog "ERROR" "$AppName auth config failed and rolled back. rolledBack=$rolledBack"
Write-Host "  -> Manual configuration required." -ForegroundColor Yellow
Write-Host "  -> Open: http://127.0.0.1:$Port$UrlBase/settings/general" -ForegroundColor Yellow
Write-Host "       Username : $Username" -ForegroundColor Yellow
Write-Host "       Password : (your config.json AdminPassword)" -ForegroundColor Yellow
exit 1
