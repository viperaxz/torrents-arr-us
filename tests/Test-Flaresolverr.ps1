# tests/Test-Flaresolverr.ps1 -- FlareSolverr CAPTCHA bypass test module

param([int]$LayerFilter = 0)

$svc  = 'Flaresolverr'
$port = $Config.Ports.Flaresolverr

if ($Config.Apps.Flaresolverr -ne $true) {
    $Script:Results.Add((New-TestResult $svc 1 'Enabled' 'SKIP' 'Apps.Flaresolverr = false in config'))
    return
}

# -- Layer 1: Health -----------------------------------------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 1) {
    $portOk = Test-TcpPort $port
    $Script:Results.Add((New-TestResult $svc 1 'PortOpen' $(if ($portOk) { 'PASS' } else { 'FAIL' }) "TCP :$port"))

    $health = Invoke-ApiCheck "http://127.0.0.1:$port/" -TimeoutSec 8
    if ($health.ok) {
        $ver = if ($health.data -and $health.data.version) { $health.data.version } else { 'unknown' }
        $Script:Results.Add((New-TestResult $svc 1 'HealthEndpoint' 'PASS' "FlareSolverr $ver" $health.latency_ms))
    } else {
        $Script:Results.Add((New-TestResult $svc 1 'HealthEndpoint' 'FAIL' $health.error $health.latency_ms))
    }

    $nssm = Get-Service 'Flaresolverr' -ErrorAction SilentlyContinue
    $Script:Results.Add((New-TestResult $svc 1 'ServiceRunning' $(if ($nssm -and $nssm.Status -eq 'Running') { 'PASS' } else { 'FAIL' }) "NSSM service state"))

    # FlareSolverr fetches any URL on request and its API has no authentication, so
    # it must never be reachable off-host. It is started with HOST=127.0.0.1.
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        try {
            $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction Stop)
            $exposed   = @($listeners | Where-Object { $_.LocalAddress -ne '127.0.0.1' -and $_.LocalAddress -ne '::1' })
            if ($listeners.Count -gt 0) {
                $Script:Results.Add((New-TestResult $svc 1 'LoopbackOnly' $(if ($exposed.Count -eq 0) { 'PASS' } else { 'FAIL' }) "listening on $(@($listeners | Select-Object -ExpandProperty LocalAddress) -join ',')"))
            }
        } catch {
            $Script:Results.Add((New-TestResult $svc 1 'LoopbackOnly' 'SKIP' "cannot query listeners: $($_.Exception.Message)"))
        }
    }

    # An inbound allow rule for :8191 would expose the headless browser to the
    # network; the installer deliberately leaves none behind.
    try {
        $fwRules = @(Get-NetFirewallRule -DisplayName 'Flaresolverr' -ErrorAction Stop |
                        Where-Object { $_.Action -eq 'Allow' -and $_.Enabled -eq 'True' })
        $Script:Results.Add((New-TestResult $svc 1 'NoFirewallRule' $(if ($fwRules.Count -eq 0) { 'PASS' } else { 'FAIL' }) "$($fwRules.Count) enabled allow rule(s) named Flaresolverr"))
    } catch {
        $Script:Results.Add((New-TestResult $svc 1 'NoFirewallRule' 'SKIP' "cannot query firewall: $($_.Exception.Message)"))
    }
}

# -- Layer 2: Registered in Prowlarr ------------------------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 2) {
    $prowlarrKey  = Get-XmlApiKey 'C:\ProgramData\Prowlarr\config.xml'
    $prowlarrPort = $Config.Ports.Prowlarr
    $pBase        = Get-AppUrlBase 'prowlarr' $Config.General.DomainMode

    if ($prowlarrKey) {
        $proxies = Invoke-ApiCheck "http://127.0.0.1:$prowlarrPort${pBase}/api/v1/indexerproxy" @{'X-Api-Key'=$prowlarrKey} -TimeoutSec 8
        if ($proxies.ok) {
            $fsProxies = @($proxies.data | Where-Object { $_.implementation -match 'FlareSolverr|flaresolverr' })
            $fsReg     = $fsProxies.Count -gt 0
            $Script:Results.Add((New-TestResult $svc 2 'RegisteredInProwlarr' $(if ($fsReg) { 'PASS' } else { 'FAIL' }) "FlareSolverr proxy in Prowlarr indexer proxies"))

            # A proxy without tags is stored but inert: Prowlarr derives
            # IndexerProxyDefinition.Enable from Tags.Any(), and indexers only get a
            # proxy whose tag list intersects their own. This is the failure that
            # left Cloudflare-protected indexers unsearchable.
            if ($fsReg) {
                $proxyTags = @($fsProxies[0].tags)
                $Script:Results.Add((New-TestResult $svc 2 'ProxyTagged' $(if ($proxyTags.Count -gt 0) { 'PASS' } else { 'FAIL' }) "proxy tags=[$($proxyTags -join ',')] (untagged proxies are ignored by Prowlarr)"))

                if ($proxyTags.Count -gt 0) {
                    $idxRaw = Invoke-ApiCheck "http://127.0.0.1:$prowlarrPort${pBase}/api/v1/indexer" @{'X-Api-Key'=$prowlarrKey} -TimeoutSec 8
                    if ($idxRaw.ok) {
                        $linked = @($idxRaw.data | Where-Object { @($_.tags | Where-Object { $proxyTags -contains $_ }).Count -gt 0 })
                        $Script:Results.Add((New-TestResult $svc 2 'IndexersShareTag' $(if ($linked.Count -gt 0) { 'PASS' } else { 'WARN' }) "$($linked.Count) indexer(s) share the FlareSolverr tag; CF-protected indexers bypass FlareSolverr without it"))
                    }
                }
            }
        } else {
            $Script:Results.Add((New-TestResult $svc 2 'RegisteredInProwlarr' 'FAIL' "Prowlarr API error: $($proxies.error)"))
        }
    } else {
        $Script:Results.Add((New-TestResult $svc 2 'RegisteredInProwlarr' 'SKIP' 'Prowlarr config.xml unreadable'))
    }
}
