# update_sonarr.ps1
# Per-app update script: Sonarr (GitHub zip, full binary-directory swap).
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

$AppName     = "Sonarr"
$ServiceName = "Sonarr"

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

    # -- Normalise a legacy nested install layout -------------------------------
    # The Sonarr release zip contains a single top-level "Sonarr" folder and the
    # swap helper flattens it, so the binaries end up in <InstallDir>\Sonarr\. Older
    # installs (03_sonarr.ps1 used to extract the archive as-is) live in
    # <InstallDir>\Sonarr\Sonarr\ and NSSM is registered against that exe. Swapping
    # without fixing this leaves NSSM pointing at a path that no longer exists, so
    # the new build never starts. Flatten the directory BEFORE the swap: the swap's
    # own rollback then restores a directory the registered path still matches.
    $appDir  = Join-Path $InstallDir $AppName
    $flatExe = Join-Path $appDir "$AppName.exe"
    if ((Test-Path $appDir) -and -not (Test-Path $flatExe)) {
        $nestedExe = Get-ChildItem -Path $appDir -Recurse -Filter "$AppName.exe" -ErrorAction SilentlyContinue |
                        Select-Object -First 1
        if ($nestedExe -and $nestedExe.DirectoryName -ne $appDir) {
            $nssmExe = (Get-Command nssm.exe -ErrorAction SilentlyContinue).Source
            if (-not $nssmExe) { $nssmExe = "C:\ProgramData\chocolatey\bin\nssm.exe" }
            if (-not (Test-Path $nssmExe)) {
                throw "nssm.exe not found: cannot re-point the $ServiceName service after flattening '$appDir'"
            }
            Write-DebugLog "INFO" "Normalising legacy nested layout: $($nestedExe.DirectoryName) -> $appDir"
            $wasRunning = $false
            $svcNow = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            if ($svcNow -and $svcNow.Status -eq "Running") { $wasRunning = $true }
            try {
                if ($svcNow -and $svcNow.Status -ne "Stopped") {
                    Stop-Service -Name $ServiceName -Force -ErrorAction Stop
                    $stopDeadline = (Get-Date).AddSeconds(60)
                    do {
                        Start-Sleep -Seconds 1
                        $svcNow = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
                    } while ($svcNow -and $svcNow.Status -ne "Stopped" -and (Get-Date) -lt $stopDeadline)
                }
                Get-ChildItem -Path $nestedExe.DirectoryName -Force |
                    ForEach-Object { Move-Item -Path $_.FullName -Destination $appDir -Force -ErrorAction Stop }
                Remove-Item -Path $nestedExe.DirectoryName -Recurse -Force -ErrorAction SilentlyContinue
                & $nssmExe set $ServiceName Application $flatExe | Out-Null
                & $nssmExe set $ServiceName AppDirectory $appDir | Out-Null
                Write-DebugLog "INFO" "Legacy layout normalised; NSSM application is now $flatExe"
            } catch {
                if ($wasRunning) { Start-Service -Name $ServiceName -ErrorAction SilentlyContinue }
                throw "could not normalise the legacy nested install layout in '$appDir': $_"
            }
        }
    }

    # Probe the API port, not just the service state: NSSM keeps reporting Running
    # while it restarts a crashing process, and the process-id fallback inside the
    # helper watches the NSSM supervisor -- which survives a Sonarr.exe crash loop
    # untouched. A TCP probe only succeeds once the new build is actually listening.
    $healthPort = 0
    if ($Config -and $Config.PSObject.Properties['Ports'] -and $Config.Ports.Sonarr) {
        $healthPort = [int]$Config.Ports.Sonarr
    }
    $swapArgs = @{
        AppName      = $AppName
        InstallDir   = $InstallDir
        ZipPath      = $zipPath
        ServiceNames = @($ServiceName)
        HealthSeconds = 12
    }
    if ($healthPort -gt 0) {
        # 60s: a database migration on a large sonarr.db can outlast a token wait,
        # and a premature timeout would roll a good build back.
        $swapArgs["HealthPort"]    = $healthPort
        $swapArgs["HealthSeconds"] = 60
    }
    $swap = Swap-AppDirectoryWithRollback @swapArgs
    if (-not $swap.Ok) { throw "binary swap failed: $($swap.Detail)" }

    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $Version
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = "" }
} catch {
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}
