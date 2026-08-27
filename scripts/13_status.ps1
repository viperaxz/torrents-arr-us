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

$taskName = "Seedbox_Status_Collector"
$action   = New-ScheduledTaskAction -Execute "powershell.exe" `
              -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$collectScript`""
$trigger  = New-ScheduledTaskTrigger -Once -At (Get-Date) `
              -RepetitionInterval (New-TimeSpan -Minutes 5) `
              -RepetitionDuration (New-TimeSpan -Days 3650)
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable `
               -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" `
               -LogonType ServiceAccount -RunLevel Highest

try {
    Register-ScheduledTask -TaskName $taskName `
        -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null
    Write-Host "  -> Status collector task registered (every 5 min, SYSTEM)." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "Scheduled task '$taskName' registered"
} catch {
    Write-DebugLog "WARN" "Could not register Seedbox_Status_Collector: $_"
    Write-Host "  -> Warning: could not register status task: $_" -ForegroundColor Yellow
}

# Run immediately so the dashboard has data on first load
Write-Host "  -> Running initial status collection..." -ForegroundColor DarkGray
try {
    & powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden `
        -File $collectScript
    $outPath = Join-Path $InstallDir "dashboard\current_status.json"
    if (Test-Path $outPath) {
        Write-Host "  -> current_status.json written." -ForegroundColor Green
        Write-DebugLog "INFO" "Initial status collection complete: $outPath"
    } else {
        Write-DebugLog "WARN" "collect_status.ps1 ran but output file not found: $outPath"
    }
} catch {
    Write-DebugLog "WARN" "Initial status collection failed: $_"
}

[System.IO.File]::WriteAllText($LockFile, "installed", [System.Text.Encoding]::UTF8)
Write-DebugLog "INFO" "13_status.ps1 complete. Lock: $LockFile"
Write-Host "[$AppName] Done." -ForegroundColor Cyan
