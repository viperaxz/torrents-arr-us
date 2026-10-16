# update_deluge.ps1
# Per-app update script: Deluge (Chocolatey, restart daemon + web services).
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

$AppName     = "Deluge"
$ServiceList = @("DelugeDaemon", "DelugeWeb")

$installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $AppName

if ($WhatIf) {
    return [PSCustomObject]@{ App = $AppName; Status = "DRYRUN"; Installed = $installed; Target = $Version; Detail = "stop services + choco upgrade deluge + re-apply Web UI js fix + start services" }
}
if (-not $installed -or $installed -ieq "unknown") {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "not installed or installed version unknown" }
}

try {
    # Stop both services first: the Deluge NSIS package replaces deluged.exe /
    # deluge-web.exe, which cannot be swapped while the daemon holds the images open
    # (a silent partial upgrade would then be recorded as successful).
    foreach ($svcName in $ServiceList) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne "Stopped") {
            Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 3

    try {
        Invoke-ChocoUpgrade -Package "deluge" -Version $Version

        # The upgrade replaces the whole package tree, so re-apply the Web UI js fix
        # from 07_deluge.ps1: the package ships only deluge-all-debug.js, which leaves
        # the Web UI in debug mode and unable to list torrents.
        $debugJs = $null
        $jsRoots = @()
        $jsRoots += (Get-ChildItem "C:\Program Files" -Directory -Filter "Deluge*" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        if (Test-Path "C:\ProgramData\chocolatey\lib\deluge") { $jsRoots += "C:\ProgramData\chocolatey\lib\deluge" }
        foreach ($root in $jsRoots) {
            if (-not $root -or -not (Test-Path $root)) { continue }
            $debugJs = Get-ChildItem $root -Filter "deluge-all-debug.js" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($debugJs) { break }
        }
        if ($debugJs) {
            $normalJs = Join-Path $debugJs.DirectoryName "deluge-all.js"
            if (-not (Test-Path $normalJs)) {
                Copy-Item $debugJs.FullName $normalJs -Force
                Write-Host "  -> Re-applied Web UI fix: $normalJs" -ForegroundColor Gray
                Write-UcLog "INFO" "Re-applied deluge-all.js from deluge-all-debug.js"
            }
        } else {
            Write-Warning "deluge-all-debug.js not found -- Web UI debug-mode fix not re-applied."
            Write-UcLog "WARN" "deluge-all-debug.js not found during Deluge update"
        }
    } finally {
        # Start the services again even when the upgrade threw, so a failed update
        # does not leave Deluge down.
        foreach ($svcName in $ServiceList) {
            $svcNow = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svcNow -and $svcNow.Status -ne "Running") {
                Start-Service -Name $svcName -ErrorAction SilentlyContinue
            }
        }
    }

    Start-Sleep -Seconds 15
    foreach ($svcName in $ServiceList) {
        $svcAfter = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if (-not $svcAfter -or $svcAfter.Status -ne "Running") { throw "$svcName not Running after upgrade" }
    }

    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $Version
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = "" }
} catch {
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}
