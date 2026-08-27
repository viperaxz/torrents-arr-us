# update_grafana.ps1
# Per-app update script: Grafana (pinned stable version from dl.grafana.com).
# Grafana binaries live in <InstallDir>\Grafana; data is in a separate directory
# (<InstallDir>\Grafana-data), so a full binary-directory swap is safe.
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

$AppName     = "Grafana"
$ServiceName = "Grafana"

$installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $AppName

if ($WhatIf) {
    return [PSCustomObject]@{ App = $AppName; Status = "DRYRUN"; Installed = $installed; Target = $Version; Detail = "download grafana-$Version.windows-amd64.zip + swap" }
}
if (-not $installed -or $installed -ieq "unknown") {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "not installed or installed version unknown" }
}

try {
    $zipPath = Join-Path $BinDir "grafana-$Version.windows-amd64.zip"
    if (-not (Test-Path $zipPath)) {
        $url = "https://dl.grafana.com/oss/release/grafana-$Version.windows-amd64.zip"
        Write-Host "  -> Downloading $url ..." -ForegroundColor Gray
        Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
    }

    $swap = Swap-AppDirectoryWithRollback -AppName $AppName -InstallDir $InstallDir `
                -ZipPath $zipPath -ServiceNames @($ServiceName) -HealthSeconds 25
    if (-not $swap.Ok) { throw "binary swap failed: $($swap.Detail)" }

    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $Version
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = "" }
} catch {
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}
