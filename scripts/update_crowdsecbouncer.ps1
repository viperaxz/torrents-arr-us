# update_crowdsecbouncer.ps1
# Per-app update script: CrowdSec Windows Firewall bouncer (Chocolatey).
# Health check: the bouncer service Running whenever it was Running before the
# upgrade.  A service that was already Stopped is left Stopped (this script never
# starts one the operator stopped on purpose), and an upgrade that leaves the
# bouncer down is reported FAILED with a non-zero exit code instead of OK -- the
# engine only detects, so a bouncer that is down means nothing gets blocked.
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [Parameter(Mandatory = $true)][string]$BinDir,
    [object]$Config,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "update_common.ps1")
$Config = Initialize-UpdateScript -Config $Config

$AppName     = "CrowdSecBouncer"
$ServiceName = "cs-windows-firewall-bouncer"
# Releases have shipped the bouncer under slightly different service names, so the
# real one is resolved at runtime the way 12_security.ps1 does -- a hardcoded name
# would report a healthy install as FAILED and restart nothing.
$ServiceCandidates = @($ServiceName, "crowdsec-firewall", "firewall-bouncer")

# -- Service state -------------------------------------------------------------
# An upgrade can stop the bouncer, replace its service, or leave it stopped where it
# was running before, so the state the operator had is captured up front and
# restored afterwards.  (Chocolatey offers no downgrade, so the package itself
# cannot be rolled back -- only the service can.)

function Resolve-BouncerService {
    # Returns the bouncer's ServiceController, or $null when there is none.
    param([string[]]$Candidates)
    foreach ($c in $Candidates) {
        $s = Get-Service -Name $c -ErrorAction SilentlyContinue
        if ($s) { return $s }
    }
    foreach ($c in $Candidates) {
        # Fuzzy fallback for a release rename; the engine's "crowdsec" service
        # cannot match these candidates, so no exclusion is needed here.
        $s = Get-Service -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*$c*" -or $_.DisplayName -like "*$c*" } |
            Select-Object -First 1
        if ($s) { return $s }
    }
    return $null
}

function Get-BouncerServiceState {
    # Pre-upgrade snapshot: Running, Stopped, disabled (StartType) or missing.
    param([string[]]$Candidates)
    $svc = Resolve-BouncerService -Candidates $Candidates
    if (-not $svc) {
        return [PSCustomObject]@{
            Name       = ""
            Exists     = $false
            WasRunning = $false
            StatusText = "no service"
            StartType  = ""
        }
    }
    return [PSCustomObject]@{
        Name       = $svc.Name
        Exists     = $true
        WasRunning = ($svc.Status -eq "Running")
        StatusText = "$($svc.Status)"
        StartType  = "$($svc.StartType)"
    }
}

function Start-BouncerServiceAndWait {
    # Starts (or, with -ForceRestart, bounces) the service and returns the last
    # ServiceController seen.  -ForceRestart is what makes a binary upgrade take
    # effect: choco only swaps the file on disk, so the old image stays resident
    # until the service restarts (the same reason update_caddy.ps1 restarts Caddy).
    # The retries and the bounded wait mirror 12_security.ps1's bouncer path, which
    # needs more than one attempt and more time than a plain restart.
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$ForceRestart,
        [int]$Attempts = 3,
        [int]$TimeoutSeconds = 15
    )
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $svc) { return $null }
        if ($svc.Status -eq "Running") {
            # Bounce it once only; a later attempt has already been restarted.
            if (-not $ForceRestart -or $attempt -gt 1) { return $svc }
            Restart-Service -Name $Name -Force -ErrorAction SilentlyContinue
        } elseif ($svc.Status -eq "Stopped") {
            Start-Service -Name $Name -ErrorAction SilentlyContinue
        } else {
            Restart-Service -Name $Name -Force -ErrorAction SilentlyContinue
        }

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq "Running") { return $svc }
            Start-Sleep -Seconds 2
        }
        if ($attempt -lt $Attempts) { Start-Sleep -Seconds 5 }
    }
    return (Get-Service -Name $Name -ErrorAction SilentlyContinue)
}

