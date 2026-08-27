# tests/Test-Update.ps1 -- update system test module
# Dot-sourced by test-suite.ps1; expects $Config, $InstallDir already set.
# Verifies the manifest, the local version ledger, per-app update script
# coverage, and that the shared update plan builds without errors.

param([int]$LayerFilter = 0)

$svc         = 'Update'
$ProjectRoot = Join-Path $PSScriptRoot '..'

# -- Layer 1: Static integrity (local files) ----------------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 1) {
    $manifestPath = Join-Path $ProjectRoot 'versions.json'

    $manifestOk  = $false
    $manifestMsg = ''
    if (Test-Path $manifestPath) {
        try {
            $m = Get-Content -Raw $manifestPath | ConvertFrom-Json
            if ($m.schema -ge 2 -and $m.apps) { $manifestOk = $true }
            else { $manifestMsg = "manifest schema $($m.schema) too old (expected >= 2)" }
        } catch { $manifestMsg = $_.Exception.Message }
    } else { $manifestMsg = 'versions.json missing' }
    $Script:Results.Add((New-TestResult $svc 1 'ManifestSchema' $(if ($manifestOk) { 'PASS' } else { 'FAIL' }) $manifestMsg))

    $ledgerPath = Join-Path $InstallDir '.locks\installed_versions.json'
    $ledgerOk   = $true
    $ledgerMsg  = 'ledger present and parseable'
    if (-not (Test-Path $ledgerPath)) {
        $ledgerOk  = $false
        $ledgerMsg = 'ledger not created yet (populated on install/update)'
    } else {
        try { $null = Get-Content -Raw $ledgerPath | ConvertFrom-Json }
        catch { $ledgerOk = $false; $ledgerMsg = $_.Exception.Message }
    }
    $Script:Results.Add((New-TestResult $svc 1 'LedgerParseable' $(if ($ledgerOk) { 'PASS' } else { 'WARN' }) $ledgerMsg))

    # Every manifest app must have an update script, except known-manual apps.
    $scriptsDir = Join-Path $ProjectRoot 'scripts'
    $missing    = [System.Collections.Generic.List[string]]::new()
    $manualApps = @('NSSM', 'Python312')
    try {
        $m = Get-Content -Raw $manifestPath | ConvertFrom-Json
        foreach ($prop in $m.apps.PSObject.Properties) {
            if ($prop.Name -in $manualApps) { continue }
            $scriptPath = Join-Path $scriptsDir "update_$($prop.Name.ToLower()).ps1"
            if (-not (Test-Path $scriptPath)) { $missing.Add($prop.Name) }
        }
    } catch {}
    $Script:Results.Add((New-TestResult $svc 1 'UpdateScriptsPresent' `
        $(if ($missing.Count -eq 0) { 'PASS' } else { 'FAIL' }) `
        $(if ($missing.Count -gt 0) { "missing update scripts: $($missing -join ', ')" } else { "all manifest apps covered" })))
}

# -- Layer 2: Dry-run plan against the live manifest ---------------------------
if ($LayerFilter -eq 0 -or $LayerFilter -eq 2) {
    try {
        . (Join-Path $ProjectRoot 'scripts\update_common.ps1')
        $manifestPath = Join-Path $ProjectRoot 'versions.json'
        $manifest     = Get-Content -Raw $manifestPath | ConvertFrom-Json

        $compareManifest = Get-RemoteManifest -LocalManifest $manifest
        $remoteOk = -not ([object]::ReferenceEquals($compareManifest, $manifest))

        $plan    = @(Get-UpdatePlan -Manifest $compareManifest -InstallDir $InstallDir `
                        -ScriptsDir (Join-Path $ProjectRoot 'scripts'))
        $updates = @($plan | Where-Object { $_.State -eq 'update' })
        $manual  = @($plan | Where-Object { $_.State -eq 'manual' })
        $unknown = @($plan | Where-Object { $_.State -eq 'unknown' })

        $Script:Results.Add((New-TestResult $svc 2 'RemoteManifestReachable' `
            $(if ($remoteOk) { 'PASS' } else { 'WARN' }) `
            $(if ($remoteOk) { 'using remote manifest' } else { 'remote unreachable, using local manifest' })))
        $Script:Results.Add((New-TestResult $svc 2 'PlanBuilds' 'PASS' `
            "$($plan.Count) apps: $($updates.Count) update, $($manual.Count) manual, $($unknown.Count) unknown version"))
    } catch {
        $Script:Results.Add((New-TestResult $svc 2 'PlanBuilds' 'FAIL' $_.Exception.Message))
    }
}
