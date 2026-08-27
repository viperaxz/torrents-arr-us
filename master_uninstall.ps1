#Requires -RunAsAdministrator
param(
    [switch]$Force
)

# "Continue" (not "SilentlyContinue"): the uninstaller must surface failures
# so the operator knows what could not be cleaned up. Each fallible call still
# uses -ErrorAction SilentlyContinue individually where a failure is non-fatal.
$ErrorActionPreference = "Continue"

$ConfigPath = Join-Path $PSScriptRoot "config.json"
if (Test-Path $ConfigPath) {
    $Config     = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
    $InstallDir = $Config.General.InstallDir
} else {
    $InstallDir = "C:\MediaServer"
    Write-Warning "config.json not found. Using default InstallDir: $InstallDir"
    $Config = $null
}

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "scripts\debug_logger.ps1")
if ($Config) {
    Initialize-DebugLog -Config $Config
    Write-DebugLog "INFO" "master_uninstall.ps1 started. Force=$Force"
    Write-DebugLog "VAR InstallDir = $InstallDir"
} else {
    Write-Host "[DEBUG] config.json not found  --  debug logging disabled." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Red
Write-Host "  SEEDBOX UNINSTALLER" -ForegroundColor Red
Write-Host "  InstallDir : $InstallDir" -ForegroundColor Red
Write-Host "  Removes    : services, tasks, app data, binaries" -ForegroundColor Red
Write-Host "  Keeps      : Chocolatey, NSSM, vcredist, media files, Sonarr/Radarr backups" -ForegroundColor Red
Write-Host "=============================================" -ForegroundColor Red
Write-Host ""

if ($Force) {
    $confirm = "yes"
} else {
    $confirm = Read-Host "Type 'yes' to proceed"
}
if ($confirm -ne "yes") { Write-Host "Aborted." -ForegroundColor Yellow; exit 0 }
Write-Host ""
Write-DebugLog "INFO" "Uninstall confirmed by user"

function Remove-NssmService {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "  -> $Name : stopping..." -ForegroundColor Yellow
        Write-DebugLog "INFO" "Stopping service: $Name (current status: $($svc.Status))"
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        & nssm remove $Name confirm 2>$null | Out-Null
        Write-Host "  -> $Name : removed." -ForegroundColor Yellow
        Write-DebugLog "INFO" "Service removed: $Name"
    } else {
        Write-DebugLog "VAR service not found (skip): $Name"
    }
}

# -- 1. Stop any stray processes -----------------------------------------------
Write-Host "[1/8] Stopping processes..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== PHASE 1: Stop stray processes ==="
# Bazarr runs as a Python child process; kill it before NSSM service removal.
$bazarrProcs = Get-Process -Name "python", "python3", "python312" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*bazarr*" }
Write-DebugLog "VAR bazarr Python processes found: $($bazarrProcs.Count)"
$bazarrProcs | Stop-Process -Force -ErrorAction SilentlyContinue
if ($bazarrProcs.Count -gt 0) { Write-DebugLog "INFO" "Killed $($bazarrProcs.Count) bazarr Python process(es)" }

# -- 2. Remove NSSM services ---------------------------------------------------
Write-Host "[2/8] Removing services..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== PHASE 2: Remove services ==="

