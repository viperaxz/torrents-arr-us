param(
    [switch]$SkipLayer2,                # pass -SkipLayer2 to stop after Layer 1 (install + auth)
    [string]$Force = ""                 # pass -Force <AppName> to wipe and reinstall a single app
)

$ErrorActionPreference = "Stop"

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Please run this script as an Administrator!"
    exit 1
}

$ConfigPath = Join-Path $PSScriptRoot "config.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Error "config.json not found! Copy config.json.example to config.json and edit it."
    exit 1
}

Write-Host "Parsing configuration..." -ForegroundColor Cyan
$Config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

# -- Load versions manifest -----------------------------------------------------
$VersionsPath = Join-Path $PSScriptRoot "versions.json"
if (Test-Path $VersionsPath) {
    $Versions = Get-Content -Raw -Path $VersionsPath | ConvertFrom-Json
    $Config | Add-Member -MemberType NoteProperty -Name "_Versions" -Value $Versions -Force
    Write-Host "Version manifest loaded (schema $($Versions.schema), updated $($Versions.updated))." -ForegroundColor DarkGray
} else {
    Write-Warning "versions.json not found. App installers will fall back to 'latest' releases."
}

$DomainMode = $Config.General.DomainMode
if ($DomainMode -ne "cloudflare" -and $DomainMode -ne "duckdns") {
    Write-Error "DomainMode must be 'cloudflare' or 'duckdns'. Got: $DomainMode"
    exit 1
}

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "scripts\debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "master_install.ps1 started. SkipLayer2=$SkipLayer2"
Write-DebugLog "INFO" "Config loaded from: $ConfigPath"
Write-DebugLog "VAR DomainMode = $DomainMode"
Write-DebugLog "VAR TlsMode    = $($Config.General.TlsMode)"
Write-DebugLog "VAR InstallDir = $($Config.General.InstallDir)"
Write-DebugLog "VAR Apps enabled: Jellyfin=$($Config.Apps.Jellyfin) Sonarr=$($Config.Apps.Sonarr) Radarr=$($Config.Apps.Radarr) Prowlarr=$($Config.Apps.Prowlarr) Deluge=$($Config.Apps.Deluge) Ffmpeg=$($Config.Apps.Ffmpeg) Bazarr=$($Config.Apps.Bazarr) Flaresolverr=$($Config.Apps.Flaresolverr) Jellyseerr=$($Config.Apps.Jellyseerr)"

Write-Host "Domain mode: $($DomainMode.ToUpper())" -ForegroundColor Cyan
Write-Host "TLS mode:    $($Config.General.TlsMode)" -ForegroundColor Cyan

# Ensure lock directory and media paths exist
$LocksDir = Join-Path $Config.General.InstallDir ".locks"
Write-DebugLog "VAR LocksDir = $LocksDir"
if (-not (Test-Path $LocksDir)) {
    New-Item -Path $LocksDir -ItemType Directory -Force | Out-Null
    Write-DebugLog "INFO" "Created LocksDir: $LocksDir"
}

foreach ($mediaPath in @($Config.Paths.Downloads, $Config.Paths.Movies, $Config.Paths.TV)) {
    if ($mediaPath -and -not (Test-Path $mediaPath)) {
        New-Item -Path $mediaPath -ItemType Directory -Force | Out-Null
        Write-Host "  Created: $mediaPath" -ForegroundColor DarkGray
        Write-DebugLog "INFO" "Created media directory: $mediaPath"
    } else {
        Write-DebugLog "VAR media path already exists: $mediaPath"
    }
}

$ScriptsDir    = Join-Path $PSScriptRoot "scripts"
$installFailed = @{}
$configFailed  = [System.Collections.Generic.List[string]]::new()

