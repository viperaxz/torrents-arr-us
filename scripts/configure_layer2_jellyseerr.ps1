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
Write-DebugLog "INFO" "configure_layer2_jellyseerr.ps1 started"

$AppName    = "Jellyseerr"
$AppPort    = if ($Config.Ports.PSObject.Properties["Jellyseerr"]) { $Config.Ports.Jellyseerr } else { 5055 }
$JfPort     = $Config.Ports.Jellyfin
$DomainMode = $Config.General.DomainMode
$AdminUser  = $Config.General.AdminUsername
$AdminPass  = $Config.General.AdminPassword
$JfUrlBase  = if ($DomainMode -eq "duckdns") { "/jellyfin" } else { "" }
$ApiBase    = "http://127.0.0.1:$AppPort"

Write-DebugLog "VAR AppName=$AppName AppPort=$AppPort JfPort=$JfPort DomainMode=$DomainMode"

if ($Config.Apps.Jellyseerr -ne $true) {
    Write-Host "[$AppName] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "$AppName skipped (not enabled)"
    return
}

# Collect users to provision.  Sources (in priority order):
#   1. Config.Users array
#   2. Nothing  --  skip silently, shared provisioning is optional
$users = @()
if ($Config.PSObject.Properties["Users"] -and $Config.Users) {
    $users = @($Config.Users)
}
$defaultPwd = if ($Config.General.PSObject.Properties["DefaultUserPassword"] -and $Config.General.DefaultUserPassword) {
    $Config.General.DefaultUserPassword
} else {
    $null
}

Write-DebugLog "VAR users=$($users.Count) defaultPwd=$(if ($defaultPwd) { '[REDACTED]' } else { '(not set)' })"

if ($users.Count -eq 0) {
    Write-Host "[$AppName] No users in config  --  skipping user import." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "No users defined in Config.Users  --  skipping"
    return
}

Write-Host "[$AppName] Importing $($users.Count) user(s) from Jellyfin..." -ForegroundColor Cyan

# -- 1. Ensure Jellyseerr is running -------------------------------------------
$svc = Get-Service -Name $AppName -ErrorAction SilentlyContinue
Write-DebugLog "VAR $AppName service status=$(if ($svc) { $svc.Status } else { 'NOT FOUND' })"
if (-not $svc) {
    Write-Warning "[$AppName] Service not found. Run the installer first."
    Write-DebugLog "ERROR" "Jellyseerr service not found"
    exit 1
}
if ($svc.Status -ne "Running") {
    Write-Host "  -> Starting $AppName..." -ForegroundColor Gray
    Start-Service -Name $AppName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10
}

# -- 2. Authenticate against Jellyseerr ---------------------------------------
Write-Host "  -> Authenticating with Jellyseerr..." -ForegroundColor Gray
$authBody = @{
    username = $AdminUser
    password = $AdminPass
} | ConvertTo-Json -Compress

Write-DebugLog "INFO" "POST /api/v1/auth/jellyfin adminUser=$AdminUser jfPort=$JfPort"

