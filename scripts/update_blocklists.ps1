#Requires -RunAsAdministrator
# Fetches Spamhaus DROP/EDROP and Firehol level-1, applies as Windows Firewall block rules.
# Safe to re-run: removes old Seedbox-Abuse-Blocklist* rules before recreating them.

# NOTE: deliberately NOT SilentlyContinue at script scope. A blanket suppression
# here hid firewall-rule creation failures, so the script reported success while
# applying nothing. Each fallible call now handles its own errors explicitly.
$ErrorActionPreference = "Stop"

# Spamhaus EDROP was merged into DROP; the old edrop.txt endpoint still answers
# HTTP 200 with a deprecation stub, so fetching it yields 0 CIDRs without erroring.
$sources = @(
    "https://www.spamhaus.org/drop/drop.txt",
    "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level1.netset"
)

$cidrs = [System.Collections.Generic.List[string]]::new()
$failedSources = 0
foreach ($url in $sources) {
    try {
        $content = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop).Content
        $lines   = $content -split "`n" | Where-Object { $_ -match "^\d" }
        $before  = $cidrs.Count
        foreach ($line in $lines) {
            $cidr = ($line -split "[\s;#]")[0].Trim()
            if ($cidr -match "^\d+\.\d+\.\d+\.\d+(/\d+)?$") { $cidrs.Add($cidr) | Out-Null }
        }
        $got = $cidrs.Count - $before
        # A source that answers 200 but parses to nothing is a silent retirement,
        # not a success -- surface it rather than letting the total quietly shrink.
        if ($got -eq 0) {
            Write-Host "  [Blocklist] WARNING: $url returned no usable CIDRs (retired or format changed)." -ForegroundColor Yellow
            $failedSources++
        } else {
            Write-Host "  [Blocklist] $got CIDRs from $url" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  [Blocklist] Source unavailable: $url ($($_.Exception.Message))" -ForegroundColor Yellow
        $failedSources++
    }
}

# Deduplicate
$unique = @($cidrs | Select-Object -Unique)

# Strip non-routable space. firehol_level1 intentionally ships RFC1918, loopback,
# CGNAT and link-local because it targets edge routers, where a private source
# address is bogus. On a host these entries block the local LAN (and Tailscale's
# 100.64/10), which silently kills SMB, discovery and anything else on-link.
$bogons = @(
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
    "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.168.0.0/16",
    "198.18.0.0/15", "224.0.0.0/4", "240.0.0.0/4"
)

function Get-CidrRange([string]$cidr) {
    $parts = $cidr -split "/"
    try { $ip = [System.Net.IPAddress]::Parse($parts[0]) } catch { return $null }
    if ($ip.AddressFamily -ne "InterNetwork") { return $null }
    $bytes = $ip.GetAddressBytes(); [Array]::Reverse($bytes)
    $base  = [uint64][System.BitConverter]::ToUInt32($bytes, 0)
    $len   = if ($parts.Count -gt 1) { [int]$parts[1] } else { 32 }
    if ($len -lt 0 -or $len -gt 32) { return $null }
    $size  = [uint64][math]::Pow(2, 32 - $len)
    return @{ Start = $base; End = $base + $size - 1 }
}

$bogonRanges = @()
foreach ($b in $bogons) {
    $r = Get-CidrRange $b
    if ($r) { $bogonRanges += $r }
}

# Anti-lockout: never block this machine's own public IP or any address bound to
# a local interface. Residential IPs do land in these lists (previous tenant of a
# dynamic lease, a compromised neighbour in the same /24), and a blocklist that
# contains your own WAN address kills inbound access to the whole seedbox.
$selfAddrs = [System.Collections.Generic.List[string]]::new()
try {
    $selfPublic = (Invoke-WebRequest -Uri "https://api.ipify.org" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop).Content.Trim()
    if ($selfPublic -match "^\d+\.\d+\.\d+\.\d+$") { $selfAddrs.Add($selfPublic) }
} catch {
    Write-Host "  [Blocklist] Could not detect public IP -- self-exclusion limited to local addresses." -ForegroundColor Yellow
}
try {
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -and $_.IPAddress -ne "127.0.0.1" } |
        ForEach-Object { if (-not $selfAddrs.Contains($_.IPAddress)) { $selfAddrs.Add($_.IPAddress) } }
} catch { }

$selfRanges = @()
foreach ($s in $selfAddrs) {
    $r = Get-CidrRange $s
    if ($r) { $selfRanges += $r }
}
if ($selfAddrs.Count -gt 0) {
    Write-Host "  [Blocklist] Self-exclusion active for: $($selfAddrs -join ', ')" -ForegroundColor DarkGray
}