# -Force <AppName>: service-name -> bin-dir mapping ---------------------------------------------
# Some app names differ between the service, the lock file, and the binary directory.
$ForceServiceMap = @{
    "jellyfin"     = @("JellyfinServer", "jellyfin", "Jellyfin")
    "sonarr"       = @("Sonarr")
    "radarr"       = @("Radarr")
    "prowlarr"     = @("Prowlarr")
    "deluge"        = @("DelugeDaemon","DelugeWeb")
    "bazarr"       = @("Bazarr")
    "flaresolverr" = @("Flaresolverr")
    "jellyseerr"   = @("Jellyseerr")
    "grafana"      = @("Grafana")
    "zurg"         = @("Zurg")
    "rclone-rd"    = @("rclone-rd-movies")
}
$ForceBinMap = @{
    "rclone-rd" = "rclone"
}
# -- -Force <AppName>: wipe binaries so the installer runs fresh ----------------
if ($Force -ne "") {
    $ForceAppLower = $Force.ToLower()
    $ForceLock     = Join-Path $Config.General.InstallDir ".locks\.$ForceAppLower.lock"
    $ForceBinSub   = if ($ForceBinMap.ContainsKey($ForceAppLower)) { $ForceBinMap[$ForceAppLower] } else { $Force }
    $ForceBinDir   = Join-Path $Config.General.InstallDir $ForceBinSub

    Write-Host ""
    Write-Host "[Force] Preparing $Force for forced reinstall..." -ForegroundColor Yellow

    # Stop the running service if present (try all known service name variants)
    $svcNames = if ($ForceServiceMap.ContainsKey($ForceAppLower)) { $ForceServiceMap[$ForceAppLower] } else { @($Force) }
    $forceSvc = $null
    foreach ($candidate in $svcNames) {
        $forceSvc = Get-Service -Name $candidate -ErrorAction SilentlyContinue
        if ($forceSvc) { break }
    }
    if ($forceSvc -and $forceSvc.Status -eq "Running") {
        Write-Host "[Force] Stopping $($forceSvc.Name) service..." -ForegroundColor Yellow
        Stop-Service -Name $forceSvc.Name -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    } elseif (-not $forceSvc) {
        Write-Host "[Force] No running service found for '$Force' (may be CLI-only or task-based)." -ForegroundColor DarkGray
    }

    # Remove the lock file so the installer proceeds
    if (Test-Path $ForceLock) {
        Remove-Item $ForceLock -Force
        Write-Host "[Force] Removed lock file: $ForceLock" -ForegroundColor DarkGray
    }

    # Remove binaries directory (DataDir is intentionally NOT touched)
    if (Test-Path $ForceBinDir) {
        Remove-Item $ForceBinDir -Recurse -Force
        Write-Host "[Force] Removed binaries: $ForceBinDir" -ForegroundColor DarkGray
    } else {
        Write-Host "[Force] No binary directory at '$ForceBinDir' (may be Choco-installed or CLI-only)." -ForegroundColor DarkGray
    }

    Write-Host "[Force] $Force ready for reinstall." -ForegroundColor Green
    Write-Host ""
}

Write-DebugLog "VAR ScriptsDir = $ScriptsDir"

# 1. Prerequisites (fatal  --  nothing else works without these)
Write-DebugLog "INFO" "=== PHASE: Prerequisites ==="
& (Join-Path $ScriptsDir "00_prerequisites.ps1")
Write-DebugLog "INFO" "=== Prerequisites complete. LASTEXITCODE=$LASTEXITCODE ==="

# 1b. Service account (fatal  --  all services depend on this)
Write-DebugLog "INFO" "=== PHASE: Service Account ==="
& (Join-Path $ScriptsDir "00_service_account.ps1") -Config $Config
Write-DebugLog "INFO" "=== Service account complete. LASTEXITCODE=$LASTEXITCODE ==="

# 2. Web server + DNS updater (fatal)
Write-DebugLog "INFO" "=== PHASE: Web Server ==="
& (Join-Path $ScriptsDir "01_webserver.ps1") -Config $Config
Write-DebugLog "INFO" "=== Web server complete. LASTEXITCODE=$LASTEXITCODE ==="

# -- 3. Application installers -------------------------------------------------
# Each installer is wrapped in try-catch so a single failure doesn't abort the run.
# Write-Error in a child script throws (inherited $ErrorActionPreference="Stop") and
# is caught here; explicit exit 1 is caught via $LASTEXITCODE.
$appInstalls = @(
    @{ Name = "Jellyfin";      Script = "02_jellyfin.ps1"      }
    @{ Name = "Sonarr";        Script = "03_sonarr.ps1"        }
    @{ Name = "Radarr";        Script = "04_radarr.ps1"        }
    @{ Name = "Prowlarr";      Script = "05_prowlarr.ps1"      }
    @{ Name = "Deluge";         Script = "07_deluge.ps1"        }
    @{ Name = "ffmpeg";        Script = "08_ffmpeg.ps1"        }
    @{ Name = "Bazarr";        Script = "09_bazarr.ps1"        }
    @{ Name = "Flaresolverr";  Script = "10_flaresolverr.ps1"  }
    @{ Name = "Jellyseerr";    Script = "11_jellyseerr.ps1"    }
    @{ Name = "Security";      Script = "12_security.ps1"      }
    @{ Name = "Status";        Script = "13_status.ps1"        }
    @{ Name = "Grafana";       Script = "14_grafana.ps1"       }
    @{ Name = "Zurg";          Script = "15_zurg.ps1"          }
    @{ Name = "rclone-rd";     Script = "16_rclone.ps1"        }
)

