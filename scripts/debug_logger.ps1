# debug_logger.ps1
# Dot-source this file in any seedbox script to get structured debug logging.
#
# Usage (two-arg form  --  explicit level):
#   Write-DebugLog "INFO"  "Phase started: $PhaseName"
#   Write-DebugLog "WARN"  "Service did not start within deadline"
#   Write-DebugLog "ERROR" "Download failed: $_"
#
# Usage (one-arg form  --  DEBUG level implied):
#   Write-DebugLog "VAR AppPort = $AppPort"
#   Write-DebugLog "VAR SvcUser=$SvcUser status=$status"
#
# Controlled by:
#   config.json -> General.DebugLogging = true | false
#
# Log file:   <InstallDir>\logs\seedbox_debug_<timestamp>.log
# Fallback:   <project root>\logs\seedbox_debug_<timestamp>.log
#
# Sensitive values (passwords, tokens) are NEVER logged automatically.
# Scripts must use [REDACTED] when referencing them by name.

function global:Initialize-DebugLog {
    param(
        [Parameter(Mandatory=$true)]
        [object]$Config
    )

    $global:SeedboxDebugEnabled = ($Config.General.DebugLogging -eq $true)
    if (-not $global:SeedboxDebugEnabled) { return }

    # Only create the log file once per session  --  multiple dot-sourced scripts share it
    if ($global:SeedboxDebugLogFile) { return }

    $installDir = $Config.General.InstallDir
    if ($installDir) {
        $logDir = Join-Path $installDir "logs"
    } elseif ($PSScriptRoot) {
        $logDir = Join-Path $PSScriptRoot "..\logs"
    } else {
        $logDir = Join-Path ([System.IO.Path]::GetTempPath()) "seedbox-logs"
    }

    if (-not (Test-Path $logDir)) {
        try { New-Item -Path $logDir -ItemType Directory -Force | Out-Null } catch {}
    }

    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $global:SeedboxDebugLogFile = Join-Path $logDir "seedbox_debug_$stamp.log"

    $sep = "=" * 80
    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $lines = @(
        $sep,
        "[$now] [INFO ] [debug_logger] *** Seedbox debug logging started ***",
        "[$now] [INFO ] [debug_logger] Log file   : $($global:SeedboxDebugLogFile)",
        "[$now] [INFO ] [debug_logger] InstallDir : $installDir",
        "[$now] [INFO ] [debug_logger] DomainMode : $($Config.General.DomainMode)",
        "[$now] [INFO ] [debug_logger] TlsMode    : $($Config.General.TlsMode)",
        "[$now] [INFO ] [debug_logger] AdminUser  : $($Config.General.AdminUsername)",
        $sep
    )
    $lines | ForEach-Object { Add-Content -Path $global:SeedboxDebugLogFile -Value $_ -Encoding UTF8 -ErrorAction SilentlyContinue }

    # If the log file already existed from a previous run (same-second timestamp
    # collision) the Add-Content calls above would have appended on top of stale
    # data.  Read the whole file back, keep only the lines from THIS session
    # (starting with the "*** started ***" marker), and re-write.
    try {
        $allLines = Get-Content -Path $global:SeedboxDebugLogFile -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($allLines -and $allLines.Count -gt 0) {
            $firstOurLine = $allLines | Select-String -Pattern '\*\*\* Seedbox debug logging started \*\*\*' -SimpleMatch | Select-Object -First 1
            if ($firstOurLine -and $firstOurLine.LineNumber -gt 1) {
                $cleanLines = $allLines[($firstOurLine.LineNumber - 1)..($allLines.Count - 1)]
                [System.IO.File]::WriteAllText($global:SeedboxDebugLogFile,
                    ($cleanLines -join "`r`n") + "`r`n",
                    [System.Text.Encoding]::UTF8)
                Write-DebugLog "INFO" "[debug_logger] Cleared $($firstOurLine.LineNumber - 1) stale line(s) from previous session"
            }
        }
    } catch {
        # Best-effort cleanup; if it fails the log is just a bit larger.
    }
    Write-Host "[$now] [INFO ] [debug_logger] Debug logging ENABLED -> $($global:SeedboxDebugLogFile)" -ForegroundColor DarkCyan
}

function global:Write-DebugLog {
    # Accepts two calling conventions:
    #   1. Write-DebugLog "LEVEL" "message text"    --  explicit level (INFO/WARN/ERROR/VAR/DEBUG)
    #   2. Write-DebugLog "message text"             --  implicit DEBUG level
    param(
        [Parameter(Position=0, Mandatory=$true)]
        [string]$LevelOrMessage,
        [Parameter(Position=1)]
        [string]$Message = ""
    )

    if (-not $global:SeedboxDebugEnabled) { return }

    # Route to level + message
    if ($Message -ne "") {
        # Two-arg call: first arg is the level, second is the message
        $Level = $LevelOrMessage.ToUpper()
        $msg   = $Message
    } else {
        # One-arg call: entire string is the message, level defaults to DEBUG
        $Level = "DEBUG"
        $msg   = $LevelOrMessage
    }

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"

    # Walk the call stack to find the first frame with a real script file name
    $callerName = "?"
    try {
        $stack = Get-PSCallStack
        for ($i = 1; $i -lt $stack.Count; $i++) {
            if ($stack[$i].ScriptName) {
                $callerName = [System.IO.Path]::GetFileNameWithoutExtension($stack[$i].ScriptName)
                break
            }
        }
    } catch {}

    $lvlPad = $Level.PadRight(5)
    $line   = "[$ts] [$lvlPad] [$callerName] $msg"

    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "INFO"  { "Cyan" }
        default { "DarkGray" }
    }
    Write-Host $line -ForegroundColor $color

    if ($global:SeedboxDebugLogFile) {
        Add-Content -Path $global:SeedboxDebugLogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}
