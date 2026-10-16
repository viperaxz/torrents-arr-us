# update_caddy.ps1
# Per-app update script: Caddy (Chocolatey + config reload).
# The Caddyfile, CrowdSec integration, cert cache, and DNS updater tasks live
# outside the choco package, so a plain upgrade is safe: the existing Caddyfile
# stays valid across Caddy minor/patch bumps.  We reload it and health-check the
# service afterwards.
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [Parameter(Mandatory = $true)][string]$BinDir,
    [object]$Config,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "update_common.ps1")
$Config = Initialize-UpdateScript -Config $Config

$AppName = "Caddy"

$installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $AppName

if ($WhatIf) {
    return [PSCustomObject]@{ App = $AppName; Status = "DRYRUN"; Installed = $installed; Target = $Version; Detail = "choco upgrade caddy + reload config" }
}
if (-not $installed -or $installed -ieq "unknown") {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "not installed or installed version unknown" }
}

try {
    Invoke-ChocoUpgrade -Package "caddy" -Version $Version

    $caddyExe = (Get-Command caddy.exe -ErrorAction SilentlyContinue).Source
    if (-not $caddyExe) { throw "caddy.exe not found in PATH after upgrade" }

    # Reload the existing Caddyfile (untouched by choco).
    $caddyfile = Join-Path $InstallDir "Caddy\Caddyfile"
    if (-not (Test-Path $caddyfile)) {
        throw "Caddyfile not found at $caddyfile -- re-run .\master_install.ps1 to regenerate it"
    }

    # caddy writes JSON logs to stderr even on success; suppress safely.
    try { & $caddyExe reload --config $caddyfile 2>&1 | Out-Null } catch {}
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "caddy reload failed (exit $LASTEXITCODE); restarting service instead."
        Restart-Service -Name "Caddy" -Force
    }

    Start-Sleep -Seconds 5
    $svcAfter = Get-Service -Name "Caddy" -ErrorAction SilentlyContinue
    if (-not $svcAfter -or $svcAfter.Status -ne "Running") { throw "Caddy service not Running after upgrade" }

    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $Version
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = "" }
} catch {
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}