Write-DebugLog "INFO" "=== PHASE: App Installers ($($appInstalls.Count) apps) ==="

foreach ($app in $appInstalls) {
    Write-DebugLog "INFO" "--- Installing $($app.Name) via $($app.Script) ---"
    try {
        $global:LASTEXITCODE = 0
        & (Join-Path $ScriptsDir $app.Script) -Config $Config
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Exited with code $LASTEXITCODE" }
        Write-DebugLog "INFO" "$($app.Name) install: SUCCESS"
    } catch {
        $installFailed[$app.Name] = "$_"
        Write-Warning "[$($app.Name)] Install FAILED - configure step will be skipped."
        Write-DebugLog "ERROR" "$($app.Name) install FAILED: $_"
    }
}

Write-DebugLog "INFO" "=== App Installers complete. Failed: $($installFailed.Keys -join ', ') ==="

# -- 4. Post-install configuration --------------------------------------------
# Skips configure if the matching install failed.
# exit 1 from a configure script is detected via $LASTEXITCODE (it does not throw).
# Unexpected exceptions are caught by try-catch.
function Invoke-Configure([string]$Name, [string]$Script) {
    if ($installFailed.ContainsKey($Name)) {
        Write-Host "[$Name] Configure skipped (install did not complete)." -ForegroundColor DarkGray
        Write-DebugLog "WARN" "[$Name] Configure skipped: install failed"
        return
    }
    Write-DebugLog "INFO" "--- Configuring $Name via $Script ---"
    try {
        $global:LASTEXITCODE = 0
        & (Join-Path $ScriptsDir $Script) -Config $Config
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            $configFailed.Add($Name)
            Write-DebugLog "ERROR" "$Name configure exited with code $LASTEXITCODE"
        } else {
            Write-DebugLog "INFO" "$Name configure: SUCCESS"
        }
    } catch {
        $configFailed.Add($Name)
        Write-Warning "[$Name] Configuration failed unexpectedly: $_"
        Write-DebugLog "ERROR" "$Name configure FAILED: $_"
    }
}

Write-DebugLog "INFO" "=== PHASE: Layer 1 Configuration ==="

Invoke-Configure "Jellyfin"    "configure_layer1_jellyfin.ps1"
if ($Config.Apps.Deluge -eq $true) {
    Invoke-Configure "Deluge" "configure_layer1_deluge.ps1"
}
Invoke-Configure "Sonarr"      "configure_layer1_sonarr.ps1"
Invoke-Configure "Radarr"      "configure_layer1_radarr.ps1"
Invoke-Configure "Prowlarr"    "configure_layer1_prowlarr.ps1"
if ($Config.Apps.Bazarr -eq $true) {
    Invoke-Configure "Bazarr" "configure_layer1_bazarr.ps1"
}
# Jellyseerr Layer 1 runs last: requires Jellyfin, Sonarr, and Radarr to be up and configured
if ($Config.Apps.Jellyseerr -eq $true) {
    Invoke-Configure "Jellyseerr" "configure_layer1_jellyseerr.ps1"
}

Write-DebugLog "INFO" "=== Layer 1 complete. ConfigFailed: $($configFailed -join ', ') ==="

# -- 5. Layer 2: Application integration --------------------------------------
if ($SkipLayer2) {
    Write-Host ""
    Write-Host "  Layer 2 skipped (-SkipLayer2)." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "=== Layer 2 SKIPPED (-SkipLayer2 flag) ==="
} else {
    Write-Host ""
    Write-DebugLog "INFO" "=== PHASE: Layer 2 ==="
    $layer2Script = Join-Path $PSScriptRoot "master_configure_layer2.ps1"
    try {
        $global:LASTEXITCODE = 0
        & $layer2Script
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            Write-Warning "Layer 2 configuration finished with errors (see above)."
            Write-DebugLog "WARN" "Layer 2 exited with code $LASTEXITCODE"
        } else {
            Write-DebugLog "INFO" "=== Layer 2 complete ==="
        }
    } catch {
        Write-Warning "Layer 2 configuration failed unexpectedly: $_"
        Write-DebugLog "ERROR" "Layer 2 FAILED: $_"
    }
}

