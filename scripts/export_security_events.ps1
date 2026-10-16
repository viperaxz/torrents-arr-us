# win-seedbox: Export Security event log 4625 events for CrowdSec acquisition.
# Runs every 5 minutes via Seedbox_SecurityEventExport scheduled task.
# Output is one XML Event per line -- CrowdSec file datasource reads line-by-line.
# The seedbox-eventlog-file parser (deployed by 12_security.ps1) extracts
# Channel/EventID from the raw XML on each line; crowdsecurity/windows-auth
# (s01-parse) then pulls the source IP out of the same raw XML.
#
# The spool is APPEND-ONLY and only new events are written.  CrowdSec tails it
# with ReOpen/Follow enabled, and nxadm/tail re-opens a truncated OR replaced
# file at offset 0 ("Truncated files are always reopened", reopen() seeks to 0).
# Rewriting the spool with the same 50 events every 5 minutes therefore either
# stalls the reader on a stale handle (rename) or re-ingests those events every
# cycle (truncate), repeatedly refilling the windows-bf leaky bucket.  Appending
# is the only write pattern a tail follower sees exactly once.

param(
    [string]$LogDir = ""
)

if (-not $LogDir) {
    $LogDir = if ($env:INSTALL_DIR) { Join-Path $env:INSTALL_DIR "logs" } else { "E:\MediaServer\logs" }
}

$OutFile   = Join-Path $LogDir "security-4625.xml"
$StateFile = Join-Path $LogDir "security-4625.last"    # highest exported EventRecordID
$MaxBytes  = 5MB

if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }

# BOM-free UTF-8: PowerShell's Set-Content -Encoding UTF8 prepends a BOM, which
# would land in the middle of the first XML line and break the parser's
# XMLGet* expressions for that event.
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Highest RecordId already in the spool, so a re-run never duplicates an event.
# RecordId is monotonic per log, which makes it the dedup key.
$lastId = 0
if (Test-Path $StateFile) {
    $state = (Get-Content -Path $StateFile -Raw -ErrorAction SilentlyContinue)
    if ($state -and $state.Trim() -match '^\d+$') { $lastId = [long]$state.Trim() }
} elseif (Test-Path $OutFile) {
    # Watermark lost but the spool survived: recover it from the last line
    # rather than re-exporting events that CrowdSec has already consumed.
    $lastLine = Get-Content -Path $OutFile -Tail 1 -ErrorAction SilentlyContinue
    if ($lastLine -and $lastLine -match '<EventRecordID>(\d+)<') { $lastId = [long]$Matches[1] }
}

$events = @(Get-WinEvent -FilterHashtable @{LogName='Security'; ID=4625} -MaxEvents 50 -ErrorAction SilentlyContinue)
if ($events.Count -eq 0) { exit 0 }

# Security log cleared/rotated -> the counter restarted, so start over instead of
# going blind forever.
$newest = ($events | Measure-Object -Property RecordId -Maximum).Maximum
if ($newest -and $newest -lt $lastId) { $lastId = 0 }

$fresh = @($events | Where-Object { $_.RecordId -gt $lastId } | Sort-Object RecordId)
if ($fresh.Count -eq 0) { exit 0 }

# Empty the spool when it grows past the cap.  Truncating to zero is safe where
# rewriting is not: an empty file has nothing old to re-read, so the follower
# simply resumes on our next append.
if ((Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt $MaxBytes) {
    [System.IO.File]::WriteAllText($OutFile, "", $Utf8NoBom)
}

# One XML event per line (strip CR/LF so CrowdSec sees one event per line).
$lines = @($fresh | ForEach-Object { $_.ToXml() -replace '\r?\n', ' ' }) -join "`r`n"
[System.IO.File]::AppendAllText($OutFile, $lines + "`r`n", $Utf8NoBom)

[System.IO.File]::WriteAllText($StateFile, [string]$fresh[-1].RecordId, $Utf8NoBom)
exit 0
