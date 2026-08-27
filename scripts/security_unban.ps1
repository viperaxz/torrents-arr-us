#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Inspect and clear IP bans. The recovery tool for "I locked myself out".

.DESCRIPTION
    Three independent things on this box can block an inbound IP:

      1. CrowdSec decisions  -> enforced by cs-windows-firewall-bouncer
                                as firewall rules named crowdsec-blocklist*
      2. Abuse blocklists    -> Seedbox-Abuse-Blocklist* firewall rules
                                (Spamhaus DROP + Firehol level-1)
      3. Legacy IPBan rules  -> IPBan_* firewall rules, only on installs that
                                predate the CrowdSec migration

    This script reports all three and can clear them. Run it locally (console,
    RDP from the LAN, or over Tailscale) -- those paths are whitelisted and
    stay reachable even when the public path is blocked.

.PARAMETER Ip
    Unban a single address. Removes its CrowdSec decision and drops it out of
    any abuse-blocklist rule that covers it.

.PARAMETER All
    Clear every CrowdSec decision. Does not touch the abuse blocklists.

.PARAMETER Whitelist
    Permanently whitelist the address: adds it to Security.ExtraWhitelistIps in
    config.json and rewrites the CrowdSec whitelist parser. Use for an IP that
    keeps getting banned, e.g. a static office or VPN exit address.

.EXAMPLE
    .\security_unban.ps1
    Show everything currently blocked.

.EXAMPLE
    .\security_unban.ps1 -Ip 203.0.113.44
    Unban one address.

.EXAMPLE
    .\security_unban.ps1 -Ip 203.0.113.44 -Whitelist
    Unban it and make sure it never gets banned again.

.EXAMPLE
    .\security_unban.ps1 -All
    Clear every active CrowdSec ban.
#>
param(
    [string]$Ip,
    [switch]$All,
    [switch]$Whitelist
)

# "Continue", not "Stop": cscli writes normal progress to stderr, and under PS 5.1 a
# terminating EAP turns that into a NativeCommandError. This is a recovery tool -- it
# must keep working when things are already broken, so errors are handled explicitly.
$ErrorActionPreference = "Continue"

$CsCli      = "C:\Program Files\CrowdSec\cscli.exe"
$ConfigPath = Join-Path (Split-Path $PSScriptRoot -Parent) "config.json"

function Write-Section($text) {
    Write-Host ""
    Write-Host "== $text " -ForegroundColor Cyan -NoNewline
    Write-Host ("=" * [Math]::Max(0, 66 - $text.Length)) -ForegroundColor Cyan
}

# -- Report --------------------------------------------------------------------
Write-Section "CrowdSec decisions"
if (-not (Test-Path $CsCli)) {
    Write-Host "  cscli.exe not found at $CsCli -- CrowdSec is not installed." -ForegroundColor Yellow
} else {
    $csSvc  = Get-Service 'crowdsec' -ErrorAction SilentlyContinue
    $bncSvc = Get-Service 'cs-windows-firewall-bouncer' -ErrorAction SilentlyContinue
    Write-Host ("  engine  : {0}" -f $(if ($csSvc)  { $csSvc.Status }  else { 'not installed' })) -ForegroundColor Gray
    Write-Host ("  bouncer : {0}" -f $(if ($bncSvc) { $bncSvc.Status } else { 'not installed' })) -ForegroundColor Gray

    try {
        $raw = (& $CsCli decisions list -o json 2>$null | Out-String).Trim()
        if ($raw -and $raw -ne 'null') {
            $rows = foreach ($alert in @($raw | ConvertFrom-Json)) {
                foreach ($d in @($alert.decisions)) {
                    [pscustomobject]@{
                        IP       = $d.value
                        Reason   = $d.scenario
                        Duration = $d.duration
                        Origin   = $d.origin
                    }
                }
            }
            if ($rows) { $rows | Format-Table -AutoSize | Out-String | Write-Host }
            else       { Write-Host "  No active decisions." -ForegroundColor Green }
        } else {
            Write-Host "  No active decisions." -ForegroundColor Green
        }
    } catch {
        Write-Host "  Could not query decisions: $_" -ForegroundColor Yellow
    }
}

Write-Section "Firewall block rules"
foreach ($pattern in @("crowdsec-blocklist*", "Seedbox-Abuse-Blocklist*", "IPBan_*")) {
    $rules = @(Get-NetFirewallRule -DisplayName $pattern -ErrorAction SilentlyContinue)
    Write-Host ("  {0,-28} {1} rule(s)" -f $pattern, $rules.Count) -ForegroundColor Gray
}