# Backup Caddy cert cache before the service and data directory are removed.
$CaddyDataDir = Join-Path $InstallDir "caddy-data"
Write-DebugLog "VAR CaddyDataDir = $CaddyDataDir"
Write-DebugLog "VAR CaddyDataDir exists: $(Test-Path $CaddyDataDir)"
if ($Config -and (Test-Path $CaddyDataDir) -and
    (Get-ChildItem $CaddyDataDir -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
    Write-Host "  -> Backing up Caddy cert cache..." -ForegroundColor Yellow
    Write-DebugLog "INFO" "Backing up Caddy cert cache from $CaddyDataDir"
    try {
        . (Join-Path $PSScriptRoot "scripts\cert_cache_helpers.ps1")
        $CertCacheFile = Join-Path $PSScriptRoot "cert-cache\caddy-data.enc"
        Write-DebugLog "VAR CertCacheFile = $CertCacheFile"
        Protect-CaddyData -SourceDir $CaddyDataDir -DestFile $CertCacheFile `
                          -Password $Config.General.AdminPassword
        Write-Host "  -> Cert cache saved to cert-cache\caddy-data.enc" -ForegroundColor Green
        Write-DebugLog "INFO" "Cert cache backup saved to: $CertCacheFile"
    } catch {
        Write-Warning "  -> Cert cache backup failed: $_"
        Write-DebugLog "ERROR" "Cert cache backup failed: $_"
    }
} elseif (-not $Config) {
    Write-Warning "  -> config.json not found  --  cert cache NOT backed up."
    Write-DebugLog "WARN" "Cert cache NOT backed up: config.json missing"
} else {
    Write-DebugLog "INFO" "Cert cache skip: dir empty or missing"
}

# -- Deluge state backup before service removal --------------------------------
# Preserve torrent state across reinstalls. The install script restores this.
$DelugeBackupDir = Join-Path $env:LOCALAPPDATA "win-seedbox\deluge-state-backup"
$DelugeStateDir  = Join-Path $InstallDir "Deluge-data\state"
Write-DebugLog "VAR DelugeBackupDir=$DelugeBackupDir"
Write-DebugLog "VAR DelugeStateDir=$DelugeStateDir (exists=$(Test-Path $DelugeStateDir))"
if (Test-Path $DelugeStateDir) {
    Write-Host "  -> Backing up Deluge torrent state..." -ForegroundColor Yellow
    Write-DebugLog "INFO" "Backing up Deluge state to $DelugeBackupDir"
    # Stop Deluge services before copying state to avoid file locks
    Stop-Service -Name "DelugeDaemon" -Force -ErrorAction SilentlyContinue
    Stop-Service -Name "DelugeWeb"    -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Write-DebugLog "INFO" "Deluge services stopped for state backup"
    if (Test-Path $DelugeBackupDir) { Remove-Item -Recurse -Force $DelugeBackupDir -ErrorAction SilentlyContinue }
    New-Item -Path $DelugeBackupDir -ItemType Directory -Force | Out-Null
    Copy-Item -Recurse -Force $DelugeStateDir "$DelugeBackupDir\state" -ErrorAction SilentlyContinue
    Write-DebugLog "INFO" "Deluge state backed up to $DelugeBackupDir"
} else {
    Write-DebugLog "INFO" "No Deluge state to back up (dir missing)"
}

# IPBan was replaced by CrowdSec; this clears the service on upgrades from older installs.
Remove-NssmService "IPBan"
Remove-NssmService "Caddy"
Remove-NssmService "php-cgi"
Remove-NssmService "Sonarr"
Remove-NssmService "Radarr"
Remove-NssmService "Prowlarr"
Remove-NssmService "Bazarr"
Remove-NssmService "DelugeDaemon"
Remove-NssmService "DelugeWeb"
Remove-NssmService "Flaresolverr"
Remove-NssmService "Jellyseerr"
Remove-NssmService "Grafana"
Remove-NssmService "Loki"
Remove-NssmService "Alloy"

# Unmount rclone drives before removing the services that hold them.
# Killing the rclone process without unmounting leaves the drive letter stuck
# (Windows treats it as an in-use mount point until the next reboot).
Write-DebugLog "INFO" "Checking for rclone mounts to unmount..."
$rcloneExe = Get-Command rclone.exe -ErrorAction SilentlyContinue
if ($rcloneExe -and $Config -and $Config.RealDebrid.PSObject.Properties['MountLetter']) {
    $mountLetter = $Config.RealDebrid.MountLetter
    $mountPath   = "${mountLetter}:\"
    Write-DebugLog "VAR Checking mount path=$mountPath exists=$(Test-Path $mountPath)"
    if (Test-Path $mountPath) {
        Write-Host "  -> Unmounting rclone drive ${mountLetter}: ..." -ForegroundColor Yellow
        Write-DebugLog "INFO" "Unmounting rclone drive $mountLetter before service removal"
        try {
            & $rcloneExe.Source unmount "${mountLetter}:" 2>&1 | Out-Null
            Write-Host "  -> rclone drive ${mountLetter}: unmounted." -ForegroundColor Yellow
            Write-DebugLog "INFO" "rclone unmount ${mountLetter}: succeeded"
        } catch {
            Write-Warning "  -> rclone unmount ${mountLetter}: failed (may need manual unmount after reboot): $_"
            Write-DebugLog "WARN" "rclone unmount ${mountLetter}: failed: $_"
        }
    } else {
        Write-DebugLog "INFO" "No rclone mount at $mountPath; skipping unmount"
    }
} elseif ($rcloneExe) {
    Write-DebugLog "INFO" "rclone.exe found but config/RealDebrid.MountLetter missing; skipping unmount"
} else {
    Write-DebugLog "INFO" "rclone.exe not found on PATH; skipping unmount"
}
Remove-NssmService "rclone-rd-movies"
Remove-NssmService "rclone-rd"
Remove-NssmService "Zurg"

# CrowdSec + its firewall bouncer are MSI-installed services, not NSSM ones.
# Stop them here; the packages themselves are removed in the Chocolatey phase.
Write-DebugLog "INFO" "Stopping CrowdSec services..."
foreach ($csName in @("cs-windows-firewall-bouncer", "crowdsec")) {
    $svc = Get-Service -Name $csName -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "  -> CrowdSec ($csName) : stopping..." -ForegroundColor Yellow
        Write-DebugLog "INFO" "Stopping CrowdSec service: $csName (status: $($svc.Status))"
        Stop-Service -Name $csName -Force -ErrorAction SilentlyContinue
    } else {
        Write-DebugLog "VAR CrowdSec service '$csName' not present"
    }
}

# Remove the CrowdSec Program Files tree explicitly.  Chocolatey uninstall
# (step 7) often leaves this behind because the MSI repair/remove logic is
# not always triggered by `choco uninstall`.  A leftover cscli.exe without
# a matching C:\ProgramData\CrowdSec\config\config.yaml will cause the
# security installer (12_security.ps1) to skip the install thinking
# everything is fine, then fail every cscli command with a YAML read error.
$csProgDir = "C:\Program Files\CrowdSec"
Write-DebugLog "VAR CrowdSec Program Files dir '$csProgDir' exists: $(Test-Path $csProgDir)"
if (Test-Path $csProgDir) {
    Write-Host "  -> CrowdSec : removing program files..." -ForegroundColor Yellow
    Write-DebugLog "INFO" "Removing CrowdSec Program Files: $csProgDir"
    Remove-Item -Path $csProgDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $csProgDir) {
        Write-Warning "  -> CrowdSec : could not fully remove $csProgDir (may be locked)"
        Write-DebugLog "WARN" "CrowdSec program files still present after removal attempt"
    } else {
        Write-Host "  -> CrowdSec : program files removed." -ForegroundColor Yellow
        Write-DebugLog "INFO" "CrowdSec program files removed"
    }
}

# Also clean up the bouncer Program Files if present (separate install tree).
$csBouncerProgDir = "C:\Program Files\CrowdSec\cs-windows-firewall-bouncer"
if (Test-Path $csBouncerProgDir) {
    Write-DebugLog "INFO" "Removing bouncer program files: $csBouncerProgDir"
    Remove-Item -Path $csBouncerProgDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Jellyfin: stop service, then uninstall via NSIS standalone installer if present.
# If installed via Chocolatey instead, choco uninstall in step 7 handles it.
Write-DebugLog "INFO" "Checking Jellyfin service..."
foreach ($jfName in @("JellyfinServer", "jellyfin", "Jellyfin")) {
    $svc = Get-Service -Name $jfName -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "  -> Jellyfin ($jfName) : stopping..." -ForegroundColor Yellow
        Write-DebugLog "INFO" "Stopping Jellyfin service: $jfName (status: $($svc.Status))"
        Stop-Service -Name $jfName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        break
    }
}
$jfReg = Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\JellyfinServer" -ErrorAction SilentlyContinue
Write-DebugLog "VAR Jellyfin registry entry found: $($null -ne $jfReg)"
if ($jfReg) {
    $jfExe = $jfReg.UninstallString.Trim('"')
    Write-DebugLog "VAR Jellyfin uninstaller: $jfExe"
    if (Test-Path $jfExe) {
        Write-Host "  -> Jellyfin : running NSIS silent uninstaller..." -ForegroundColor Yellow
        Write-DebugLog "INFO" "Running Jellyfin NSIS uninstaller: $jfExe"
        Start-Process -FilePath $jfExe -ArgumentList "/S" -Wait -NoNewWindow
        Write-Host "  -> Jellyfin : uninstaller finished." -ForegroundColor Yellow
        Write-DebugLog "INFO" "Jellyfin NSIS uninstaller finished"
    }
}
$jfDir = "C:\Program Files\Jellyfin"
if (Test-Path $jfDir) {
    Remove-Item -Path $jfDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  -> Jellyfin : leftover files removed." -ForegroundColor Yellow
    Write-DebugLog "INFO" "Removed Jellyfin leftover dir: $jfDir"
}

# -- 3. Remove scheduled tasks -------------------------------------------------
Write-Host "[3/8] Removing scheduled tasks..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== PHASE 3: Remove scheduled tasks ==="
foreach ($task in @("Seedbox_Cloudflare_Updater", "Seedbox_DuckDNS_Updater",
                    "Seedbox_Blocklist_Update", "Seedbox_GeoBlock_Update",
                    "Seedbox_Status_Collector",
                    "win-seedbox Update Check")) {
    $exists = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    Write-DebugLog "VAR task '$task' exists: $($null -ne $exists)"
    if ($exists) {
        Unregister-ScheduledTask -TaskName $task -Confirm:$false
        Write-Host "  -> Removed: $task" -ForegroundColor Yellow
        Write-DebugLog "INFO" "Removed scheduled task: $task"
    }
}

# -- 4. Remove firewall rules --------------------------------------------------
Write-Host "[4/8] Removing firewall rules..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== PHASE 4: Remove firewall rules ==="
$fwRules = @(
    "Caddy HTTP", "Caddy HTTPS",
    "Jellyfin", "Sonarr", "Radarr", "Prowlarr", "Bazarr",
    "Deluge BT", "Deluge BT UDP",
    "Flaresolverr", "Jellyseerr"
)
foreach ($rule in $fwRules) {
    Write-DebugLog "VAR removing firewall rule: $rule"
    Remove-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue
}
Get-NetFirewallRule -DisplayName "Seedbox-Abuse-Blocklist*" -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
# CrowdSec's firewall bouncer writes one rule per 1000 banned IPs, all prefixed
# "crowdsec-blocklist". Uninstalling the MSI does not clean these up.
Get-NetFirewallRule -DisplayName "crowdsec-blocklist*" -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
# Legacy IPBan rules from installs predating the CrowdSec migration.
Get-NetFirewallRule -DisplayName "IPBan_*" -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
# Geoblocking was removed as a feature; this clears any leftover Seedbox-Geo-* rules from installs predating the removal.
Get-NetFirewallRule -DisplayName "Seedbox-Geo-*" -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
Write-Host "  -> Firewall rules removed." -ForegroundColor Yellow
Write-DebugLog "INFO" "Firewall rules removal complete (including abuse blocklist + legacy geo rules)"

# -- 5. Remove app data (ProgramData + user AppData) --------------------------
Write-Host "[5/8] Removing app data directories..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== PHASE 5: Remove app data ==="

# -- Sonarr / Radarr data backup before the ProgramData wipe -------------------
# Preserve each app's database + config.xml across reinstalls. The matching
# installer scripts (03_sonarr.ps1 / 04_radarr.ps1) restore them before the
# service first starts. MediaCover caches and logs are skipped on purpose:
# they regenerate automatically after a library refresh.
$ArrBackupRoot = Join-Path $env:LOCALAPPDATA "win-seedbox\arr-backup"
Write-DebugLog "VAR ArrBackupRoot=$ArrBackupRoot"
foreach ($arrName in @("Sonarr", "Radarr")) {
    $arrLower = $arrName.ToLower()
    $arrData  = "C:\ProgramData\$arrName"
    $arrDb    = Join-Path $arrData "$arrLower.db"
    Write-DebugLog "VAR $arrName data dir=$arrData (exists=$(Test-Path $arrData)) db exists=$(Test-Path $arrDb)"
    if (Test-Path $arrDb) {
        $arrBackup = Join-Path $ArrBackupRoot $arrLower
        if (Test-Path $arrBackup) { Remove-Item -Path $arrBackup -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -Path $arrBackup -ItemType Directory -Force | Out-Null
        Get-ChildItem -Path $arrData -File -Filter "$arrLower.db*" -ErrorAction SilentlyContinue |
            Copy-Item -Destination $arrBackup -Force -ErrorAction SilentlyContinue
        $arrCfg = Join-Path $arrData "config.xml"
        if (Test-Path $arrCfg) {
            Copy-Item -Path $arrCfg -Destination $arrBackup -Force -ErrorAction SilentlyContinue
        }
        Write-Host "  -> $arrName data backed up (database + config.xml) -> $arrBackup" -ForegroundColor Yellow
        Write-DebugLog "INFO" "$arrName backup saved to $arrBackup"
    } else {
        Write-DebugLog "INFO" "$arrName database not found -- nothing to back up"
    }
}

$dataDirs = @(
    "C:\ProgramData\Jellyfin",
    "C:\ProgramData\Sonarr",
    "C:\ProgramData\Radarr",
    "C:\ProgramData\Prowlarr",
    "C:\ProgramData\Bazarr",
    "C:\ProgramData\Flaresolverr",
    "C:\ProgramData\Jellyseerr",
    "C:\ProgramData\CrowdSec"
)
foreach ($dir in $dataDirs) {
    $exists = Test-Path $dir
    Write-DebugLog "VAR data dir '$dir' exists: $exists"
    if ($exists) {
        Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  -> Removed: $dir" -ForegroundColor Yellow
        Write-DebugLog "INFO" "Removed data dir: $dir"
    }
}

# -- 6. Remove InstallDir contents ---------------------------------------------
Write-Host "[6/8] Removing installation files from $InstallDir..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== PHASE 6: Remove InstallDir contents from $InstallDir ==="
foreach ($sub in @("Caddy", "caddy-data", "Sonarr", "Radarr", "Prowlarr", "Bazarr", "Deluge-data", "Flaresolverr", "Jellyseerr", "Grafana", "Grafana-data", "Loki", "Loki-data", "Alloy", "Alloy-data", "Zurg", "rclone", "dashboard", "scripts", "secrets", ".locks", "logs")) {
    $path = Join-Path $InstallDir $sub
    $exists = Test-Path $path
    Write-DebugLog "VAR subdir '$sub' exists: $exists"
    if ($exists) {
        Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  -> Removed: $path" -ForegroundColor Yellow
        Write-DebugLog "INFO" "Removed: $path"
    }
}
foreach ($script in @("Update-CloudflareDNS.ps1", "Update-DuckDNS.ps1", "sonarr_jellyfin_refresh.py", "sonarr_jellyfin_refresh.cmd")) {
    $path = Join-Path $InstallDir $script
    $exists = Test-Path $path
    Write-DebugLog "VAR script '$script' exists: $exists"
    if ($exists) {
        Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
        Write-Host "  -> Removed: $path" -ForegroundColor Yellow
        Write-DebugLog "INFO" "Removed script: $path"
    }
}

# Remove the InstallDir itself when everything above is gone.  Keeping this
# separate from the per-item cleanup makes it obvious what is being deleted
# and avoids Remove-Item -Recurse racing the loop above.
$remaining = Get-ChildItem -Path $InstallDir -Force -ErrorAction SilentlyContinue
Write-DebugLog "VAR remaining items in $InstallDir after cleanup: $(if ($remaining) { $remaining.Count } else { 0 })"
if (-not $remaining -or $remaining.Count -eq 0) {
    Remove-Item -Path $InstallDir -Force -ErrorAction SilentlyContinue
    if (Test-Path $InstallDir) {
        Write-Warning "  -> Could not remove $InstallDir (may be locked)."
        Write-DebugLog "WARN" "InstallDir still present after removal attempt"
    } else {
        Write-Host "  -> Removed empty directory: $InstallDir" -ForegroundColor Yellow
        Write-DebugLog "INFO" "Removed empty InstallDir: $InstallDir"
    }
} else {
    Write-Host "  -> Skipping $InstallDir (not empty, $($remaining.Count) item(s) remain)." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "InstallDir not removed: $($remaining.Count) item(s) remain"
}

# -- 7. Remove Chocolatey app packages ----------------------------------------
# Does NOT remove prerequisites: nssm, php, git, vcredist140, chocolatey itself
Write-Host "[7/8] Uninstalling Chocolatey app packages..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== PHASE 7: Uninstall Chocolatey packages ==="
foreach ($pkg in @("caddy", "jellyfin", "deluge", "ffmpeg", "python312",
                   "crowdsec-windows-firewall-bouncer", "crowdsec", "winfsp")) {
    $installed = choco list --exact $pkg -r 2>$null
    $isInstalled = -not [string]::IsNullOrWhiteSpace($installed)
    Write-DebugLog "VAR choco package '$pkg' installed: $isInstalled (output: $installed)"
    if ($isInstalled) {
        Write-Host "  -> Uninstalling: $pkg..." -ForegroundColor Yellow
        Write-DebugLog "INFO" "Uninstalling choco package: $pkg"
        choco uninstall $pkg -y --no-progress 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  -> $pkg removed." -ForegroundColor Yellow
            Write-DebugLog "INFO" "choco uninstall $($pkg): SUCCESS (exit 0)"
        } else {
            Write-Warning "  -> $pkg uninstall failed (exit $LASTEXITCODE)  --  remove manually."
            Write-DebugLog "ERROR" "choco uninstall $($pkg): FAILED (exit $LASTEXITCODE)"
        }
    }
}
# Chocolatey leaves behind Python lib dirs even after package removal
$py312Dir = "C:\Python312"
Write-DebugLog "VAR $py312Dir exists: $(Test-Path $py312Dir)"
if (Test-Path $py312Dir) {
    Remove-Item -Path $py312Dir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  -> Removed: C:\Python312 (leftover from python312)" -ForegroundColor Yellow
    Write-DebugLog "INFO" "Removed Python312 leftover: $py312Dir"
}

# -- 8. Remove service account -------------------------------------------------
Write-Host "[8/8] Removing service account..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== PHASE 8: Remove service account ==="
$svcUser = "seedbox-svc"
$svcExists = Get-LocalUser -Name $svcUser -ErrorAction SilentlyContinue
Write-DebugLog "VAR $svcUser exists: $($null -ne $svcExists)"
if ($svcExists) {
    # Resolve the SID so we can unload the registry hive and remove ProfileList.
    $svcSid = (New-Object System.Security.Principal.NTAccount($svcUser)).Translate(
                  [System.Security.Principal.SecurityIdentifier]).Value
    Write-DebugLog "VAR SID for $svcUser = $svcSid"

    # Try to unload the registry hive (services are already stopped so it may be free).
    reg unload "HKU\$svcSid"               2>$null | Out-Null
    reg unload "HKU\${svcSid}_Classes"     2>$null | Out-Null
    Write-DebugLog "INFO" "Registry hive unload attempted for SID $svcSid"

    # Remove Win32_UserProfile (profile folder + WMI entry).
    $svcProfile = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
                  Where-Object { $_.LocalPath -like "*$svcUser*" }
    Write-DebugLog "VAR $svcUser profile found: $($null -ne $svcProfile)"
    if ($svcProfile) {
        $svcProfile | Remove-CimInstance -ErrorAction SilentlyContinue
        Write-Host "  -> seedbox-svc profile removed (C:\Users\seedbox-svc)." -ForegroundColor Yellow
        Write-DebugLog "INFO" "WMI profile removed for $svcUser"
    }

    # Remove ProfileList registry key (survives WMI removal on some Windows builds).
    $plKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$svcSid"
    $plKeyExists = Test-Path $plKey
    Write-DebugLog "VAR ProfileList registry key exists: $plKeyExists ($plKey)"
    if ($plKeyExists) {
        Remove-Item $plKey -Recurse -Force -ErrorAction SilentlyContinue
        Write-DebugLog "INFO" "Removed ProfileList key: $plKey"
    }

    # Delete folder directly if still present (hive unload succeeded).
    $profileDir = "C:\Users\$svcUser"
    Write-DebugLog "VAR profile dir $profileDir exists: $(Test-Path $profileDir)"
    if (Test-Path $profileDir) {
        Remove-Item -Path $profileDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $profileDir) {
            Write-Warning "  -> C:\Users\seedbox-svc still locked by kernel  --  reboot and delete manually."
            Write-DebugLog "WARN" "$profileDir still locked after removal attempt"
        } else {
            Write-Host "  -> seedbox-svc profile folder deleted." -ForegroundColor Yellow
            Write-DebugLog "INFO" "Profile folder deleted: $profileDir"
        }
    }

    Remove-LocalUser -Name $svcUser -ErrorAction SilentlyContinue
    Write-Host "  -> seedbox-svc account removed." -ForegroundColor Yellow
    Write-DebugLog "INFO" "Local user account removed: $svcUser"
}

# -- Done ----------------------------------------------------------------------
Write-DebugLog "INFO" "=== Uninstall complete ==="
Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Uninstall complete." -ForegroundColor Green
Write-Host "  Kept intact:" -ForegroundColor Green
Write-Host "    - Chocolatey, NSSM, vcredist (prerequisites)" -ForegroundColor Gray
if ($Config) {
    Write-Host "    - $($Config.Paths.Downloads) (downloads)" -ForegroundColor Gray
    Write-Host "    - $($Config.Paths.Movies) (movies)" -ForegroundColor Gray
    Write-Host "    - $($Config.Paths.TV) (TV)" -ForegroundColor Gray
}
Write-Host "    - Sonarr / Radarr data -> $env:LOCALAPPDATA\win-seedbox\arr-backup (restored on reinstall)" -ForegroundColor Gray
Write-Host "  Run master_install.ps1 to reinstall from scratch." -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
