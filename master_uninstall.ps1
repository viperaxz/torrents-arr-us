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
    Initialize-DebugLog -Config $Config -NewRun
    Write-DebugLog "INFO" "master_uninstall.ps1 started. Force=$Force"
    Write-DebugLog "VAR InstallDir = $InstallDir"
} else {
    Write-Host "[DEBUG] config.json not found  --  debug logging disabled." -ForegroundColor DarkGray
}

# Shared choco plumbing. This is the file that died at step 7 of 8 with
# "The term 'choco' is not recognized": a shell opened BEFORE Chocolatey was
# installed never sees chocolatey\bin even though the Machine PATH names it,
# because a process reads PATH only at startup. Resolve-ChocoExe does not trust
# $env:Path -- it checks the known install location and re-reads the registry.
. (Join-Path $PSScriptRoot "scripts\choco_helpers.ps1")

Write-Host ""
Write-Host "=============================================" -ForegroundColor Red
Write-Host "  SEEDBOX UNINSTALLER" -ForegroundColor Red
Write-Host "  InstallDir : $InstallDir" -ForegroundColor Red
Write-Host "  Removes    : services, tasks, app data, binaries" -ForegroundColor Red
Write-Host "  Keeps      : Chocolatey, NSSM, vcredist, Python 3.12, media files, Sonarr/Radarr backups" -ForegroundColor Red
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

# Bounded service stops live in service_helpers.ps1 so the installer, the
# uninstaller and the configure scripts all share one implementation.
if (-not (Get-Command Stop-ServicesBounded -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "scripts\service_helpers.ps1")
}

function Remove-NssmService {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "  -> $Name : stopping..." -ForegroundColor Yellow
        Write-DebugLog "INFO" "Stopping service: $Name (current status: $($svc.Status))"
        $null = Stop-ServiceBounded -Name $Name
        if (-not $script:NssmExe) {
            # The uninstaller's PATH is the one this shell started with; nssm is a
            # Chocolatey shim that may not be on it. Removal used to fail silently
            # (the error was redirected away) while the log still said "removed".
            $script:NssmExe = (Get-Command nssm.exe -ErrorAction SilentlyContinue).Source
            if (-not $script:NssmExe) {
                $candidate = Join-Path $env:ProgramData "chocolatey\bin\nssm.exe"
                if (Test-Path $candidate) { $script:NssmExe = $candidate }
            }
        }
        if ($script:NssmExe) {
            & $script:NssmExe remove $Name confirm 2>&1 | Out-Null
        } else {
            Write-Warning "  -> $Name : nssm.exe not found -- the service could not be removed."
            Write-DebugLog "ERROR" "nssm.exe not found; cannot remove service $Name"
        }
        # Verify instead of claiming: a surviving service holds its port and its
        # binary directory, which breaks the reinstall that follows. The short retry
        # covers the moment the SCM needs to drop a service that was just marked
        # for deletion -- it must not turn into a false warning on a healthy run.
        $still = $null
        for ($i = 0; $i -lt 4; $i++) {
            $still = Get-Service -Name $Name -ErrorAction SilentlyContinue
            if (-not $still) { break }
            Start-Sleep -Milliseconds 500
        }
        if ($still) {
            Write-Warning "  -> $Name : still present after removal (status=$($still.Status))."
            Write-DebugLog "ERROR" "Service $Name still present after nssm remove"
        } else {
            Write-Host "  -> $Name : removed." -ForegroundColor Yellow
            Write-DebugLog "INFO" "Service removed: $Name"
        }
    } else {
        Write-DebugLog "VAR service not found (skip): $Name"
    }
}

