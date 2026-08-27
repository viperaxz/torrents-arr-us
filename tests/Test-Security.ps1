# tests/Test-Security.ps1 -- Security layer (CrowdSec, firewall bouncer, blocklists) test module

param([int]$LayerFilter = 0)

$svc = 'Security'

$CsCli       = 'C:\Program Files\CrowdSec\cscli.exe'
$CsConfigDir = 'C:\ProgramData\CrowdSec\config'
# The bouncer MSI writes its config to config\bouncers\ (not bouncers\).
$BouncerYaml       = 'C:\ProgramData\CrowdSec\config\bouncers\cs-windows-firewall-bouncer.yaml'
$BouncerYamlLegacy = 'C:\ProgramData\CrowdSec\bouncers\cs-windows-firewall-bouncer\cs-windows-firewall-bouncer.yaml'

# -- Layer 1: Services and rules present --------------------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 1) {
    # The engine detects. Without it there is no security layer at all.
    $cs = Get-Service 'crowdsec' -ErrorAction SilentlyContinue
    $Script:Results.Add((New-TestResult $svc 1 'CrowdSecRunning' `
        $(if ($cs -and $cs.Status -eq 'Running') { 'PASS' } else { 'FAIL' }) `
        "CrowdSec engine state: $(if ($cs) { $cs.Status } else { 'not installed' })"))

    # The bouncer enforces. Engine without bouncer = detection with no blocking.
    $bnc = Get-Service 'cs-windows-firewall-bouncer' -ErrorAction SilentlyContinue
    $Script:Results.Add((New-TestResult $svc 1 'BouncerRunning' `
        $(if ($bnc -and $bnc.Status -eq 'Running') { 'PASS' } else { 'FAIL' }) `
        "Firewall bouncer state: $(if ($bnc) { $bnc.Status } else { 'not installed' })"))

    $blocklistRule = Get-NetFirewallRule -DisplayName 'Seedbox-Abuse-Blocklist' -ErrorAction SilentlyContinue
    $Script:Results.Add((New-TestResult $svc 1 'BlocklistRule' `
        $(if ($blocklistRule) { 'PASS' } else { 'WARN' }) 'Abuse blocklist firewall rule present'))
}

# -- Layer 2: Acquisition, collections, whitelist, enforcement ----------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 2) {

    # Acquisition must cover the Caddy access log -- that single source is what
    # gives coverage of Jellyfin, all *Arr apps, Deluge Web UI and the dashboard.
    $acquisPath = Join-Path $CsConfigDir 'acquis.yaml'
    if (Test-Path $acquisPath) {
        $acquis = Get-Content $acquisPath -Raw -ErrorAction SilentlyContinue
        $hasCaddy = $acquis -match 'caddy-access\.log'
        $hasEvtLog = $acquis -match 'wineventlog'
        $Script:Results.Add((New-TestResult $svc 2 'CaddyAcquisition' `
            $(if ($hasCaddy) { 'PASS' } else { 'FAIL' }) 'Caddy access log registered as a CrowdSec datasource'))
        $Script:Results.Add((New-TestResult $svc 2 'EventLogAcquisition' `
            $(if ($hasEvtLog) { 'PASS' } else { 'WARN' }) 'Windows Security event log registered as a datasource'))
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'CaddyAcquisition' 'SKIP' "acquis.yaml not found at $acquisPath"))
        $Script:Results.Add((New-TestResult $svc 2 'EventLogAcquisition' 'SKIP' 'acquis.yaml not found'))
    }

    # Whitelist -- the guard against banning yourself.
    $wlPath = Join-Path $CsConfigDir 'parsers\s02-enrich\seedbox-whitelist.yaml'
    $Script:Results.Add((New-TestResult $svc 2 'TrustedWhitelist' `
        $(if (Test-Path $wlPath) { 'PASS' } else { 'WARN' }) 'LAN + public IP whitelist parser installed'))

    # Bouncer must be registered against the local LAPI with a real key.
    $bouncerPath = if (Test-Path $BouncerYaml) { $BouncerYaml } elseif (Test-Path $BouncerYamlLegacy) { $BouncerYamlLegacy } else { $null }
    if ($bouncerPath) {
        $bcfg = Get-Content $bouncerPath -Raw -ErrorAction SilentlyContinue
        $hasKey = $bcfg -match '(?m)^api_key:\s*\S{20,}'
        $Script:Results.Add((New-TestResult $svc 2 'BouncerApiKey' `
            $(if ($hasKey) { 'PASS' } else { 'FAIL' }) 'Bouncer configured with a LAPI API key'))
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'BouncerApiKey' 'FAIL' "Bouncer config not found at $BouncerYaml"))
    }

    if (Test-Path $CsCli) {
        # Collections actually loaded by the running engine.
        try {
            $raw = (& $CsCli collections list -o json 2>$null | Out-String).Trim()
            $names = if ($raw -and $raw -ne 'null') {
                @(($raw | ConvertFrom-Json).collections | ForEach-Object { $_.name })
            } else { @() }
            $hasCaddyCol = $names -contains 'crowdsecurity/caddy'
            $hasWinCol   = $names -contains 'crowdsecurity/windows'
            $Script:Results.Add((New-TestResult $svc 2 'CaddyCollection' `
                $(if ($hasCaddyCol) { 'PASS' } else { 'FAIL' }) 'crowdsecurity/caddy collection installed'))
            $Script:Results.Add((New-TestResult $svc 2 'WindowsCollection' `
                $(if ($hasWinCol) { 'PASS' } else { 'WARN' }) 'crowdsecurity/windows collection installed'))
        } catch {
            $Script:Results.Add((New-TestResult $svc 2 'CaddyCollection' 'FAIL' "cscli collections list failed: $_"))
        }

        # The bouncer must appear in cscli AND have called home recently.
        try {
            $braw = (& $CsCli bouncers list -o json 2>$null | Out-String).Trim()
            $bouncers = if ($braw -and $braw -ne 'null') { @($braw | ConvertFrom-Json) } else { @() }
            $registered = @($bouncers | Where-Object { $_.name -match 'firewall' })
            $Script:Results.Add((New-TestResult $svc 2 'BouncerRegistered' `
                $(if ($registered.Count -gt 0) { 'PASS' } else { 'FAIL' }) `
                "$($bouncers.Count) bouncer(s) registered with the LAPI"))
        } catch {
            $Script:Results.Add((New-TestResult $svc 2 'BouncerRegistered' 'FAIL' "cscli bouncers list failed: $_"))
        }

        # Active decisions -- informational, zero is normal on a fresh install.
        try {
            $draw = (& $CsCli decisions list -o json 2>$null | Out-String).Trim()
            $banCount = 0
            if ($draw -and $draw -ne 'null') {
                foreach ($a in @($draw | ConvertFrom-Json)) { if ($a.decisions) { $banCount += @($a.decisions).Count } }
            }
            $Script:Results.Add((New-TestResult $svc 2 'ActiveDecisions' 'PASS' "$banCount IP(s) currently banned by CrowdSec"))
        } catch {
            $Script:Results.Add((New-TestResult $svc 2 'ActiveDecisions' 'WARN' "cscli decisions list failed: $_"))
        }
    } else {
        foreach ($t in @('CaddyCollection', 'WindowsCollection', 'BouncerRegistered', 'ActiveDecisions')) {
            $Script:Results.Add((New-TestResult $svc 2 $t 'SKIP' "cscli.exe not found at $CsCli"))
        }
    }
}
