# update_flaresolverr.ps1
# Per-app update script: FlareSolverr (GitHub zip, full binary-directory swap).
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

$AppName     = "Flaresolverr"
$ServiceName = "Flaresolverr"

$installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $AppName

if ($WhatIf) {
    return [PSCustomObject]@{ App = $AppName; Status = "DRYRUN"; Installed = $installed; Target = $Version; Detail = "GitHub zip swap (service: $ServiceName)" }
}
if (-not $installed -or $installed -ieq "unknown") {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "not installed or installed version unknown" }
}

try {
    $entry   = $Config._Versions.Apps.$AppName
    $zipPath = Join-Path $BinDir "flaresolverr-$Version.zip"
    Invoke-GitHubReleaseDownload -Repo $entry.repo -Tag $Version -AssetPattern $entry.asset -ZipPath $zipPath

    $swap = Swap-AppDirectoryWithRollback -AppName $AppName -InstallDir $InstallDir `
                -ZipPath $zipPath -ServiceNames @($ServiceName) -HealthSeconds 15
    if (-not $swap.Ok) { throw "binary swap failed: $($swap.Detail)" }

    # Swap-AppDirectoryWithRollback only proves the service object is Running, and
    # NSSM keeps reporting Running while it restarts a crashing process. This app
    # serves HTTP only after it has located a browser, launched Chrome once and
    # (on a version bump, which changes the bundled Chrome) downloaded a matching
    # chromedriver, so prove the new build answers before recording it. The ledger
    # is deliberately not updated on failure: the next run retries the swap.
    $port    = 8191
    $portCfg = if ($Config) { $Config.Ports } else { $null }
    if ($portCfg -and $portCfg.PSObject.Properties["Flaresolverr"]) { $port = $portCfg.Flaresolverr }

    $ready    = $false
    $deadline = (Get-Date).AddSeconds(120)
    while (-not $ready -and (Get-Date) -lt $deadline) {
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:$port/" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop | Out-Null
            $ready = $true
        } catch { Start-Sleep -Seconds 5 }
    }
    if (-not $ready) {
        throw "swapped to $Version but http://127.0.0.1:$port/ never answered within 120s - check C:\ProgramData\$AppName\flaresolverr-stderr.log"
    }

    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $Version
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = "API ready on :$port" }
} catch {
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}
