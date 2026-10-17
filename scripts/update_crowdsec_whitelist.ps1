#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Keeps the operator's current WAN IP in the CrowdSec whitelist parser.
.DESCRIPTION
    Run by the Seedbox_CrowdSecWhitelistRefresh scheduled task (SYSTEM, every 5
    minutes). Residential lines rotate IPs; the WAN IP whitelisted at install
    time by 12_security.ps1 would otherwise go stale, letting a false positive
    ban lock the operator out of their own box.

    The operator entry carries a "# seedbox-operator-wan-ip" marker inside the
    managed seedbox-whitelist.yaml, so this script can find and replace exactly
    that one entry. CrowdSec is restarted only when the entry actually changes
    (parsers load at service start; there is no hot-reload for custom parser
    files on Windows).

    Idempotent and safe to run when CrowdSec is absent: it exits silently.
.PARAMETER Ip
    Optional explicit IP. When omitted, the public IP is detected via ipify.
    (Provided for testability; the scheduled task always self-detects.)
#>

param([string]$Ip)

$ErrorActionPreference = 'Continue'   # a scheduled-task helper: never crash noisily

$CsConfigDir = 'C:\ProgramData\CrowdSec\config'
$WlFile      = Join-Path $CsConfigDir 'parsers\s02-enrich\seedbox-whitelist.yaml'
$Marker      = 'seedbox-operator-wan-ip'

if (-not (Test-Path $WlFile)) { exit 0 }   # CrowdSec not installed -- nothing to do

if (-not $Ip) {
    try {
        $Ip = (Invoke-RestMethod 'https://api.ipify.org' -UseBasicParsing -TimeoutSec 10).Trim()
    } catch {
        exit 0   # offline or DNS trouble -- retry on the next run
    }
}
if ($Ip -notmatch '^(\d{1,3}\.){3}\d{1,3}$') { exit 0 }   # sanity: IPv4 only

# Materialise the file first. Casting the (possibly $null) Get-Content result
# straight into the List constructor throws ArgumentNullException on an empty or
# unreadable file -- exactly the case the guard below exists for -- and that
# unhandled exception killed the run before it could exit quietly.
$raw = @(Get-Content -Path $WlFile -Encoding UTF8 -ErrorAction SilentlyContinue)
if ($raw.Count -eq 0) { exit 0 }   # unreadable/corrupt/empty file -- never clobber it
$lines = [System.Collections.Generic.List[string]]::new([string[]]$raw)

$changed = $false
$found   = $false
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match "^\s*-\s*'([\d\.]+)'\s*#\s*$Marker") {
        if ($Matches[1] -ne $Ip) {
            $lines[$i] = "    - '$Ip'  # $Marker (auto-refreshed)"
            $changed = $true
        }
        $found = $true
        break
    }
}
if (-not $found) {
    # No marker yet (e.g. install predates this feature). Insert into the ip:
    # list -- i.e. before the 'cidr:' key, never after it (appending at the end
    # would drop the IP into the cidr list, which CrowdSec rejects).
    $insertAt = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*cidr:') { $insertAt = $i; break }
    }
    if ($insertAt -ge 0) { $lines.Insert($insertAt, "    - '$Ip'  # $Marker (auto-refreshed)") }
    else                 { $lines.Add("    - '$Ip'  # $Marker (auto-refreshed)") }
    $changed = $true
}

if ($changed) {
    # BOM-free UTF-8, matching Write-YamlFile / 12_security.ps1.
    [System.IO.File]::WriteAllLines($WlFile, $lines, (New-Object System.Text.UTF8Encoding($false)))
}

# -- Does the engine need a restart? -------------------------------------------
# Parsers are only read at service start -- there is no hot reload for custom
# parser files on Windows.  Resolve the service the same way 12_security.ps1 does
# (a hardcoded name would make every refresh a silent no-op on a release that
# renames it).
$svcName = $null
foreach ($candidate in @('crowdsec', 'CrowdSec')) {
    $s = Get-Service -Name $candidate -ErrorAction SilentlyContinue
    if ($s) { $svcName = $s.Name; break }
}
if (-not $svcName) {
    $s = Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*crowdsec*' -and $_.Name -notlike '*bouncer*' } |
        Select-Object -First 1
    if ($s) { $svcName = $s.Name }
}
if (-not $svcName) { exit 0 }   # engine not installed -- nothing to reload

# "The file changed" is not the only reason to reload.  A previous run can write
# the new IP and then fail every restart attempt; the next run finds the file
# already correct, concludes "nothing changed", and leaves the engine enforcing a
# whitelist from its last start -- i.e. the old WAN IP is still allowed and the
# new one is bannable.  The engine's own start time is the durable evidence: if it
# started before the file was last written, it has not loaded this file.  That
# needs no marker file and keeps an idle run a no-op (engine newer than file).
$needsReload = $changed
if (-not $needsReload) {
    try {
        $procId = (Get-CimInstance -ClassName Win32_Service -Filter "Name='$svcName'" -ErrorAction Stop).ProcessId
        if ($procId) {
            $engineStart = (Get-Process -Id $procId -ErrorAction Stop).StartTime
            $needsReload = ((Get-Item -LiteralPath $WlFile -ErrorAction Stop).LastWriteTime -gt $engineStart)
        }
    } catch {
        $needsReload = $false   # cannot tell -- stay a no-op rather than churn restarts
    }
}
if (-not $needsReload) { exit 0 }

$restarted = $false
for ($attempt = 1; $attempt -le 3 -and -not $restarted; $attempt++) {
    try {
        Restart-Service -Name $svcName -Force -ErrorAction Stop
        $restarted = $true
    } catch {
        Start-Sleep -Seconds 2
    }
}
if (-not $restarted) { exit 1 }   # file is correct; the next run retries the reload
exit 0
