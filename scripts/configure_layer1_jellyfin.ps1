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
Write-DebugLog "INFO" "configure_layer1_jellyfin.ps1 started"

$AppName    = "Jellyfin"
$Port       = $Config.Ports.Jellyfin
$DomainMode = $Config.General.DomainMode
$Username   = $Config.General.AdminUsername
$Password   = $Config.General.AdminPassword
$MoviesPath = $Config.Paths.Movies
$TVPath     = $Config.Paths.TV

# Server name shown in Jellyfin UI  --  derived from the access domain in config
$ServerName = if ($DomainMode -eq "duckdns") {
    $Config.General.DuckDnsDomain
} else {
    $Config.General.Domain
}

# Jellyfin base URL: empty for subdomain mode, /jellyfin for path mode
$BaseUrl = if ($DomainMode -eq "duckdns") { "/jellyfin" } else { "" }
$ApiBase = "http://127.0.0.1:$Port$BaseUrl"

# Jellyfin requires this header on all API calls (token added after auth)
$Client = 'MediaBrowser Client="JellyfinConfig", Device="JellyfinConfig", DeviceId="JellyfinConfig001", Version="1.0.0"'

Write-DebugLog "VAR AppName=$AppName Port=$Port DomainMode=$DomainMode"
Write-DebugLog "VAR ServerName=$ServerName BaseUrl=$BaseUrl ApiBase=$ApiBase"
Write-DebugLog "VAR AdminUsername=$Username AdminPassword=[REDACTED]"
Write-DebugLog "VAR MoviesPath=$MoviesPath TVPath=$TVPath"

if ($Config.Apps.Jellyfin -ne $true) {
    Write-Host "[$AppName] Skipped per configuration." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "$AppName skipped (not enabled)"
    return
}

Write-Host "[$AppName] Configuring..." -ForegroundColor Cyan

# -- 1. Ensure service is running ----------------------------------------------
$svc = Get-Service -ErrorAction SilentlyContinue |
       Where-Object { $_.Name -like "*jellyfin*" -or $_.DisplayName -like "*jellyfin*" } |
       Select-Object -First 1
Write-DebugLog "VAR Jellyfin service found=$($null -ne $svc) name=$(if ($svc) { $svc.Name } else { 'N/A' }) status=$(if ($svc) { $svc.Status } else { 'N/A' })"
if (-not $svc) {
    Write-Warning "[$AppName] Service not found. Run the installer first."
    Write-DebugLog "ERROR" "Jellyfin service not found"
    return
}
if ($svc.Status -ne "Running") {
    Write-Host "  -> Starting $AppName..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Starting Jellyfin service '$($svc.Name)' (was $($svc.Status))..."
    Start-Service -Name $svc.Name -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10
    $svc = Get-Service -Name $svc.Name
    Write-DebugLog "VAR Jellyfin status after start=$($svc.Status)"
}

