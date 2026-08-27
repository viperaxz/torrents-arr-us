<#
.SYNOPSIS
    Layer 2 Configuration: Application Integration

.DESCRIPTION
    Configures applications to work together:
    - Sonarr/Radarr with Deluge (download client)
    - Sonarr/Radarr root folders and indexer proxies
    - Jellyfin media libraries
    - Prowlarr with Sonarr/Radarr applications

    This runs AFTER Layer 1 (install + auth/security).

.EXAMPLE
    .\master_configure_layer2.ps1
#>

$ErrorActionPreference = "Stop"

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Please run this script as an Administrator!"
    exit 1
}

$ConfigPath = Join-Path $PSScriptRoot "config.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Error "config.json not found! Copy config.json.example to config.json and edit it."
    exit 1
}

Write-Host "+======================================================================+" -ForegroundColor Cyan
Write-Host "|        WIN-SEEDBOX: LAYER 2 - APPLICATION INTEGRATION               |" -ForegroundColor Cyan
Write-Host "+======================================================================+" -ForegroundColor Cyan
Write-Host ""

Write-Host "Parsing configuration..." -ForegroundColor Cyan
$Config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

# -- Debug logging -------------------------------------------------------------
. (Join-Path $PSScriptRoot "scripts\debug_logger.ps1")
Initialize-DebugLog -Config $Config
Write-DebugLog "INFO" "master_configure_layer2.ps1 started"
Write-DebugLog "VAR DomainMode = $($Config.General.DomainMode)"
Write-DebugLog "VAR Apps: Sonarr=$($Config.Apps.Sonarr) Radarr=$($Config.Apps.Radarr) Prowlarr=$($Config.Apps.Prowlarr) Jellyfin=$($Config.Apps.Jellyfin) Bazarr=$($Config.Apps.Bazarr) Jellyseerr=$($Config.Apps.Jellyseerr)"

# -- Load versions manifest (same as master_install.ps1) --------------------------
$VersionsPath = Join-Path $PSScriptRoot "versions.json"
if (Test-Path $VersionsPath) {
    $Versions = Get-Content -Raw -Path $VersionsPath | ConvertFrom-Json
    $Config | Add-Member -MemberType NoteProperty -Name "_Versions" -Value $Versions -Force
    Write-Host "Version manifest loaded (schema $($Versions.schema), updated $($Versions.updated))." -ForegroundColor DarkGray
    Write-DebugLog "INFO" "master_configure_layer2.ps1: versions.json loaded (schema=$($Versions.schema))"
} else {
    Write-DebugLog "WARN" "versions.json not found. Layer 2 scripts that need version pinning may use latest releases."
}

$ScriptsDir = Join-Path $PSScriptRoot "scripts"
$configFailed = [System.Collections.Generic.List[string]]::new()
Write-DebugLog "VAR ScriptsDir = $ScriptsDir"

# -- Layer 2 Configuration Scripts ---------------------------------------------
$layer2Configs = @(
    # Jellyfin runs first: creates persistent API key used by Sonarr/Radarr notifications
    @{ Name = "Jellyfin";              Script = "configure_layer2_jellyfin_libraries.ps1" }
    @{ Name = "Jellyfin Transcoding"; Script = "configure_layer2_jellyfin_transcoding.ps1";
       Enabled = { $Config.Apps.Jellyfin -eq $true -and $Config.Layer2.PSObject.Properties['Jellyfin'] -and $Config.Layer2.Jellyfin.PSObject.Properties['GPU'] -and $Config.Layer2.Jellyfin.GPU } }
    @{ Name = "Recyclarr"; Script = "configure_layer2_recyclarr.ps1";
       Enabled = { $Config.Apps.Sonarr -eq $true -or $Config.Apps.Radarr -eq $true } }
    # Prowlarr runs before Sonarr/Radarr: it adds indexers and syncs them to the
    # apps, so when Sonarr/Radarr configure seed ratios the indexers already exist.
    @{ Name = "Prowlarr";       Script = "configure_layer2_prowlarr.ps1" }
    @{ Name = "Flaresolverr"; Script = "configure_layer2_flaresolverr.ps1";
       Enabled = { $Config.Apps.Flaresolverr -eq $true -and $Config.Apps.Prowlarr -eq $true } }
    @{ Name = "Sonarr";         Script = "configure_layer2_sonarr.ps1" }
    @{ Name = "Radarr";         Script = "configure_layer2_radarr.ps1" }
    @{ Name = "Bazarr";               Script = "configure_layer2_bazarr.ps1" }
    # Jellyseerr: import Jellyfin users -- requires Jellyfin to be up and Layer 1 Jellyseerr complete
    @{ Name = "Jellyseerr"; Script = "configure_layer2_jellyseerr.ps1" }
)

