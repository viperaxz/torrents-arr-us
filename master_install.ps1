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
Initialize-DebugLog -Config $Config -NewRun
# Shared choco plumbing: PATH-safe resolution (a shell opened before Chocolatey
# was installed never sees chocolatey\bin) plus retry-on-transient-feed-failure
# with the output captured instead of discarded.
. (Join-Path $PSScriptRoot "scripts\choco_helpers.ps1")

# Bounded service stop/start. nssm services can sit in Stop Pending indefinitely and
# the built-in cmdlets wait on that forever; see service_helpers.ps1.
. (Join-Path $PSScriptRoot "scripts\service_helpers.ps1")
Write-DebugLog "INFO" "master_install.ps1 started. SkipLayer2=$SkipLayer2"
Write-DebugLog "INFO" "Config loaded from: $ConfigPath"
Write-DebugLog "VAR DomainMode = $DomainMode"
Write-DebugLog "VAR TlsMode    = $($Config.General.TlsMode)"
Write-DebugLog "VAR InstallDir = $($Config.General.InstallDir)"
Write-DebugLog "VAR Apps enabled: Jellyfin=$($Config.Apps.Jellyfin) Sonarr=$($Config.Apps.Sonarr) Radarr=$($Config.Apps.Radarr) Prowlarr=$($Config.Apps.Prowlarr) Deluge=$($Config.Apps.Deluge) Ffmpeg=$($Config.Apps.Ffmpeg) Bazarr=$($Config.Apps.Bazarr) Flaresolverr=$($Config.Apps.Flaresolverr) Jellyseerr=$($Config.Apps.Jellyseerr)"

Write-Host "Domain mode: $($DomainMode.ToUpper())" -ForegroundColor Cyan
Write-Host "TLS mode:    $($Config.General.TlsMode)" -ForegroundColor Cyan

# -- Warn on blank / example-default credentials --------------------------------
# These values are used for Caddy basic-auth, the app logins, and Grafana, so a
# leftover placeholder from config.json.example is an open door on a public host.
# (ServiceAccountPassword is checked by 00_service_account.ps1.)
if ([string]::IsNullOrWhiteSpace($Config.General.AdminPassword)) {
    Write-Warning "AdminPassword is blank in config.json -- Caddy basic-auth and every app login will be unusable."
    Write-DebugLog "WARN" "AdminPassword is blank"
} elseif ($Config.General.AdminPassword -in @("SuperSecretPassword123!", "changeme", "password", "admin")) {
    Write-Warning "AdminPassword is still the placeholder value from config.json.example. Change it before exposing this host."
    Write-DebugLog "WARN" "AdminPassword is a known placeholder value"
}
if ($Config.General.PSObject.Properties['DefaultUserPassword'] -and
    $Config.General.DefaultUserPassword -in @("UserPass123!", "Welcome1!", "changeme", "password")) {
    Write-Warning "DefaultUserPassword is still the placeholder value from config.json.example. Change it before creating the Jellyfin users."
    Write-DebugLog "WARN" "DefaultUserPassword is a known placeholder value"
}

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
# Infrastructure packages that are Chocolatey-only: they own no directory under
# InstallDir and no installer lock file, so -Force has to upgrade them directly.
$ForceChocoMap = @{
    "nssm"      = @{ Package = "nssm";      ManifestApp = "NSSM" }
    "python312" = @{ Package = "python312"; ManifestApp = "Python312" }
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
        $null = Stop-ServiceBounded -Name $forceSvc.Name
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

    # Infrastructure packages (NSSM, python312) are Chocolatey-only: they have no
    # directory under InstallDir, no installer lock file, and no update_*.ps1, so
    # without this branch `master_install.ps1 -Force NSSM` would silently do
    # nothing while `box check` keeps reporting a pending manual update.
    if ($ForceChocoMap.ContainsKey($ForceAppLower)) {
        $chocoPkg    = $ForceChocoMap[$ForceAppLower].Package
        $manifestApp = $ForceChocoMap[$ForceAppLower].ManifestApp
        $pinVersion  = $null
        if ($Versions -and $Versions.apps -and $Versions.apps.PSObject.Properties[$manifestApp]) {
            $pinVersion = $Versions.apps.$manifestApp.version
        }

        if (-not (Resolve-ChocoExe)) {
            Write-Warning "[Force] Chocolatey not found -- cannot upgrade '$chocoPkg'."
        } else {
            $pinLabel = if ($pinVersion) { " to $pinVersion" } else { "" }
            Write-Host "[Force] Upgrading Chocolatey package '$chocoPkg'$pinLabel..." -ForegroundColor Yellow
            $chocoArgs = @('upgrade', $chocoPkg)
            if ($pinVersion) { $chocoArgs += @('--version', $pinVersion) }
            $chocoArgs += @('-y', '--no-progress')
            Write-DebugLog "INFO" "choco $($chocoArgs -join ' ')"
            $chocoRun    = Invoke-Choco -Arguments $chocoArgs
            $chocoExit   = $chocoRun.ExitCode
            $chocoTail   = $chocoRun.Output
            if ($chocoTail -and $chocoTail.Length -gt 800) { $chocoTail = $chocoTail.Substring($chocoTail.Length - 800) }

            if ($chocoExit -ne 0 -or $chocoRun.Transient) {
                Write-Warning "[Force] choco upgrade $chocoPkg exited with code $chocoExit -- version may be unchanged."
                Write-DebugLog "ERROR" "choco upgrade $chocoPkg failed (exit $chocoExit, transient=$($chocoRun.Transient), attempts=$($chocoRun.Attempts)): $chocoTail"
            }

            # Record the real installed version so `box check` stops reporting it as pending.
            . (Join-Path $ScriptsDir "update_common.ps1")
            $entry = if ($Versions -and $Versions.apps) { $Versions.apps.$manifestApp } else { $null }
            $detected = Detect-InstalledVersion -AppName $manifestApp -Entry $entry -InstallDir $Config.General.InstallDir
            if ($detected) {
                Set-InstalledVersion -InstallDir $Config.General.InstallDir -AppName $manifestApp -Version $detected
                Write-Host "[Force] $manifestApp installed version recorded: $detected" -ForegroundColor DarkGray
            }
        }
    }

    Write-Host "[Force] $Force ready for reinstall." -ForegroundColor Green
    Write-Host ""
}