# -- 2. Wait for public API ----------------------------------------------------
Write-Host "  -> Waiting for API on port $Port..." -ForegroundColor Gray
$pingUrl = "$ApiBase/System/Info/Public"
Write-DebugLog "INFO" "Polling Jellyfin API at $pingUrl (up to 300s)..."
$apiUp   = $false
$deadline = (Get-Date).AddSeconds(300)
$apiWaited = 0
while (-not $apiUp -and (Get-Date) -lt $deadline) {
    try {
        Invoke-WebRequest -Uri $pingUrl `
            -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop | Out-Null
        $apiUp = $true
    } catch { Start-Sleep -Seconds 3; $apiWaited += 3 }
}
Write-DebugLog "VAR Jellyfin API up=$apiUp waited=${apiWaited}s"
if (-not $apiUp) {
    Write-Warning "[$AppName] API not responding after 300s. Skipping."
    Write-DebugLog "ERROR" "Jellyfin API not responding at $pingUrl after 300s"
    exit 1
}

# -- 3. Run startup wizard (skipped when already complete) ---------------------
Write-DebugLog "INFO" "Checking wizard status via $pingUrl"
$sysInfo     = Invoke-RestMethod -Uri $pingUrl -UseBasicParsing
$wizardDone  = $sysInfo.StartupWizardCompleted
Write-DebugLog "VAR StartupWizardCompleted=$wizardDone"

$step2ErrBody = $null
$step2Failed  = $false

if (-not $wizardDone) {
    Write-Host "  -> Running setup wizard..." -ForegroundColor Gray
    Write-DebugLog "INFO" "Wizard not complete. Running 4-step setup..."

    # Step 1  --  Language / metadata region
    $step1 = @{
        UICulture                 = "en-US"
        MetadataCountryCode       = "US"
        PreferredMetadataLanguage = "en"
    } | ConvertTo-Json -Compress
    Write-DebugLog "INFO" "Step 1/4: Setting language/region..."
    try {
        Invoke-RestMethod -Uri "$ApiBase/Startup/Configuration" -Method Post `
            -Body $step1 -ContentType "application/json" `
            -Headers @{"Authorization" = $Client} -UseBasicParsing -ErrorAction Stop | Out-Null
        Write-Host "  -> Step 1/4: Language set." -ForegroundColor Gray
        Write-DebugLog "INFO" "Step 1/4 complete: language=en-US region=US"
    } catch {
        Write-Warning "[$AppName] Startup/Configuration failed: $_"
        Write-DebugLog "ERROR" "Step 1/4 failed: $_"
        exit 1
    }

    # Step 2  --  Admin user.
    # GET /Startup/User first  --  this initializes the user record in Jellyfin's database.
    Write-DebugLog "INFO" "Step 2/4: GET Startup/User to initialize record..."
    try {
        Invoke-RestMethod -Uri "$ApiBase/Startup/User" -Method Get `
            -Headers @{"Authorization" = $Client} -UseBasicParsing -ErrorAction Stop | Out-Null
        Write-DebugLog "INFO" "GET Startup/User succeeded"
    } catch {
        Write-Host "  -> Step 2/4: GET Startup/User skipped (not available on this build)." -ForegroundColor DarkGray
        Write-DebugLog "WARN" "GET Startup/User skipped: $_"
    }

    $step2 = @{ Name = $Username; Password = $Password } | ConvertTo-Json -Compress
    Write-DebugLog "INFO" "Step 2/4: Creating admin user '$Username'..."
    Write-DebugLog "VAR admin password=[REDACTED]"
    try {
        Invoke-RestMethod -Uri "$ApiBase/Startup/User" -Method Post `
            -Body $step2 -ContentType "application/json" `
            -Headers @{"Authorization" = $Client} -UseBasicParsing -ErrorAction Stop | Out-Null
        Write-Host "  -> Step 2/4: Admin user '$Username' created." -ForegroundColor Gray
        Write-DebugLog "INFO" "Step 2/4 complete: admin user '$Username' created"
    } catch {
        if ($_.Exception.Response) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $step2ErrBody = $reader.ReadToEnd()
                $reader.Dispose()
                $stream.Dispose()
            } catch {}
        }
        if (-not $step2ErrBody) { $step2ErrBody = $_.ToString() }
        $step2Failed = $true
        Write-Host "  -> Step 2/4: User setup returned an error - will verify via auth." -ForegroundColor Yellow
        Write-Host "     Detail: $step2ErrBody" -ForegroundColor DarkGray
        Write-DebugLog "WARN" "Step 2/4 returned error (may be recoverable): $step2ErrBody"
    }

    # Step 3  --  Complete wizard
    Write-DebugLog "INFO" "Step 3/4: Completing wizard..."
    try {
        Invoke-RestMethod -Uri "$ApiBase/Startup/Complete" -Method Post `
            -Headers @{"Authorization" = $Client} -UseBasicParsing -ErrorAction Stop | Out-Null
        Write-Host "  -> Step 3/4: Wizard completed." -ForegroundColor Gray
        Write-DebugLog "INFO" "Step 3/4 complete: wizard marked done"
    } catch {
        Write-Warning "[$AppName] Startup/Complete failed: $_"
        Write-DebugLog "ERROR" "Step 3/4 Startup/Complete failed: $_"
        exit 1
    }

    Start-Sleep -Seconds 3
} else {
    Write-DebugLog "INFO" "Wizard already complete. Skipping setup steps."
}

# -- 4. Authenticate -----------------------------------------------------------
if ($step2Failed) {
    Write-Warning "[$AppName] Admin user creation failed (Step 2/4 error above). Authentication is not possible -- the user may not exist yet. Check the error detail and re-run Layer 1."
    Write-DebugLog "ERROR" "Authentication skipped: Step 2/4 user creation failed earlier. Detail: $step2ErrBody"
    exit 1
}

Write-Host "  -> Authenticating as '$Username'..." -ForegroundColor Gray
Write-DebugLog "INFO" "Authenticating as '$Username' (password=[REDACTED])..."
$authBody    = @{ Username = $Username; Pw = $Password } | ConvertTo-Json -Compress
$authResp    = $null
$lastAuthErr = $null
$deadline    = (Get-Date).AddSeconds(60)
$authWaited  = 0
while (-not $authResp -and (Get-Date) -lt $deadline) {
    try {
        $authResp = Invoke-RestMethod -Uri "$ApiBase/Users/AuthenticateByName" -Method Post `
            -Body $authBody -ContentType "application/json" `
            -Headers @{"Authorization" = $Client} -UseBasicParsing -ErrorAction Stop
    } catch {
        $lastAuthErr = $_.ToString()
        Start-Sleep -Seconds 3
        $authWaited += 3
    }
}
Write-DebugLog "VAR auth succeeded=$($null -ne $authResp) waited=${authWaited}s"
if (-not $authResp) {
    $errDetail = if ($lastAuthErr) { $lastAuthErr } elseif ($step2ErrBody) { $step2ErrBody } else { "no response" }
    Write-Warning "[$AppName] Authentication failed: $errDetail"
    Write-DebugLog "ERROR" "Authentication failed after ${authWaited}s: $errDetail"
    exit 1
}
Write-DebugLog "VAR Access token obtained (length=$($authResp.AccessToken.Length)) [REDACTED]"
$AuthHeader = "$Client, Token=`"$($authResp.AccessToken)`""

# -- 5. Set server name --------------------------------------------------------
Write-Host "  -> Setting server name to '$ServerName'..." -ForegroundColor Gray
Write-DebugLog "INFO" "Setting ServerName to '$ServerName'..."
try {
    $sysCfg = Invoke-RestMethod -Uri "$ApiBase/System/Configuration" `
        -Headers @{"Authorization" = $AuthHeader} -UseBasicParsing -ErrorAction Stop
    $currentName = $sysCfg.ServerName
    Write-DebugLog "VAR current ServerName='$currentName' target='$ServerName'"
    if ($sysCfg.ServerName -ne $ServerName) {
        $sysCfg.ServerName = $ServerName
        Invoke-RestMethod -Uri "$ApiBase/System/Configuration" -Method Post `
            -Body ($sysCfg | ConvertTo-Json -Depth 20 -Compress) -ContentType "application/json" `
            -Headers @{"Authorization" = $AuthHeader} -UseBasicParsing -ErrorAction Stop | Out-Null
        Write-Host "  -> Step 4/4: Server name set." -ForegroundColor Gray
        Write-DebugLog "INFO" "ServerName updated: '$currentName' -> '$ServerName'"
    } else {
        Write-Host "  -> Server name already set. Skipping." -ForegroundColor Gray
        Write-DebugLog "INFO" "ServerName already '$ServerName'  --  no change needed"
    }
} catch {
    Write-Warning "[$AppName] Could not set server name: $_"
    Write-DebugLog "WARN" "Failed to set ServerName: $_"
}

# -- 6. Add media libraries ----------------------------------------------------
Write-DebugLog "INFO" "Fetching existing Jellyfin libraries..."
$existing = @()
try {
    $existing = Invoke-RestMethod -Uri "$ApiBase/Library/VirtualFolders" `
        -Headers @{"Authorization" = $AuthHeader} -UseBasicParsing -ErrorAction Stop
    Write-DebugLog "VAR existing libraries count=$($existing.Count) names=$($existing.Name -join ',')"
} catch {
    Write-Warning "[$AppName] Could not retrieve existing libraries: $_"
    Write-DebugLog "WARN" "Could not retrieve existing libraries: $_"
}

$libraries = @(
    [pscustomobject]@{ Name = "Movies"; Type = "movies";  Path = $MoviesPath },
    [pscustomobject]@{ Name = "TV Shows";  Type = "tvshows"; Path = $TVPath }
)

foreach ($lib in $libraries) {
    $alreadyExists = $existing | Where-Object { $_.Name -eq $lib.Name }
    Write-DebugLog "VAR library '$($lib.Name)' exists=$($null -ne $alreadyExists) path=$($lib.Path)"
    if ($alreadyExists) {
        Write-Host "  -> Library '$($lib.Name)' already exists. Skipping." -ForegroundColor Gray
        Write-DebugLog "INFO" "Library '$($lib.Name)' already exists  --  skipping"
        continue
    }
    if (-not (Test-Path $lib.Path)) {
        Write-Warning "  -> Path '$($lib.Path)' not found. Skipping '$($lib.Name)' library."
        Write-DebugLog "WARN" "Library path not found: $($lib.Path)  --  skipping '$($lib.Name)'"
        continue
    }
    $body = @{
        LibraryOptions = @{
            PathInfos = @( @{ Path = $lib.Path } )
        }
    } | ConvertTo-Json -Depth 5 -Compress
    Write-DebugLog "INFO" "Creating library '$($lib.Name)' type=$($lib.Type) path=$($lib.Path)"
    try {
        Invoke-RestMethod `
            -Uri "$ApiBase/Library/VirtualFolders?name=$($lib.Name)&collectionType=$($lib.Type)&refreshLibrary=false" `
            -Method Post -Body $body -ContentType "application/json" `
            -Headers @{"Authorization" = $AuthHeader} -UseBasicParsing -ErrorAction Stop | Out-Null
        Write-Host "  -> Library '$($lib.Name)': $($lib.Path)" -ForegroundColor Green
        Write-DebugLog "INFO" "Library '$($lib.Name)' created successfully"
    } catch {
        Write-Warning "  -> Could not add '$($lib.Name)' library: $_"
        Write-DebugLog "ERROR" "Failed to create library '$($lib.Name)': $_"
    }
}

# -- 7. Provision additional users from Config.Users ---------------------------
$configUsers = @()
if ($Config.PSObject.Properties["Users"] -and $Config.Users) {
    $configUsers = @($Config.Users)
}
$defaultPwd = if ($Config.General.PSObject.Properties["DefaultUserPassword"] -and $Config.General.DefaultUserPassword) {
    $Config.General.DefaultUserPassword
} else {
    $null
}
Write-DebugLog "VAR Config.Users count=$($configUsers.Count) DefaultUserPassword=$(if ($defaultPwd) { '[REDACTED]' } else { '(not set)' })"

if ($configUsers.Count -gt 0) {
    Write-Host "  -> Provisioning $($configUsers.Count) user(s)..." -ForegroundColor Gray

    # Fetch current user list once (to check for existing accounts)
    $existingUsers = @()
    try {
        $existingUsers = Invoke-RestMethod -Uri "$ApiBase/Users" `
            -Headers @{"Authorization" = $AuthHeader} -UseBasicParsing -ErrorAction Stop
        Write-DebugLog "VAR existing Jellyfin users=$($existingUsers.Count)"
    } catch {
        Write-Warning "  -> Could not retrieve existing user list: $_"
        Write-DebugLog "WARN" "Could not fetch /Users: $_"
    }

    foreach ($u in $configUsers) {
        $uName = $u.Username
        $uPwd  = if ($u.PSObject.Properties["Password"] -and $u.Password) { $u.Password } else { $defaultPwd }

        Write-DebugLog "VAR Provisioning user '$uName' pwd=$(if ($uPwd) { '[REDACTED]' } else { '(none  --  will skip password)' })"

        $existing = $existingUsers | Where-Object { $_.Name -ieq $uName } | Select-Object -First 1
        if ($existing) {
            Write-Host "    -> '$uName' already exists (id=$($existing.Id)). Skipping." -ForegroundColor DarkGray
            Write-DebugLog "INFO" "User '$uName' already exists id=$($existing.Id)"
            continue
        }

        # Create the user (no password on creation; set separately)
        $newUser = $null
        try {
            $newUser = Invoke-RestMethod -Uri "$ApiBase/Users/New" -Method Post `
                -Body (@{ Name = $uName } | ConvertTo-Json -Compress) `
                -ContentType "application/json" `
                -Headers @{"Authorization" = $AuthHeader} -UseBasicParsing -ErrorAction Stop
            Write-DebugLog "VAR Created Jellyfin user '$uName' id=$($newUser.Id)"
        } catch {
            Write-Warning "    -> Could not create user '$uName': $_"
            Write-DebugLog "ERROR" "Failed to create Jellyfin user '$uName': $_"
            continue
        }

        # Set the password
        if ($uPwd -and $newUser) {
            try {
                Invoke-RestMethod -Uri "$ApiBase/Users/$($newUser.Id)/Password" -Method Post `
                    -Body (@{ CurrentPw = ""; NewPw = $uPwd } | ConvertTo-Json -Compress) `
                    -ContentType "application/json" `
                    -Headers @{"Authorization" = $AuthHeader} -UseBasicParsing -ErrorAction Stop | Out-Null
                Write-Host "    -> '$uName' created." -ForegroundColor Green
                Write-DebugLog "INFO" "Password set for '$uName' id=$($newUser.Id)"
            } catch {
                Write-Warning "    -> User '$uName' created but password could not be set: $_"
                Write-DebugLog "WARN" "Password set failed for '$uName': $_"
            }
        } elseif ($newUser) {
            Write-Host "    -> '$uName' created (no password  --  set one manually)." -ForegroundColor Yellow
            Write-DebugLog "WARN" "User '$uName' created without a password (no DefaultUserPassword or per-user Password in config)"
        }
    }
} else {
    Write-DebugLog "INFO" "No Config.Users defined  --  skipping user provisioning"
}

Write-Host ""
Write-Host "  -> Server name : $ServerName" -ForegroundColor Green
Write-Host "  -> Admin user  : $Username" -ForegroundColor Green
Write-Host "  -> Movies      : $MoviesPath" -ForegroundColor Green
Write-Host "  -> Shows       : $TVPath" -ForegroundColor Green
if ($configUsers.Count -gt 0) {
    Write-Host "  -> Users       : $($configUsers.Username -join ', ')" -ForegroundColor Green
}
Write-Host "[$AppName] Configuration complete." -ForegroundColor Cyan
Write-DebugLog "INFO" "configure_layer1_jellyfin.ps1 complete. ServerName=$ServerName username=$Username users=$($configUsers.Count)"
