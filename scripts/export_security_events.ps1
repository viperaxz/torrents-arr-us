# win-seedbox: Export Security event log 4625 events for CrowdSec acquisition.
# Runs every 5 minutes via Seedbox_SecurityEventExport scheduled task.
# Output is one XML Event per line -- CrowdSec file datasource reads line-by-line.
# The seedbox-eventlog-file parser (deployed by 12_security.ps1) extracts
# Channel/EventID/IP from the raw XML on each line.

param(
    [string]$LogDir = ""
)

if (-not $LogDir) {
    $LogDir = if ($env:INSTALL_DIR) { Join-Path $env:INSTALL_DIR "logs" } else { "E:\MediaServer\logs" }
}

$OutFile = Join-Path $LogDir "security-4625.xml"
$TmpFile = Join-Path $LogDir "security-4625.tmp.xml"

# Write to a temp file then atomically replace -- CrowdSec holds a read handle
# on the real file while tailing it, so direct Set-Content would fail.
$events = Get-WinEvent -FilterHashtable @{LogName='Security'; ID=4625} -MaxEvents 50 -ErrorAction SilentlyContinue
if ($events) {
    $events | ForEach-Object {
        # One XML event per line (strip CR/LF so CrowdSec sees one event per line)
        $_.ToXml() -replace '\r?\n', ' '
    } | Set-Content -Path $TmpFile -Encoding UTF8
    Move-Item -Force -Path $TmpFile -Destination $OutFile
}