# -- Register daily update-check scheduled task --------------------------------
$checkScript = Join-Path $PSScriptRoot "scripts\check_updates.ps1"
if (Test-Path $checkScript) {
    $taskName = "win-seedbox Update Check"
    try {
        $action  = New-ScheduledTaskAction -Execute "powershell.exe" `
                       -Argument "-WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File `"$checkScript`""
        $trigger = New-ScheduledTaskTrigger -Daily -At "10:00AM"
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Force | Out-Null
        Write-Host "  Update check task registered (daily at 10:00, runs as $env:USERNAME)." -ForegroundColor DarkGray
        Write-DebugLog "INFO" "Scheduled task '$taskName' registered for $env:USERDOMAIN\$env:USERNAME"
    } catch {
        Write-Warning "Could not register update-check task: $_"
        Write-DebugLog "WARN" "Failed to register scheduled task '$taskName': $_"
    }
}

# -- Register 'box' CLI in system PATH ----------------------------------------
$projectRoot    = $PSScriptRoot
$machinePath    = [Environment]::GetEnvironmentVariable("Path", "Machine")
$pathEntries    = $machinePath -split ";" | Where-Object { $_.Trim() -ne "" }
$alreadyInPath  = $pathEntries | Where-Object { $_.TrimEnd('\') -eq $projectRoot.TrimEnd('\') }
if (-not $alreadyInPath) {
    $newPath = ($pathEntries + $projectRoot) -join ";"
    [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
    $env:Path = $env:Path + ";$projectRoot"
    Write-Host "  'box' command registered (project dir added to PATH)." -ForegroundColor DarkGray
    Write-Host "  Open a new terminal and run: box update | box check | box uninstall" -ForegroundColor DarkGray
    Write-DebugLog "INFO" "Project dir added to Machine PATH: $projectRoot"
} else {
    Write-DebugLog "INFO" "Project dir already in Machine PATH: $projectRoot"
}

# Restart Alloy after all services are up so it can watch log files that were
# created or rotated during the install (e.g. jellyfin.log appears after Jellyfin
# starts, which can race with Alloy's first startup attempt).
if ($Config.Apps.Grafana -eq $true) {
    $alloySvc = Get-Service -Name "Alloy" -ErrorAction SilentlyContinue
    if ($alloySvc -and $alloySvc.Status -eq "Running") {
        Write-Host "  Restarting Alloy so it picks up all log files..." -ForegroundColor DarkGray
        Restart-Service -Name "Alloy" -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
        $alloySvc = Get-Service -Name "Alloy" -ErrorAction SilentlyContinue
        if ($alloySvc -and $alloySvc.Status -eq "Running") {
            Write-DebugLog "INFO" "Alloy restarted post-install to pick up all log file targets"
        } else {
            Write-Warning "  Alloy did not restart -- log shipping may be incomplete."
            Write-DebugLog "WARN" "Alloy restart failed: service is $($alloySvc.Status)"
        }
    }
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Installation complete!" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green

if ($DomainMode -eq "cloudflare") {
    $Domain = $Config.General.Domain
    Write-Host "  Dashboard:    https://$Domain" -ForegroundColor Cyan
    if ($Config.Apps.Jellyfin    -eq $true) { Write-Host "  Jellyfin:     https://jellyfin.$Domain"         -ForegroundColor Cyan }
    if ($Config.Apps.Sonarr      -eq $true) { Write-Host "  Sonarr:       https://sonarr.$Domain"          -ForegroundColor Cyan }
    if ($Config.Apps.Radarr      -eq $true) { Write-Host "  Radarr:       https://radarr.$Domain"          -ForegroundColor Cyan }
    if ($Config.Apps.Prowlarr    -eq $true) { Write-Host "  Prowlarr:     https://prowlarr.$Domain"        -ForegroundColor Cyan }
    if ($Config.Apps.Deluge       -eq $true) { Write-Host "  Deluge:       https://deluge.$Domain"          -ForegroundColor Cyan }
    if ($Config.Apps.Bazarr      -eq $true) { Write-Host "  Bazarr:       https://bazarr.$Domain"          -ForegroundColor Cyan }
    if ($Config.Apps.Jellyseerr  -eq $true) { Write-Host "  Jellyseerr:   https://jellyseerr.$Domain"      -ForegroundColor Cyan }
    if ($Config.Apps.Grafana     -eq $true) { Write-Host "  Grafana:      https://grafana.$Domain/dashboards" -ForegroundColor Cyan }
} else {
    $DuckHost = $Config.General.DuckDnsDomain
    Write-Host "  Dashboard:    https://$DuckHost" -ForegroundColor Cyan
    if ($Config.Apps.Jellyfin    -eq $true) { Write-Host "  Jellyfin:     https://$DuckHost/jellyfin"              -ForegroundColor Cyan }
    if ($Config.Apps.Sonarr      -eq $true) { Write-Host "  Sonarr:       https://$DuckHost/sonarr"                -ForegroundColor Cyan }
    if ($Config.Apps.Radarr      -eq $true) { Write-Host "  Radarr:       https://$DuckHost/radarr"                -ForegroundColor Cyan }
    if ($Config.Apps.Prowlarr    -eq $true) { Write-Host "  Prowlarr:     https://$DuckHost/prowlarr"              -ForegroundColor Cyan }
    if ($Config.Apps.Deluge       -eq $true) { Write-Host "  Deluge:       https://$DuckHost/deluge"               -ForegroundColor Cyan }
    if ($Config.Apps.Bazarr      -eq $true) { Write-Host "  Bazarr:       https://$DuckHost/bazarr"                -ForegroundColor Cyan }
    if ($Config.Apps.Jellyseerr  -eq $true) { Write-Host "  Jellyseerr:   https://$DuckHost/jellyseerr"            -ForegroundColor Cyan }
    if ($Config.Apps.Grafana     -eq $true) { Write-Host "  Grafana:      https://$DuckHost/grafana/dashboards"    -ForegroundColor Cyan }
    Write-Host ""
    if ($Config.General.TlsMode -eq "internal") {
        Write-Host "  NOTE: To trust the local Caddy root CA (removes browser warnings):" -ForegroundColor Yellow
        Write-Host "  Run once as admin: caddy trust" -ForegroundColor Yellow
    }
}
Write-Host "=============================================" -ForegroundColor Green

# -- CrowdSec status -----------------------------------------------------------
$crowdsecEnrolled = if ($Config.PSObject.Properties['Security'] -and $Config.Security.PSObject.Properties['CrowdSecEnrollKey']) {
    $Config.Security.CrowdSecEnrollKey
} else { '' }
Write-Host ""
Write-Host "  CrowdSec IDS/IPS:" -ForegroundColor Cyan
Write-Host "    Status: installed and running (engine + firewall bouncer)" -ForegroundColor DarkGray
if ($crowdsecEnrolled) {
    Write-Host "    Console: https://app.crowdsec.net (enrolled)" -ForegroundColor Green
} else {
    Write-Host "    Console: https://app.crowdsec.net (not enrolled)" -ForegroundColor Yellow
    Write-Host "    To enroll: sign up at app.crowdsec.net, copy your enrollment key," -ForegroundColor DarkGray
    Write-Host "    add it to config.json as Security.CrowdSecEnrollKey, then run:" -ForegroundColor DarkGray
    Write-Host "      & 'C:\Program Files\CrowdSec\cscli.exe' console enroll <key>" -ForegroundColor DarkGray
}
Write-Host "    Local CLI:" -ForegroundColor DarkGray
Write-Host "      & 'C:\Program Files\CrowdSec\cscli.exe' metrics" -ForegroundColor DarkGray
Write-Host "      & 'C:\Program Files\CrowdSec\cscli.exe' decisions list" -ForegroundColor DarkGray
Write-Host "      & 'C:\Program Files\CrowdSec\cscli.exe' alerts list" -ForegroundColor DarkGray
Write-DebugLog "INFO" "CrowdSec status displayed. Enrolled=$($crowdsecEnrolled -ne '' -and $crowdsecEnrolled -ne $null)"

# -- Action required summary ---------------------------------------------------
if ($installFailed.Count -gt 0 -or $configFailed.Count -gt 0) {
    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Yellow
    Write-Host "  ACTION REQUIRED" -ForegroundColor Yellow
    Write-Host "=============================================" -ForegroundColor Yellow

    foreach ($name in $installFailed.Keys) {
        Write-Host ""
        Write-Host "  [NOT INSTALLED] $name" -ForegroundColor Red
        Write-Host "  -> Re-run master_install.ps1 or install $name manually." -ForegroundColor Red
        Write-Host "     Error: $($installFailed[$name])" -ForegroundColor DarkGray
    }

    foreach ($name in $configFailed) {
        Write-Host ""
        Write-Host "  [NEEDS MANUAL CONFIG] $name" -ForegroundColor Yellow
        Write-Host "  -> App installed but auto-configuration failed." -ForegroundColor Yellow
        Write-Host "     Open the app settings and configure manually (see warnings above)." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Yellow
}

Write-DebugLog "INFO" "master_install.ps1 finished. installFailed=$($installFailed.Count) configFailed=$($configFailed.Count)"
