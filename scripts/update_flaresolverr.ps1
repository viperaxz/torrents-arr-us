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

    $port    = 8191
    $portCfg = if ($Config) { $Config.Ports } else { $null }
    if ($portCfg -and $portCfg.PSObject.Properties["Flaresolverr"]) { $port = $portCfg.Flaresolverr }
    $healthUrl = "http://127.0.0.1:$port/"

    # The HTTP gate has to run INSIDE the swap, not after it: the helper deletes
    # its .bak as soon as the services are merely Running, and NSSM keeps
    # reporting Running while it restarts a crashing process. This app serves HTTP
    # only after it has located a browser, fetched/patched chromedriver and
    # launched Chrome once (a version bump changes the bundled Chrome), so a build
    # that starts and never answers must roll back rather than be left in place
    # with the ledger untouched and nothing to restore from. Hence the 120s budget,
    # the same one the installer allows for a first start.
    $swap = Swap-AppDirectoryWithRollback -AppName $AppName -InstallDir $InstallDir `
                -ZipPath $zipPath -ServiceNames @($ServiceName) -HealthSeconds 120 `
                -HealthUrl $healthUrl
    if (-not $swap.Ok) {
        $hint = if ($swap.Detail -like "*health check failed*") { " - check C:\ProgramData\$AppName\flaresolverr-stderr.log" } else { "" }
        throw "binary swap failed: $($swap.Detail)$hint"
    }

    # The ledger is deliberately not updated on failure: the next run retries.
    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $Version
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = "API ready on :$port" }
} catch {
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}