Write-Host ""
Write-Host "Starting Layer 2 configuration steps..." -ForegroundColor Cyan
Write-Host ""
Write-DebugLog "INFO" "=== Layer 2: $($layer2Configs.Count) steps configured ==="

foreach ($app in $layer2Configs) {
    $isEnabled = if ($app.ContainsKey('Enabled')) {
        & $app.Enabled
    } elseif ($Config.Apps.PSObject.Properties[$app.Name]) {
        $Config.Apps.$($app.Name) -eq $true
    } else {
        Write-DebugLog "WARN" "[$($app.Name)] no Enabled block and no Apps key -- did the manifest lose a custom check?"
        $false
    }
    Write-DebugLog "VAR [$($app.Name)] isEnabled = $isEnabled"
    if (-not $isEnabled) {
        Write-Host "[$($app.Name)] Skipped (disabled in config)." -ForegroundColor DarkGray
        Write-DebugLog "INFO" "[$($app.Name)] Skipped (disabled in config)"
        continue
    }

    $scriptPath = Join-Path $ScriptsDir $app.Script
    Write-DebugLog "VAR [$($app.Name)] scriptPath = $scriptPath"
    if (-not (Test-Path $scriptPath)) {
        Write-Warning "[$($app.Name)] Script not found: $scriptPath"
        Write-DebugLog "ERROR" "[$($app.Name)] Script not found: $scriptPath"
        $configFailed.Add($app.Name)
        continue
    }

    Write-Host "[$($app.Name)] Configuring application integration..." -ForegroundColor Cyan
    Write-DebugLog "INFO" "--- Starting $($app.Name) Layer 2 via $($app.Script) ---"
    try {
        $global:LASTEXITCODE = 0
        & $scriptPath -Config $Config
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "Exited with code $LASTEXITCODE"
        }
        Write-Host "[$($app.Name)] [OK] Configuration complete." -ForegroundColor Green
        Write-DebugLog "INFO" "[$($app.Name)] Layer 2 SUCCESS"
    } catch {
        Write-Warning "[$($app.Name)] Configuration FAILED: $_"
        Write-DebugLog "ERROR" "[$($app.Name)] Layer 2 FAILED: $_"
        $configFailed.Add($app.Name)
    }

    Write-Host ""
}

Write-DebugLog "INFO" "=== Layer 2 all steps done. Failed: $($configFailed -join ', ') ==="

# -- Summary -------------------------------------------------------------------
Write-Host "+======================================================================+" -ForegroundColor Cyan
Write-Host "|                      LAYER 2 SUMMARY                                |" -ForegroundColor Cyan
Write-Host "+======================================================================+" -ForegroundColor Cyan

if ($configFailed.Count -eq 0) {
    Write-Host "[OK] All Layer 2 configurations completed successfully!" -ForegroundColor Green
    Write-DebugLog "INFO" "Layer 2 complete: all steps succeeded"
} else {
    Write-Host "[WARN] Some configurations failed:" -ForegroundColor Yellow
    foreach ($app in $configFailed) {
        Write-Host "  - $app" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Check the logs above for details. You can run the script again after fixing issues." -ForegroundColor Yellow
    Write-DebugLog "WARN" "Layer 2 complete with failures: $($configFailed -join ', ')"
    exit 1
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Verify your applications are properly configured" -ForegroundColor Gray
Write-Host "  2. Check Sonarr/Radarr for download clients and root folders" -ForegroundColor Gray
Write-Host "  3. Verify Prowlarr has Sonarr/Radarr connected" -ForegroundColor Gray
Write-Host "  4. Add indexers in Prowlarr for Sonarr/Radarr to use" -ForegroundColor Gray
Write-Host ""

Write-DebugLog "INFO" "master_configure_layer2.ps1 finished"