# Jellyseerr may still be connecting to Jellyfin internally.
# Retry with back-off for up to 60 s so a transient failure doesn't abort Layer 2.
$session   = $null
$authUp    = $false
$authErr   = ""
$deadline  = (Get-Date).AddSeconds(60)
$authWaited = 0
while (-not $authUp -and (Get-Date) -lt $deadline) {
    try {
        Invoke-RestMethod -Uri "$ApiBase/api/v1/auth/jellyfin" -Method Post `
            -Body $authBody -ContentType "application/json" `
            -UseBasicParsing -SessionVariable "session" -ErrorAction Stop | Out-Null
        $authUp = $true
        Write-DebugLog "INFO" "Jellyseerr auth succeeded"
    } catch {
        $authErr = $_.ToString()
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

function Invoke-JellyseerrApi {
    param([string]$Path, [string]$Method = "Get", [object]$Body = $null)
    $params = @{
        Uri             = "$ApiBase$Path"
        Method          = $Method
        WebSession      = $session
        UseBasicParsing = $true
        ErrorAction     = "Stop"
    }
    if ($Body) {
        $params["Body"]        = ($Body | ConvertTo-Json -Compress -Depth 10)
        $params["ContentType"] = "application/json"
    }
    return Invoke-RestMethod @params
}

# -- 3. Get all Jellyfin users via the Jellyseerr proxy ------------------------
# Jellyseerr exposes /api/v1/settings/jellyfin/users which returns the
# known Jellyfin users with their jellyfinUserId field.
Write-Host "  -> Fetching Jellyfin user list..." -ForegroundColor Gray
Write-DebugLog "INFO" "GET /api/v1/settings/jellyfin/users"
$jfUsers = @()
try {
    $jfUsers = Invoke-JellyseerrApi -Path "/api/v1/settings/jellyfin/users"
    if (-not ($jfUsers -is [array])) { $jfUsers = @($jfUsers) }
    Write-DebugLog "VAR Jellyfin users from Jellyseerr=$($jfUsers.Count)"
} catch {
    Write-Warning "[$AppName] Could not fetch Jellyfin users from Jellyseerr: $_"
    Write-DebugLog "WARN" "Failed to GET /api/v1/settings/jellyfin/users: $_  --  will try direct Jellyfin API"
}

# Fallback: query Jellyfin directly if the Jellyseerr proxy endpoint fails
if ($jfUsers.Count -eq 0 -and $Config.Apps.Jellyfin -eq $true) {
    Write-DebugLog "INFO" "Fallback: querying Jellyfin /Users directly"
    $jfApiBase = "http://127.0.0.1:$JfPort$JfUrlBase"
    $embyHdr   = 'MediaBrowser Client="JellyseerrL2", Device="PS", DeviceId="JL2001", Version="1.0.0"'
    try {
        $authR = Invoke-RestMethod -Uri "$jfApiBase/Users/AuthenticateByName" -Method Post `
            -Body (@{ Username = $AdminUser; Pw = $AdminPass } | ConvertTo-Json -Compress) `
            -ContentType "application/json" `
            -Headers @{"Authorization" = $embyHdr} -UseBasicParsing -ErrorAction Stop
        $jfToken = $authR.AccessToken
        $jfAuthHdr = "$embyHdr, Token=`"$jfToken`""
        $jfUsersRaw = Invoke-RestMethod -Uri "$jfApiBase/Users" `
            -Headers @{"Authorization" = $jfAuthHdr} -UseBasicParsing -ErrorAction Stop
        # Normalise: Jellyseerr expects jellyfinUserId, Jellyfin returns Id
        $jfUsers = @($jfUsersRaw | ForEach-Object { [pscustomobject]@{ jellyfinUserId = $_.Id; username = $_.Name } })
        Write-DebugLog "VAR Jellyfin direct users=$($jfUsers.Count)"
    } catch {
        Write-Warning "[$AppName] Could not query Jellyfin /Users directly: $_"
        Write-DebugLog "WARN" "Jellyfin direct user fetch failed: $_"
    }
}

if ($jfUsers.Count -eq 0) {
    Write-Warning "[$AppName] No Jellyfin users found  --  cannot import users. Skipping."
    Write-DebugLog "WARN" "No Jellyfin users available for import"
    return
}
Write-DebugLog "VAR total Jellyfin users available=$($jfUsers.Count)"

# -- 4. Build import list ------------------------------------------------------
# Match each Config.Users entry against the Jellyfin user list by username
$importIds = @()
foreach ($u in $users) {
    $name = $u.Username
    $match = $jfUsers | Where-Object {
        ($_.username -ieq $name) -or ($_.Name -ieq $name)
    } | Select-Object -First 1

    if ($match) {
        $jfId = if ($match.jellyfinUserId) { $match.jellyfinUserId } else { $match.Id }
        $importIds += $jfId
        Write-DebugLog "VAR User '$name' -> jellyfinUserId=$jfId"
    } else {
        Write-Warning "  -> User '$name' not found in Jellyfin  --  skipping (create them in Jellyfin first)."
        Write-DebugLog "WARN" "User '$name' not found in Jellyfin user list"
    }
}

if ($importIds.Count -eq 0) {
    Write-Warning "[$AppName] None of the configured users found in Jellyfin. Skipping import."
    Write-DebugLog "WARN" "Import ID list is empty  --  no users to import"
    return
}
Write-DebugLog "VAR importing $($importIds.Count) user IDs: $($importIds -join ', ')"

# -- 5. Check which users are already imported ---------------------------------
$existingJsUsers = @()
try {
    $resp = Invoke-JellyseerrApi -Path "/api/v1/user?take=250&skip=0"
    $existingJsUsers = if ($resp.results) { @($resp.results) } else { @($resp) }
    Write-DebugLog "VAR existing Jellyseerr users=$($existingJsUsers.Count)"
} catch {
    Write-DebugLog "WARN" "Could not fetch existing Jellyseerr users: $_"
}

$existingJfIds = @($existingJsUsers | ForEach-Object { $_.jellyfinUserId } | Where-Object { $_ })
$toImport = $importIds | Where-Object { $_ -notin $existingJfIds }
Write-DebugLog "VAR already imported=$($existingJfIds.Count) toImport=$($toImport.Count)"

if ($toImport.Count -eq 0) {
    Write-Host "  -> All users are already imported in Jellyseerr." -ForegroundColor Green
    Write-DebugLog "INFO" "All users already present  --  nothing to import"
    return
}

# -- 6. Import users from Jellyfin into Jellyseerr ----------------------------
Write-Host "  -> Importing $($toImport.Count) user(s)..." -ForegroundColor Gray
Write-DebugLog "INFO" "POST /api/v1/user/import-from-jellyfin ids=$($toImport -join ', ')"
try {
    $result = Invoke-JellyseerrApi -Path "/api/v1/user/import-from-jellyfin" -Method Post -Body @{
        jellyfinUserIds = @($toImport)
    }
    $imported = if ($result -is [array]) { $result.Count } else { 1 }
    Write-Host "  -> Imported $imported user(s)." -ForegroundColor Green
    Write-DebugLog "INFO" "Import succeeded: $imported users created in Jellyseerr"
} catch {
    $errDetail = $_.ToString()
    if ($_.Exception.Response) {
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $errDetail = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
        } catch {}
    }
    Write-Warning "[$AppName] User import failed: $errDetail"
    Write-DebugLog "ERROR" "POST /api/v1/user/import-from-jellyfin failed: $errDetail"
    exit 1
}

Write-Host "[$AppName] Layer 2 user provisioning complete." -ForegroundColor Green
Write-DebugLog "INFO" "configure_layer2_jellyseerr.ps1 complete"
