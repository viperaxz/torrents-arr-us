# temp_cleanup_task.ps1 -- registers the recurring temp-cleanup task.
#
# FlareSolverr's bundled Chrome gets a fresh profile per launch under the service
# account's temp directory and never removes it (Prowlarr calls the solver without a
# session, so that is one ~189 MB profile per request).  Measured on a live box: 720
# orphaned profiles = 66.8 GB, which filled C: to 0.49 GB free and then stopped
# Jellyfin -- it refuses to start with less than 2 GiB free on its data volume.
#
# scripts\clean_temp.ps1 is the countermeasure; this file owns the schedule so that
# every path which touches FlareSolverr (fresh install, re-run of the installer on an
# already-installed box, and the binary updater) leaves the task in place.  Callers
# only need to dot-source this file and call Register-TempCleanupTask.

function Write-TempCleanupLog {
    param([string]$Level, [string]$Message)
    if (Get-Command Write-DebugLog -ErrorAction SilentlyContinue) { Write-DebugLog $Level $Message; return }
    if (Get-Command Write-UcLog    -ErrorAction SilentlyContinue) { Write-UcLog    $Level $Message }
}

function Register-TempCleanupTask {
    param(
        [Parameter(Mandatory = $true)][string]$InstallDir,
        # Directory holding clean_temp.ps1 (the project's scripts\ dir).
        [Parameter(Mandatory = $true)][string]$SourceDir,
        # Directory holding config.json, baked into the task's command line.
        [string]$ConfigPath
    )

    $taskName = "Seedbox_TempCleanup"
    $installScripts = Join-Path $InstallDir "scripts"
    if (-not (Test-Path $installScripts)) { New-Item -ItemType Directory -Path $installScripts -Force | Out-Null }

    $cleanSrc = Join-Path $SourceDir "clean_temp.ps1"
    if (-not (Test-Path $cleanSrc)) {
        Write-TempCleanupLog "WARN" "clean_temp.ps1 not found at $cleanSrc -- $taskName not registered"
        return $false
    }

    # The task points at the INSTALL tree, never back into the source checkout: that
    # clone can be moved or deleted, and the task would then die silently.
    $cleanDst = Join-Path $installScripts "clean_temp.ps1"
    Copy-Item -LiteralPath $cleanSrc -Destination $cleanDst -Force

    if (-not $ConfigPath) { $ConfigPath = Join-Path (Split-Path $SourceDir -Parent) "config.json" }

    try {
        $action = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$cleanDst`" -ConfigPath `"$ConfigPath`" -Quiet"
        # Repeat every 6 hours. -StartWhenAvailable means a run missed while the box
        # was off (or during a reboot) fires soon after it comes back, which is what
        # clears anything a dead process was holding open.
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(10) `
            -RepetitionInterval (New-TimeSpan -Hours 6) `
            -RepetitionDuration (New-TimeSpan -Days 3650)
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" `
            -LogonType ServiceAccount -RunLevel Highest
        # IgnoreNew: two cleaners racing over the same links is pointless. The script
        # also takes a lock, so even an overlapping manual run is harmless.
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
            -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $taskName `
            -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force | Out-Null

        $registered = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        # Present is not armed: a Disabled task shows up in every query and never runs.
        if ($registered -and $registered.State -in @('Ready', 'Running')) {
            Write-Host "  -> $taskName registered (every 6h)." -ForegroundColor DarkGray
            Write-TempCleanupLog "INFO" "$taskName registered (state=$($registered.State))"
            return $true
        }
        Write-Warning "  -> $taskName did not register cleanly (state=$($registered.State))."
        Write-TempCleanupLog "ERROR" "$taskName state=$($registered.State)"
        return $false
    } catch {
        Write-Warning "  -> Could not register $taskName : $_"
        Write-TempCleanupLog "ERROR" "$taskName registration failed: $_"
        return $false
    }
}