Write-DebugLog "VAR ScriptsDir = $ScriptsDir"

# 1. Prerequisites (fatal  --  nothing else works without these)
Write-DebugLog "INFO" "=== PHASE: Prerequisites ==="
& (Join-Path $ScriptsDir "00_prerequisites.ps1") -Config $Config
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
        # master_configure_layer2.ps1 is also runnable on its own, so it asks the
        # logger for a fresh file. Invoked from here it must NOT: doing so split
        # the install log in two at the Layer 2 boundary.
        $env:SEEDBOX_LOG_CHILD = '1'
        try {
            & $layer2Script
        } finally {
            Remove-Item Env:\SEEDBOX_LOG_CHILD -ErrorAction SilentlyContinue
        }
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

# -- Register health-check (test suite) tasks, schedules from config ------------
# The "Test Suite Results" Grafana dashboard reads {job="test-suite"} from Loki, so
# it stays empty until test-suite.ps1 runs. Two schedules, both read from config.json:
#
#   Tests.Quick { Enabled, IntervalMinutes }  ->  -Quick          L1 only, cheap tick
#   Tests.Full  { Enabled, Hour }             ->  -ScheduledDaily all layers, once/day
#
# Missing keys fall back to the defaults below, so a config written before this block
# existed still installs. Disabling a schedule also *removes* a task left behind by an
# earlier install -- otherwise "disabled" in config would silently keep running.
$suiteScript = Join-Path $PSScriptRoot "test-suite.ps1"
$testsCfg    = if ($Config.PSObject.Properties['Tests']) { $Config.Tests } else { $null }
$quickCfg    = if ($testsCfg -and $testsCfg.PSObject.Properties['Quick']) { $testsCfg.Quick } else { $null }
$fullCfg     = if ($testsCfg -and $testsCfg.PSObject.Properties['Full'])  { $testsCfg.Full }  else { $null }

$quickEnabled = -not ($quickCfg -and $quickCfg.PSObject.Properties['Enabled'] -and $quickCfg.Enabled -eq $false)
$quickMinutes = 15
if ($quickCfg -and $quickCfg.PSObject.Properties['IntervalMinutes']) {
    $quickMinutes = [int]$quickCfg.IntervalMinutes
    if ($quickMinutes -lt 1 -or $quickMinutes -gt 1440) {
        Write-Warning "  Tests.Quick.IntervalMinutes=$($quickCfg.IntervalMinutes) is out of range (1-1440); using 15."
        Write-DebugLog "WARN" "Tests.Quick.IntervalMinutes out of range, defaulted to 15"
        $quickMinutes = 15
    }
}

