# update_bazarr.ps1
# Per-app update script: Bazarr (GitHub zip swap + pip requirements refresh).
# Bazarr runs from Python with --no-update, so a binary swap alone is not
# enough: new releases can add Python dependencies.  This script swaps the
# source tree, re-runs pip against the new requirements.txt, and only then
# restarts the service.
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

$AppName     = "Bazarr"
$ServiceName = "Bazarr"
$AppBinDir   = Join-Path $InstallDir $AppName

$installed = Get-InstalledVersion -InstallDir $InstallDir -AppName $AppName

if ($WhatIf) {
    return [PSCustomObject]@{ App = $AppName; Status = "DRYRUN"; Installed = $installed; Target = $Version; Detail = "GitHub zip swap + pip install -r requirements.txt" }
}
if (-not $installed -or $installed -ieq "unknown") {
    return [PSCustomObject]@{ App = $AppName; Status = "SKIPPED"; Installed = $installed; Target = $Version; Detail = "not installed or installed version unknown" }
}

# Locate the Python interpreter the Bazarr service was registered with.
$pythonExe = $null
try {
    $nssmApp = (& nssm get $ServiceName Application 2>$null | Out-String).Trim().Trim('"')
    if ($nssmApp -and (Test-Path $nssmApp)) { $pythonExe = $nssmApp }
} catch {}
if (-not $pythonExe) {
    foreach ($candidate in @("C:\Python312\python.exe", (Get-Command python.exe -ErrorAction SilentlyContinue).Source)) {
        if ($candidate -and (Test-Path $candidate)) { $pythonExe = $candidate; break }
    }
}

try {
    $entry   = $Config._Versions.Apps.$AppName
    $zipPath = Join-Path $BinDir "bazarr-$Version.zip"
    Invoke-GitHubReleaseDownload -Repo $entry.repo -Tag $Version -AssetPattern $entry.asset -ZipPath $zipPath

    # Stop service, backup, extract new source.
    $appBinBak = "$AppBinDir.bak"
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") { Stop-Service -Name $ServiceName -Force }
    Start-Sleep -Seconds 2
    if (Test-Path $appBinBak) { Remove-Item $appBinBak -Recurse -Force }
    if (Test-Path $AppBinDir) { Rename-Item -Path $AppBinDir -NewName "$AppName.bak" -Force }
    New-Item -Path $AppBinDir -ItemType Directory -Force | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $AppBinDir -Force
    $children = Get-ChildItem $AppBinDir
    if ($children.Count -eq 1 -and $children[0].PSIsContainer) {
        $inner = $children[0].FullName
        Get-ChildItem $inner | ForEach-Object { Move-Item $_.FullName $AppBinDir -Force }
        Remove-Item $inner -Recurse -Force
    }

    # Refresh Python dependencies against the NEW requirements.txt.
    if (-not $pythonExe) {
        Write-Warning "Python interpreter not found; skipping pip refresh (may break new Bazarr features)."
    } else {
        $reqFile = Join-Path $AppBinDir "requirements.txt"
        if (Test-Path $reqFile) {
            Write-Host "  -> Installing Python requirements..." -ForegroundColor Gray
            $savedEAP = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                $null = & $pythonExe -m pip install "webrtcvad-wheels>=2.0.10" --prefer-binary --quiet --no-warn-script-location 2>&1
                $null = & $pythonExe -m pip install -r $reqFile --prefer-binary --quiet --no-warn-script-location 2>&1
                if ($LASTEXITCODE -ne 0) { throw "pip install -r requirements.txt exited with code $LASTEXITCODE" }
            } finally {
                $ErrorActionPreference = $savedEAP
            }
        } else {
            Write-Warning "requirements.txt not found in new Bazarr source; skipping pip refresh."
        }
    }

    # Start service and health-check.
    Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 15
    $svcAfter = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svcAfter -or $svcAfter.Status -ne "Running") { throw "Bazarr service not Running after update" }

    if (Test-Path $appBinBak) { Remove-Item $appBinBak -Recurse -Force }
    Set-InstalledVersion -InstallDir $InstallDir -AppName $AppName -Version $Version
    return [PSCustomObject]@{ App = $AppName; Status = "OK"; Installed = $installed; Target = $Version; Detail = "" }
} catch {
    # Rollback: restore the previous source tree, but only when the backup
    # rename actually happened.  Failures before the backup (download,
    # service stop) leave the live directory untouched.
    $appBinBak = "$AppBinDir.bak"
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (Test-Path $appBinBak) {
        if (Test-Path $AppBinDir) { Remove-Item $AppBinDir -Recurse -Force -ErrorAction SilentlyContinue }
        Rename-Item -Path $appBinBak -NewName $AppName -Force
    }
    Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
    return [PSCustomObject]@{ App = $AppName; Status = "FAILED"; Installed = $installed; Target = $Version; Detail = $_.Exception.Message }
}
