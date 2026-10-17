# update_prowlarr.ps1
# Per-app update script: Prowlarr (GitHub zip, full binary-directory swap).
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

$AppName     = "Prowlarr"
$ServiceName = "Prowlarr"

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

    # Where the app actually listens and answers: prefer its own config.xml over
    # config.json, which only says what the install was supposed to set.
    $apiKey  = $null
    $port    = if ($Config -and $Config.PSObject.Properties['Ports'] -and $Config.Ports.PSObject.Properties['Prowlarr']) { [int]$Config.Ports.Prowlarr } else { 9696 }
    $urlBase = if ($Config -and $Config.PSObject.Properties['General'] -and $Config.General.DomainMode -eq "duckdns") { "/prowlarr" } else { "" }
    $cfgXmlPath = "C:\ProgramData\$AppName\config.xml"
    try {
        $prowlarrCfg = [xml](Get-Content -Path $cfgXmlPath -Encoding UTF8 -ErrorAction Stop)
        $apiKey  = $prowlarrCfg.Config.ApiKey
        if ($prowlarrCfg.Config.Port) { $port = [int]$prowlarrCfg.Config.Port }
        $urlBase = [string]$prowlarrCfg.Config.UrlBase
    } catch {
        Write-DebugLog "WARN" "could not read $cfgXmlPath for the health probe: $_"
    }

    # Probe the API port, not just the service state: NSSM keeps reporting Running
    # while it restarts a crashing process, and the process-id fallback inside the
    # helper watches the NSSM supervisor -- which survives a Prowlarr.exe crash loop
    # untouched. A TCP probe only succeeds once the new build is actually listening.
    $swapArgs = @{
        AppName       = $AppName
        InstallDir    = $InstallDir
        ZipPath       = $zipPath
        ServiceNames  = @($ServiceName)
        HealthSeconds = 12
    }
    if ($port -gt 0) {
        $swapArgs["HealthPort"]    = $port
        $swapArgs["HealthSeconds"] = 30
    }
    $swap = Swap-AppDirectoryWithRollback @swapArgs
    if (-not $swap.Ok) { throw "binary swap failed: $($swap.Detail)" }

    # The port probe only proves something is listening, so prove the new build
    # serves its API before writing the ledger: a build that listens but answers
    # 500, or that dies after binding, would otherwise be recorded as a successful
    # update. The ledger is deliberately not updated on failure -- the next run
    # retries.
    if ($apiKey) {
        $statusUrl = "http://127.0.0.1:$port$urlBase/api/v1/system/status"
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
            throw "swapped to $Version but $statusUrl never answered within 120s - check C:\ProgramData\$AppName\logs\prowlarr.txt"
        }
        Write-DebugLog "INFO" "Health gate passed: $statusUrl answered"
    } else {
        Write-Warning "Cannot confirm $AppName serves its API after the swap: no API key in $cfgXmlPath. Ledger update skipped."
        throw "swapped to $Version but the API could not be verified (no API key in $cfgXmlPath)"
    }

    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $Version
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = "" }
} catch {
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}
