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

$lines = [System.Collections.Generic.List[string]]::new(
    [string[]](Get-Content -Path $WlFile -Encoding UTF8 -ErrorAction SilentlyContinue))
if ($lines.Count -eq 0) { exit 0 }   # unreadable/corrupt file -- never clobber it

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

    # Parsers are only read at service start -- there is no hot reload for custom
    # parser files on Windows.  Resolve the service the same way 12_security.ps1
    # does (a hardcoded name would make every refresh a silent no-op on a release
    # that renames it) and retry a transient failure, because the next run would
    # otherwise find the file already correct, skip the restart, and leave the
    # engine running with the previous WAN IP whitelisted.
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

    $restarted = $false
    for ($attempt = 1; $attempt -le 3 -and -not $restarted; $attempt++) {
        try {
            Restart-Service -Name $svcName -Force -ErrorAction Stop
            $restarted = $true
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    if (-not $restarted) { exit 1 }   # file is correct; the engine picks it up on its next start
}
exit 0