# -- Remove a single entry from the Machine PATH -------------------------------
# Written against the registry rather than [Environment]::SetEnvironmentVariable so
# the value's type survives. That API rewrites an ExpandString PATH as a plain
# String, which would stop any %VAR% reference in the remaining entries (e.g.
# %SystemRoot%\system32) from expanding.
function Remove-MachinePathEntry {
    param([Parameter(Mandatory = $true)][string]$Entry)
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    try {
        $kind = (Get-Item $key -ErrorAction Stop).GetValueKind('Path')
        $cur  = (Get-ItemProperty -Path $key -Name Path -ErrorAction Stop).Path
    } catch {
        Write-DebugLog "WARN" "Could not read the Machine PATH, skipping removal of '$Entry': $_"
        return $false
    }
    if (-not $cur) { return $false }

    # Same normalization the installer applies when adding an entry.
    $wanted  = $Entry.Trim().Trim('"').TrimEnd('\')
    $entries = @($cur -split ';' | Where-Object { $_.Trim().Trim('"') -ne '' })
    $kept    = @($entries | Where-Object { -not ($_.Trim().Trim('"').TrimEnd('\') -ieq $wanted) })
    if ($kept.Count -eq $entries.Count) { return $false }

    $type = if ($kind -eq 'ExpandString') { 'ExpandString' } else { 'String' }
    Set-ItemProperty -Path $key -Name Path -Value ($kept -join ';') -Type $type -ErrorAction Stop
    return $true
}

# -- Schedule a locked path for deletion at the next boot ----------------------
# A profile whose registry hives are still mapped cannot be deleted in-session:
# UsrClass.dat stays open until the hive is unloaded, which only happens on
# reboot. PendingFileRenameOperations is processed before services start, so
# queue files first and then directories deepest-first; each directory is empty
# by the time its own delete entry runs.
# Returns { Queued; AlreadyQueued } so the caller can distinguish "nothing to do,
# an earlier run already scheduled it" from "could not be queued at all".
function Register-PathForDeletionAtReboot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $items = @()
    $items += @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                Sort-Object -Property @{ Expression = { $_.FullName.Length } } -Descending)
    $items += @(Get-ChildItem -LiteralPath $Path -Recurse -Force -Directory -ErrorAction SilentlyContinue |
                Sort-Object -Property @{ Expression = { $_.FullName.Length } } -Descending)
    $items += @(Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    if ($items.Count -eq 0) { return [PSCustomObject]@{ Queued = 0; AlreadyQueued = 0 } }

    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $existing = (Get-ItemProperty -Path $key -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    # Keep every existing entry verbatim: the value is a flat list of
    # source/destination pairs and an empty destination means "delete".
    $entries = New-Object System.Collections.Generic.List[string]
    if ($null -ne $existing) {
        foreach ($e in @($existing)) { $entries.Add([string]$e) }
    }

    $queued  = 0
    $skipped = 0
    $already = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $entries) { if ($e) { [void]$already.Add([string]$e) } }
    foreach ($item in $items) {
        $full = $item.FullName
        if ($full.StartsWith('\\?\')) { $full = $full.Substring(4) }
        # A path queued by an earlier uninstall that has not rebooted yet must not be
        # queued again -- repeated cycles without a reboot would otherwise keep
        # appending the same 17 entries per profile folder to this value forever.
        if (-not $already.Add('\??\' + $full)) { $skipped++; continue }
        $entries.Add('\??\' + $full)
        $entries.Add('')
        $queued++
    }
    # AlreadyQueued is reported separately so a caller can tell "nothing to do,
    # it is already scheduled" (the repeat-uninstall-without-reboot case) from
    # "this path could not be queued at all".
    if ($queued -eq 0) { return [PSCustomObject]@{ Queued = 0; AlreadyQueued = $skipped } }
    Set-ItemProperty -Path $key -Name PendingFileRenameOperations -Value ([string[]]$entries.ToArray()) -Type MultiString -ErrorAction Stop
    return [PSCustomObject]@{ Queued = $queued; AlreadyQueued = $skipped }
}

# -- 1. Stop any stray processes -----------------------------------------------
Write-Host "[1/8] Stopping processes..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== PHASE 1: Stop stray processes ==="
# Bazarr runs as a Python child process; kill it before NSSM service removal.
# The command line has to come from CIM: System.Diagnostics.Process objects
# (what Get-Process returns under Windows PowerShell 5.1) expose no CommandLine
# property, so a Get-Process filter here silently matched nothing.
$bazarrProcs = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'python%'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*bazarr*" })
Write-DebugLog "VAR bazarr Python processes found: $($bazarrProcs.Count)"
foreach ($bazarrProc in $bazarrProcs) {
    Stop-Process -Id $bazarrProc.ProcessId -Force -ErrorAction SilentlyContinue
}
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
    # Stop Caddy first so the store is quiescent -- an ACME renewal writing into
    # caddy-data/ while the tree is being zipped would corrupt the archive.
    $null = Stop-ServiceBounded -Name "Caddy"
    Write-DebugLog "INFO" "Caddy service stopped for cert cache backup"
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
    Stop-ServiceBounded -Name "DelugeDaemon" | Out-Null
    Stop-ServiceBounded -Name "DelugeWeb"    | Out-Null
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
# Stop everything in one concurrent pass before any service is removed. Doing it
# inside the removal loop meant every wedged service cost its own full timeout.
$AllServices = @(
    "IPBan", "Caddy", "php-cgi", "Sonarr", "Radarr", "Prowlarr", "Bazarr",
    "DelugeDaemon", "DelugeWeb", "Flaresolverr", "Jellyseerr",
    "Grafana", "Loki", "Alloy", "rclone-rd-movies", "rclone-rd", "Zurg"
)
Write-Host "  -> Stopping all services in parallel..." -ForegroundColor Yellow
Stop-ServicesBounded -Names $AllServices
Write-DebugLog "INFO" "Concurrent stop pass complete for: $($AllServices -join ', ')"

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
# rclone is never added to PATH (the mount service points at the absolute path
# under InstallDir), so look there first and only then fall back to PATH --
# otherwise this whole cleanup was skipped on every normal uninstall.
$rclonePath = Join-Path $InstallDir "rclone\rclone.exe"
if (-not (Test-Path $rclonePath)) {
    $rcloneCmd = Get-Command rclone.exe -ErrorAction SilentlyContinue
    $rclonePath = if ($rcloneCmd) { $rcloneCmd.Source } else { $null }
}
Write-DebugLog "VAR rclone executable = $rclonePath"

$rdMountLetter = $null
if ($Config -and $Config.PSObject.Properties['RealDebrid'] -and $Config.RealDebrid -and
    $Config.RealDebrid.PSObject.Properties['MountLetter'] -and $Config.RealDebrid.MountLetter) {
    $rdMountLetter = [string]$Config.RealDebrid.MountLetter
}

if ($rclonePath -and $rdMountLetter) {
    $mountLetter = $rdMountLetter
    $mountPath   = "${mountLetter}:\"
    Write-DebugLog "VAR Checking mount path=$mountPath exists=$(Test-Path $mountPath)"
    if (Test-Path $mountPath) {
        Write-Host "  -> Unmounting rclone drive ${mountLetter}: ..." -ForegroundColor Yellow
        Write-DebugLog "INFO" "Unmounting rclone drive $mountLetter before service removal"
        try {
            & $rclonePath unmount "${mountLetter}:" 2>&1 | Out-Null
            Write-Host "  -> rclone drive ${mountLetter}: unmounted." -ForegroundColor Yellow
            Write-DebugLog "INFO" "rclone unmount ${mountLetter}: succeeded"
        } catch {
            Write-Warning "  -> rclone unmount ${mountLetter}: failed (may need manual unmount after reboot): $_"
            Write-DebugLog "WARN" "rclone unmount ${mountLetter}: failed: $_"
        }
    } else {
        Write-DebugLog "INFO" "No rclone mount at $mountPath; skipping unmount"
    }
} elseif ($rclonePath) {
    Write-DebugLog "INFO" "rclone found but config.json has no RealDebrid.MountLetter; skipping unmount"
} else {
    Write-DebugLog "INFO" "rclone.exe not found (PATH or $InstallDir\rclone); skipping unmount"
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
        $null = Stop-ServiceBounded -Name $csName
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
        # The MSI files are often still mapped by the just-stopped services.
        # Phase 7 (choco uninstall) usually clears them, so warn only then.
        Write-DebugLog "INFO" "CrowdSec program files still present after direct removal; phase 7 will retry"
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
        $null = Stop-ServiceBounded -Name $jfName
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
                    "Seedbox_Status_Collector", "Seedbox_TestSuite", "Seedbox_TestSuiteFull",
                    "Seedbox_SecurityEventExport", "Seedbox_CrowdSecWhitelistRefresh",
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

# Recyclarr keeps its generated config, state and CLI logs under %APPDATA%.
# secrets.yml holds the LIVE Sonarr/Radarr keys in the clear and win-seedbox.yml
# is the generated config that references them, so the whole tree goes: leaving
# the directory behind also left stale state for the next install to trip over.
$RecyclarrAppData = Join-Path $env:APPDATA "recyclarr"
Write-DebugLog "VAR recyclarr appdata=$RecyclarrAppData (exists=$(Test-Path $RecyclarrAppData))"
if (Test-Path $RecyclarrAppData) {
    Remove-Item -Path $RecyclarrAppData -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $RecyclarrAppData) {
        Write-Warning "  -> Could not remove $RecyclarrAppData -- it holds live Sonarr/Radarr API keys."
        Write-DebugLog "WARN" "recyclarr appdata could not be removed"
    } else {
        Write-Host "  -> Removed recyclarr config/state/API keys: $RecyclarrAppData" -ForegroundColor Yellow
        Write-DebugLog "INFO" "Removed recyclarr appdata (generated config, state, live Sonarr/Radarr API keys)"
    }
}

# -- 6. Remove InstallDir contents ---------------------------------------------
# The debug log lives in <InstallDir>\logs, which this phase deletes. Move it
# somewhere durable first, otherwise everything from here on (PATH, choco
# packages, service account) is lost and the uninstall leaves no log at all.
if ($global:SeedboxDebugLogFile) {
    $DebugLogArchiveDir = Join-Path $env:LOCALAPPDATA "win-seedbox\logs"
    $relocated = Move-SeedboxDebugLog -DestinationDir $DebugLogArchiveDir
    if ($relocated) {
        Write-Host "  -> Debug log preserved: $relocated" -ForegroundColor DarkGray
    }
}
Write-Host "[6/8] Removing installation files from $InstallDir..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== PHASE 6: Remove InstallDir contents from $InstallDir ==="
foreach ($sub in @("Caddy", "caddy-data", "Sonarr", "Radarr", "Prowlarr", "Bazarr", "ffmpeg", ".ffmpeg-staging", "Deluge-data", "Flaresolverr", "Jellyseerr", "Grafana", "Grafana-data", "Loki", "Loki-data", "Alloy", "Alloy-data", "Zurg", "rclone", "dashboard", "scripts", "secrets", ".locks", "logs")) {
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
    # Name what survived. This warning is the only thing that reveals a path the
    # explicit removal lists above do not know about -- a whole 'ffmpeg' directory
    # (ffmpeg.exe + ffprobe.exe, ~176 MB) was being left behind, and because only a
    # count was reported it blocked removal of InstallDir without ever saying why.
    $remainingNames = @($remaining | ForEach-Object { $_.Name }) -join ', '
    Write-Warning "  -> Skipping $InstallDir  --  $($remaining.Count) item(s) remain: $remainingNames"
    Write-DebugLog "WARN" "InstallDir not removed; $($remaining.Count) item(s) remain: $remainingNames"
}

# Remove the two Machine PATH entries the installer adds: the ffmpeg directory
# under InstallDir, and the repo root so the 'box' CLI resolves from any directory.
# Left behind they keep PATH pointing at directories that no longer exist.
foreach ($pathEntry in @((Join-Path $InstallDir "ffmpeg"), $PSScriptRoot)) {
    if (Remove-MachinePathEntry -Entry $pathEntry) {
        Write-Host "  -> Removed from Machine PATH: $pathEntry" -ForegroundColor Yellow
        Write-DebugLog "INFO" "Removed Machine PATH entry: $pathEntry"
    } else {
        Write-DebugLog "INFO" "Machine PATH entry absent, nothing to remove: $pathEntry"
    }
}

# -- 7. Remove Chocolatey app packages ----------------------------------------
# Does NOT remove prerequisites: nssm, php, git, vcredist140, python312, chocolatey
# itself. Python stays for the same reason the others do -- Bazarr needs it -- and
# because reinstalling it is the destructive step: `choco install python312`
# performs an InstallAllUsers=1 install, and where a per-user Python 3.12 exists
# the python.org bundle removes it and can leave orphaned MSI state that makes
# every later attempt fail with 1603 / 0x80070643. Repeating that on every
# uninstall cycle is how a working interpreter gets destroyed.
Write-Host "[7/8] Uninstalling Chocolatey app packages..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== PHASE 7: Uninstall Chocolatey packages ==="
# Resolve choco up front (not via $env:Path) so this phase can never abort with
# "The term 'choco' is not recognized" just because this shell predates the
# Chocolatey install.
$ChocoExe = Resolve-ChocoExe
Write-DebugLog "VAR choco.exe resolved to: $(if ($ChocoExe) { $ChocoExe } else { '(not found)' })"
if (-not $ChocoExe) {
    Write-Warning "  -> Chocolatey not found -- skipping app package removal (prerequisites are kept anyway)."
    Write-DebugLog "ERROR" "choco.exe could not be located; skipping phase 7 package removal"
}
foreach ($pkg in @("caddy", "jellyfin", "deluge", "ffmpeg",
                   "crowdsec-windows-firewall-bouncer", "crowdsec", "winfsp")) {
    if (-not $ChocoExe) { break }
    $installed = Get-ChocoInstalledVersion -Package $pkg
    $isInstalled = -not [string]::IsNullOrWhiteSpace($installed)
    Write-DebugLog "VAR choco package '$pkg' installed: $isInstalled (output: $installed)"
    if ($isInstalled) {
        Write-Host "  -> Uninstalling: $pkg..." -ForegroundColor Yellow
        Write-DebugLog "INFO" "Uninstalling choco package: $pkg"
        $uninstall = Invoke-Choco -Arguments @('uninstall', $pkg, '-y', '--no-progress')
        $uninstallTail = $uninstall.Output
        if ($uninstallTail -and $uninstallTail.Length -gt 800) { $uninstallTail = $uninstallTail.Substring($uninstallTail.Length - 800) }
        if ($uninstall.ExitCode -eq 0) {
            Write-Host "  -> $pkg removed." -ForegroundColor Yellow
            Write-DebugLog "INFO" "choco uninstall $($pkg): SUCCESS (exit 0, attempts $($uninstall.Attempts))"
        } else {
            Write-Warning "  -> $pkg uninstall failed (exit $($uninstall.ExitCode))  --  remove manually."
            Write-DebugLog "ERROR" "choco uninstall $($pkg): FAILED (exit $($uninstall.ExitCode), transient=$($uninstall.Transient), attempts=$($uninstall.Attempts)): $uninstallTail"
        }
    }
}

# Phase 2's direct removal can fail while the CrowdSec services are still
# winding down; the MSI removal above normally finishes the job. Warn only if
# the tree survived both attempts.
$csProgDir = "C:\Program Files\CrowdSec"
if (Test-Path $csProgDir) {
    Write-Warning "  -> CrowdSec : $csProgDir still present after package removal  --  remove manually."
    Write-DebugLog "WARN" "CrowdSec program files still present after package removal: $csProgDir"
}

# -- 8. Remove service account -------------------------------------------------
Write-Host "[8/8] Removing service account..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== PHASE 8: Remove service account ==="
$svcUser = "seedbox-svc"
$profileDir = ''
$svcExists = Get-LocalUser -Name $svcUser -ErrorAction SilentlyContinue
Write-DebugLog "VAR $svcUser exists: $($null -ne $svcExists)"
if ($svcExists) {
    # Resolve the SID so we can unload the registry hive and remove ProfileList.
    $svcSid = (New-Object System.Security.Principal.NTAccount($svcUser)).Translate(
                  [System.Security.Principal.SecurityIdentifier]).Value
    Write-DebugLog "VAR SID for $svcUser = $svcSid"

    # Try to unload the registry hives (services are already stopped so they may be
    # free). A still-loaded hive keeps UsrClass.dat open, which is what stops the
    # profile directory from being deleted -- so report the failure instead of
    # hiding it and then blaming a generic "kernel lock" later.
    foreach ($hive in @("HKU\$svcSid", "HKU\${svcSid}_Classes")) {
        $unloaded = $false
        for ($attempt = 1; $attempt -le 3 -and -not $unloaded; $attempt++) {
            $output = & reg unload $hive 2>&1
            if ($LASTEXITCODE -eq 0) {
                $unloaded = $true
            } else {
                Write-DebugLog "VAR reg unload $hive attempt $attempt failed: $($output -join ' ')"
                Start-Sleep -Milliseconds 500
            }
        }
        if ($unloaded) {
            Write-DebugLog "INFO" "Registry hive unloaded: $hive"
        } else {
            Write-DebugLog "WARN" "Registry hive $hive is still loaded and cannot be unloaded until reboot"
        }
    }

    # Remove Win32_UserProfile (profile folder + WMI entry).
    $svcProfile = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
                  Where-Object { $_.LocalPath -like "*$svcUser*" }
    $profileDir = if ($svcProfile) { $svcProfile.LocalPath } else { "C:\Users\$svcUser" }
    Write-DebugLog "VAR $svcUser profile found: $($null -ne $svcProfile) path=$profileDir"
    if ($svcProfile) {
        $svcProfile | Remove-CimInstance -ErrorAction SilentlyContinue
        $stillRegistered = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
                           Where-Object { $_.LocalPath -like "*$svcUser*" }
        if ($stillRegistered) {
            Write-Warning "  -> seedbox-svc profile entry could not be removed from WMI."
            Write-DebugLog "WARN" "Win32_UserProfile entry for $svcUser still present after Remove-CimInstance"
        } else {
            Write-Host "  -> seedbox-svc profile removed ($profileDir)." -ForegroundColor Yellow
            Write-DebugLog "INFO" "WMI profile removed for $svcUser"
        }
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
    Write-DebugLog "VAR profile dir $profileDir exists: $(Test-Path $profileDir)"
    if (Test-Path $profileDir) {
        Remove-Item -Path $profileDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $profileDir) {
        # UsrClass.dat stays mapped by the still-loaded hive until reboot. Queue
        # the tree for deletion before services start rather than telling the
        # operator to clean it up by hand after every uninstall.
        $registration = [PSCustomObject]@{ Queued = 0; AlreadyQueued = 0 }
        try {
            $registration = Register-PathForDeletionAtReboot -Path $profileDir
        } catch {
            Write-DebugLog "ERROR" "Could not queue $profileDir for deletion at reboot: $_"
        }
        if ($registration.Queued -gt 0) {
            Write-Host "  -> $profileDir is locked until reboot; deletion queued for next boot ($($registration.Queued) entries)." -ForegroundColor Yellow
            Write-DebugLog "INFO" "Queued $($registration.Queued) entries under $profileDir for deletion at next boot"
        } elseif ($registration.AlreadyQueued -gt 0) {
            # Repeat uninstall before the pending reboot: the entries are already in
            # PendingFileRenameOperations, so nothing is missing and nothing is done.
            Write-Host "  -> $profileDir is locked until reboot; deletion was already queued by an earlier run." -ForegroundColor Yellow
            Write-DebugLog "INFO" "$profileDir already queued for deletion at next boot ($($registration.AlreadyQueued) entries)"
        } else {
            Write-Warning "  -> $profileDir is locked and could not be queued for deletion  --  remove it manually after reboot."
            Write-DebugLog "WARN" "$profileDir still locked after removal attempt and could not be queued"
        }
    } else {
        Write-Host "  -> seedbox-svc profile folder deleted." -ForegroundColor Yellow
        Write-DebugLog "INFO" "Profile folder deleted: $profileDir"
    }

    Remove-LocalUser -Name $svcUser -ErrorAction SilentlyContinue
    Write-Host "  -> seedbox-svc account removed." -ForegroundColor Yellow
    Write-DebugLog "INFO" "Local user account removed: $svcUser"
}

# Every cycle leaves the previous profile behind: its hive stays mapped until the
# next reboot, so Windows names the next one seedbox-svc.DESKTOP-XXXXXX.000, then
# .001, and so on. Handling only the current profile therefore leaves one dead
# 2.6 MB tree per cycle (measured: five of them after five cycles). Sweep every
# one, including the ones earlier cycles created.
$leftoverProfiles = @(Get-ChildItem -Path 'C:\Users' -Directory -Filter "$svcUser*" -Force -ErrorAction SilentlyContinue |
                      Where-Object { $_.FullName -ne $profileDir -and $_.FullName -ne $env:USERPROFILE })
if ($leftoverProfiles.Count -gt 0) {
    $sweepDeleted = 0
    $sweepQueued  = 0
    foreach ($dir in $leftoverProfiles) {
        if (-not (Test-Path -LiteralPath $dir.FullName)) { continue }
        Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $dir.FullName) {
            try { $sweepQueued += Register-PathForDeletionAtReboot -Path $dir.FullName } catch { }
        } else {
            $sweepDeleted++
        }
    }
    Write-Host "  -> Removed $sweepDeleted stale $svcUser profile folder(s) from earlier cycles$(if ($sweepQueued -gt 0) { "; queued $sweepQueued entries for the remaining locked one(s)" })." -ForegroundColor Yellow
    Write-DebugLog "INFO" "Stale $svcUser profile sweep: deleted=$sweepDeleted queuedEntries=$sweepQueued of $($leftoverProfiles.Count) folder(s)"
}

# -- Done ----------------------------------------------------------------------
Write-DebugLog "INFO" "=== Uninstall complete ==="
Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Uninstall complete." -ForegroundColor Green
Write-Host "  Kept intact:" -ForegroundColor Green
Write-Host "    - Chocolatey, NSSM, vcredist, Python 3.12 (prerequisites)" -ForegroundColor Gray
if ($Config) {
    Write-Host "    - $($Config.Paths.Downloads) (downloads)" -ForegroundColor Gray
    Write-Host "    - $($Config.Paths.Movies) (movies)" -ForegroundColor Gray
    Write-Host "    - $($Config.Paths.TV) (TV)" -ForegroundColor Gray
}
Write-Host "    - Sonarr / Radarr data -> $env:LOCALAPPDATA\win-seedbox\arr-backup (restored on reinstall)" -ForegroundColor Gray
Write-Host "  Run master_install.ps1 to reinstall from scratch." -ForegroundColor Green
if ($global:SeedboxDebugLogFile -and (Test-Path $global:SeedboxDebugLogFile)) {
    Write-Host "  Debug log  : $global:SeedboxDebugLogFile" -ForegroundColor Gray
}
Write-Host "=============================================" -ForegroundColor Green

# Explicit exit code so callers (box.ps1 / box.cmd) get a deterministic 0
# instead of whatever $LASTEXITCODE the last native command left behind.
exit 0
