# test-suite.ps1 -- modular test runner for the win-seedbox stack
#
# Usage:
#   .\test-suite.ps1                          # all services, all layers
#   .\test-suite.ps1 -Service Sonarr          # one service, all layers
#   .\test-suite.ps1 -Service Sonarr -Layer 2 # one service, one layer
#   .\test-suite.ps1 -Quick                   # L1 only across all services
#
# Results are pushed to Loki when Apps.Grafana = true (works unelevated) and also
# exported to <InstallDir>\dashboard\test_results.json. That directory is
# administrator-only (README: "Install directory permissions"), so run this from
# an elevated prompt when you want the JSON export -- an unelevated run still
# reports to the console and to Loki and prints the grant command instead.

param(
    [string]$Service = '',
    [int]$Layer      = 0,
    [switch]$Quick
)

$ErrorActionPreference = 'Continue'

# -- Bootstrap -----------------------------------------------------------------
$configPath = Join-Path $PSScriptRoot 'config.json'
if (-not (Test-Path $configPath)) {
    Write-Error "config.json not found at $configPath"
    exit 1
}
$Config     = Get-Content $configPath -Raw | ConvertFrom-Json
$InstallDir = $Config.General.InstallDir

. (Join-Path $PSScriptRoot 'tests\Helpers.ps1')

$Script:Results     = [System.Collections.Generic.List[object]]::new()
$Script:LokiEnabled = ($Config.Apps.Grafana -eq $true)
$LayerFilter        = if ($Quick) { 1 } elseif ($Layer -gt 0) { $Layer } else { 0 }
$StartTime          = Get-Date

# -- Module map (name -> file) -------------------------------------------------
$modules = [ordered]@{
    'Caddy'        = 'Test-Caddy.ps1'
    'Jellyfin'     = 'Test-Jellyfin.ps1'
    'Sonarr'       = 'Test-Sonarr.ps1'
    'Radarr'       = 'Test-Radarr.ps1'
    'Prowlarr'     = 'Test-Prowlarr.ps1'
    'Deluge'        = 'Test-Deluge.ps1'
    'Bazarr'       = 'Test-Bazarr.ps1'
    'Flaresolverr' = 'Test-Flaresolverr.ps1'
    'Jellyseerr'   = 'Test-Jellyseerr.ps1'
    'Security'     = 'Test-Security.ps1'
    'Grafana'      = 'Test-Grafana.ps1'
    'RealDebrid'   = 'Test-RealDebrid.ps1'
    'Update'       = 'Test-Update.ps1'
}

# -- Run selected modules -------------------------------------------------------
$testsDir = Join-Path $PSScriptRoot 'tests'

# Fail fast on a typo'd -Service instead of running zero modules and reporting
# a green PASS:0 summary.
if ($Service) {
    $matched = @($modules.Keys | Where-Object { $_ -ieq $Service })
    if ($matched.Count -eq 0) {
        Write-Error "Unknown -Service '$Service'. Valid values: $($modules.Keys -join ', ')"
        exit 1
    }
    $Service = $matched[0]
}

foreach ($key in $modules.Keys) {
    if ($Service -and $key -ne $Service) { continue }
    $modPath = Join-Path $testsDir $modules[$key]
    if (-not (Test-Path $modPath)) {
        Write-Host "  [SKIP] $key -- module not found: $modPath" -ForegroundColor DarkGray
        continue
    }
    try {
        . $modPath -LayerFilter $LayerFilter
    } catch {
        $Script:Results.Add((New-TestResult $key 0 'ModuleError' 'FAIL' $_.Exception.Message))
    }
}

# -- Output --------------------------------------------------------------------
# Push before the JSON export so the export can record whether Loki accepted the
# results: an empty Grafana panel is otherwise indistinguishable from a suite that
# never ran.
$lokiPush = 'skipped (Apps.Grafana is not true)'
if ($Script:LokiEnabled) {
    $pushRes  = Push-TestResultsToLoki -Results $Script:Results.ToArray()
    $lokiPush = if ($pushRes.ok) { 'ok' } else { 'failed: ' + $pushRes.error }
    if (-not $pushRes.ok) {
        Write-Warning "Could not push results to Loki: $($pushRes.error)"
        Write-Host "  The Grafana 'Test Suite Results' dashboard will not show this run." -ForegroundColor DarkGray
    }
}

$resultJson = Join-Path $InstallDir 'dashboard\test_results.json'
try {
    Export-TestResults -Results $Script:Results.ToArray() -OutputPath $resultJson -StartTime $StartTime -LokiPush $lokiPush
} catch {
    # <InstallDir> is administrator-only, so an unelevated run cannot drop the
    # JSON next to the dashboard.  The console summary and the Loki/Grafana push
    # above are unaffected -- say so, and print the same grant command the
    # installer prints so the operator can restore the export deliberately.
    $dashboardDir = Split-Path -Parent $resultJson
    Write-Warning "Could not write $resultJson : $($_.Exception.Message)"
    Write-Host "  <InstallDir> is administrator-only (see README: 'Install directory permissions')." -ForegroundColor DarkGray
    Write-Host "  Run this script from an elevated prompt, or grant write access to just the dashboard directory:" -ForegroundColor DarkGray
    Write-Host "    icacls `"$dashboardDir`" /grant `"$env:USERDOMAIN\${env:USERNAME}:(OI)(CI)(M)`"" -ForegroundColor DarkGray
    Write-Host "  (Granting the whole install tree instead would also expose the service binaries and secrets\ to that account.)" -ForegroundColor DarkGray
}

if ($lokiPush -notin @('ok', 'skipped (Apps.Grafana is not true)')) {
    Write-Host "  Results were NOT published to Grafana (loki_push = $lokiPush)." -ForegroundColor Yellow
}

Write-TestSummary -Results $Script:Results.ToArray()
