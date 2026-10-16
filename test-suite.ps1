# test-suite.ps1 -- modular test runner for the win-seedbox stack
#
# Usage:
#   .\test-suite.ps1                          # all services, all layers
#   .\test-suite.ps1 -Service Sonarr          # one service, all layers
#   .\test-suite.ps1 -Service Sonarr -Layer 2 # one service, one layer
#   .\test-suite.ps1 -Quick                   # L1 only across all services
#
# Results are written to <InstallDir>\dashboard\test_results.json
# and pushed to Loki when Apps.Grafana = true.

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
$resultJson = Join-Path $InstallDir 'dashboard\test_results.json'
Export-TestResults -Results $Script:Results.ToArray() -OutputPath $resultJson -StartTime $StartTime

if ($Script:LokiEnabled) {
    Push-TestResultsToLoki -Results $Script:Results.ToArray()
}

Write-TestSummary -Results $Script:Results.ToArray()