# -- Actions -------------------------------------------------------------------
if ($All) {
    Write-Section "Clearing all CrowdSec decisions"
    if (Test-Path $CsCli) {
        & $CsCli decisions delete --all
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  All CrowdSec decisions cleared." -ForegroundColor Green
            Write-Host "  The bouncer syncs within ~10s; firewall rules clear themselves." -ForegroundColor DarkGray
        } else {
            Write-Host "  cscli exited $LASTEXITCODE -- decisions may not have cleared." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  CrowdSec not installed -- nothing to clear." -ForegroundColor Yellow
    }
}

if ($Ip) {
    Write-Section "Unbanning $Ip"

    if (Test-Path $CsCli) {
        & $CsCli decisions delete --ip $Ip
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  CrowdSec decision(s) removed for $Ip." -ForegroundColor Green
        } else {
            Write-Host "  cscli exited $LASTEXITCODE for $Ip (may simply not have been banned)." -ForegroundColor DarkGray
        }
    }

    # The abuse blocklists are static reputation lists, not CrowdSec decisions --
    # they need their own removal, and the rule must be rebuilt without the entry.
    $hit = $false
    foreach ($rule in @(Get-NetFirewallRule -DisplayName "Seedbox-Abuse-Blocklist*" -ErrorAction SilentlyContinue)) {
        $filter  = $rule | Get-NetFirewallAddressFilter
        $remotes = @($filter.RemoteAddress)
        $match   = $remotes | Where-Object { $_ -eq $Ip -or $_ -like "$($Ip.Split('.')[0..2] -join '.').*" }
        if ($match) {
            $hit = $true
            Write-Host "  Found in $($rule.DisplayName): $($match -join ', ')" -ForegroundColor Yellow
            $kept = @($remotes | Where-Object { $_ -notin $match })
            if ($kept.Count -gt 0) {
                $rule | Set-NetFirewallRule -RemoteAddress $kept
                Write-Host "  Removed from $($rule.DisplayName) ($($kept.Count) entries remain)." -ForegroundColor Green
            } else {
                $rule | Remove-NetFirewallRule
                Write-Host "  Rule $($rule.DisplayName) was only this entry -- removed." -ForegroundColor Green
            }
        }
    }
    if (-not $hit) {
        Write-Host "  Not present in any abuse blocklist rule." -ForegroundColor DarkGray
    }

    if ($Whitelist) {
        Write-Section "Whitelisting $Ip permanently"
        if (-not (Test-Path $ConfigPath)) {
            Write-Host "  config.json not found at $ConfigPath -- cannot persist." -ForegroundColor Yellow
        } else {
            $cfg = Get-Content -Raw $ConfigPath | ConvertFrom-Json

            if (-not $cfg.PSObject.Properties['Security']) {
                $cfg | Add-Member -NotePropertyName 'Security' -NotePropertyValue ([pscustomobject]@{
                    CrowdSecEnrollKey = ''
                    BanDurationHours  = 4
                    ExtraWhitelistIps = @()
                    AbuseBlocklists   = $true
                })
            }
            if (-not $cfg.Security.PSObject.Properties['ExtraWhitelistIps']) {
                $cfg.Security | Add-Member -NotePropertyName 'ExtraWhitelistIps' -NotePropertyValue @()
            }

            $existing = @($cfg.Security.ExtraWhitelistIps)
            if ($existing -contains $Ip) {
                Write-Host "  $Ip is already in Security.ExtraWhitelistIps." -ForegroundColor DarkGray
            } else {
                $cfg.Security.ExtraWhitelistIps = @($existing + $Ip)
                $json = $cfg | ConvertTo-Json -Depth 100
                [System.IO.File]::WriteAllText($ConfigPath, $json, (New-Object System.Text.UTF8Encoding($false)))
                Write-Host "  Added $Ip to Security.ExtraWhitelistIps in config.json." -ForegroundColor Green
            }

            Write-Host "  Re-run the security installer to apply it to CrowdSec:" -ForegroundColor DarkGray
            Write-Host "    Remove-Item '<InstallDir>\.locks\.security.lock'" -ForegroundColor DarkGray
            Write-Host "    .\scripts\12_security.ps1 -Config (Get-Content .\config.json | ConvertFrom-Json)" -ForegroundColor DarkGray
        }
    }
}

if (-not $Ip -and -not $All) {
    Write-Section "Usage"
    Write-Host "  .\security_unban.ps1 -Ip 1.2.3.4              unban one address"      -ForegroundColor Gray
    Write-Host "  .\security_unban.ps1 -Ip 1.2.3.4 -Whitelist   unban + never ban again" -ForegroundColor Gray
    Write-Host "  .\security_unban.ps1 -All                     clear every ban"         -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Always reachable even when banned: LAN (192.168.x), Tailscale (100.64/10)," -ForegroundColor DarkGray
    Write-Host "  and the local console -- all whitelisted at CrowdSec's enrich stage."       -ForegroundColor DarkGray
}
Write-Host ""
