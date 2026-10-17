# service_helpers.ps1
# Bounded service stop/start/restart.
#
# Why this exists: nssm-supervised services regularly stay in Stop Pending for far
# longer than the SCM's patience, and Stop-Service / Restart-Service wait on that
# indefinitely. Measured on a healthy machine, a service can take 25-42s to report
# Stopped, and when it does not report at all the caller hangs forever. An install
# observed +146s on one DelugeWeb restart, +85s on Alloy, +72s on Prowlarr and
# +58s on a Prowlarr SQLite stop -- roughly 400s of a 21-minute run.
#
# These helpers send the request with sc.exe (which returns as soon as the request
# is accepted), poll against a deadline, and if the service never reports Stopped,
# terminate the supervising process so the SCM can complete the stop.
#
# Dot-source this file, then call Stop-ServiceBounded / Start-ServiceBounded /
# Restart-ServiceBounded.

function Write-SvcLog {
    # Works whether or not the caller has dot-sourced debug_logger.ps1.
    param([string]$Level, [string]$Message)
    if (Get-Command Write-DebugLog -ErrorAction SilentlyContinue) {
        Write-DebugLog $Level $Message
    }
}

function Get-SvcState {
    param([Parameter(Mandatory = $true)][string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $null }
    $svc.Refresh()
    return $svc
}

function Stop-ServiceTree {
    # Terminates a supervising process AND its descendants.
    #
    # Killing only the nssm supervisor leaves the supervised application running as
    # an orphan: an orphaned Sonarr kept holding port 8989, so every later start of
    # the Sonarr service died with "Failed to bind to address http://[::]:8989:
    # address already in use" and nssm throttled the service to Paused. Anything that
    # kills a supervisor has to take its children with it.
    param([Parameter(Mandatory = $true)][int]$SupervisorPid)

    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$SupervisorPid" -ErrorAction SilentlyContinue)
    foreach ($child in $children) {
        # Depth-first: a child may itself have spawned something.
        Stop-ServiceTree -SupervisorPid $child.ProcessId
        Write-SvcLog "VAR" "terminating child of $SupervisorPid : pid=$($child.ProcessId) name=$($child.Name)"
        $null = Invoke-CimMethod -InputObject $child -MethodName Terminate -ErrorAction SilentlyContinue
    }
    $supervisor = Get-Process -Id $SupervisorPid -ErrorAction SilentlyContinue
    if ($supervisor) {
        Write-SvcLog "VAR" "terminating supervisor pid=$SupervisorPid name=$($supervisor.ProcessName)"
        $null = $supervisor.Kill()
    }
}

function Stop-ServicesBounded {
    # Stops a set of services concurrently and returns nothing. Stopping them one at
    # a time costs the full timeout per service; issuing every request first and then
    # polling the whole set makes that one bounded wait instead of one per service.
    param(
        [string[]]$Names,
        [int]$TimeoutSeconds = 60
    )
    $targets = @()
    foreach ($n in @($Names)) {
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        $svc.Refresh()
        if ($svc.Status -eq 'Stopped') { continue }
        & sc.exe stop $n 2>&1 | Out-Null
        $targets += $svc
    }
    if ($targets.Count -eq 0) { return }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $still = 0
        foreach ($svc in $targets) {
            $svc.Refresh()
            if ($svc.Status -ne 'Stopped') { $still++ }
        }
        if ($still -eq 0) { break }
    }

    $escalated = $false
    foreach ($svc in $targets) {
        $svc.Refresh()
        if ($svc.Status -eq 'Stopped') { continue }
        Write-Warning "  -> $($svc.ServiceName) did not stop within ${TimeoutSeconds}s (status=$($svc.Status)); terminating its process tree."
        Write-SvcLog "WARN" "$($svc.ServiceName) stuck in $($svc.Status) after ${TimeoutSeconds}s; terminating supervisor + children"
        $wmiSvc = Get-CimInstance Win32_Service -Filter "Name='$($svc.ServiceName)'" -ErrorAction SilentlyContinue
        if ($wmiSvc -and $wmiSvc.ProcessId -gt 0) { Stop-ServiceTree -SupervisorPid $wmiSvc.ProcessId }
        $escalated = $true
    }
    if ($escalated) { Start-Sleep -Seconds 5 }
    foreach ($svc in $targets) {
        $svc.Refresh()
        Write-SvcLog "VAR" "$($svc.ServiceName) final status=$($svc.Status)"
    }
}

function Stop-ServiceBounded {
    # Returns $true when the service is Stopped (or does not exist).
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutSeconds = 60
    )
    Stop-ServicesBounded -Names @($Name) -TimeoutSeconds $TimeoutSeconds
    $svc = Get-SvcState -Name $Name
    if (-not $svc) { return $true }
    return ($svc.Status -eq 'Stopped')
}

function Start-ServiceBounded {
    # Returns $true when the service reaches Running. The default bound is generous
    # because some services (Jellyfin, Jellyseerr) do real first-start work.
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutSeconds = 120
    )
    $svc = Get-SvcState -Name $Name
    if (-not $svc) { return $false }
    if ($svc.Status -eq 'Running') { return $true }

    # A service left in Stop Pending cannot be started until the stop completes.
    if ($svc.Status -eq 'StopPending') {
        $null = Stop-ServiceBounded -Name $Name -TimeoutSeconds $TimeoutSeconds
        $svc = Get-SvcState -Name $Name
        if (-not $svc) { return $false }
    }

    Write-SvcLog "INFO" "Starting $Name (status=$($svc.Status), bound=${TimeoutSeconds}s)"
    & sc.exe start $Name 2>&1 | Out-Null

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $svc.Refresh()
        if ($svc.Status -eq 'Running') {
            Write-SvcLog "INFO" "$Name running"
            return $true
        }
    }
    $svc.Refresh()
    Write-Warning "  -> $Name did not reach Running within ${TimeoutSeconds}s (status=$($svc.Status))."
    Write-SvcLog "ERROR" "$Name did not reach Running within ${TimeoutSeconds}s (status=$($svc.Status))"
    return $false
}

function Restart-ServiceBounded {
    # Stop then start. Unlike Restart-Service this works from a stopped service too,
    # which is how several callers were already (incorrectly) using -Force.
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$StopTimeoutSeconds = 60,
        [int]$StartTimeoutSeconds = 90
    )
    $stopped = Stop-ServiceBounded -Name $Name -TimeoutSeconds $StopTimeoutSeconds
    if (-not $stopped) {
        # Force the stop through rather than leaving the caller unable to continue.
        Write-SvcLog "WARN" "$Name could not be stopped cleanly; attempting to start anyway"
    }
    return (Start-ServiceBounded -Name $Name -TimeoutSeconds $StartTimeoutSeconds)
}