$routable   = @()
$dropped    = 0
$selfSkipped = 0
$invalid    = 0
foreach ($c in $unique) {
    $r = Get-CidrRange $c
    if (-not $r) { $invalid++; continue }

    $isBogon = $false
    foreach ($b in $bogonRanges) {
        if ($r.Start -le $b.End -and $r.End -ge $b.Start) { $isBogon = $true; break }
    }
    if ($isBogon) { $dropped++; continue }

    # Drop any range that would cover one of our own addresses.
    $isSelf = $false
    foreach ($s in $selfRanges) {
        if ($r.Start -le $s.End -and $r.End -ge $s.Start) { $isSelf = $true; break }
    }
    if ($isSelf) { $selfSkipped++; continue }

    $routable += $c
}
$unique = @($routable)

if ($invalid -gt 0) {
    Write-Host "  [Blocklist] Skipped $invalid invalid range(s) (unparseable IP or CIDR)." -ForegroundColor Yellow
}
if ($dropped -gt 0) {
    Write-Host "  [Blocklist] Skipped $dropped non-routable range(s) (RFC1918/loopback/CGNAT/link-local)." -ForegroundColor DarkGray
}
if ($selfSkipped -gt 0) {
    Write-Host "  [Blocklist] Skipped $selfSkipped range(s) covering this host's own address -- self-lockout prevented." -ForegroundColor Yellow
}

# Bail out BEFORE removing the existing rules. Otherwise a transient network
# failure would tear down working protection and replace it with nothing.
if ($unique.Count -eq 0) {
    Write-Host "  [Blocklist] No CIDRs loaded -- sources unavailable. Existing rules left untouched." -ForegroundColor Yellow
    exit 1
}

# Remove old rules
Get-NetFirewallRule -DisplayName "Seedbox-Abuse-Blocklist*" -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue

$maxPerRule = 5000
$batch      = 0
$applied    = 0
$ruleErrors = 0
for ($i = 0; $i -lt $unique.Count; $i += $maxPerRule) {
    $end   = [Math]::Min($i + $maxPerRule, $unique.Count) - 1
    $name  = if ($unique.Count -le $maxPerRule) { "Seedbox-Abuse-Blocklist" } else { "Seedbox-Abuse-Blocklist-$batch" }
    $slice = $unique[$i..$end]
    try {
        New-NetFirewallRule -DisplayName $name `
            -Direction Inbound -Action Block `
            -RemoteAddress $slice `
            -Protocol Any -Profile Any -Enabled True -ErrorAction Stop | Out-Null
        $applied += $slice.Count
    } catch {
        Write-Host "  [Blocklist] FAILED to create rule '$name': $($_.Exception.Message)" -ForegroundColor Red
        $ruleErrors++
    }
    $batch++
}

# Verify against the firewall itself rather than trusting the loop above.
$live = @(Get-NetFirewallRule -DisplayName "Seedbox-Abuse-Blocklist*" -ErrorAction SilentlyContinue)
if ($live.Count -eq 0) {
    Write-Host "  [Blocklist] ERROR: no blocklist rule present after update -- traffic is NOT filtered." -ForegroundColor Red
    exit 1
}

# -- Persist state for the status dashboard ------------------------------------
# The dashboard Security card reads this file (via collect_status.ps1) to show
# which lists are applied, how many CIDRs, and when they were last refreshed.
try {
    $cfgPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'config.json'
    if (Test-Path $cfgPath) {
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        if ($cfg.General -and $cfg.General.InstallDir) {
            $dashDir = Join-Path $cfg.General.InstallDir 'dashboard'
            if (-not (Test-Path $dashDir)) { New-Item -Path $dashDir -ItemType Directory -Force | Out-Null }
            $blState = [ordered]@{
                sources        = 'Spamhaus DROP + Firehol level-1'
                cidr_count     = $applied
                rule_count     = $live.Count
                failed_sources = $failedSources
                updated        = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
            }
            [System.IO.File]::WriteAllText(
                (Join-Path $dashDir 'blocklist_state.json'),
                ($blState | ConvertTo-Json),
                (New-Object System.Text.UTF8Encoding($false)))
            Write-Host "  [Blocklist] Dashboard state written (sources + counts)." -ForegroundColor DarkGray
        }
    }
} catch {
    Write-Host "  [Blocklist] Could not write dashboard state: $($_.Exception.Message)" -ForegroundColor Yellow
}

$srcNote = if ($failedSources -gt 0) { " ($failedSources source(s) unavailable)" } else { "" }
Write-Host "  [Blocklist] $applied abuse CIDRs blocked across $($live.Count) rule(s) (Spamhaus DROP + Firehol level-1)$srcNote." -ForegroundColor Green
if ($ruleErrors -gt 0) { exit 1 }
