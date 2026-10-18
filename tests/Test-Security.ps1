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

    # Wildcard: with more than 5000 unique CIDRs the rules are split and named
    # Seedbox-Abuse-Blocklist-0/1/..., i.e. the bare name does not exist. The
    # current deduped list (~4.8k) fits in one rule, so an exact-name lookup
    # silently starts failing the moment the lists grow.
    $blocklistRule = Get-NetFirewallRule -DisplayName 'Seedbox-Abuse-Blocklist*' -ErrorAction SilentlyContinue
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
        $hasCaddy = $acquis -match 'caddy-access(-relay)?\.log'
        $hasEvtLog = $acquis -match 'security-4625\.xml'
        $Script:Results.Add((New-TestResult $svc 2 'CaddyAcquisition' `
            $(if ($hasCaddy) { 'PASS' } else { 'FAIL' }) 'Caddy access log registered as a CrowdSec datasource'))
        $Script:Results.Add((New-TestResult $svc 2 'EventLogAcquisition' `
            $(if ($hasEvtLog) { 'PASS' } else { 'WARN' }) 'Windows Security event log registered as a datasource'))
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'CaddyAcquisition' 'SKIP' "acquis.yaml not found at $acquisPath"))
        $Script:Results.Add((New-TestResult $svc 2 'EventLogAcquisition' 'SKIP' 'acquis.yaml not found'))
    }

    # Configured is not the same as consuming. The Caddy access log is the only
    # source covering HTTP (every proxied app sits behind it), and a file tail can
    # start cleanly ("Adding file ... to datasources") and then never read a line,
    # in which case HTTP attacks are invisible while acquis.yaml, the collection and
    # the parsers all look correct. If the log has been written since the engine
    # started but cscli reports zero reads for it, that source is dead.
    $caddyLogPath = $null
    if ($acquis) {
        $mCaddy = [regex]::Match($acquis, "-\s*'([^']*caddy-access(?:-relay)?\.log)'")
        if ($mCaddy.Success) { $caddyLogPath = $mCaddy.Groups[1].Value }
    }
    if (-not $caddyLogPath -or -not (Test-Path -LiteralPath $caddyLogPath) -or -not (Test-Path $CsCli)) {
        $Script:Results.Add((New-TestResult $svc 2 'CaddyDatasourceLive' 'SKIP' 'Caddy access log or cscli not available'))
    } else {
        $csReads    = -1
        $engineStart = $null
        try {
            $metrics = ((& $CsCli metrics -o json 2>$null | Out-String) | ConvertFrom-Json)
            $mKey    = "file:$caddyLogPath"
            if ($metrics.acquisition -and $metrics.acquisition.PSObject.Properties[$mKey]) {
                $csReads = [int]$metrics.acquisition.$mKey.reads
            } else {
                $csReads = 0
            }
        } catch { $csReads = -1 }
        try {
            $csSvcObj = Get-Service 'crowdsec' -ErrorAction SilentlyContinue
            if ($csSvcObj) {
                $csProcId = (Get-CimInstance -ClassName Win32_Service -Filter "Name='$($csSvcObj.Name)'" -ErrorAction Stop).ProcessId
                if ($csProcId) { $engineStart = (Get-Process -Id $csProcId -ErrorAction Stop).StartTime }
            }
        } catch { $engineStart = $null }
        $caddyWritten = (Get-Item -LiteralPath $caddyLogPath).LastWriteTime
        # The engine anchors the tail at EOF on startup, so lines written before it
        # started are deliberately skipped. Judging "log newer than the engine" with
        # no margin turned a sub-second ordering into a false FAIL immediately after
        # the post-install restart. Only call it dead once the file has been written
        # well past the engine's start and CrowdSec still has not read anything.
        $missedTraffic = ($engineStart -and $caddyWritten -gt $engineStart.AddSeconds(60) -and $csReads -eq 0)
        if ($csReads -lt 0) {
            $Script:Results.Add((New-TestResult $svc 2 'CaddyDatasourceLive' 'WARN' 'cscli metrics could not be read'))
        } elseif ($missedTraffic) {
            $Script:Results.Add((New-TestResult $svc 2 'CaddyDatasourceLive' 'FAIL' `
                "Caddy log written $($caddyWritten.ToString('HH:mm:ss')) (engine started $($engineStart.ToString('HH:mm:ss'))) but CrowdSec read 0 lines -- the tail is stuck, HTTP detection is dead"))
        } elseif ($csReads -eq 0) {
            $Script:Results.Add((New-TestResult $svc 2 'CaddyDatasourceLive' 'WARN' `
                'No Caddy lines consumed yet (no matching HTTP traffic since the engine started)'))
        } else {
            $Script:Results.Add((New-TestResult $svc 2 'CaddyDatasourceLive' 'PASS' "$csReads line(s) consumed from the Caddy access log"))
        }
    }

    # Whitelist -- the guard against banning yourself.
    $wlPath = Join-Path $CsConfigDir 'parsers\s02-enrich\seedbox-whitelist.yaml'
    $Script:Results.Add((New-TestResult $svc 2 'TrustedWhitelist' `
        $(if (Test-Path $wlPath) { 'PASS' } else { 'WARN' }) 'LAN + public IP whitelist parser installed'))

    # Operator-IP auto-refresh -- keeps the WAN IP entry current on dynamic IPs
    # (DuckDNS lines rotate), so a stale whitelist can never lock the operator out.
    # Present-but-Disabled is not armed: the task shows up in every query and never
    # runs, which is exactly how the missing tasks went unnoticed for a whole cycle.
    $wlTask = Get-ScheduledTask -TaskName 'Seedbox_CrowdSecWhitelistRefresh' -ErrorAction SilentlyContinue
    $wlArmed = [bool]($wlTask -and ($wlTask.State -in @('Ready', 'Running')))
    $Script:Results.Add((New-TestResult $svc 2 'WhitelistRefreshTask' `
        $(if ($wlArmed) { 'PASS' } else { 'WARN' }) `
        "Scheduled task keeps the operator WAN IP whitelisted (state: $(if ($wlTask) { $wlTask.State } else { 'not registered' }))"))
    $wlContent = if (Test-Path $wlPath) { Get-Content $wlPath -Raw -ErrorAction SilentlyContinue } else { '' }
    $Script:Results.Add((New-TestResult $svc 2 'WhitelistOperatorMarker' `
        $(if ($wlContent -match 'seedbox-operator-wan-ip') { 'PASS' } else { 'WARN' }) 'Operator WAN IP entry marked for auto-refresh'))

    # Event-log export task: without it security-4625.xml never grows and the windows
    # collection sees nothing, while acquis.yaml still looks perfectly configured.
    $evtTask = Get-ScheduledTask -TaskName 'Seedbox_SecurityEventExport' -ErrorAction SilentlyContinue
    $evtArmed = [bool]($evtTask -and ($evtTask.State -in @('Ready', 'Running')))
    $Script:Results.Add((New-TestResult $svc 2 'EventExportTask' `
        $(if ($evtArmed) { 'PASS' } else { 'WARN' }) `
        "4625 export task registered (state: $(if ($evtTask) { $evtTask.State } else { 'not registered' }))"))

    # 6-hourly blocklist refresh. A missing task is WARN, not FAIL: the blocklists
    # may be deliberately disabled via Security.AbuseBlocklists.
    $blTask = Get-ScheduledTask -TaskName 'Seedbox_Blocklist_Update' -ErrorAction SilentlyContinue
    $blArmed = [bool]($blTask -and ($blTask.State -in @('Ready', 'Running')))
    $Script:Results.Add((New-TestResult $svc 2 'BlocklistTask' `
        $(if ($blArmed) { 'PASS' } else { 'WARN' }) `
        "Blocklist refresh task registered (state: $(if ($blTask) { $blTask.State } else { 'not registered' }))"))

    # Every task helper must live in the install tree. A task pointing back at the
    # source clone keeps working until that clone is moved or deleted, and then
    # fails forever with nothing left in the install tree to run by hand.
    # Seedbox_CaddyLogRelay is included because a dead relay silently stops all
    # HTTP attack detection: acquis.yaml stays valid, the engine looks healthy.
    $relayTask = Get-ScheduledTask -TaskName 'Seedbox_CaddyLogRelay' -ErrorAction SilentlyContinue
    $relayArmed = [bool]($relayTask -and ($relayTask.State -in @('Ready', 'Running')))
    $Script:Results.Add((New-TestResult $svc 2 'CaddyLogRelayTask' `
        $(if ($relayArmed) { 'PASS' } else { 'FAIL' }) `
        "Caddy log relay task armed (state: $(if ($relayTask) { $relayTask.State } else { 'not registered' }))"))

    $taskScripts = @()
    foreach ($t in @($evtTask, $wlTask, $blTask, $relayTask)) {
        if (-not $t) { continue }
        $taskArgs = ($t.Actions | ForEach-Object { $_.Arguments }) -join ' '
        $m = [regex]::Match($taskArgs, '-File\s+"?([^"]+\.ps1)"?')
        if ($m.Success) { $taskScripts += [pscustomobject]@{ Task = $t.TaskName; Path = $m.Groups[1].Value } }
    }
    $missingScripts = @($taskScripts | Where-Object { -not (Test-Path -LiteralPath $_.Path) })
    $Script:Results.Add((New-TestResult $svc 2 'TaskScriptsPresent' `
        $(if ($missingScripts.Count -gt 0) { 'FAIL' } elseif ($taskScripts.Count -gt 0) { 'PASS' } else { 'SKIP' }) `
        $(if ($missingScripts.Count -gt 0) { "Missing: $($missingScripts.Path -join '; ')" } else { "$($taskScripts.Count) scheduled-task script(s) present on disk" })))

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
        # Collections actually loaded by the running engine. The JSON shape of
        # `cscli collections list -o json` differs between releases (array of
        # {name=...} items, or an object keyed by item name), so accept either
        # instead of silently reporting FAIL on the other one.
        try {
            $raw = (& $CsCli collections list -o json 2>$null | Out-String).Trim()
            $names = @()
            if ($raw -and $raw -ne 'null') {
                $parsed = $raw | ConvertFrom-Json
                # `cscli collections list -o json` has been seen wrapped in a
                # {collections:{...}} object and as a bare array of items.
                $nodes = if ($parsed.PSObject.Properties['collections']) { @($parsed.collections) } else { @($parsed) }
                foreach ($node in $nodes) {
                    foreach ($p in @($node.PSObject.Properties)) {
                        if ($p.Name -eq 'name' -and $p.Value) { $names += [string]$p.Value }
                        elseif ($p.Name -match '/')          { $names += [string]$p.Name }
                    }
                }
            }
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
        # Deliberately the local list only: the Community Blocklist (origin CAPI) is
        # thousands of entries and is counted by security_unban.ps1 instead.  Say
        # "locally-sourced" so a healthy but quiet box does not read as "nothing is
        # blocked" while the bouncer enforces the central list.
        try {
            $draw = (& $CsCli decisions list -o json 2>$null | Out-String).Trim()
            $banCount = 0
            if ($draw -and $draw -ne 'null' -and $draw -ne '[]') {
                foreach ($a in @($draw | ConvertFrom-Json)) { if ($a.decisions) { $banCount += @($a.decisions).Count } }
            }
            $Script:Results.Add((New-TestResult $svc 2 'ActiveDecisions' 'PASS' `
                "$banCount locally-sourced ban(s); Community Blocklist decisions not counted here"))
        } catch {
            $Script:Results.Add((New-TestResult $svc 2 'ActiveDecisions' 'WARN' "cscli decisions list failed: $_"))
        }
    } else {
        foreach ($t in @('CaddyCollection', 'WindowsCollection', 'BouncerRegistered', 'ActiveDecisions')) {
            $Script:Results.Add((New-TestResult $svc 2 $t 'SKIP' "cscli.exe not found at $CsCli"))
        }
    }
}