function Restore-BouncerServiceState {
    # Puts the service back the way the operator had it and describes the outcome.
    # Used on every failure path so a failed upgrade cannot leave enforcement down,
    # and never throws: the caller is already reporting a failure.
    param([Parameter(Mandatory = $true)]$Before)
    if (-not $Before.Exists) { return "no bouncer service existed before the upgrade either" }
    if (-not $Before.WasRunning) { return "$($Before.Name) left $($Before.StatusText) as before the upgrade" }
    try {
        $svc = Start-BouncerServiceAndWait -Name $Before.Name
        if ($svc -and $svc.Status -eq "Running") { return "$($Before.Name) left Running as before the upgrade" }
        return "$($Before.Name) could NOT be restarted -- enforcement is DOWN"
    } catch {
        return "$($Before.Name) could NOT be restarted ($($_.Exception.Message)) -- enforcement is DOWN"
    }
}

$installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $AppName

if ($WhatIf) {
    return [PSCustomObject]@{ App = $AppName; Status = "DRYRUN"; Installed = $installed; Target = $Version; Detail = "choco upgrade crowdsec-windows-firewall-bouncer" }
}
if (-not $installed -or $installed -ieq "unknown") {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "not installed or installed version unknown" }
}

# Remember what the operator had before choco touches anything: an upgrade that
# leaves the bouncer down silently drops enforcement, while an upgrade that
# resurrects a deliberately stopped service makes an unrequested change.
$status = "OK"
$detail = ""
$before = $null

try {
    $before = Get-BouncerServiceState -Candidates $ServiceCandidates
    Write-UcLog "INFO" "bouncer service before upgrade: name='$($before.Name)' status='$($before.StatusText)' startType='$($before.StartType)'"

    $upgradeError = ""
    try {
        Invoke-ChocoUpgrade -Package "crowdsec-windows-firewall-bouncer" -Version $Version
    } catch {
        # A failed upgrade must not leave the operator worse off than before it ran.
        # (Chocolatey offers no downgrade, so only the service state is restored.)
        $upgradeError = "choco upgrade failed: $($_.Exception.Message)"
    }

    if ($upgradeError) {
        $status = "FAILED"
        $detail = "$upgradeError; " + (Restore-BouncerServiceState -Before $before)
    } else {
        $svc = Resolve-BouncerService -Candidates $ServiceCandidates

        if (-not $svc) {
            $status = "FAILED"
            if ($before.Exists) { $detail = "$($before.Name) is gone after the upgrade -- enforcement is DOWN" }
            else { $detail = "no bouncer service before or after the upgrade -- enforcement cannot be verified" }
        } elseif (-not $before.Exists) {
            # The upgrade registered the service: report what it ended up as instead
            # of assuming the package started it.
            if ($svc.Status -eq "Running") {
                $detail = "$($svc.Name) registered by the upgrade and Running"
            } else {
                $status = "FAILED"
                $detail = "$($svc.Name) appeared with the upgrade but is $($svc.Status) -- enforcement is DOWN"
            }
        } elseif ($before.WasRunning) {
            # It was Running before, so it must be Running now, and it has to be
            # restarted for the new binaries to be the ones running.
            $svc = Start-BouncerServiceAndWait -Name $svc.Name -ForceRestart
            if ($svc -and $svc.Status -eq "Running") {
                $detail = "$($svc.Name) restarted and Running"
            } else {
                $status = "FAILED"
                $detail = "$($before.Name) is not Running after the upgrade -- enforcement is DOWN"
            }
        } elseif ($svc.Status -eq "Running") {
            # Stopped before, Running now: the package started it.  Say so rather
            # than silently taking credit for a change nobody asked for.
            $detail = "$($svc.Name) was Stopped before the upgrade and the package left it Running"
        } else {
            # Stopped before: leave it stopped and say so.  Starting a service the
            # operator stopped on purpose would be an unrequested change.
            $detail = "$($svc.Name) left $($svc.Status) as before the upgrade -- enforcement is not active"
        }
    }
} catch {
    # Anything unexpected (service control manager unavailable, a start that times
    # out) must surface as FAILED -- never as a raw error, and never as OK.
    $status = "FAILED"
    $detail = "bouncer update failed: $($_.Exception.Message)"
    if ($before) { $detail += "; " + (Restore-BouncerServiceState -Before $before) }
}

if ($status -eq "OK") {
    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $Version
} else {
    Write-UcLog "ERROR" "CrowdSec bouncer update $status - $detail"
}

$result = [PSCustomObject]@{ App = $AppName; Status = $status; Installed = $installed; Target = $Version; Detail = $detail }
$result

# Reporting OK while the bouncer is down is the bug this guards against, so a
# FAILED status also has to be visible as a non-zero exit code to the caller.
if ($status -eq "OK") { exit 0 }
exit 1