$fullEnabled = -not ($fullCfg -and $fullCfg.PSObject.Properties['Enabled'] -and $fullCfg.Enabled -eq $false)
$fullHour    = 13
if ($fullCfg -and $fullCfg.PSObject.Properties['Hour']) {
    $fullHour = [int]$fullCfg.Hour
    if ($fullHour -lt 0 -or $fullHour -gt 23) {
        Write-Warning "  Tests.Full.Hour=$($fullCfg.Hour) is out of range (0-23); using 13."
        Write-DebugLog "WARN" "Tests.Full.Hour out of range, defaulted to 13"
        $fullHour = 13
    }
}
Write-DebugLog "VAR Tests.Quick enabled=$quickEnabled interval=${quickMinutes}m  Tests.Full enabled=$fullEnabled hour=$fullHour"

if (Test-Path $suiteScript) {
    # -- Quick tick (Layer 1) --------------------------------------------------
    $suiteTask = "Seedbox_TestSuite"
    if ($quickEnabled) {
        try {
            $suiteAction    = New-ScheduledTaskAction -Execute "powershell.exe" `
                                  -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$suiteScript`" -Quick"
            $suiteTrigger   = New-ScheduledTaskTrigger -Once -At (Get-Date) `
                                  -RepetitionInterval (New-TimeSpan -Minutes $quickMinutes) `
                                  -RepetitionDuration (New-TimeSpan -Days 3650)
            # IgnoreNew so a slow run is never overlapped; the battery flags match the
            # other Seedbox_* registrations (a desktop box is often on a UPS/battery).
            $suiteSettings  = New-ScheduledTaskSettingsSet -StartWhenAvailable `
                                  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                                  -MultipleInstances IgnoreNew `
                                  -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
            $suitePrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" `
                                  -LogonType ServiceAccount -RunLevel Highest
            Register-ScheduledTask -TaskName $suiteTask -Action $suiteAction -Trigger $suiteTrigger `
                -Settings $suiteSettings -Principal $suitePrincipal -Force | Out-Null
            Write-Host "  Health-check task registered (test-suite -Quick every $quickMinutes min, SYSTEM)." -ForegroundColor DarkGray
            Write-DebugLog "INFO" "Scheduled task '$suiteTask' registered (every ${quickMinutes}m)"
        } catch {
            Write-Warning "Could not register the health-check task: $_"
            Write-DebugLog "WARN" "Failed to register scheduled task '$suiteTask': $_"
        }

        # First run now: the task fires at the next interval boundary, and an empty
        # dashboard until then reads as "broken".  This context is elevated, so the
        # <InstallDir>\dashboard\test_results.json export succeeds too.
        try {
            Write-Host "  Running the first health check (test-suite -Quick)..." -ForegroundColor DarkGray
            $savedEAP = $ErrorActionPreference
            try {
                # test-suite.ps1 warns to stderr on a SKIP; that must not abort the install.
                $ErrorActionPreference = "Continue"
                $suiteOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $suiteScript -Quick 2>&1 | Out-String
            } finally {
                $ErrorActionPreference = $savedEAP
            }
            $suiteSummary = ($suiteOut -split "`r?`n" | Where-Object { $_ -match 'PASS:\d+' } | Select-Object -Last 1)
            if ($suiteSummary) {
                Write-Host "  $($suiteSummary.Trim())" -ForegroundColor DarkGray
                Write-DebugLog "INFO" "Initial health check: $($suiteSummary.Trim())"
            } else {
                Write-DebugLog "WARN" "Initial health check produced no summary line (exit=$LASTEXITCODE)"
            }
        } catch {
            Write-DebugLog "WARN" "Initial health check run failed: $_"
        }
    } else {
        $existingQuick = Get-ScheduledTask -TaskName $suiteTask -ErrorAction SilentlyContinue
        if ($existingQuick) {
            Unregister-ScheduledTask -TaskName $suiteTask -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "  Health check disabled in config.json -- removed $suiteTask." -ForegroundColor DarkGray
            Write-DebugLog "INFO" "Tests.Quick.Enabled=false: removed scheduled task '$suiteTask'"
        } else {
            Write-Host "  Health check disabled in config.json (Tests.Quick.Enabled=false)." -ForegroundColor DarkGray
            Write-DebugLog "INFO" "Tests.Quick disabled by config; no task present"
        }
    }

    # -- Daily full pass (all layers) ------------------------------------------
    # A full pass runs real operations (RSS sync over every synced indexer, a live
    # indexer search, a magnet added and removed), so once a day and -ScheduledDaily
    # refuses a second run on the same calendar day.
    $fullTaskName = "Seedbox_TestSuiteFull"
    if ($fullEnabled) {
        try {
            $fullAt         = ('{0:00}:00' -f $fullHour)
            $fullAction     = New-ScheduledTaskAction -Execute "powershell.exe" `
                                  -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$suiteScript`" -ScheduledDaily"
            $fullTrigger    = New-ScheduledTaskTrigger -Daily -At $fullAt
            $fullSettings   = New-ScheduledTaskSettingsSet -StartWhenAvailable `
                                  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                                  -MultipleInstances IgnoreNew `
                                  -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
            $fullPrincipal  = New-ScheduledTaskPrincipal -UserId "SYSTEM" `
                                  -LogonType ServiceAccount -RunLevel Highest
            Register-ScheduledTask -TaskName $fullTaskName -Action $fullAction -Trigger $fullTrigger `
                -Settings $fullSettings -Principal $fullPrincipal -Force | Out-Null
            $fullTask = Get-ScheduledTask -TaskName $fullTaskName -ErrorAction SilentlyContinue
            if ($fullTask) {
                Write-Host "  Full health-check task registered (test-suite daily at $fullAt, once per day)." -ForegroundColor DarkGray
                Write-DebugLog "INFO" "Scheduled task '$fullTaskName' registered (daily $fullAt, state=$($fullTask.State))"
            } else {
                Write-Warning "  $fullTaskName did NOT register -- the full suite will not run on a schedule."
                Write-DebugLog "ERROR" "$fullTaskName registration did not take effect"
            }
        } catch {
            Write-Warning "Could not register the full health-check task: $_"
            Write-DebugLog "WARN" "Failed to register scheduled task '$fullTaskName': $_"
        }
    } else {
        $existingFull = Get-ScheduledTask -TaskName $fullTaskName -ErrorAction SilentlyContinue
        if ($existingFull) {
            Unregister-ScheduledTask -TaskName $fullTaskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "  Full health check disabled in config.json -- removed $fullTaskName." -ForegroundColor DarkGray
            Write-DebugLog "INFO" "Tests.Full.Enabled=false: removed scheduled task '$fullTaskName'"
        } else {
            Write-Host "  Full health check disabled in config.json (Tests.Full.Enabled=false)." -ForegroundColor DarkGray
            Write-DebugLog "INFO" "Tests.Full disabled by config; no task present"
        }
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
        $null = Restart-ServiceBounded -Name "Alloy"
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

# Optional LLM proxy (rendered by 01_webserver.ps1 only when LLM.Enabled is true)
$LlmSummaryEnabled = ($Config.PSObject.Properties['LLM'] -and
                      $Config.LLM.PSObject.Properties['Enabled'] -and
                      $Config.LLM.Enabled -eq $true)
$LlmSummarySub = if ($LlmSummaryEnabled -and $Config.LLM.PSObject.Properties['Subdomain'] -and $Config.LLM.Subdomain) {
    ([string]$Config.LLM.Subdomain).ToLower()
} else { "llm" }
$LlmSummaryUi = -not ($LlmSummaryEnabled -and
                      $Config.LLM.PSObject.Properties['ExposeUi'] -and
                      $Config.LLM.ExposeUi -eq $false)

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
    if ($LlmSummaryEnabled) {
        Write-Host "  LLM API:      https://$LlmSummarySub.$Domain/v1" -ForegroundColor Cyan
        if ($LlmSummaryUi) { Write-Host "  LLM UI:       https://$LlmSummarySub.$Domain" -ForegroundColor Cyan }
    }
} else {
    $DuckHost = $Config.General.DuckDnsDomain
    # Path mode: Jellyseerr (when enabled) owns the site root and the dashboard
    # lives on /dashboard; with Jellyseerr disabled the root falls back to the
    # dashboard. Keep this in step with the DuckDNS Caddyfile routing.
    if ($Config.Apps.Jellyseerr  -eq $true) {
        Write-Host "  Jellyseerr:   https://$DuckHost"                        -ForegroundColor Cyan
        Write-Host "  Dashboard:    https://$DuckHost/dashboard"              -ForegroundColor Cyan
    } else {
        Write-Host "  Dashboard:    https://$DuckHost"                        -ForegroundColor Cyan
        Write-Host "                https://$DuckHost/dashboard (Jellyseerr is disabled)" -ForegroundColor DarkGray
    }
    if ($Config.Apps.Jellyfin    -eq $true) { Write-Host "  Jellyfin:     https://$DuckHost/jellyfin"              -ForegroundColor Cyan }
    if ($Config.Apps.Sonarr      -eq $true) { Write-Host "  Sonarr:       https://$DuckHost/sonarr"                -ForegroundColor Cyan }
    if ($Config.Apps.Radarr      -eq $true) { Write-Host "  Radarr:       https://$DuckHost/radarr"                -ForegroundColor Cyan }
    if ($Config.Apps.Prowlarr    -eq $true) { Write-Host "  Prowlarr:     https://$DuckHost/prowlarr"              -ForegroundColor Cyan }
    if ($Config.Apps.Deluge       -eq $true) { Write-Host "  Deluge:       https://$DuckHost/deluge"               -ForegroundColor Cyan }
    if ($Config.Apps.Bazarr      -eq $true) { Write-Host "  Bazarr:       https://$DuckHost/bazarr"                -ForegroundColor Cyan }
    if ($Config.Apps.Grafana     -eq $true) { Write-Host "  Grafana:      https://$DuckHost/grafana/dashboards"    -ForegroundColor Cyan }
    if ($LlmSummaryEnabled) { Write-Host "  LLM API:      https://$DuckHost/llm/v1 (API only - the LLM UI is not published in DuckDNS mode)" -ForegroundColor Cyan }
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

# -- Recovery-tool readiness ---------------------------------------------------
# scripts/security_unban.ps1 is the tool you reach for when you have locked
# yourself out. Its -Whitelist switch permanently whitelists an address, but it
# deliberately REFUSES to invent a missing "Security" block (creating one
# surgically has a far worse failure surface than refusing). An operator would
# otherwise discover that gap at the worst possible moment, so say it here, at
# the very end of the install. Detection, enforcement and the blocklists do not
# depend on this block -- only the -Whitelist path does.
if (-not $Config.PSObject.Properties['Security']) {
    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Yellow
    Write-Host "  ACTION REQUIRED: config.json has no `"Security`" block" -ForegroundColor Yellow
    Write-Host "=============================================" -ForegroundColor Yellow
    Write-Host "  security_unban.ps1 -Whitelist will refuse to run until this exists, so" -ForegroundColor Yellow
    Write-Host "  you could not permanently whitelist an address that keeps getting banned." -ForegroundColor Yellow
    Write-Host "  (CrowdSec detection, the firewall bouncer and the abuse blocklists are" -ForegroundColor Yellow
    Write-Host "  unaffected -- they are running now.)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Add this to config.json:" -ForegroundColor Cyan
    Write-Host '    "Security": {' -ForegroundColor Cyan
    Write-Host '      "CrowdSecEnrollKey": "",' -ForegroundColor Cyan
    Write-Host '      "BanDurationHours": 4,' -ForegroundColor Cyan
    Write-Host '      "ExtraWhitelistIps": [],' -ForegroundColor Cyan
    Write-Host '      "AbuseBlocklists": true' -ForegroundColor Cyan
    Write-Host '    },' -ForegroundColor Cyan
    Write-Host "  then re-run master_install.ps1 so the whitelist parser is rewritten." -ForegroundColor DarkGray
    Write-Host "=============================================" -ForegroundColor Yellow
    Write-DebugLog "WARN" "config.json has no Security block: security_unban.ps1 -Whitelist will refuse to run"
    Write-Warning "config.json has no Security block -- security_unban.ps1 -Whitelist cannot store a whitelist entry."
}

Write-DebugLog "INFO" "master_install.ps1 finished. installFailed=$($installFailed.Count) configFailed=$($configFailed.Count)"
