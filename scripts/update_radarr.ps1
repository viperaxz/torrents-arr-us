# update_radarr.ps1
# Per-app update script: Radarr (GitHub zip, full binary-directory swap).
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

$AppName     = "Radarr"
$ServiceName = "Radarr"

$installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $AppName

if ($WhatIf) {
    return [PSCustomObject]@{ App = $AppName; Status = "DRYRUN"; Installed = $installed; Target = $Version; Detail = "GitHub zip swap (service: $ServiceName)" }
}
if (-not $installed -or $installed -ieq "unknown") {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "not installed or installed version unknown" }
}

try {
    $entry   = $Config._Versions.Apps.$AppName
    $zipPath = Join-Path $BinDir "$($AppName.ToLower())-$Version.zip"
    Invoke-GitHubReleaseDownload -Repo $entry.repo -Tag $Version -AssetPattern $entry.asset -ZipPath $zipPath

    $swap = Swap-AppDirectoryWithRollback -AppName $AppName -InstallDir $InstallDir `
                -ZipPath $zipPath -ServiceNames @($ServiceName) -HealthSeconds 12
    if (-not $swap.Ok) { throw "binary swap failed: $($swap.Detail)" }

    # Swap-AppDirectoryWithRollback's fallback gate only notices a crash loop (the
    # service object keeps reporting Running while NSSM restarts a dying process),
    # so a build that starts but never serves its API would be recorded as a
    # successful update. Prove the new build answers before writing the ledger.
    # The ledger is deliberately not updated on failure: the next run retries.
    $apiKey  = $null
    $port    = if ($Config -and $Config.PSObject.Properties['Ports'] -and $Config.Ports.PSObject.Properties['Radarr']) { $Config.Ports.Radarr } else { 7878 }
    $urlBase = if ($Config -and $Config.PSObject.Properties['General'] -and $Config.General.DomainMode -eq "duckdns") { "/radarr" } else { "" }
    try {
        # config.xml is where the app actually listens and answers; prefer it over
        # config.json, which only says what the install was supposed to set.
        $radarrCfg = [xml](Get-Content -Path "C:\ProgramData\$AppName\config.xml" -Encoding UTF8 -ErrorAction Stop)
        $apiKey = $radarrCfg.Config.ApiKey
        if ($radarrCfg.Config.Port) { $port = [int]$radarrCfg.Config.Port }
        $urlBase = [string]$radarrCfg.Config.UrlBase
    } catch {
        Write-DebugLog "WARN" "could not read $AppName config.xml for the health probe: $_"
    }

    if ($apiKey) {
        $statusUrl = "http://127.0.0.1:$port$urlBase/api/v3/system/status"
        Write-DebugLog "INFO" "Health gate: GET $statusUrl (budget 120s)"
        $ready    = $false
        $deadline = (Get-Date).AddSeconds(120)
        while (-not $ready -and (Get-Date) -lt $deadline) {
            try {
                Invoke-RestMethod -Uri $statusUrl -Headers @{"X-Api-Key" = $apiKey} `
                    -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop | Out-Null
                $ready = $true
            } catch { Start-Sleep -Seconds 5 }
        }
        if (-not $ready) {
            throw "swapped to $Version but $statusUrl never answered within 120s - check C:\ProgramData\$AppName\logs\radarr.txt"
        }
        Write-DebugLog "INFO" "Health gate passed: $statusUrl answered"
    } else {
        Write-DebugLog "WARN" "no API key; relying on the service-state gate only"
    }

    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $Version
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = "" }
} catch {
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}
