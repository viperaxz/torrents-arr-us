param(
    [Parameter(Mandatory=$true)]
    [object]$Config
)

. (Join-Path $PSScriptRoot "debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "13_status.ps1 started"

$AppName    = "Status"
$InstallDir = $Config.General.InstallDir
$LockFile   = Join-Path $InstallDir ".locks\.status.lock"

if (Test-Path $LockFile) {
    Write-Host "[$AppName] Already installed. Skipping." -ForegroundColor Green
    Write-DebugLog "INFO" "$AppName already installed (lock file present)"
    return
}

Write-Host "[$AppName] Registering status collector..." -ForegroundColor Cyan
Write-DebugLog "INFO" "=== Registering Status Collector ==="

$collectScript = Join-Path $PSScriptRoot "collect_status.ps1"
Write-DebugLog "VAR collectScript=$collectScript"

# Registering a task that points at a missing script would report success now and
# freeze the dashboard on whatever JSON was written last, so fail before the task
# exists.  exit 1 (not just a warning) so master_install records the failure and
# a later run retries -- the lock file is never written on this path either.
if (-not (Test-Path $collectScript)) {
    Write-Host "  -> ERROR: collect_status.ps1 not found next to 13_status.ps1 ($collectScript)." -ForegroundColor Red
    Write-Host "     Status collector NOT scheduled; the dashboard would never update." -ForegroundColor Yellow
    Write-DebugLog "ERROR" "collect_status.ps1 missing at $collectScript -- task not registered"
    exit 1
}

$taskName = "Seedbox_Status_Collector"
$action   = New-ScheduledTaskAction -Execute "powershell.exe" `
              -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$collectScript`""
$trigger  = New-ScheduledTaskTrigger -Once -At (Get-Date) `
              -RepetitionInterval (New-TimeSpan -Minutes 5) `
              -RepetitionDuration (New-TimeSpan -Days 3650)
# Worst case a fully hung stack costs ~150 s of per-probe timeouts inside
# collect_status.ps1, so a 2-minute execution limit could kill the run before it
# writes current_status.json.  IgnoreNew prevents overlapping runs when a
# collection outlives its 5-minute schedule; the battery flags match the other
# Seedbox_* task registrations.
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable `
               -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
               -MultipleInstances IgnoreNew `
               -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" `
               -LogonType ServiceAccount -RunLevel Highest

$taskOk = $false
try {
    Register-ScheduledTask -TaskName $taskName `
        -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null
    $taskOk = $true
    Write-Host "  -> Status collector task registered (every 5 min, SYSTEM)." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "Scheduled task '$taskName' registered"
} catch {
    # Registration fails when the script is not elevated or the Task Scheduler
    # service is unavailable.  Stay retryable: fall back to a task that might
    # already exist, and leave the lock file unwritten if there is none, so the
    # next run tries again instead of reporting "already installed" forever.
    try { $taskOk = ($null -ne (Get-ScheduledTask -TaskName $taskName -ErrorAction Stop)) } catch { $taskOk = $false }
    Write-DebugLog "WARN" "Could not register Seedbox_Status_Collector: $_"
    Write-Host "  -> Warning: could not register status task: $_" -ForegroundColor Yellow
    if ($taskOk) { Write-Host "  -> Using the existing '$taskName' task." -ForegroundColor DarkGray }
}

# Run immediately so the dashboard has data on first load.  A stale file from a
# previous install must not be reported as a fresh write, so the result is checked
# against the moment the child process started (and against its exit code).
$outPath        = Join-Path $InstallDir "dashboard\current_status.json"
$collectStarted = Get-Date
Write-Host "  -> Running initial status collection..." -ForegroundColor DarkGray
try {
    $global:LASTEXITCODE = 0
    & powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden `
        -File $collectScript
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Write-DebugLog "WARN" "collect_status.ps1 exited with code $LASTEXITCODE"
        Write-Host "  -> Warning: status collection exited with code $LASTEXITCODE." -ForegroundColor Yellow
    }
    if ((Test-Path $outPath) -and ((Get-Item $outPath -ErrorAction SilentlyContinue).LastWriteTime -ge $collectStarted)) {
        Write-Host "  -> current_status.json written." -ForegroundColor Green
        Write-DebugLog "INFO" "Initial status collection complete: $outPath"
    } else {
        Write-Host "  -> Warning: current_status.json was not refreshed (the scheduled task retries in 5 minutes)." -ForegroundColor Yellow
        Write-DebugLog "WARN" "collect_status.ps1 did not refresh $outPath"
    }
} catch {
    Write-DebugLog "WARN" "Initial status collection failed: $_"
}

if ($taskOk) {
    [System.IO.File]::WriteAllText($LockFile, "installed", (New-Object System.Text.UTF8Encoding($false)))
    Write-DebugLog "INFO" "13_status.ps1 complete. Lock: $LockFile"
} else {
    Write-DebugLog "WARN" "Status task not registered -- lock file left unwritten so a later run retries"
    Write-Host "  -> Status collector is NOT scheduled. Re-run this script as administrator." -ForegroundColor Yellow
}
Write-Host "[$AppName] Done." -ForegroundColor Cyan
